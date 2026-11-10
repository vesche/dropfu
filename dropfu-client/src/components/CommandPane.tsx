import { createSignal, createEffect, onCleanup, For, onMount, Show } from "solid-js";
import { buildCommand, buildShellData, buildShellClose, buildFileChunk } from "../lib/protocol";
import { parseCommand } from "../lib/commandLine";
import { send, onMessage, status, waitForMessage } from "../lib/ws";
import {
  state, pushOutput, bindRequest, completeRequest, setPaneShell, setPaneAgent, clearPaneOutput,
} from "../state/session";
import { formatHelp } from "../lib/commands";
import styles from "./CommandPane.module.css";

interface Props {
  paneId: string;
  isActive: boolean;
  onFocus: () => void;
}

const HISTORY_MAX = 200;

export default function CommandPane(props: Props) {
  let outputRef!: HTMLDivElement;
  let inputRef!: HTMLInputElement;

  const [shellMode, setShellMode] = createSignal(false);
  const [shellSessionId, setShellSessionId] = createSignal<string | null>(null);
  const [history, setHistory] = createSignal<string[]>([]);
  const [histIdx, setHistIdx] = createSignal(-1);
  const [stickBottom, setStickBottom] = createSignal(true);
  const pending = () => state.panes[props.paneId]?.pendingRequestIds.length ?? 0;

  const outputs = () => state.outputs[props.paneId] ?? [];

  const selectedAgent = () => {
    const paneAgent = state.panes[props.paneId]?.agentId ?? state.selectedAgentId;
    if (!paneAgent) return null;
    return state.agents.find((a) => a.agent_id === paneAgent) ?? null;
  };

  const prompt = () => selectedAgent()?.hostname ?? "no-agent";

  createEffect(() => {
    const len = outputs().length;
    if (len > 0 && stickBottom() && outputRef) {
      requestAnimationFrame(() => {
        outputRef.scrollTop = outputRef.scrollHeight;
      });
    }
  });

  createEffect(() => {
    if (props.isActive && inputRef) inputRef.focus();
  });

  createEffect(() => {
    // Bind pane to currently selected agent when focused and no shell active.
    if (props.isActive && !shellMode() && state.selectedAgentId) {
      setPaneAgent(props.paneId, state.selectedAgentId);
    }
  });

  onMount(() => {
    const unsub = onMessage((msg) => {
      if (msg.type === "shell_data" && msg.id === shellSessionId()) {
        if (msg.payload.eof) {
          const sid = shellSessionId();
          const agentId = state.panes[props.paneId]?.agentId ?? state.selectedAgentId;
          // The process is already gone. Tell the agent to drop the session;
          // otherwise the next `shell` is refused as still active.
          if (sid && agentId) send(buildShellClose(sid, agentId));
          if (sid) completeRequest(sid);
          setShellMode(false);
          setShellSessionId(null);
          setPaneShell(props.paneId, null);
        }
      }
      if (msg.id === shellSessionId() &&
          (msg.type === "error" || (msg.type === "result" && msg.payload.status !== "success"))) {
        setShellMode(false);
        setShellSessionId(null);
        setPaneShell(props.paneId, null);
      }
    });
    onCleanup(unsub);
  });

  function onScroll() {
    if (!outputRef) return;
    const nearBottom = outputRef.scrollHeight - outputRef.scrollTop - outputRef.clientHeight < 48;
    setStickBottom(nearBottom);
  }

  function pushHistory(cmd: string) {
    setHistory((h) => {
      const next = [...h.filter((x) => x !== cmd), cmd];
      return next.slice(-HISTORY_MAX);
    });
    setHistIdx(-1);
  }

  async function handleUpload(destPath: string) {
    const agentId = state.panes[props.paneId]?.agentId ?? state.selectedAgentId;
    if (!agentId) {
      pushOutput(props.paneId, { kind: "error", text: "no agent selected", ts: Date.now() / 1000 });
      return;
    }
    const input = document.createElement("input");
    input.type = "file";
    input.onchange = async () => {
      const file = input.files?.[0];
      if (!file) return;
      if (file.size > 100 * 1024 * 1024) {
        pushOutput(props.paneId, { kind: "error", text: "file exceeds 100 MiB transfer limit", ts: Date.now() / 1000 });
        return;
      }
      const start = buildCommand(agentId, "upload", [destPath, String(file.size)]);
      bindRequest(start.id, props.paneId);
      if (!send(start)) {
        completeRequest(start.id);
        pushOutput(props.paneId, { kind: "error", text: "not connected", ts: Date.now() / 1000 });
        return;
      }
      const readyPromise = waitForMessage(
        (msg) => msg.id === start.id && (msg.type === "result" || msg.type === "error"),
      );
      pushOutput(props.paneId, {
        kind: "info",
        text: `[file] uploading ${file.name} (${file.size} bytes) → ${destPath}`,
        ts: Date.now() / 1000,
      });

      const buf = new Uint8Array(await file.arrayBuffer());
      const CHUNK = 48_000;
      let offset = 0;
      let ready;
      try {
        ready = await readyPromise;
      } catch (error) {
        completeRequest(start.id);
        pushOutput(props.paneId, {
          kind: "error",
          text: `upload failed: ${error instanceof Error ? error.message : "no ready response"}`,
          ts: Date.now() / 1000,
        });
        return;
      }
      if (ready.type !== "result" || ready.payload.status !== "success" || ready.payload.data !== "ready for upload") {
        completeRequest(start.id);
        return;
      }

      // The ready result completes the command request. Rebind the same transfer
      // id so the final file acknowledgement returns to this pane.
      bindRequest(start.id, props.paneId);
      while (offset < buf.length || buf.length === 0) {
        const end = Math.min(offset + CHUNK, buf.length);
        const slice = buf.subarray(offset, end);
        let binary = "";
        for (let i = 0; i < slice.length; i++) binary += String.fromCharCode(slice[i]!);
        const b64 = btoa(binary);
        const final = end >= buf.length;
        const chunk = buildFileChunk(start.id, agentId, offset, b64, final);
        if (!send(chunk)) {
          completeRequest(start.id);
          pushOutput(props.paneId, { kind: "error", text: "upload interrupted — disconnected", ts: Date.now() / 1000 });
          return;
        }
        offset = end;
        if (final || buf.length === 0) break;
      }
    };
    input.click();
  }

  function handleSubmit(e: Event) {
    e.preventDefault();
    const value = inputRef.value.trim();
    if (!value) return;
    inputRef.value = "";

    if (shellMode()) {
      const agentId = state.panes[props.paneId]?.agentId ?? state.selectedAgentId;
      const sid = shellSessionId();
      if (agentId && sid) {
        if (value === "exit") {
          send(buildShellClose(sid, agentId));
          completeRequest(sid);
          setShellMode(false);
          setShellSessionId(null);
          setPaneShell(props.paneId, null);
          pushOutput(props.paneId, { kind: "info", text: "[leaving shell mode]", ts: Date.now() / 1000 });
          return;
        }
        if (!send(buildShellData(sid, agentId, value + "\n"))) {
          pushOutput(props.paneId, { kind: "error", text: "not connected", ts: Date.now() / 1000 });
          return;
        }
        pushOutput(props.paneId, { kind: "cmd", text: value, ts: Date.now() / 1000 });
      }
      return;
    }

    pushHistory(value);
    pushOutput(props.paneId, { kind: "cmd", text: `${prompt()}> ${value}`, ts: Date.now() / 1000 });

    let parts: string[];
    try {
      parts = parseCommand(value);
    } catch (error) {
      pushOutput(props.paneId, {
        kind: "error",
        text: error instanceof Error ? error.message : "invalid command",
        ts: Date.now() / 1000,
      });
      return;
    }
    const cmd = parts[0]!;
    const args = parts.slice(1);

    if (cmd === "help") {
      pushOutput(props.paneId, { kind: "result", text: formatHelp(), ts: Date.now() / 1000 });
      return;
    }
    if (cmd === "clear") {
      clearPaneOutput(props.paneId);
      return;
    }

    const agentId = state.panes[props.paneId]?.agentId ?? state.selectedAgentId;
    if (!agentId) {
      pushOutput(props.paneId, { kind: "error", text: "no agent selected", ts: Date.now() / 1000 });
      return;
    }

    if (status() !== "connected") {
      pushOutput(props.paneId, { kind: "error", text: "not connected to server", ts: Date.now() / 1000 });
      return;
    }

    if (cmd === "seppuku") {
      const confirm = window.confirm("Self-destruct this agent? This cannot be undone.");
      if (!confirm) {
        pushOutput(props.paneId, { kind: "info", text: "seppuku cancelled", ts: Date.now() / 1000 });
        return;
      }
    }

    if (cmd === "upload") {
      const dest = args[0] ?? "upload.bin";
      void handleUpload(dest);
      return;
    }

    if (cmd === "shell") {
      setShellMode(true);
      pushOutput(props.paneId, {
        kind: "info",
        text: "[entering shell mode — type 'exit' to leave]",
        ts: Date.now() / 1000,
      });
    }

    const envelope = buildCommand(agentId, cmd, args);
    bindRequest(envelope.id, props.paneId);
    setPaneAgent(props.paneId, agentId);

    if (cmd === "shell") {
      setShellSessionId(envelope.id);
      setPaneShell(props.paneId, envelope.id);
    }

    if (!send(envelope)) {
      completeRequest(envelope.id);
      pushOutput(props.paneId, { kind: "error", text: "failed to send — disconnected", ts: Date.now() / 1000 });
      return;
    }
  }

  function handleKeyDown(e: KeyboardEvent) {
    if (e.shiftKey && ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Delete", "Backspace"].includes(e.key)) {
      return;
    }
    if (e.key === "ArrowUp") {
      e.preventDefault();
      const h = history();
      if (!h.length) return;
      const next = histIdx() < 0 ? h.length - 1 : Math.max(0, histIdx() - 1);
      setHistIdx(next);
      inputRef.value = h[next] ?? "";
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      const h = history();
      if (histIdx() < 0) return;
      const next = histIdx() + 1;
      if (next >= h.length) {
        setHistIdx(-1);
        inputRef.value = "";
      } else {
        setHistIdx(next);
        inputRef.value = h[next] ?? "";
      }
    }
  }

  function lineClass(kind: string): string {
    switch (kind) {
      case "cmd": return styles.lineCmd;
      case "error": return styles.lineError;
      case "info": return styles.lineInfo;
      case "shell": return styles.lineShell;
      default: return styles.lineResult;
    }
  }

  // Visible window for virtualization-lite: last N lines rendered fully;
  // older content collapsed into a summary when very large.
  const visibleLines = () => {
    const lines = outputs().filter((l) => l.kind !== "clear");
    const max = 2000;
    if (lines.length <= max) return { skipped: 0, lines };
    return { skipped: lines.length - max, lines: lines.slice(-max) };
  };

  return (
    <div
      class={styles.pane}
      classList={{ [styles.active]: props.isActive }}
      onClick={props.onFocus}
      role="region"
      aria-label={`Command pane ${props.paneId}`}
    >
      <div
        class={styles.output}
        ref={outputRef}
        onScroll={onScroll}
        role="log"
        aria-live="polite"
        aria-relevant="additions"
      >
        <Show when={visibleLines().skipped > 0}>
          <div class={styles.lineInfo}>
            <pre>… {visibleLines().skipped} earlier lines truncated …</pre>
          </div>
        </Show>
        <For each={visibleLines().lines}>
          {(line) => (
            <div class={lineClass(line.kind)}>
              <pre>{line.text}</pre>
            </div>
          )}
        </For>
        <Show when={!stickBottom()}>
          <button
            class={styles.jumpBottom}
            onClick={() => {
              setStickBottom(true);
              if (outputRef) outputRef.scrollTop = outputRef.scrollHeight;
            }}
          >
            ↓ new output
          </button>
        </Show>
      </div>
      <form class={styles.inputRow} onSubmit={handleSubmit}>
        <span class={styles.prompt} aria-hidden="true">
          {shellMode() ? `${prompt()} (shell)>` : `${prompt()}>`}
          {pending() > 0 ? ` [${pending()}]` : ""}
        </span>
        <input
          id={`input-${props.paneId}`}
          ref={inputRef}
          class={styles.input}
          type="text"
          autofocus={props.isActive}
          onKeyDown={handleKeyDown}
          spellcheck={false}
          autocomplete="off"
          aria-label="Command input"
        />
      </form>
    </div>
  );
}
