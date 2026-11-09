import { For, createSignal, onMount, onCleanup } from "solid-js";
import type { AgentEntry } from "../lib/protocol";
import styles from "./AgentList.module.css";

interface Props {
  agents: AgentEntry[];
  selectedId: string | null;
  onSelect: (id: string) => void;
}

function badge(privilege: string): string {
  return privilege === "root" || privilege === "admin" ? "#" : "$";
}

function timeSince(epoch: number, now: number): string {
  const secs = Math.max(0, Math.floor(now / 1000) - epoch);
  if (secs < 60) return `${secs}s`;
  if (secs < 3600) return `${Math.floor(secs / 60)}m`;
  return `${Math.floor(secs / 3600)}h`;
}

function statusClass(lastSeen: number, now: number): string {
  const age = Math.floor(now / 1000) - lastSeen;
  if (age < 60) return styles.statusGreen;
  if (age < 300) return styles.statusYellow;
  return styles.statusRed;
}

export default function AgentList(props: Props) {
  const [now, setNow] = createSignal(Date.now());
  onMount(() => {
    const t = setInterval(() => setNow(Date.now()), 5000);
    onCleanup(() => clearInterval(t));
  });

  function onKeyDown(e: KeyboardEvent, id: string, index: number) {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      props.onSelect(id);
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      const next = props.agents[index + 1];
      if (next) props.onSelect(next.agent_id);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      const prev = props.agents[index - 1];
      if (prev) props.onSelect(prev.agent_id);
    }
  }

  return (
    <aside class={styles.sidebar} aria-label="Connected agents">
      <div class={styles.header} id="agent-list-label">agents ({props.agents.length})</div>
      <ul class={styles.list} role="listbox" aria-labelledby="agent-list-label">
        <For each={props.agents} fallback={<li class={styles.empty}>no agents</li>}>
          {(a, i) => (
            <li
              class={styles.item}
              classList={{ [styles.selected]: a.agent_id === props.selectedId }}
              role="option"
              aria-selected={a.agent_id === props.selectedId}
              tabindex={0}
              onClick={() => props.onSelect(a.agent_id)}
              onKeyDown={(e) => onKeyDown(e, a.agent_id, i())}
            >
              <span
                class={`${styles.statusDot} ${statusClass(a.last_seen, now())}`}
                aria-label={a.last_seen ? `last seen ${timeSince(a.last_seen, now())}` : "unknown"}
              />
              <span class={styles.badge} aria-label={`privilege ${a.privilege}`}>{badge(a.privilege)}</span>
              <span class={styles.hostname}>{a.hostname}</span>
              <span class={styles.meta}>{a.os}/{a.arch}</span>
              <span class={styles.seen}>{timeSince(a.last_seen, now())}</span>
            </li>
          )}
        </For>
      </ul>
    </aside>
  );
}
