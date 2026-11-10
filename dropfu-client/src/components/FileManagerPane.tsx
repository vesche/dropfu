import {
  For, Show, createEffect, createMemo, createSignal, onCleanup, onMount,
} from "solid-js";
import type { ResultMessage } from "../lib/protocol";
import { buildCommand } from "../lib/protocol";
import {
  type DirectoryListing,
  type FileManagerEntry,
  type FilePreview,
  formatFileSize,
  parseDirectoryListing,
  parseFilePreview,
  remoteBasename,
} from "../lib/fileManager";
import { send, status as connectionStatus, waitForMessage } from "../lib/ws";
import {
  bindRequest, completeRequest, setPaneAgent, state,
} from "../state/session";
import styles from "./FileManagerPane.module.css";

interface Props {
  paneId: string;
  isActive: boolean;
  onFocus: () => void;
  onExit: () => void;
}

type PreviewState =
  | { kind: "directory"; value: DirectoryListing }
  | { kind: "file"; value: FilePreview };

function entryMark(kind: FileManagerEntry["kind"]): string {
  switch (kind) {
    case "directory": return "d";
    case "symlink": return "l";
    case "file": return "-";
    default: return "?";
  }
}

function modifiedLabel(epoch: number): string {
  if (epoch <= 0) return "unknown";
  return new Date(epoch * 1000).toLocaleString();
}

