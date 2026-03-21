// ---------------------------------------------------------------------------
// Dropfu wire protocol – TypeScript definitions (mirrors protocol.zig)
// ---------------------------------------------------------------------------

export const MSG_REGISTER = "register" as const;
export const MSG_AGENT_LIST = "agent_list" as const;
export const MSG_COMMAND = "command" as const;
export const MSG_RESULT = "result" as const;
export const MSG_SHELL_DATA = "shell_data" as const;
export const MSG_FILE_META = "file_meta" as const;
export const MSG_FILE_CHUNK = "file_chunk" as const;
export const MSG_ERROR = "error" as const;

export type MsgType =
  | typeof MSG_REGISTER
  | typeof MSG_AGENT_LIST
  | typeof MSG_COMMAND
  | typeof MSG_RESULT
  | typeof MSG_SHELL_DATA
  | typeof MSG_FILE_META
  | typeof MSG_FILE_CHUNK
  | typeof MSG_ERROR;

// --- Payloads ---------------------------------------------------------------

export interface RegisterPayload {
  hostname: string;
  os: string;
  arch: string;
  privilege: string;
  version: string;
}

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
  status: "success" | "error";
  data: string;
}

export interface ShellPayload {
  data: string;
  eof: boolean;
}

export interface FileMetaPayload {
  direction: "upload" | "download";
  filename: string;
  size: number;
}

export interface FileChunkPayload {
  offset: number;
  data: string;       // base64
  final: boolean;
}

export interface ErrorPayload {
  code: string;
  message: string;
}

// --- Envelope ---------------------------------------------------------------

export interface Envelope<P = unknown> {
  type: MsgType;
  id: string;
  agent_id?: string;
  timestamp: number;
  payload: P;
}

export type RegisterMessage     = Envelope<RegisterPayload>;
export type AgentListMessage    = Envelope<AgentListPayload>;
export type CommandMessage      = Envelope<CommandPayload>;
export type ResultMessage       = Envelope<ResultPayload>;
export type ShellDataMessage    = Envelope<ShellPayload>;
export type FileMetaMessage     = Envelope<FileMetaPayload>;
export type FileChunkMessage    = Envelope<FileChunkPayload>;
export type ErrorMessage        = Envelope<ErrorPayload>;

export type AnyMessage =
  | RegisterMessage
  | AgentListMessage
  | CommandMessage
  | ResultMessage
  | ShellDataMessage
  | FileMetaMessage
  | FileChunkMessage
  | ErrorMessage;

// --- Builders ---------------------------------------------------------------

let _counter = 0;
export function generateId(): string {
  const ts = Date.now().toString(16);
  const rnd = Math.random().toString(16).slice(2, 10);
  return `${ts}${rnd}${(++_counter).toString(16)}`;
}

export function buildCommand(
  agentId: string,
  command: string,
  args: string[],
): CommandMessage {
  return {
    type: MSG_COMMAND,
    id: generateId(),
    agent_id: agentId,
    timestamp: Math.floor(Date.now() / 1000),
    payload: { command, args },
  };
}

export function buildShellData(
  sessionId: string,
  agentId: string,
  data: string,
  eof = false,
): ShellDataMessage {
  return {
    type: MSG_SHELL_DATA,
    id: sessionId,
    agent_id: agentId,
    timestamp: Math.floor(Date.now() / 1000),
    payload: { data, eof },
  };
}

export function buildFileUploadStart(
  agentId: string,
  filename: string,
  size: number,
): FileMetaMessage {
  return {
    type: MSG_FILE_META,
    id: generateId(),
    agent_id: agentId,
    timestamp: Math.floor(Date.now() / 1000),
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
    payload: { offset, data, final },
  };
}
