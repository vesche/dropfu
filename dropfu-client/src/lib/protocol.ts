export const PROTOCOL_VERSION = 1 as const;

export const MSG_REGISTER = "register" as const;
export const MSG_AGENT_LIST = "agent_list" as const;
export const MSG_COMMAND = "command" as const;
export const MSG_RESULT = "result" as const;
export const MSG_SHELL_DATA = "shell_data" as const;
export const MSG_SHELL_CLOSE = "shell_close" as const;
export const MSG_FILE_META = "file_meta" as const;
export const MSG_FILE_CHUNK = "file_chunk" as const;
export const MSG_FILE_ACK = "file_ack" as const;
export const MSG_ERROR = "error" as const;
export const MSG_HEARTBEAT = "heartbeat" as const;

export type MsgType =
  | typeof MSG_REGISTER
  | typeof MSG_AGENT_LIST
  | typeof MSG_COMMAND
  | typeof MSG_RESULT
  | typeof MSG_SHELL_DATA
  | typeof MSG_SHELL_CLOSE
  | typeof MSG_FILE_META
  | typeof MSG_FILE_CHUNK
  | typeof MSG_FILE_ACK
  | typeof MSG_ERROR
  | typeof MSG_HEARTBEAT;

export interface AgentEntry {
  agent_id: string;
  hostname: string;
  os: string;
  arch: string;
  privilege: string;
  connected_at: number;
  last_seen: number;
}

export interface AgentListPayload {
  agents: AgentEntry[];
}

export interface CommandPayload {
  command: string;
  args: string[];
}

export interface ResultPayload {
  status: "success" | "error" | string;
  data: string;
}

export interface ShellPayload {
  data: string;
  eof?: boolean;
}

export interface FileMetaPayload {
  direction: "upload" | "download" | string;
  filename: string;
  size: number;
  sha256?: string;
}

export interface FileChunkPayload {
  offset: number;
  data: string;
  final?: boolean;
}

export interface FileAckPayload {
  status: string;
  sha256?: string;
  message?: string;
}

export interface ErrorPayload {
  code: string;
  message: string;
}

interface BaseEnvelope {
  id: string;
  agent_id?: string;
  timestamp: number;
  protocol_version?: number;
}

export type RegisterMessage = BaseEnvelope & { type: typeof MSG_REGISTER; payload: unknown };
export type AgentListMessage = BaseEnvelope & { type: typeof MSG_AGENT_LIST; payload: AgentListPayload };
export type CommandMessage = BaseEnvelope & { type: typeof MSG_COMMAND; agent_id: string; payload: CommandPayload };
export type ResultMessage = BaseEnvelope & { type: typeof MSG_RESULT; agent_id?: string; payload: ResultPayload };
export type ShellDataMessage = BaseEnvelope & { type: typeof MSG_SHELL_DATA; agent_id: string; payload: ShellPayload };
export type ShellCloseMessage = BaseEnvelope & { type: typeof MSG_SHELL_CLOSE; agent_id: string; payload?: Record<string, never> };
export type FileMetaMessage = BaseEnvelope & { type: typeof MSG_FILE_META; agent_id: string; payload: FileMetaPayload };
export type FileChunkMessage = BaseEnvelope & { type: typeof MSG_FILE_CHUNK; agent_id: string; payload: FileChunkPayload };
export type FileAckMessage = BaseEnvelope & { type: typeof MSG_FILE_ACK; agent_id?: string; payload: FileAckPayload };
export type ErrorMessage = BaseEnvelope & { type: typeof MSG_ERROR; payload: ErrorPayload };
export type HeartbeatMessage = BaseEnvelope & { type: typeof MSG_HEARTBEAT; payload?: Record<string, never> };

export type AnyMessage =
  | RegisterMessage
  | AgentListMessage
  | CommandMessage
  | ResultMessage
  | ShellDataMessage
  | ShellCloseMessage
  | FileMetaMessage
  | FileChunkMessage
  | FileAckMessage
  | ErrorMessage
  | HeartbeatMessage;

export type Envelope = AnyMessage;

const MSG_TYPES = new Set<string>([
  MSG_REGISTER, MSG_AGENT_LIST, MSG_COMMAND, MSG_RESULT, MSG_SHELL_DATA,
  MSG_SHELL_CLOSE, MSG_FILE_META, MSG_FILE_CHUNK, MSG_FILE_ACK, MSG_ERROR, MSG_HEARTBEAT,
]);

let _counter = 0;
export function generateId(): string {
  const ts = Date.now().toString(16);
  const rnd = (typeof crypto !== "undefined" && "getRandomValues" in crypto)
    ? Array.from(crypto.getRandomValues(new Uint8Array(4)), (b) => b.toString(16).padStart(2, "0")).join("")
    : Math.random().toString(16).slice(2, 10);
  return `${ts}${rnd}${(++_counter).toString(16)}`;
}

