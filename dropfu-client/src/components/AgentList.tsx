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

function timeSince(epoch: number): string {
  const secs = Math.floor(Date.now() / 1000) - epoch;
  if (secs < 60) return `${secs}s`;
  if (secs < 3600) return `${Math.floor(secs / 60)}m`;
  return `${Math.floor(secs / 3600)}h`;
}

function statusClass(lastSeen: number): string {
  const age = Math.floor(Date.now() / 1000) - lastSeen;
  if (age < 60) return styles.statusGreen;
  if (age < 300) return styles.statusYellow;
  return styles.statusRed;
}

export default function AgentList(props: Props) {
  return (
    <aside class={styles.sidebar}>
      <div class={styles.header}>agents ({props.agents.length})</div>
      <ul class={styles.list}>
        {props.agents.map((a) => (
          <li
            class={styles.item}
            classList={{ [styles.selected]: a.agent_id === props.selectedId }}
            onClick={() => props.onSelect(a.agent_id)}
          >
            <span class={`${styles.statusDot} ${statusClass(a.last_seen)}`} />
            <span class={styles.badge}>{badge(a.privilege)}</span>
            <span class={styles.hostname}>{a.hostname}</span>
            <span class={styles.meta}>
              {a.os}/{a.arch}
            </span>
            <span class={styles.seen}>{timeSince(a.last_seen)}</span>
          </li>
        ))}
        {props.agents.length === 0 && (
          <li class={styles.empty}>no agents</li>
        )}
      </ul>
    </aside>
  );
}
