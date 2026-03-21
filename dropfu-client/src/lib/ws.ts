import { createSignal } from "solid-js";
import type { AnyMessage, Envelope } from "./protocol";

export type ConnectionStatus = "disconnected" | "connecting" | "connected";

function deriveWsUrl(): string {
  const env = import.meta.env.VITE_WS_URL;
  if (env) return env as string;
  // In dev mode, Vite proxies /ws to the Zig server — same-origin avoids
  // cross-port and IPv6 resolution issues in browsers.
  const loc = typeof window !== "undefined" ? window.location : undefined;
  if (loc) {
    const proto = loc.protocol === "https:" ? "wss:" : "ws:";
    return `${proto}//${loc.host}/ws`;
  }
  return "ws://127.0.0.1:8443";
}

const WS_URL = deriveWsUrl();

const RECONNECT_BASE_MS = 500;
const RECONNECT_MAX_MS = 30_000;

type MessageHandler = (msg: AnyMessage) => void;

const [status, setStatus] = createSignal<ConnectionStatus>("disconnected");

let ws: WebSocket | null = null;
let reconnectAttempt = 0;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
const handlers = new Set<MessageHandler>();

function scheduleReconnect() {
  if (reconnectTimer !== null) return;
  const delay = Math.min(RECONNECT_BASE_MS * 2 ** reconnectAttempt, RECONNECT_MAX_MS);
  reconnectAttempt++;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delay);
}

export function connect(): void {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;

  setStatus("connecting");
  ws = new WebSocket(WS_URL);

  ws.onopen = () => {
    console.log("[dropfu] ws connected to", WS_URL);
    setStatus("connected");
    reconnectAttempt = 0;
  };

  ws.onclose = (ev) => {
    console.log("[dropfu] ws closed", ev.code, ev.reason);
    setStatus("disconnected");
    ws = null;
    scheduleReconnect();
  };

  ws.onerror = (ev) => {
    console.error("[dropfu] ws error", ev);
    ws?.close();
  };

  ws.onmessage = (ev) => {
    try {
      const msg: AnyMessage = JSON.parse(ev.data as string);
      for (const h of handlers) h(msg);
    } catch {
      /* ignore malformed frames */
    }
  };
}

export function disconnect(): void {
  if (reconnectTimer !== null) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  reconnectAttempt = 0;
  ws?.close();
  ws = null;
  setStatus("disconnected");
}

export function send(msg: Envelope): void {
  if (ws?.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
  }
}

export function onMessage(handler: MessageHandler): () => void {
  handlers.add(handler);
  return () => handlers.delete(handler);
}

export { status };