export default function FileManagerPane(props: Props) {
  let paneRef!: HTMLDivElement;
  let currentListRef!: HTMLDivElement;
  let searchRef!: HTMLInputElement;

  const [listing, setListing] = createSignal<DirectoryListing | null>(null);
  const [parentListing, setParentListing] = createSignal<DirectoryListing | null>(null);
  const [preview, setPreview] = createSignal<PreviewState | null>(null);
  const [selectedIndex, setSelectedIndex] = createSignal(0);
  const [filter, setFilter] = createSignal("");
  const [searching, setSearching] = createSignal(false);
  const [loading, setLoading] = createSignal(false);
  const [previewLoading, setPreviewLoading] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [notice, setNotice] = createSignal("ready");

  let directoryGeneration = 0;
  let previewGeneration = 0;

  const paneAgentId = () => state.panes[props.paneId]?.agentId ?? state.selectedAgentId;
  const agent = () => state.agents.find((item) => item.agent_id === paneAgentId()) ?? null;

  const visibleEntries = createMemo(() => {
    const entries = listing()?.entries ?? [];
    const query = filter().trim().toLocaleLowerCase();
    if (!query) return entries;
    return entries.filter((entry) => entry.name.toLocaleLowerCase().includes(query));
  });

  const selectedEntry = createMemo(() => visibleEntries()[selectedIndex()] ?? null);

  createEffect(() => {
    if (props.isActive && !searching() && paneRef) paneRef.focus();
  });

  createEffect(() => {
    const entry = selectedEntry();
    const generation = ++previewGeneration;
    setPreview(null);
    if (!entry) {
      setPreviewLoading(false);
      return;
    }

    setPreviewLoading(true);
    const timer = window.setTimeout(() => {
      void loadPreview(entry, generation);
    }, 120);
    onCleanup(() => window.clearTimeout(timer));
  });

  onMount(() => {
    const agentId = paneAgentId();
    if (agentId) setPaneAgent(props.paneId, agentId);
    void loadDirectory(".");
  });

  async function request(command: string, args: string[], timeoutMs = 12_000): Promise<ResultMessage> {
    const agentId = paneAgentId();
    if (!agentId) throw new Error("no agent selected");
    if (connectionStatus() !== "connected") throw new Error("not connected to server");

    const envelope = buildCommand(agentId, command, args);
    bindRequest(envelope.id, props.paneId, true);
    try {
      if (!send(envelope)) throw new Error("failed to send request");
      const message = await waitForMessage(
        (candidate) => candidate.id === envelope.id &&
          (candidate.type === "result" || candidate.type === "error"),
        timeoutMs,
      );
      if (message.type === "error") {
        throw new Error(message.payload.message);
      }
      if (message.type !== "result") {
        throw new Error("unexpected response from agent");
      }
      if (message.payload.status !== "success") {
        throw new Error(message.payload.data || "agent request failed");
      }
      return message;
    } finally {
      completeRequest(envelope.id);
    }
  }

  async function fetchDirectory(path: string): Promise<DirectoryListing> {
    const result = await request("file-manager.list", [path]);
    if (result.payload.content_type !== "application/json") {
      throw new Error("agent does not support structured directory listings");
    }
    return parseDirectoryListing(result.payload.data);
  }

  async function loadDirectory(path: string, preferredName?: string) {
    const generation = ++directoryGeneration;
    setLoading(true);
    setError(null);
    setNotice(`loading ${path}`);
    try {
      const next = await fetchDirectory(path);
      if (generation !== directoryGeneration) return;

      setListing(next);
      setFilter("");
      const preferredIndex = preferredName
        ? next.entries.findIndex((entry) => entry.name === preferredName)
        : -1;
      setSelectedIndex(preferredIndex >= 0 ? preferredIndex : 0);
      setNotice(`${next.entries.length} entries${next.truncated ? " (truncated)" : ""}`);

      if (next.parent === next.path) {
        setParentListing(null);
      } else {
        void fetchDirectory(next.parent).then((parent) => {
          if (generation === directoryGeneration) setParentListing(parent);
        }).catch(() => {
          if (generation === directoryGeneration) setParentListing(null);
        });
      }
    } catch (cause) {
      if (generation !== directoryGeneration) return;
      const message = cause instanceof Error ? cause.message : "failed to load directory";
      setError(message);
      setNotice(message);
    } finally {
      if (generation === directoryGeneration) setLoading(false);
    }
  }

  async function loadPreview(entry: FileManagerEntry, generation: number) {
    try {
      if (entry.kind === "directory") {
        const directory = await fetchDirectory(entry.path);
        if (generation === previewGeneration) {
          setPreview({ kind: "directory", value: directory });
        }
      } else {
        const result = await request("file-manager.preview", [entry.path]);
        if (result.payload.content_type !== "application/json") {
          throw new Error("agent does not support structured previews");
        }
        const file = parseFilePreview(result.payload.data);
        if (generation === previewGeneration) {
          setPreview({ kind: "file", value: file });
        }
      }
    } catch (cause) {
      if (generation === previewGeneration) {
        setPreview(null);
        setNotice(cause instanceof Error ? cause.message : "preview unavailable");
      }
    } finally {
      if (generation === previewGeneration) setPreviewLoading(false);
    }
  }

  function scrollSelectionIntoView() {
    requestAnimationFrame(() => {
      currentListRef?.querySelector<HTMLElement>('[aria-selected="true"]')
        ?.scrollIntoView({ block: "nearest" });
    });
  }

  function moveSelection(delta: number) {
    const length = visibleEntries().length;
    if (!length) return;
    setSelectedIndex((index) => Math.min(length - 1, Math.max(0, index + delta)));
    scrollSelectionIntoView();
  }

  function selectBoundary(index: number) {
    const length = visibleEntries().length;
    if (!length) return;
    setSelectedIndex(index < 0 ? length - 1 : 0);
    scrollSelectionIntoView();
  }

  function openSelected() {
    const entry = selectedEntry();
    if (entry?.kind === "directory") void loadDirectory(entry.path);
  }

  function goParent() {
    const current = listing();
    if (!current || current.parent === current.path) return;
    void loadDirectory(current.parent, remoteBasename(current.path));
  }

  async function runMutation(command: "cp" | "mv" | "rm", args: string[]) {
    setNotice(`${command} in progress`);
    try {
      const result = await request(command, args, 30_000);
      setNotice(result.payload.data);
      await loadDirectory(listing()?.path ?? ".");
    } catch (cause) {
      setNotice(cause instanceof Error ? cause.message : `${command} failed`);
    }
  }

  function copySelected() {
    const entry = selectedEntry();
    if (!entry) return;
    const destination = window.prompt("Copy to remote path:", entry.path);
    if (destination && destination !== entry.path) void runMutation("cp", [entry.path, destination]);
  }

  function moveSelected() {
    const entry = selectedEntry();
    if (!entry) return;
    const destination = window.prompt("Move/rename to remote path:", entry.path);
    if (destination && destination !== entry.path) void runMutation("mv", [entry.path, destination]);
  }

  function removeSelected() {
    const entry = selectedEntry();
    if (!entry) return;
    if (entry.kind === "directory") {
      setNotice("directory removal is not supported");
      return;
    }
    if (window.confirm(`Delete "${entry.path}"? This cannot be undone.`)) {
      void runMutation("rm", [entry.path]);
    }
  }

  function downloadSelected() {
    const entry = selectedEntry();
    const agentId = paneAgentId();
    if (!entry || !agentId) return;
    if (entry.kind === "directory") {
      setNotice("select a file to download");
      return;
    }
    const envelope = buildCommand(agentId, "download", [entry.path]);
    bindRequest(envelope.id, props.paneId);
    if (!send(envelope)) {
      completeRequest(envelope.id);
      setNotice("download failed: disconnected");
      return;
    }
    setNotice(`downloading ${entry.name}`);
  }

  function beginSearch() {
    setSearching(true);
    requestAnimationFrame(() => {
      searchRef?.focus();
      searchRef?.select();
    });
  }

  function endSearch(clear = false) {
    if (clear) setFilter("");
    setSelectedIndex(0);
    setSearching(false);
    requestAnimationFrame(() => paneRef?.focus());
  }

  function handleKeyDown(event: KeyboardEvent) {
    if (event.shiftKey && ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Delete", "Backspace"].includes(event.key)) {
      return;
    }

    switch (event.key) {
      case "ArrowDown":
      case "j":
        event.preventDefault();
        moveSelection(1);
        break;
      case "ArrowUp":
      case "k":
        event.preventDefault();
        moveSelection(-1);
        break;
      case "ArrowRight":
      case "l":
      case "Enter":
        event.preventDefault();
        openSelected();
        break;
      case "ArrowLeft":
      case "h":
      case "Backspace":
        event.preventDefault();
        goParent();
        break;
      case "Home":
      case "g":
        event.preventDefault();
        selectBoundary(0);
        break;
      case "End":
      case "G":
        event.preventDefault();
        selectBoundary(-1);
        break;
      case "/":
        event.preventDefault();
        beginSearch();
        break;
      case "r":
        event.preventDefault();
        void loadDirectory(listing()?.path ?? ".");
        break;
      case "c":
        event.preventDefault();
        copySelected();
        break;
      case "m":
      case "F2":
        event.preventDefault();
        moveSelected();
        break;
      case "Delete":
        event.preventDefault();
        removeSelected();
        break;
      case "d":
        event.preventDefault();
        downloadSelected();
        break;
      case "q":
      case "Escape":
        event.preventDefault();
        props.onExit();
        break;
    }
  }

  function renderEntry(entry: FileManagerEntry, index: number) {
    const selected = () => index === selectedIndex();
    return (
      <button
        type="button"
        class={styles.entry}
        classList={{
          [styles.selected]: selected(),
          [styles.directory]: entry.kind === "directory",
        }}
        role="option"
        aria-selected={selected()}
        onClick={() => {
          setSelectedIndex(index);
          props.onFocus();
        }}
        onDblClick={openSelected}
      >
        <span class={styles.kind}>{entryMark(entry.kind)}</span>
        <span class={styles.name}>{entry.name}</span>
        <span class={styles.size}>{entry.kind === "directory" ? "" : formatFileSize(entry.size)}</span>
      </button>
    );
  }

  return (
    <div
      ref={paneRef}
      class={styles.pane}
      classList={{ [styles.active]: props.isActive }}
      tabindex={0}
      role="application"
      aria-label={`File manager for ${agent()?.hostname ?? "agent"}`}
      onFocus={props.onFocus}
      onPointerDown={props.onFocus}
      onKeyDown={handleKeyDown}
    >
      <header class={styles.header}>
        <span class={styles.title}>file-manager</span>
        <span class={styles.agent}>{agent()?.hostname ?? "no-agent"}</span>
        <span class={styles.path} title={listing()?.path}>{listing()?.path ?? "."}</span>
        <button type="button" class={styles.exit} onClick={props.onExit} aria-label="Exit file manager">×</button>
      </header>

      <div class={styles.columns}>
        <section class={`${styles.column} ${styles.parentColumn}`} aria-label="Parent directory">
          <div class={styles.columnTitle}>parent</div>
          <div class={styles.list}>
            <For each={parentListing()?.entries}>
              {(entry) => (
                <div
                  class={styles.previewEntry}
                  classList={{
                    [styles.parentCurrent]: entry.name === remoteBasename(listing()?.path ?? ""),
                    [styles.directory]: entry.kind === "directory",
                  }}
                >
                  <span class={styles.kind}>{entryMark(entry.kind)}</span>
                  <span class={styles.name}>{entry.name}</span>
                </div>
              )}
            </For>
          </div>
        </section>

        <section class={`${styles.column} ${styles.currentColumn}`} aria-label="Current directory">
          <div class={styles.columnTitle}>
            current
            <Show when={loading()}><span> loading…</span></Show>
          </div>
          <div class={styles.list} ref={currentListRef} role="listbox" aria-label="Directory entries">
            <Show when={error()}>
              <div class={styles.error}>{error()}</div>
            </Show>
            <For each={visibleEntries()} fallback={<div class={styles.empty}>(empty)</div>}>
              {(entry, index) => renderEntry(entry, index())}
            </For>
          </div>
        </section>

        <section class={`${styles.column} ${styles.previewColumn}`} aria-label="Selection preview">
          <div class={styles.columnTitle}>
            preview
            <Show when={previewLoading()}><span> loading…</span></Show>
          </div>
          <div class={styles.previewBody}>
            <Show when={preview()?.kind === "directory"}>
              <For each={(preview() as { kind: "directory"; value: DirectoryListing } | null)?.value.entries.slice(0, 500)}>
                {(entry) => (
                  <div class={styles.previewEntry} classList={{ [styles.directory]: entry.kind === "directory" }}>
                    <span class={styles.kind}>{entryMark(entry.kind)}</span>
                    <span class={styles.name}>{entry.name}</span>
                  </div>
                )}
              </For>
            </Show>
            <Show when={preview()?.kind === "file"}>
              {(() => {
                const file = () => (preview() as { kind: "file"; value: FilePreview }).value;
                return (
                  <>
                    <dl class={styles.metadata}>
                      <dt>name</dt><dd>{file().name}</dd>
                      <dt>size</dt><dd>{formatFileSize(file().size)}</dd>
                      <dt>modified</dt><dd>{modifiedLabel(file().modified)}</dd>
                      <dt>type</dt><dd>{file().binary ? "binary" : "text"}</dd>
                    </dl>
                    <Show
                      when={!file().binary}
                      fallback={<div class={styles.binary}>Binary preview unavailable.</div>}
                    >
                      <pre class={styles.textPreview}>{file().text}</pre>
                      <Show when={file().truncated}>
                        <div class={styles.truncated}>… preview truncated at 32 KiB …</div>
                      </Show>
                    </Show>
                  </>
                );
              })()}
            </Show>
          </div>
        </section>
      </div>

      <footer class={styles.footer}>
        <Show
          when={searching()}
          fallback={
            <>
              <span class={styles.notice}>{notice()}</span>
              <span class={styles.keys}>j/k move · h/l open · / filter · d download · c copy · m move · Del remove · r refresh · q exit</span>
            </>
          }
        >
          <label class={styles.search}>
            <span>/</span>
            <input
              ref={searchRef}
              value={filter()}
              onInput={(event) => {
                setFilter(event.currentTarget.value);
                setSelectedIndex(0);
              }}
              onKeyDown={(event) => {
                event.stopPropagation();
                if (event.key === "Enter") {
                  event.preventDefault();
                  endSearch();
                } else if (event.key === "Escape") {
                  event.preventDefault();
                  endSearch(true);
                }
              }}
              aria-label="Filter directory entries"
            />
          </label>
        </Show>
      </footer>
    </div>
  );
}
