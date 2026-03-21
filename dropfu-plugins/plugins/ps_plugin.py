"""Cross-platform process listing using psutil."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from base import DropfuPlugin, main

try:
    import psutil
except ImportError:
    psutil = None


def _humanize_mem(nbytes):
    for unit in ("B", "KB", "MB", "GB"):
        if abs(nbytes) < 1024:
            return f"{nbytes:.1f}{unit}"
        nbytes /= 1024
    return f"{nbytes:.1f}TB"


def list_processes(sort_by="cpu", top_n=0):
    procs = []
    for p in psutil.process_iter(["pid", "name", "username", "cpu_percent", "memory_info", "status"]):
        try:
            info = p.info
            rss = info["memory_info"].rss if info["memory_info"] else 0
            procs.append({
                "pid": info["pid"],
                "user": (info["username"] or "?")[:12],
                "cpu": info["cpu_percent"] or 0.0,
                "rss": rss,
                "rss_h": _humanize_mem(rss),
                "status": (info["status"] or "?")[:8],
                "name": (info["name"] or "?")[:40],
            })
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            continue

    if sort_by == "cpu":
        procs.sort(key=lambda p: p["cpu"], reverse=True)
    elif sort_by == "mem":
        procs.sort(key=lambda p: p["rss"], reverse=True)
    elif sort_by == "pid":
        procs.sort(key=lambda p: p["pid"])

    if top_n > 0:
        procs = procs[:top_n]

    return procs


def format_processes(procs):
    lines = [f"{'PID':>7}  {'USER':<12}  {'CPU%':>5}  {'MEM':>8}  {'STATUS':<8}  COMMAND"]
    lines.append("-" * 72)
    for p in procs:
        lines.append(
            f"{p['pid']:>7}  {p['user']:<12}  {p['cpu']:>5.1f}  {p['rss_h']:>8}  {p['status']:<8}  {p['name']}"
        )
    lines.append(f"\nTotal: {len(procs)} processes")
    return "\n".join(lines)


class PsPlugin(DropfuPlugin):
    name = "ps"
    description = "List running processes"

    def run(self, args):
        if psutil is None:
            self.error("psutil library not available (pip install psutil)")
            return

        sort_by = "cpu"
        top_n = 0
        i = 0
        while i < len(args):
            if args[i] == "--sort" and i + 1 < len(args):
                sort_by = args[i + 1]
                if sort_by not in ("cpu", "mem", "pid"):
                    self.error(f"Invalid sort: {sort_by} (use cpu, mem, or pid)")
                    return
                i += 2
            elif args[i] == "--top" and i + 1 < len(args):
                try:
                    top_n = int(args[i + 1])
                except ValueError:
                    self.error(f"Invalid top count: {args[i + 1]}")
                    return
                i += 2
            else:
                self.error(f"Unknown argument: {args[i]}\nUsage: ps [--sort cpu|mem|pid] [--top N]")
                return

        procs = list_processes(sort_by, top_n)
        self.output(format_processes(procs))


if __name__ == "__main__":
    main(PsPlugin)
