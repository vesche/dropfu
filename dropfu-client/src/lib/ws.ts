import { createSignal } from "solid-js";
import type { AnyMessage, Envelope } from "./protocol";
import { parseMessage, MSG_HEARTBEAT, generateId, PROTOCOL_VERSION } from "./protocol";

export type ConnectionStatus = "disconnected" | "connecting" | "connected" | "auth_required";

function deriveWsUrl(): string {
  const env = import.meta.env.VITE_WS_URL;
  if (env) return env as string;
  const loc = typeof window !== "undefined" ? window.location : undefined;
  if (loc) {
    const proto = loc.protocol === "https:" ? "wss:" : "ws:";
    return `${proto}//${loc.host}/ws`;
  }
  return "ws://127.0.0.1:8443";
}

function deriveHttpBase(): string {
  const env = import.meta.env.VITE_HTTP_URL;
  if (env) return env as string;
  const loc = typeof window !== "undefined" ? window.location : undefined;
  if (loc) return `${loc.protocol}//${loc.host}`;
  return "http://127.0.0.1:8443";
}

const WS_URL = deriveWsUrl();
export const HTTP_BASE = deriveHttpBase();

const RECONNECT_BASE_MS = 500;
const RECONNECT_MAX_MS = 30_000;
const HEARTBEAT_MS = 15_000;

type MessageHandler = (msg: AnyMessage) => void;

const [status, setStatus] = createSignal<ConnectionStatus>("disconnected");

let ws: WebSocket | null = null;
let reconnectAttempt = 0;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let heartbeatTimer: ReturnType<typeof setInterval> | null = null;
let intentionalClose = false;
const handlers = new Set<MessageHandler>();

function scheduleReconnect() {
  if (intentionalClose) return;
  if (reconnectTimer !== null) return;
  const jitter = Math.random() * 250;
  const delay = Math.min(RECONNECT_BASE_MS * 2 ** reconnectAttempt, RECONNECT_MAX_MS) + jitter;
  reconnectAttempt++;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delay);
}

function clearHeartbeat() {
  if (heartbeatTimer !== null) {
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }
}

function startHeartbeat() {
  clearHeartbeat();
  heartbeatTimer = setInterval(() => {
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({
        type: MSG_HEARTBEAT,
        id: generateId(),
        timestamp: Math.floor(Date.now() / 1000),
        protocol_version: PROTOCOL_VERSION,
        payload: {},
      }));
    }
  }, HEARTBEAT_MS);
}

export async function login(token: string): Promise<boolean> {
  const res = await fetch(`${HTTP_BASE}/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    credentials: "include",
    body: JSON.stringify({ token }),
  });
  return res.ok;
}

export function connect(): void {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;
  intentionalClose = false;
  setStatus("connecting");
  ws = new WebSocket(WS_URL);

  ws.onopen = () => {
    setStatus("connected");
    reconnectAttempt = 0;
    startHeartbeat();
  };

  ws.onclose = () => {
    clearHeartbeat();
    setStatus("disconnected");
    ws = null;
    scheduleReconnect();
  };

  ws.onerror = () => {
    ws?.close();
  };

  ws.onmessage = (ev) => {
    try {
      const raw = JSON.parse(ev.data as string);
      const msg = parseMessage(raw);
      if (!msg) return;
      for (const h of handlers) {
        try {
          h(msg);
        } catch {
          /* isolate handler failures */
        }
      }
    } catch {
      /* ignore malformed frames */
    }
  };
}

export function disconnect(): void {
  intentionalClose = true;
  if (reconnectTimer !== null) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  clearHeartbeat();
  reconnectAttempt = 0;
  ws?.close();
  ws = null;
  setStatus("disconnected");
}

export function send(msg: Envelope): boolean {
  if (ws?.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
    return true;
  }
  return false;
}

export function onMessage(handler: MessageHandler): () => void {
  handlers.add(handler);
  return () => handlers.delete(handler);
}

export { status };
