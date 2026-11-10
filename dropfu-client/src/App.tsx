import { createSignal, createEffect, onMount, onCleanup, Show } from "solid-js";
import type { AnyMessage } from "./lib/protocol";
import {
  MSG_AGENT_LIST, MSG_RESULT, MSG_SHELL_DATA, MSG_FILE_META, MSG_FILE_CHUNK,
  MSG_FILE_ACK, MSG_ERROR, MSG_HEARTBEAT,
} from "./lib/protocol";
import { connect, disconnect, onMessage, status, login } from "./lib/ws";
import {
  state, setState, pushOutput, resolveRequest, completeRequest, ensurePane, isSilentRequest,
} from "./state/session";
import AgentList from "./components/AgentList";
import PaneManager from "./components/PaneManager";
import styles from "./App.module.css";

export { state, setState, pushOutput };

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function downloadBlob(filename: string, parts: Uint8Array[]) {
  const blob = new Blob(parts as BlobPart[]);
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

export default function App() {
  const [activePaneId, setActivePaneId] = createSignal("root");
  const [tokenInput, setTokenInput] = createSignal("");
  const [loginBusy, setLoginBusy] = createSignal(false);

  onMount(() => {
    // Attempt cookie-authenticated WS; if server rejects, UI shows login.
    connect();
    ensurePane("root");
  });

  createEffect(() => {
    const unsub = onMessage((msg: AnyMessage) => {
      switch (msg.type) {
        case MSG_AGENT_LIST:
          setState("agents", msg.payload.agents);
          setState("authenticated", true);
          setState("authError", null);
          if (state.selectedAgentId) {
            const still = msg.payload.agents.some((a) => a.agent_id === state.selectedAgentId);
            if (!still) setState("selectedAgentId", null);
          }
          break;

        case MSG_RESULT: {
          const pane = resolveRequest(msg.id) ?? activePaneId();
          const isActiveShell = state.panes[pane]?.shellSessionId === msg.id &&
            msg.payload.status === "success";
          if (!isSilentRequest(msg.id)) {
            pushOutput(pane, {
              kind: msg.payload.status === "success" ? "result" : "error",
              text: msg.payload.data,
              ts: msg.timestamp,
            });
          }
          if (!isActiveShell) completeRequest(msg.id);
          break;
        }

        case MSG_SHELL_DATA: {
          const pane = resolveRequest(msg.id) ?? activePaneId();
          if (msg.payload.data) {
            pushOutput(pane, { kind: "shell", text: msg.payload.data, ts: msg.timestamp });
          }
          if (msg.payload.eof) {
            pushOutput(pane, { kind: "info", text: "[shell closed]", ts: msg.timestamp });
            completeRequest(msg.id);
          }
          break;
        }

        case MSG_FILE_META: {
          const pane = resolveRequest(msg.id) ?? activePaneId();
          pushOutput(pane, {
            kind: "info",
            text: `[file] ${msg.payload.direction} "${msg.payload.filename}" (${msg.payload.size} bytes)`,
            ts: msg.timestamp,
          });
          if (msg.payload.direction === "download") {
            setState("transfers", msg.id, {
              id: msg.id,
              paneId: pane,
              filename: msg.payload.filename,
              size: msg.payload.size,
              direction: "download",
              offset: 0,
              chunks: [],
              done: false,
            });
          }
          break;
        }

        case MSG_FILE_CHUNK: {
          const t = state.transfers[msg.id];
          if (!t) break;
          if (msg.payload.offset !== t.offset) {
            pushOutput(t.paneId, {
              kind: "error",
              text: `[file] download offset mismatch: expected ${t.offset}, received ${msg.payload.offset}`,
              ts: msg.timestamp,
            });
            break;
          }
          let bytes: Uint8Array;
          try {
            bytes = b64ToBytes(msg.payload.data);
          } catch {
            pushOutput(t.paneId, { kind: "error", text: "[file] invalid base64 data", ts: msg.timestamp });
            break;
          }
          setState("transfers", msg.id, "chunks", t.chunks.length, bytes);
          setState("transfers", msg.id, "offset", msg.payload.offset + bytes.length);
          if (msg.payload.final) {
            const received = msg.payload.offset + bytes.length;
            if (received !== t.size) {
              pushOutput(t.paneId, {
                kind: "error",
                text: `[file] download size mismatch: expected ${t.size}, received ${received}`,
                ts: msg.timestamp,
              });
              break;
            }
            const all = state.transfers[msg.id]?.chunks ?? [];
            downloadBlob(t.filename, all);
            pushOutput(t.paneId, {
              kind: "info",
              text: `[file] download complete: ${t.filename}`,
              ts: msg.timestamp,
            });
            setState("transfers", msg.id, "done", true);
          }
          break;
        }

        case MSG_FILE_ACK: {
          const pane = resolveRequest(msg.id) ?? activePaneId();
          pushOutput(pane, {
            kind: msg.payload.status === "success" ? "info" : "error",
            text: `[file] ${msg.payload.message || msg.payload.status}${msg.payload.sha256 ? ` sha256=${msg.payload.sha256}` : ""}`,
            ts: msg.timestamp,
          });
          completeRequest(msg.id);
          break;
        }

        case MSG_ERROR: {
          const pane = resolveRequest(msg.id) ?? activePaneId();
          if (!isSilentRequest(msg.id)) {
            pushOutput(pane, {
              kind: "error",
              text: `[error] ${msg.payload.code}: ${msg.payload.message}`,
              ts: msg.timestamp,
            });
          }
          if (msg.payload.code === "unauthorized") {
            setState("authenticated", false);
            setState("authError", msg.payload.message);
          }
          completeRequest(msg.id);
          break;
        }

        case MSG_HEARTBEAT:
          break;
      }
    });
    onCleanup(unsub);
  });

  async function handleLogin(e: Event) {
    e.preventDefault();
    setLoginBusy(true);
    setState("authError", null);
    try {
      const ok = await login(tokenInput());
      if (!ok) {
        setState("authError", "invalid operator token");
        return;
      }
      // Reconnect with the newly issued session cookie. Authentication is only
      // considered complete after the server sends a valid agent list.
      disconnect();
      connect();
    } catch {
      setState("authError", "login failed — is the server reachable?");
    } finally {
      setLoginBusy(false);
    }
  }

  const connLabel = () => {
    switch (status()) {
      case "connected": return "connected";
      case "connecting": return "connecting…";
      case "auth_required": return "auth required";
      default: return "disconnected";
    }
  };

  return (
    <div class={styles.app}>
      <header class={styles.topbar}>
        <button
          class={styles.sidebarToggle}
          onClick={() => setState("sidebarOpen", (o) => !o)}
          title="Toggle sidebar"
          aria-label="Toggle agent sidebar"
          aria-expanded={state.sidebarOpen}
        >
          {state.sidebarOpen ? "\u25C0" : "\u25B6"}
        </button>
        <span class={styles.brand}>dropfu</span>
        <span
          class={styles.connStatus}
          classList={{
            [styles.connOk]: status() === "connected",
            [styles.connBad]: status() === "disconnected",
          }}
          role="status"
          aria-live="polite"
        >
          {connLabel()}
        </span>
      </header>

      <Show when={!state.authenticated}>
        <div class={styles.loginOverlay} role="dialog" aria-label="Operator login">
          <form class={styles.loginCard} onSubmit={handleLogin}>
            <h1>dropfu</h1>
            <p>Enter the operator token to connect.</p>
            <input
              id="operator-token"
              type="password"
              autocomplete="current-password"
              placeholder="operator token"
              aria-label="Operator token"
              value={tokenInput()}
              onInput={(e) => setTokenInput(e.currentTarget.value)}
              disabled={loginBusy()}
            />
            <button type="submit" disabled={loginBusy() || tokenInput().length < 16}>
              {loginBusy() ? "connecting…" : "connect"}
            </button>
            <Show when={state.authError}>
              <p class={styles.loginError}>{state.authError}</p>
            </Show>
          </form>
        </div>
      </Show>

      <div class={styles.body}>
        <Show when={state.sidebarOpen}>
          <AgentList
            agents={state.agents}
            selectedId={state.selectedAgentId}
            onSelect={(id) => setState("selectedAgentId", id)}
          />
        </Show>
        <PaneManager
          activePaneId={activePaneId()}
          onActivePaneChange={setActivePaneId}
        />
      </div>
    </div>
  );
}
