export type FileKind = "directory" | "file" | "symlink" | "other";

export interface FileManagerEntry {
  name: string;
  path: string;
  kind: FileKind;
  size: number;
  modified: number;
}

export interface DirectoryListing {
  path: string;
  parent: string;
  entries: FileManagerEntry[];
  truncated: boolean;
}

export interface FilePreview {
  path: string;
  name: string;
  kind: FileKind;
  size: number;
  modified: number;
  text: string | null;
  binary: boolean;
  truncated: boolean;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isFileKind(value: unknown): value is FileKind {
  return value === "directory" || value === "file" || value === "symlink" || value === "other";
}

function isNonNegativeNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

function isEntry(value: unknown): value is FileManagerEntry {
  if (!isRecord(value)) return false;
  return typeof value.name === "string" &&
    typeof value.path === "string" &&
    isFileKind(value.kind) &&
    isNonNegativeNumber(value.size) &&
    typeof value.modified === "number" &&
    Number.isFinite(value.modified);
}

export function parseDirectoryListing(raw: string): DirectoryListing {
  const value: unknown = JSON.parse(raw);
  if (!isRecord(value) ||
      typeof value.path !== "string" ||
      typeof value.parent !== "string" ||
      !Array.isArray(value.entries) ||
      !value.entries.every(isEntry) ||
      typeof value.truncated !== "boolean") {
    throw new Error("agent returned an invalid directory listing");
  }
  return {
    path: value.path,
    parent: value.parent,
    entries: sortEntries(value.entries),
    truncated: value.truncated,
  };
}

export function parseFilePreview(raw: string): FilePreview {
  const value: unknown = JSON.parse(raw);
  if (!isRecord(value) ||
      typeof value.path !== "string" ||
      typeof value.name !== "string" ||
      !isFileKind(value.kind) ||
      !isNonNegativeNumber(value.size) ||
      typeof value.modified !== "number" ||
      !Number.isFinite(value.modified) ||
      (value.text !== null && typeof value.text !== "string") ||
      typeof value.binary !== "boolean" ||
      typeof value.truncated !== "boolean") {
    throw new Error("agent returned an invalid file preview");
  }
  return value as unknown as FilePreview;
}

export function sortEntries(entries: FileManagerEntry[]): FileManagerEntry[] {
  return [...entries].sort((a, b) => {
    const aGroup = a.kind === "directory" ? 0 : 1;
    const bGroup = b.kind === "directory" ? 0 : 1;
    if (aGroup !== bGroup) return aGroup - bGroup;
    return a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" });
  });
}

export function remoteBasename(path: string): string {
  const trimmed = path.replace(/[\\/]+$/, "");
  const separator = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"));
  return separator >= 0 ? trimmed.slice(separator + 1) : trimmed;
}

export function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KiB", "MiB", "GiB", "TiB"];
  let value = bytes / 1024;
  let unit = units[0]!;
  for (let i = 1; i < units.length && value >= 1024; i++) {
    value /= 1024;
    unit = units[i]!;
  }
  return `${value >= 10 ? value.toFixed(0) : value.toFixed(1)} ${unit}`;
}
