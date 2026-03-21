"""Cross-platform ICMP ping using ping3."""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from base import DropfuPlugin, main

try:
    import ping3
except ImportError:
    ping3 = None


def do_ping(target, count=4, timeout=4):
    lines = [f"PING {target} ({count} packets, timeout {timeout}s)\n"]
    delays = []
    received = 0

    for seq in range(1, count + 1):
        try:
            delay = ping3.ping(target, timeout=timeout, seq=seq)
        except PermissionError:
            return "error: ICMP ping requires root/admin privileges"
        except OSError as e:
            lines.append(f"  seq={seq}: error - {e}")
            continue

        if delay is None:
            lines.append(f"  seq={seq}: Request timed out")
        elif delay is False:
            lines.append(f"  seq={seq}: Unknown host")
            break
        else:
            ms = delay * 1000
            delays.append(ms)
            received += 1
            lines.append(f"  seq={seq}: reply from {target}  time={ms:.1f}ms")

    loss_pct = ((count - received) / count) * 100 if count > 0 else 0
    lines.append(f"\n--- {target} ping statistics ---")
    lines.append(f"{count} transmitted, {received} received, {loss_pct:.0f}% loss")

    if delays:
        avg = sum(delays) / len(delays)
        mn = min(delays)
        mx = max(delays)
        lines.append(f"rtt min/avg/max = {mn:.1f}/{avg:.1f}/{mx:.1f} ms")

    return "\n".join(lines)


class PingPlugin(DropfuPlugin):
    name = "ping"
    description = "Ping a host"

    def run(self, args):
        if ping3 is None:
            self.error("ping3 library not available (pip install ping3)")
            return

        if not args:
            self.error("Usage: ping [--count N] [--timeout N] <target>")
            return

        count = 4
        timeout = 4
        target = None
        i = 0
        while i < len(args):
            if args[i] == "--count" and i + 1 < len(args):
                try:
                    count = int(args[i + 1])
                except ValueError:
                    self.error(f"Invalid count: {args[i + 1]}")
                    return
                i += 2
            elif args[i] == "--timeout" and i + 1 < len(args):
                try:
                    timeout = int(args[i + 1])
                except ValueError:
                    self.error(f"Invalid timeout: {args[i + 1]}")
                    return
                i += 2
            else:
                target = args[i]
                i += 1

        if not target:
            self.error("No target specified")
            return

        result = do_ping(target, count, timeout)
        self.output(result)


if __name__ == "__main__":
    main(PingPlugin)
