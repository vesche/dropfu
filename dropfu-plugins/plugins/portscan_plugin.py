"""Bounded TCP connect port scanner (stdlib only)."""

import argparse
import concurrent.futures
import socket
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from base import DropfuPlugin, main

DEFAULT_PORTS = [
    21, 22, 23, 25, 53, 80, 110, 111, 135, 139, 143, 443, 445, 993, 995,
    1433, 1521, 3306, 3389, 5432, 5900, 6379, 8080, 8443, 9200, 27017,
]


def parse_ports(spec: str):
    ports = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            start, end = int(a), int(b)
            if start > end:
                start, end = end, start
            if end - start > 2000:
                raise ValueError("port range too large (max 2000 ports)")
            ports.update(range(start, end + 1))
        else:
            ports.add(int(part))
    out = sorted(p for p in ports if 1 <= p <= 65535)
    if len(out) > 2000:
        raise ValueError("too many ports (max 2000)")
    return out


def probe(host, port, timeout):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return port, True
    except OSError:
        return port, False


class PortscanPlugin(DropfuPlugin):
    name = "portscan"
    description = "Bounded TCP port scanner"

    def run(self, args):
        parser = argparse.ArgumentParser(prog="portscan", add_help=False)
        parser.add_argument("--ports", default=None)
        parser.add_argument("--timeout", type=float, default=0.8)
        parser.add_argument("--workers", type=int, default=64)
        parser.add_argument("host")
        try:
            opts = parser.parse_args(args)
        except SystemExit:
            self.error("Usage: portscan [--ports 22,80,443|20-100] [--timeout 0.8] <host>")
            return

        try:
            ports = parse_ports(opts.ports) if opts.ports else DEFAULT_PORTS
        except ValueError as e:
            self.error(str(e))
            return

        workers = max(1, min(opts.workers, 128))
        timeout = max(0.1, min(opts.timeout, 5.0))

        open_ports = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            futs = [pool.submit(probe, opts.host, p, timeout) for p in ports]
            for fut in concurrent.futures.as_completed(futs):
                port, ok = fut.result()
                if ok:
                    open_ports.append(port)

        open_ports.sort()
        lines = [
            f"PORTSCAN {opts.host} ({len(ports)} ports, timeout {timeout}s)",
            f"open: {', '.join(str(p) for p in open_ports) if open_ports else '(none)'}",
            f"scanned={len(ports)} open={len(open_ports)}",
        ]
        self.output("\n".join(lines))


if __name__ == "__main__":
    main(PortscanPlugin)