export function parseMessage(raw: unknown): AnyMessage | null {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  if (typeof obj.type !== "string" || !MSG_TYPES.has(obj.type)) return null;
  if (typeof obj.id !== "string" || !isHexId(obj.id, 64)) return null;
  if (typeof obj.timestamp !== "number" || !Number.isFinite(obj.timestamp)) return null;
  if (obj.protocol_version !== undefined && obj.protocol_version !== PROTOCOL_VERSION) return null;

  const payload = obj.payload ?? {};
  if (!isRecord(payload)) return null;

  switch (obj.type) {
    case MSG_AGENT_LIST:
      if (!Array.isArray(payload.agents) || !payload.agents.every(isAgentEntry)) return null;
      break;
    case MSG_COMMAND:
      if (typeof obj.agent_id !== "string" || !isHexId(obj.agent_id, 128) || typeof payload.command !== "string" ||
          !Array.isArray(payload.args) || !payload.args.every((arg) => typeof arg === "string")) return null;
      break;
    case MSG_RESULT:
      if (typeof payload.status !== "string" || typeof payload.data !== "string") return null;
      break;
    case MSG_SHELL_DATA:
      if (typeof obj.agent_id !== "string" || !isHexId(obj.agent_id, 128) || typeof payload.data !== "string" ||
          (payload.eof !== undefined && typeof payload.eof !== "boolean")) return null;
      break;
    case MSG_SHELL_CLOSE:
      if (typeof obj.agent_id !== "string" || !isHexId(obj.agent_id, 128)) return null;
      break;
    case MSG_FILE_META:
      if (typeof obj.agent_id !== "string" || !isHexId(obj.agent_id, 128) || typeof payload.direction !== "string" ||
          typeof payload.filename !== "string" || !isNonNegativeNumber(payload.size) ||
          (payload.sha256 !== undefined && typeof payload.sha256 !== "string")) return null;
      break;
    case MSG_FILE_CHUNK:
      if (typeof obj.agent_id !== "string" || !isHexId(obj.agent_id, 128) || !isNonNegativeNumber(payload.offset) ||
          typeof payload.data !== "string" ||
          (payload.final !== undefined && typeof payload.final !== "boolean")) return null;
      break;
    case MSG_FILE_ACK:
      if (typeof payload.status !== "string" ||
          (payload.sha256 !== undefined && typeof payload.sha256 !== "string") ||
          (payload.message !== undefined && typeof payload.message !== "string")) return null;
      break;
    case MSG_ERROR:
      if (typeof payload.code !== "string" || typeof payload.message !== "string") return null;
      break;
    case MSG_REGISTER:
    case MSG_HEARTBEAT:
      break;
    default:
      return null;
  }

  return { ...obj, payload } as unknown as AnyMessage;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonNegativeNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

function isHexId(value: string, maxLength: number): boolean {
  return value.length > 0 && value.length <= maxLength && /^[0-9a-f]+$/i.test(value);
}

function isAgentEntry(value: unknown): value is AgentEntry {
  if (!isRecord(value)) return false;
  return typeof value.agent_id === "string" && isHexId(value.agent_id, 128) &&
    typeof value.hostname === "string" &&
    typeof value.os === "string" &&
    typeof value.arch === "string" &&
    typeof value.privilege === "string" &&
    isNonNegativeNumber(value.connected_at) &&
    isNonNegativeNumber(value.last_seen);
}

export function buildCommand(agentId: string, command: string, args: string[]): CommandMessage {
  return {
    type: MSG_COMMAND,
    id: generateId(),
    agent_id: agentId,
    timestamp: Math.floor(Date.now() / 1000),
    protocol_version: PROTOCOL_VERSION,
    payload: { command, args },
  };
}

export function buildShellData(sessionId: string, agentId: string, data: string, eof = false): ShellDataMessage {
  return {
    type: MSG_SHELL_DATA,
    id: sessionId,
    agent_id: agentId,
    timestamp: Math.floor(Date.now() / 1000),
    protocol_version: PROTOCOL_VERSION,
    payload: { data, eof },
  };
}

export function buildShellClose(sessionId: string, agentId: string): ShellCloseMessage {
  return {
    type: MSG_SHELL_CLOSE,
    id: sessionId,
    agent_id: agentId,
    timestamp: Math.floor(Date.now() / 1000),
    protocol_version: PROTOCOL_VERSION,
    payload: {},
  };
}

export function buildFileMeta(
  transferId: string,
  agentId: string,
  filename: string,
  size: number,
): FileMetaMessage {
  return {
    type: MSG_FILE_META,
    id: transferId,
    agent_id: agentId,
    timestamp: Math.floor(Date.now() / 1000),
    protocol_version: PROTOCOL_VERSION,
    payload: { direction: "upload", filename, size },
  };
}

export function buildFileChunk(
  transferId: string,
  agentId: string,
  offset: number,
  data: string,
  final: boolean,
): FileChunkMessage {
  return {
    type: MSG_FILE_CHUNK,
    id: transferId,
    agent_id: agentId,
    timestamp: Math.floor(Date.now() / 1000),
    protocol_version: PROTOCOL_VERSION,
    payload: { offset, data, final },
  };
}
