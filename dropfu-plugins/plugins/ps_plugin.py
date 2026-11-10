"""Cross-platform process listing without endpoint Python dependencies."""

import csv
import os
import subprocess
import sys

if sys.platform != "win32":
    import pwd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from base import DropfuPlugin, main

def _humanize_mem(nbytes):
    for unit in ("B", "KB", "MB", "GB"):
        if abs(nbytes) < 1024:
            return f"{nbytes:.1f}{unit}"
        nbytes /= 1024
    return f"{nbytes:.1f}TB"


def _linux_processes():
    page_size = os.sysconf("SC_PAGE_SIZE")
    clock_ticks = os.sysconf("SC_CLK_TCK")
    with open("/proc/uptime", encoding="ascii") as uptime_file:
        uptime = float(uptime_file.read().split()[0])

    processes = []
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit():
            continue
        try:
            stat_text = open(
                os.path.join(entry.path, "stat"), encoding="utf-8", errors="replace"
            ).read()
            close_paren = stat_text.rfind(")")
            name = stat_text[stat_text.find("(") + 1 : close_paren]
            fields = stat_text[close_paren + 2 :].split()
            state = fields[0]
            cpu_seconds = (int(fields[11]) + int(fields[12])) / clock_ticks
            age_seconds = max(uptime - (int(fields[19]) / clock_ticks), 0.001)
            rss = int(fields[21]) * page_size

            uid = None
            with open(
                os.path.join(entry.path, "status"), encoding="utf-8", errors="replace"
            ) as status_file:
                for line in status_file:
                    if line.startswith("Uid:"):
                        uid = int(line.split()[1])
                        break
            try:
                user = pwd.getpwuid(uid).pw_name if uid is not None else "?"
            except KeyError:
                user = str(uid) if uid is not None else "?"

            processes.append(
                {
                    "pid": int(entry.name),
                    "user": user[:12],
                    "cpu": (cpu_seconds / age_seconds) * 100.0,
                    "rss": rss,
                    "rss_h": _humanize_mem(rss),
                    "status": state,
                    "name": name[:40],
                }
            )
        except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError, IndexError):
            continue
    return processes


def _posix_processes():
    ps = "/bin/ps" if os.path.exists("/bin/ps") else "/usr/bin/ps"
    result = subprocess.run(
        [ps, "-axo", "pid=,user=,%cpu=,rss=,state=,comm="],
        capture_output=True,
        text=True,
        timeout=20,
        check=True,
    )
    processes = []
    for line in result.stdout.splitlines():
        parts = line.split(None, 5)
        if len(parts) != 6:
            continue
        try:
            pid, user, cpu, rss_kb, status, name = parts
            rss = int(rss_kb) * 1024
            processes.append(
                {
                    "pid": int(pid),
                    "user": user[:12],
                    "cpu": float(cpu),
                    "rss": rss,
                    "rss_h": _humanize_mem(rss),
                    "status": status[:8],
                    "name": name[:40],
                }
            )
        except ValueError:
            continue
    return processes


def _windows_processes():
    system_root = os.environ.get("SystemRoot", r"C:\Windows")
    tasklist = os.path.join(system_root, "System32", "tasklist.exe")
    result = subprocess.run(
        [tasklist, "/FO", "CSV", "/NH"],
        capture_output=True,
        text=True,
        timeout=20,
        check=True,
    )
    processes = []
    for row in csv.reader(result.stdout.splitlines()):
        if len(row) < 5 or not row[1].isdigit():
            continue
        rss = int("".join(character for character in row[4] if character.isdigit()) or 0) * 1024
        processes.append(
            {
                "pid": int(row[1]),
                "user": "?",
                "cpu": 0.0,
                "rss": rss,
                "rss_h": _humanize_mem(rss),
                "status": row[2][:8],
                "name": row[0][:40],
            }
        )
    return processes


def list_processes(sort_by="cpu", top_n=0):
    if sys.platform.startswith("linux"):
        procs = _linux_processes()
    elif sys.platform == "win32":
        procs = _windows_processes()
    else:
        procs = _posix_processes()

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
