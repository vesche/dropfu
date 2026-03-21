import { createSignal, createEffect, onMount, onCleanup } from "solid-js";
import { createStore, produce } from "solid-js/store";
import type { AgentEntry, AnyMessage } from "./lib/protocol";
import { MSG_AGENT_LIST, MSG_RESULT, MSG_SHELL_DATA, MSG_FILE_META, MSG_FILE_CHUNK, MSG_ERROR } from "./lib/protocol";
import { connect, onMessage } from "./lib/ws";
import AgentList from "./components/AgentList";
import PaneManager from "./components/PaneManager";
import styles from "./App.module.css";

export interface OutputLine {
  kind: "cmd" | "result" | "error" | "info" | "shell" | "clear";
  text: string;
  ts: number;
}

export interface AppState {
  agents: AgentEntry[];
  selectedAgentId: string | null;
  sidebarOpen: boolean;
  outputs: Record<string, OutputLine[]>;
}

const [state, setState] = createStore<AppState>({
  agents: [],
  selectedAgentId: null,
  sidebarOpen: true,
  outputs: {},
});

function pushOutput(paneId: string, line: OutputLine) {
  setState(
    produce((s) => {
      if (!s.outputs[paneId]) s.outputs[paneId] = [];
      s.outputs[paneId].push(line);
    }),
  );
}

export { state, setState, pushOutput };

export default function App() {
  const [activePaneId, setActivePaneId] = createSignal("root");

  onMount(() => connect());

  createEffect(() => {
    const unsub = onMessage((msg: AnyMessage) => {
      switch (msg.type) {
        case MSG_AGENT_LIST:
          setState("agents", msg.payload.agents);
          break;
        case MSG_RESULT:
          pushOutput(activePaneId(), {
            kind: msg.payload.status === "success" ? "result" : "error",
            text: msg.payload.data,
            ts: msg.timestamp,
          });
          break;
        case MSG_SHELL_DATA:
          pushOutput(activePaneId(), {
            kind: "shell",
            text: msg.payload.data,
            ts: msg.timestamp,
          });
          break;
        case MSG_FILE_META:
          pushOutput(activePaneId(), {
            kind: "info",
            text: `[file] ${msg.payload.direction} "${msg.payload.filename}" (${msg.payload.size} bytes)`,
            ts: msg.timestamp,
          });
          break;
        case MSG_FILE_CHUNK:
          if (msg.payload.final) {
            pushOutput(activePaneId(), {
              kind: "info",
              text: `[file] transfer complete`,
              ts: msg.timestamp,
            });
          }
          break;
        case MSG_ERROR:
          pushOutput(activePaneId(), {
            kind: "error",
            text: `[error] ${msg.payload.code}: ${msg.payload.message}`,
            ts: msg.timestamp,
          });
          break;
      }
    });
    onCleanup(unsub);
  });

  function handleKeyDown(e: KeyboardEvent) {
    if (!e.shiftKey) return;
    if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Delete", "Backspace"].includes(e.key)) return;
    e.preventDefault();
  }

  onMount(() => {
    window.addEventListener("keydown", handleKeyDown);
    onCleanup(() => window.removeEventListener("keydown", handleKeyDown));
  });

  return (
    <div class={styles.app}>
      <header class={styles.topbar}>
        <button
          class={styles.sidebarToggle}
          onClick={() => setState("sidebarOpen", (o) => !o)}
          title="Toggle sidebar"
        >
          {state.sidebarOpen ? "\u25C0" : "\u25B6"}
        </button>
        <span class={styles.brand}>dropfu</span>
      </header>

      <div class={styles.body}>
        {state.sidebarOpen && (
          <AgentList
            agents={state.agents}
            selectedId={state.selectedAgentId}
            onSelect={(id) => setState("selectedAgentId", id)}
          />
        )}
        <PaneManager
          activePaneId={activePaneId()}
          onActivePaneChange={setActivePaneId}
        />
      </div>
    </div>
  );
}
