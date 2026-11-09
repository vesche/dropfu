import { createSignal, onMount, onCleanup, Show } from "solid-js";
import CommandPane from "./CommandPane";
import { clearPaneOutput, deletePane, ensurePane } from "../state/session";
import styles from "./PaneManager.module.css";

type SplitDir = "horizontal" | "vertical";

interface LeafNode {
  kind: "leaf";
  id: string;
}

interface SplitNode {
  kind: "split";
  direction: SplitDir;
  children: [PaneNode, PaneNode];
  ratio: number;
}

type PaneNode = LeafNode | SplitNode;

let _paneCounter = 0;
function nextPaneId(): string {
  return `pane-${++_paneCounter}`;
}

function createLeaf(id?: string): LeafNode {
  const leaf = { kind: "leaf" as const, id: id ?? nextPaneId() };
  ensurePane(leaf.id);
  return leaf;
}

interface Props {
  activePaneId: string;
  onActivePaneChange: (id: string) => void;
}

export default function PaneManager(props: Props) {
  const [tree, setTree] = createSignal<PaneNode>(createLeaf("root"));
  const [dragging, setDragging] = createSignal<{
    path: number[];
    startPos: number;
    startRatio: number;
    horizontal: boolean;
  } | null>(null);

  function findAndReplace(
    node: PaneNode,
    targetId: string,
    replacer: (leaf: LeafNode) => PaneNode,
  ): PaneNode {
    if (node.kind === "leaf") {
      return node.id === targetId ? replacer(node) : node;
    }
    return {
      ...node,
      children: [
        findAndReplace(node.children[0], targetId, replacer),
        findAndReplace(node.children[1], targetId, replacer),
      ] as [PaneNode, PaneNode],
    };
  }

  function splitPane(direction: SplitDir, position: "before" | "after") {
    const newId = nextPaneId();
    setTree((t) =>
      findAndReplace(t, props.activePaneId, (leaf) => {
        const existing: LeafNode = { kind: "leaf", id: leaf.id };
        const fresh: LeafNode = createLeaf(newId);
        const children: [PaneNode, PaneNode] =
          position === "before" ? [fresh, existing] : [existing, fresh];
        return { kind: "split", direction, children, ratio: 0.5 };
      }),
    );
    props.onActivePaneChange(newId);
  }

  function collectLeafIds(node: PaneNode): string[] {
    if (node.kind === "leaf") return [node.id];
    return [...collectLeafIds(node.children[0]), ...collectLeafIds(node.children[1])];
  }

  function removePane(node: PaneNode, targetId: string): PaneNode | null {
    if (node.kind === "leaf") {
      return node.id === targetId ? null : node;
    }
    const left = removePane(node.children[0], targetId);
    const right = removePane(node.children[1], targetId);
    if (!left && !right) return null;
    if (!left) return right;
    if (!right) return left;
    return { ...node, children: [left, right] as [PaneNode, PaneNode] };
  }

  function closePane(id: string) {
    const leaves = collectLeafIds(tree());
    if (leaves.length <= 1) return;
    const closedIdx = leaves.indexOf(id);
    const result = removePane(tree(), id);
    if (result) {
      setTree(result);
      deletePane(id);
      if (props.activePaneId === id) {
        const remaining = collectLeafIds(result);
        const focusIdx = Math.min(closedIdx, remaining.length - 1);
        props.onActivePaneChange(remaining[Math.max(0, focusIdx)] ?? "root");
      }
    }
  }

  function firstLeaf(node: PaneNode): string {
    if (node.kind === "leaf") return node.id;
    return firstLeaf(node.children[0]);
  }

  function lastLeaf(node: PaneNode): string {
    if (node.kind === "leaf") return node.id;
    return lastLeaf(node.children[1]);
  }

  function findNeighbor(dir: "left" | "right" | "up" | "down"): string | null {
    const root = tree();
    const path: { node: SplitNode; childIdx: 0 | 1 }[] = [];

    function buildPath(node: PaneNode): boolean {
      if (node.kind === "leaf") return node.id === props.activePaneId;
      if (buildPath(node.children[0])) {
        path.push({ node, childIdx: 0 });
        return true;
      }
      if (buildPath(node.children[1])) {
        path.push({ node, childIdx: 1 });
        return true;
      }
      return false;
    }
    buildPath(root);

    const axis: SplitDir = (dir === "left" || dir === "right") ? "horizontal" : "vertical";
    const forward = dir === "right" || dir === "down";

    for (const step of path) {
      if (step.node.direction !== axis) continue;
      if (forward && step.childIdx === 0) return firstLeaf(step.node.children[1]);
      if (!forward && step.childIdx === 1) return lastLeaf(step.node.children[0]);
    }
    return null;
  }

  function updateRatioAt(node: PaneNode, path: number[], ratio: number): PaneNode {
    if (path.length === 0 || node.kind === "leaf") {
      if (node.kind === "split") return { ...node, ratio };
      return node;
    }
    const idx = path[0]!;
    const rest = path.slice(1);
    const children = [...node.children] as [PaneNode, PaneNode];
    children[idx] = updateRatioAt(children[idx]!, rest, ratio) as PaneNode;
    if (rest.length === 0) {
      return { ...node, ratio: Math.min(0.85, Math.max(0.15, ratio)), children };
    }
    return { ...node, children };
  }

  function handleKeyDown(e: KeyboardEvent) {
    if (!e.shiftKey) return;
    // Don't steal keys when modifier chord is for browser shortcuts beyond our map.
    if (e.ctrlKey) {
      const dirMap: Record<string, "left" | "right" | "up" | "down"> = {
        ArrowLeft: "left", ArrowRight: "right",
        ArrowUp: "up", ArrowDown: "down",
      };
      const dir = dirMap[e.key];
      if (dir) {
        e.preventDefault();
        const target = findNeighbor(dir);
        if (target) props.onActivePaneChange(target);
      }
      return;
    }

    switch (e.key) {
      case "ArrowRight":
        e.preventDefault();
        splitPane("horizontal", "after");
        break;
      case "ArrowLeft":
        e.preventDefault();
        splitPane("horizontal", "before");
        break;
      case "ArrowDown":
        e.preventDefault();
        splitPane("vertical", "after");
        break;
      case "ArrowUp":
        e.preventDefault();
        splitPane("vertical", "before");
        break;
      case "Delete":
        e.preventDefault();
        closePane(props.activePaneId);
        break;
      case "Backspace":
        e.preventDefault();
        clearPaneOutput(props.activePaneId);
        break;
    }
  }

  function onPointerMove(e: PointerEvent) {
    const d = dragging();
    if (!d) return;
    const delta = d.horizontal ? e.clientX - d.startPos : e.clientY - d.startPos;
    // Approximate using window size; good enough for smooth resize.
    const span = d.horizontal ? window.innerWidth : window.innerHeight;
    const ratio = d.startRatio + delta / Math.max(span, 1);
    setTree((t) => updateRatioAt(t, d.path, ratio));
  }

  function onPointerUp() {
    setDragging(null);
  }

  onMount(() => {
    window.addEventListener("keydown", handleKeyDown);
    window.addEventListener("pointermove", onPointerMove);
    window.addEventListener("pointerup", onPointerUp);
    onCleanup(() => {
      window.removeEventListener("keydown", handleKeyDown);
      window.removeEventListener("pointermove", onPointerMove);
      window.removeEventListener("pointerup", onPointerUp);
    });
  });

  function renderNode(node: PaneNode, path: number[] = []): any {
    if (node.kind === "leaf") {
      const leaves = collectLeafIds(tree());
      const canClose = leaves.length > 1;
      return (
        <div class={styles.leafWrap}>
          <Show when={canClose}>
            <button
              class={styles.closeBtn}
              onClick={(e) => {
                e.stopPropagation();
                closePane(node.id);
              }}
              title="Close pane"
              aria-label="Close pane"
            >
              ×
            </button>
          </Show>
          <CommandPane
            paneId={node.id}
            isActive={node.id === props.activePaneId}
            onFocus={() => props.onActivePaneChange(node.id)}
          />
        </div>
      );
    }

    const isHorizontal = node.direction === "horizontal";
    return (
      <div
        class={styles.split}
        style={{ "flex-direction": isHorizontal ? "row" : "column" }}
      >
        <div class={styles.splitChild} style={{ flex: `${node.ratio} 1 0%` }}>
          {renderNode(node.children[0], [...path, 0])}
        </div>
        <div
          class={isHorizontal ? styles.gutterH : styles.gutterV}
          role="separator"
          aria-orientation={isHorizontal ? "vertical" : "horizontal"}
          onPointerDown={(e) => {
            e.preventDefault();
            (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
            setDragging({
              path,
              startPos: isHorizontal ? e.clientX : e.clientY,
              startRatio: node.ratio,
              horizontal: isHorizontal,
            });
          }}
        />
        <div class={styles.splitChild} style={{ flex: `${1 - node.ratio} 1 0%` }}>
          {renderNode(node.children[1], [...path, 1])}
        </div>
      </div>
    );
  }

  return <div class={styles.container}>{renderNode(tree())}</div>;
}
