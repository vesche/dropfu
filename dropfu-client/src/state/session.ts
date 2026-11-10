import { createStore, produce } from "solid-js/store";
import type { AgentEntry } from "../lib/protocol";

export interface OutputLine {
  id: number;
  kind: "cmd" | "result" | "error" | "info" | "shell" | "clear";
  text: string;
  ts: number;
}

export interface PaneMeta {
  agentId: string | null;
  shellSessionId: string | null;
  pendingRequestIds: string[];
}

export interface TransferState {
  id: string;
  paneId: string;
  filename: string;
  size: number;
  direction: "upload" | "download";
  offset: number;
  chunks: Uint8Array[];
  done: boolean;
}

const MAX_LINES_PER_PANE = 10_000;
const MAX_BYTES_PER_PANE = 5 * 1024 * 1024;

export interface AppState {
  agents: AgentEntry[];
  selectedAgentId: string | null;
  sidebarOpen: boolean;
  outputs: Record<string, OutputLine[]>;
  panes: Record<string, PaneMeta>;
  requestToPane: Record<string, string>;
  silentRequests: Record<string, boolean>;
  transfers: Record<string, TransferState>;
  authenticated: boolean;
  authError: string | null;
}

const [state, setState] = createStore<AppState>({
  agents: [],
  selectedAgentId: null,
  sidebarOpen: true,
  outputs: {},
  panes: {},
  requestToPane: {},
  silentRequests: {},
  transfers: {},
  authenticated: false,
  authError: null,
});

let lineCounter = 0;

function estimateBytes(lines: OutputLine[]): number {
  let n = 0;
  for (const l of lines) n += l.text.length;
  return n;
}

function trimOutput(lines: OutputLine[]): OutputLine[] {
  let out = lines;
  if (out.length > MAX_LINES_PER_PANE) {
    out = out.slice(out.length - MAX_LINES_PER_PANE);
  }
  while (estimateBytes(out) > MAX_BYTES_PER_PANE && out.length > 100) {
    out = out.slice(Math.floor(out.length * 0.1));
  }
  return out;
}

export function ensurePane(paneId: string, agentId: string | null = null) {
  if (!state.panes[paneId]) {
    setState("panes", paneId, {
      agentId,
      shellSessionId: null,
      pendingRequestIds: [],
    });
  }
}

export function pushOutput(paneId: string, line: Omit<OutputLine, "id">) {
  ensurePane(paneId);
  setState(
    produce((s) => {
      if (!s.outputs[paneId]) s.outputs[paneId] = [];
      s.outputs[paneId].push({ ...line, id: ++lineCounter });
      s.outputs[paneId] = trimOutput(s.outputs[paneId]);
    }),
  );
}

export function clearPaneOutput(paneId: string) {
  setState(
    produce((s) => {
      s.outputs[paneId] = [{ id: ++lineCounter, kind: "clear", text: "", ts: Date.now() / 1000 }];
    }),
  );
}

export function deletePane(paneId: string) {
  setState(
    produce((s) => {
      delete s.outputs[paneId];
      delete s.panes[paneId];
      for (const [req, pid] of Object.entries(s.requestToPane)) {
        if (pid === paneId) {
          delete s.requestToPane[req];
          delete s.silentRequests[req];
        }
      }
    }),
  );
}

export function bindRequest(requestId: string, paneId: string, silent = false) {
  setState("requestToPane", requestId, paneId);
  setState("silentRequests", requestId, silent);
  setState(
    produce((s) => {
      if (!s.panes[paneId]) {
        s.panes[paneId] = { agentId: s.selectedAgentId, shellSessionId: null, pendingRequestIds: [] };
      }
      s.panes[paneId].pendingRequestIds.push(requestId);
    }),
  );
}

export function resolveRequest(requestId: string): string | null {
  return state.requestToPane[requestId] ?? null;
}

export function isSilentRequest(requestId: string): boolean {
  return state.silentRequests[requestId] === true;
}

export function completeRequest(requestId: string) {
  setState(
    produce((s) => {
      const paneId = s.requestToPane[requestId];
      delete s.requestToPane[requestId];
      delete s.silentRequests[requestId];
      if (paneId && s.panes[paneId]) {
        s.panes[paneId].pendingRequestIds = s.panes[paneId].pendingRequestIds.filter((id) => id !== requestId);
      }
    }),
  );
}

export function setPaneAgent(paneId: string, agentId: string | null) {
  ensurePane(paneId, agentId);
  setState("panes", paneId, "agentId", agentId);
}

export function setPaneShell(paneId: string, sessionId: string | null) {
  ensurePane(paneId);
  setState("panes", paneId, "shellSessionId", sessionId);
}

export { state, setState, MAX_LINES_PER_PANE };
