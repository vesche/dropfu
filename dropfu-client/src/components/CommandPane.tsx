import { createSignal, createEffect, onCleanup, For, onMount } from "solid-js";
import { buildCommand, buildShellData } from "../lib/protocol";
import { send, onMessage } from "../lib/ws";
import { state, pushOutput, type OutputLine } from "../App";
import { formatHelp } from "../lib/commands";
import styles from "./CommandPane.module.css";

interface Props {
  paneId: string;
  isActive: boolean;
  onFocus: () => void;
}

export default function CommandPane(props: Props) {
  let outputRef!: HTMLDivElement;
  let inputRef!: HTMLInputElement;

  const [shellMode, setShellMode] = createSignal(false);
  const [shellSessionId, setShellSessionId] = createSignal<string | null>(null);

  const outputs = (): OutputLine[] => state.outputs[props.paneId] ?? [];

  const segments = (): OutputLine[][] => {
    const lines = outputs();
    const result: OutputLine[][] = [[]];
    for (const line of lines) {
      if (line.kind === "clear") {
        result.push([]);
      } else {
        result[result.length - 1].push(line);
      }
    }
    return result;
  };

  const selectedAgent = () => {
    if (!state.selectedAgentId) return null;
    return state.agents.find((a) => a.agent_id === state.selectedAgentId) ?? null;
  };

  const prompt = () => {
    const agent = selectedAgent();
    if (!agent) return "no-agent";
    return agent.hostname;
  };

  createEffect(() => {
    const len = outputs().length;
    if (len > 0) {
      requestAnimationFrame(() => {
        if (outputRef) outputRef.scrollTop = outputRef.scrollHeight;
      });
    }
  });

  createEffect(() => {
    if (props.isActive && inputRef) {
      inputRef.focus();
    }
  });

  onMount(() => {
    const unsub = onMessage((msg) => {
      if (msg.type === "shell_data" && msg.id === shellSessionId()) {
        if (msg.payload.eof) {
          setShellMode(false);
          setShellSessionId(null);
          pushOutput(props.paneId, { kind: "info", text: "[shell closed]", ts: Date.now() / 1000 });
        }
      }
    });
    onCleanup(unsub);
  });

  function handleSubmit(e: Event) {
    e.preventDefault();
    const value = inputRef.value.trim();
    if (!value) return;
    inputRef.value = "";

    if (shellMode()) {
      const agentId = state.selectedAgentId;
      const sid = shellSessionId();
      if (agentId && sid) {
        send(buildShellData(sid, agentId, value + "\n"));
        pushOutput(props.paneId, { kind: "cmd", text: value, ts: Date.now() / 1000 });
      }
      return;
    }

    pushOutput(props.paneId, { kind: "cmd", text: `${prompt()}> ${value}`, ts: Date.now() / 1000 });

    const parts = parseCommand(value);
    const cmd = parts[0];
    const args = parts.slice(1);

    if (cmd === "help") {
      pushOutput(props.paneId, { kind: "result", text: formatHelp(), ts: Date.now() / 1000 });
      return;
    }

    if (!state.selectedAgentId) {
      pushOutput(props.paneId, { kind: "error", text: "no agent selected", ts: Date.now() / 1000 });
      return;
    }

    if (cmd === "shell") {
      setShellMode(true);
      pushOutput(props.paneId, { kind: "info", text: "[entering shell mode — type 'exit' to leave]", ts: Date.now() / 1000 });
    }

    const envelope = buildCommand(state.selectedAgentId, cmd, args);

    if (cmd === "shell") {
      setShellSessionId(envelope.id);
    }

    send(envelope);
  }

  function handleKeyDown(e: KeyboardEvent) {
    if (e.shiftKey && ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(e.key)) {
      return;
    }
  }

  function parseCommand(input: string): string[] {
    const result: string[] = [];
    let current = "";
    let inQuote = false;
    let quoteChar = "";

    for (const ch of input) {
      if (inQuote) {
        if (ch === quoteChar) {
          inQuote = false;
        } else {
          current += ch;
        }
      } else if (ch === '"' || ch === "'") {
        inQuote = true;
        quoteChar = ch;
      } else if (ch === " ") {
        if (current) {
          result.push(current);
          current = "";
        }
      } else {
        current += ch;
      }
    }
    if (current) result.push(current);
    return result;
  }

  function lineClass(kind: OutputLine["kind"]): string {
    switch (kind) {
      case "cmd": return styles.lineCmd;
      case "error": return styles.lineError;
      case "info": return styles.lineInfo;
      case "shell": return styles.lineShell;
      default: return styles.lineResult;
    }
  }

  return (
    <div
      class={styles.pane}
      classList={{ [styles.active]: props.isActive }}
      onClick={props.onFocus}
    >
      <div class={styles.output} ref={outputRef}>
        <For each={segments()}>
          {(seg, i) => {
            const isLast = () => i() === segments().length - 1;
            const needsPage = () => isLast() || i() > 0;
            return (
              <div classList={{
                [styles.segment]: true,
                [styles.termPage]: needsPage(),
              }}>
                <For each={seg}>
                  {(line) => (
                    <div class={lineClass(line.kind)}>
                      <pre>{line.text}</pre>
                    </div>
                  )}
                </For>
                {isLast() && <div class={styles.termPageFill} />}
              </div>
            );
          }}
        </For>
      </div>
      <form class={styles.inputRow} onSubmit={handleSubmit}>
        <span class={styles.prompt}>
          {shellMode() ? `${prompt()} (shell)>` : `${prompt()}>`}
        </span>
        <input
          ref={inputRef}
          class={styles.input}
          type="text"
          autofocus={props.isActive}
          onKeyDown={handleKeyDown}
          spellcheck={false}
          autocomplete="off"
        />
      </form>
    </div>
  );
}
