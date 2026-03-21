"""Cross-platform network interface enumeration using ifaddr."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from base import DropfuPlugin, main

try:
    import ifaddr
except ImportError:
    ifaddr = None


def _format_adapters(adapters):
    lines = []
    for adapter in adapters:
        lines.append(f"{adapter.nice_name}:")
        if hasattr(adapter, "ips"):
            for ip in adapter.ips:
                if isinstance(ip.ip, tuple):
                    addr, flowinfo, scope_id = ip.ip[0], ip.ip[1], ip.ip[2]
                    lines.append(f"  IPv6: {addr}/{ip.network_prefix}")
                else:
                    lines.append(f"  IPv4: {ip.ip}/{ip.network_prefix}")
        lines.append("")
    return "\n".join(lines).rstrip()


class IpconfigPlugin(DropfuPlugin):
    name = "ipconfig"
    description = "Display network interface information"

    def run(self, args):
        if ifaddr is None:
            self.error("ifaddr library not available (pip install ifaddr)")
            return

        adapters = ifaddr.get_adapters()
        if not adapters:
            self.output("No network interfaces found.")
            return
        self.output(_format_adapters(adapters))


if __name__ == "__main__":
    main(IpconfigPlugin)
