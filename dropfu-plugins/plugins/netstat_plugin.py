"""Cross-platform socket table without calling endpoint binaries.

Linux reads /proc/net and /proc/<pid>/fd. Windows calls iphlpapi.
macOS calls libproc. psutil is not bundled: it ships native extensions,
and plugin zipapps accept only pure Python.

Nothing in this plugin executes netstat, ss, or lsof.
"""

import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from base import DropfuPlugin, main

LINUX_TCP_STATES = {
    "01": "ESTABLISHED",
    "02": "SYN_SENT",
    "03": "SYN_RECV",
    "04": "FIN_WAIT1",
    "05": "FIN_WAIT2",
    "06": "TIME_WAIT",
    "07": "CLOSED",
    "08": "CLOSE_WAIT",
    "09": "LAST_ACK",
    "0A": "LISTEN",
    "0B": "CLOSING",
}

# MIB_TCP_STATE. Display names match the Linux table so --state is portable.
WINDOWS_TCP_STATES = {
    1: "CLOSED",
    2: "LISTEN",
    3: "SYN_SENT",
    4: "SYN_RECV",
    5: "ESTABLISHED",
    6: "FIN_WAIT1",
    7: "FIN_WAIT2",
    8: "CLOSE_WAIT",
    9: "CLOSING",
    10: "LAST_ACK",
    11: "TIME_WAIT",
    12: "DELETE_TCB",
}

# tcp_fsm.h / TSI_S_* on Darwin.
DARWIN_TCP_STATES = {
    0: "CLOSED",
    1: "LISTEN",
    2: "SYN_SENT",
    3: "SYN_RECV",
    4: "ESTABLISHED",
    5: "CLOSE_WAIT",
    6: "FIN_WAIT1",
    7: "CLOSING",
    8: "LAST_ACK",
    9: "FIN_WAIT2",
    10: "TIME_WAIT",
}

USAGE = "Usage: netstat [--tcp] [--udp] [--listen] [--state STATE]"


def parse_netstat_args(args):
    tcp = False
    udp = False
    listen_only = False
    state = None
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--tcp":
            tcp = True
        elif arg == "--udp":
            udp = True
        elif arg == "--listen":
            listen_only = True
        elif arg == "--state" and index + 1 < len(args):
            state = args[index + 1].upper()
            index += 1
        else:
            return None, USAGE
        index += 1
    if not tcp and not udp:
        tcp = True
        udp = True
    return {
        "tcp": tcp,
        "udp": udp,
        "listen_only": listen_only,
        "state": state,
    }, None


def decode_proc_address(hex_ip):
    """Decode a /proc/net address. IPv4 is 8 hex chars, IPv6 is 32."""
    if len(hex_ip) == 8:
        raw = int(hex_ip, 16).to_bytes(4, "little")
        return socket.inet_ntop(socket.AF_INET, raw)
    if len(hex_ip) == 32:
        raw = b"".join(
            int(hex_ip[offset : offset + 8], 16).to_bytes(4, "little")
            for offset in range(0, 32, 8)
        )
        return socket.inet_ntop(socket.AF_INET6, raw)
    raise ValueError(f"unrecognized address {hex_ip!r}")


def parse_proc_net_line(line, proto):
    parts = line.split()
    if len(parts) < 10 or not parts[0].endswith(":"):
        return None
    try:
        local_hex, local_port = parts[1].rsplit(":", 1)
        remote_hex, remote_port = parts[2].rsplit(":", 1)
        return {
            "proto": proto,
            "local_ip": decode_proc_address(local_hex),
            "local_port": int(local_port, 16),
            "remote_ip": decode_proc_address(remote_hex),
            "remote_port": int(remote_port, 16),
            "state": _proc_state(proto, parts[3], int(remote_port, 16)),
            "inode": int(parts[9]),
            "pid": 0,
            "program": "",
        }
    except (ValueError, OSError):
        return None


def parse_proc_net(text, proto):
    rows = []
    for line in text.splitlines():
        row = parse_proc_net_line(line, proto)
        if row is not None:
            rows.append(row)
    return rows


def _proc_state(proto, state_hex, remote_port):
    if proto.startswith("udp"):
        if state_hex == "01" and remote_port:
            return "ESTABLISHED"
        return "UNCONN"
    return LINUX_TCP_STATES.get(state_hex.upper(), f"UNKNOWN_{state_hex}")


def filter_connections(rows, tcp=True, udp=True, listen_only=False, state=None):
    selected = []
    for row in rows:
        kind = "tcp" if row["proto"].startswith("tcp") else "udp"
        if kind == "tcp" and not tcp:
            continue
        if kind == "udp" and not udp:
            continue
        if listen_only:
            if kind == "tcp" and row["state"] != "LISTEN":
                continue
            if kind == "udp" and row["remote_port"] != 0:
                continue
        if state is not None and row["state"] != state:
            continue
        selected.append(row)
    selected.sort(key=lambda row: (row["proto"], row["local_port"], row["remote_port"], row["local_ip"]))
    return selected


def format_endpoint(ip, port, remote):
    if remote and port == 0:
        return "*:*"
    host = f"[{ip}]" if ":" in ip else ip
    return f"{host}:{port}"


def format_owner(pid, program):
    if not pid:
        return "-"
    if program:
        return f"{pid}/{program}"
    return str(pid)


def format_connections(rows):
    rendered = [("Proto", "Local Address", "Foreign Address", "State", "PID/Program")]
    for row in rows:
        rendered.append(
            (
                row["proto"],
                format_endpoint(row["local_ip"], row["local_port"], remote=False),
                format_endpoint(row["remote_ip"], row["remote_port"], remote=True),
                row["state"],
                format_owner(row["pid"], row["program"]),
            )
        )
    widths = [max(len(item[column]) for item in rendered) for column in range(5)]
    lines = [
        "  ".join(cell.ljust(widths[column]) for column, cell in enumerate(item))
        for item in rendered
    ]
    lines.append(f"\n{len(rows)} connection(s)")
    return "\n".join(lines)


def collect_connections():
    if sys.platform.startswith("linux"):
        return _linux_connections()
    if sys.platform == "win32":
        return _windows_connections()
    if sys.platform == "darwin":
        return _darwin_connections()
    raise OSError(f"netstat is not implemented for {sys.platform}")


def _linux_connections():
    rows = []
    for name in ("tcp", "tcp6", "udp", "udp6"):
        path = os.path.join("/proc/net", name)
        try:
            with open(path, encoding="ascii", errors="replace") as handle:
                text = handle.read()
        except FileNotFoundError:
            continue
        rows.extend(parse_proc_net(text, name))
    return _attach_linux_owners(rows)


def _attach_linux_owners(rows):
    owners = _linux_socket_owners()
    names = {}
    attached = []
    for row in rows:
        pid = owners.get(row["inode"], 0)
        program = ""
        if pid:
            program = names.get(pid)
            if program is None:
                program = _linux_comm(pid)
                names[pid] = program
        owned = dict(row)
        owned["pid"] = pid
        owned["program"] = program
        attached.append(owned)
    return attached


def _linux_socket_owners():
    """Map socket inode to a pid by reading /proc/<pid>/fd symlinks."""
    owners = {}
    try:
        with os.scandir("/proc") as entries:
            proc_entries = list(entries)
    except OSError:
        return owners
    for entry in proc_entries:
        if not entry.name.isdigit():
            continue
        fd_dir = os.path.join(entry.path, "fd")
        try:
            with os.scandir(fd_dir) as fd_entries:
                fds = list(fd_entries)
        except OSError:
            continue
        pid = int(entry.name)
        for fd in fds:
            try:
                target = os.readlink(fd.path)
            except OSError:
                continue
            if not (target.startswith("socket:[") and target.endswith("]")):
                continue
            try:
                inode = int(target[8:-1])
            except ValueError:
                continue
            owners.setdefault(inode, pid)
    return owners


def _linux_comm(pid):
    path = os.path.join("/proc", str(pid), "comm")
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def windows_ipv4(value):
    """IPv4 DWORD from IP Helper is the in-memory network-order address."""
    return socket.inet_ntoa(value.to_bytes(4, "little"))


def windows_port(value):
    return socket.ntohs(value & 0xFFFF)


def _windows_connections():
    import ctypes
    from ctypes import wintypes

    iphlpapi = ctypes.WinDLL("iphlpapi")
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    class TcpRow(ctypes.Structure):
        _fields_ = [
            ("dwState", wintypes.DWORD),
            ("dwLocalAddr", wintypes.DWORD),
            ("dwLocalPort", wintypes.DWORD),
            ("dwRemoteAddr", wintypes.DWORD),
            ("dwRemotePort", wintypes.DWORD),
            ("dwOwningPid", wintypes.DWORD),
        ]

    class Tcp6Row(ctypes.Structure):
        _fields_ = [
            ("ucLocalAddr", wintypes.BYTE * 16),
            ("dwLocalScopeId", wintypes.DWORD),
            ("dwLocalPort", wintypes.DWORD),
            ("ucRemoteAddr", wintypes.BYTE * 16),
            ("dwRemoteScopeId", wintypes.DWORD),
            ("dwRemotePort", wintypes.DWORD),
            ("dwState", wintypes.DWORD),
            ("dwOwningPid", wintypes.DWORD),
        ]

    class UdpRow(ctypes.Structure):
        _fields_ = [
            ("dwLocalAddr", wintypes.DWORD),
            ("dwLocalPort", wintypes.DWORD),
            ("dwOwningPid", wintypes.DWORD),
        ]

    class Udp6Row(ctypes.Structure):
        _fields_ = [
            ("ucLocalAddr", wintypes.BYTE * 16),
            ("dwLocalScopeId", wintypes.DWORD),
            ("dwLocalPort", wintypes.DWORD),
            ("dwOwningPid", wintypes.DWORD),
        ]

    get_tcp = iphlpapi.GetExtendedTcpTable
    get_udp = iphlpapi.GetExtendedUdpTable
    for fn in (get_tcp, get_udp):
        fn.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(wintypes.DWORD),
            wintypes.BOOL,
            wintypes.ULONG,
            ctypes.c_int,
            wintypes.ULONG,
        ]
        fn.restype = wintypes.DWORD

    names = {}

    def program(pid):
        if pid in names:
            return names[pid]
        names[pid] = _windows_program(kernel32, pid)
        return names[pid]

    rows = []
    for row in _windows_table(get_tcp, 2, 5, TcpRow):
        pid = int(row.dwOwningPid)
        rows.append(
            {
                "proto": "tcp",
                "local_ip": windows_ipv4(int(row.dwLocalAddr)),
                "local_port": windows_port(int(row.dwLocalPort)),
                "remote_ip": windows_ipv4(int(row.dwRemoteAddr)),
                "remote_port": windows_port(int(row.dwRemotePort)),
                "state": WINDOWS_TCP_STATES.get(int(row.dwState), "UNKNOWN"),
                "pid": pid,
                "program": program(pid),
            }
        )
    for row in _windows_table(get_tcp, 23, 5, Tcp6Row):
        pid = int(row.dwOwningPid)
        rows.append(
            {
                "proto": "tcp6",
                "local_ip": _windows_ipv6(row.ucLocalAddr, int(row.dwLocalScopeId)),
                "local_port": windows_port(int(row.dwLocalPort)),
                "remote_ip": _windows_ipv6(row.ucRemoteAddr, int(row.dwRemoteScopeId)),
                "remote_port": windows_port(int(row.dwRemotePort)),
                "state": WINDOWS_TCP_STATES.get(int(row.dwState), "UNKNOWN"),
                "pid": pid,
                "program": program(pid),
            }
        )
    # The owner-PID UDP table has no remote endpoint. netstat -ano shows *:* there too.
    for row in _windows_table(get_udp, 2, 1, UdpRow):
        pid = int(row.dwOwningPid)
        rows.append(
            {
                "proto": "udp",
                "local_ip": windows_ipv4(int(row.dwLocalAddr)),
                "local_port": windows_port(int(row.dwLocalPort)),
                "remote_ip": "0.0.0.0",
                "remote_port": 0,
                "state": "UNCONN",
                "pid": pid,
                "program": program(pid),
            }
        )
    for row in _windows_table(get_udp, 23, 1, Udp6Row):
        pid = int(row.dwOwningPid)
        rows.append(
            {
                "proto": "udp6",
                "local_ip": _windows_ipv6(row.ucLocalAddr, int(row.dwLocalScopeId)),
                "local_port": windows_port(int(row.dwLocalPort)),
                "remote_ip": "::",
                "remote_port": 0,
                "state": "UNCONN",
                "pid": pid,
                "program": program(pid),
            }
        )
    return rows


def _windows_ipv6(raw, scope_id):
    address = socket.inet_ntop(socket.AF_INET6, bytes(raw))
    if scope_id and address.lower().startswith("fe80"):
        return f"{address}%{scope_id}"
    return address


def _windows_table(fn, family, table_class, row_type):
    import ctypes
    from ctypes import wintypes

    error_insufficient = 122
    size = wintypes.DWORD(0)
    ret = fn(None, ctypes.byref(size), 0, family, table_class, 0)
    if ret not in (0, error_insufficient):
        raise ctypes.WinError(ret)
    for _ in range(3):
        buf = ctypes.create_string_buffer(max(size.value, 4))
        ret = fn(buf, ctypes.byref(size), 0, family, table_class, 0)
        if ret == 0:
            break
        if ret != error_insufficient:
            raise ctypes.WinError(ret)
    else:
        raise ctypes.WinError(ret)
    count = ctypes.cast(buf, ctypes.POINTER(wintypes.DWORD)).contents.value
    if count <= 0:
        return []
    row_size = ctypes.sizeof(row_type)
    available = max(0, (len(buf) - ctypes.sizeof(wintypes.DWORD)) // row_size)
    count = min(count, available)
    rows = ctypes.cast(
        ctypes.addressof(buf) + ctypes.sizeof(wintypes.DWORD),
        ctypes.POINTER(row_type * count),
    ).contents
    return list(rows)


def _windows_program(kernel32, pid):
    import ctypes
    from ctypes import wintypes

    if pid <= 0:
        return ""
    process_query = 0x1000
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL
    kernel32.QueryFullProcessImageNameW.argtypes = [
        wintypes.HANDLE,
        wintypes.DWORD,
        wintypes.LPWSTR,
        ctypes.POINTER(wintypes.DWORD),
    ]
    kernel32.QueryFullProcessImageNameW.restype = wintypes.BOOL

    handle = kernel32.OpenProcess(process_query, 0, pid)
    if not handle:
        return ""
    try:
        size = wintypes.DWORD(32768)
        buffer = ctypes.create_unicode_buffer(size.value)
        if not kernel32.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
            return ""
        return os.path.basename(buffer.value)
    finally:
        kernel32.CloseHandle(handle)


# LP64 layout from bsd/sys/proc_info.h. The unix-socket arm of the union is what
# makes socket_fdinfo large enough for proc_pidfdinfo to fill it.
def _darwin_structs():
    import ctypes

    class VinfoStat(ctypes.Structure):
        _fields_ = [
            ("vst_dev", ctypes.c_uint32),
            ("vst_mode", ctypes.c_uint16),
            ("vst_nlink", ctypes.c_uint16),
            ("vst_ino", ctypes.c_uint64),
            ("vst_uid", ctypes.c_uint32),
            ("vst_gid", ctypes.c_uint32),
            ("vst_atime", ctypes.c_int64),
            ("vst_atimensec", ctypes.c_int64),
            ("vst_mtime", ctypes.c_int64),
            ("vst_mtimensec", ctypes.c_int64),
            ("vst_ctime", ctypes.c_int64),
            ("vst_ctimensec", ctypes.c_int64),
            ("vst_birthtime", ctypes.c_int64),
            ("vst_birthtimensec", ctypes.c_int64),
            ("vst_size", ctypes.c_int64),
            ("vst_blocks", ctypes.c_int64),
            ("vst_blksize", ctypes.c_int32),
            ("vst_flags", ctypes.c_uint32),
            ("vst_gen", ctypes.c_uint32),
            ("vst_rdev", ctypes.c_uint32),
            ("vst_qspare", ctypes.c_int64 * 2),
        ]

    class In4In6(ctypes.Structure):
        _fields_ = [("pad", ctypes.c_uint32 * 3), ("addr4", ctypes.c_uint32)]

    class In6Addr(ctypes.Structure):
        _fields_ = [("bytes", ctypes.c_uint8 * 16)]

    class AddrUnion(ctypes.Union):
        _fields_ = [("ina_46", In4In6), ("ina_6", In6Addr)]

    class InsiV4(ctypes.Structure):
        _fields_ = [("in4_tos", ctypes.c_uint8)]

    class InsiV6(ctypes.Structure):
        _fields_ = [
            ("in6_hlim", ctypes.c_uint8),
            ("in6_cksum", ctypes.c_int),
            ("in6_ifindex", ctypes.c_uint16),
            ("in6_hops", ctypes.c_short),
        ]

    class InSockInfo(ctypes.Structure):
        _fields_ = [
            ("insi_fport", ctypes.c_int),
            ("insi_lport", ctypes.c_int),
            ("insi_gencnt", ctypes.c_uint64),
            ("insi_flags", ctypes.c_uint32),
            ("insi_flow", ctypes.c_uint32),
            ("insi_vflag", ctypes.c_uint8),
            ("insi_ip_ttl", ctypes.c_uint8),
            ("rfu_1", ctypes.c_uint32),
            ("insi_faddr", AddrUnion),
            ("insi_laddr", AddrUnion),
            ("insi_v4", InsiV4),
            ("insi_v6", InsiV6),
        ]

    class TcpSockInfo(ctypes.Structure):
        _fields_ = [
            ("tcpsi_ini", InSockInfo),
            ("tcpsi_state", ctypes.c_int),
            ("tcpsi_timer", ctypes.c_int * 4),
            ("tcpsi_mss", ctypes.c_int),
            ("tcpsi_flags", ctypes.c_uint32),
            ("rfu_1", ctypes.c_uint32),
            ("tcpsi_tp", ctypes.c_uint64),
        ]

    class UnSockInfo(ctypes.Structure):
        _fields_ = [
            ("unsi_conn_so", ctypes.c_uint64),
            ("unsi_conn_pcb", ctypes.c_uint64),
            ("unsi_addr", ctypes.c_char * 255),
            ("unsi_caddr", ctypes.c_char * 255),
        ]

    class SockbufInfo(ctypes.Structure):
        _fields_ = [
            ("sbi_cc", ctypes.c_uint32),
            ("sbi_hiwat", ctypes.c_uint32),
            ("sbi_mbcnt", ctypes.c_uint32),
            ("sbi_mbmax", ctypes.c_uint32),
            ("sbi_lowat", ctypes.c_uint32),
            ("sbi_flags", ctypes.c_short),
            ("sbi_timeo", ctypes.c_short),
        ]

    class ProtoUnion(ctypes.Union):
        _fields_ = [("pri_tcp", TcpSockInfo), ("pri_un", UnSockInfo)]

    class SocketInfo(ctypes.Structure):
        _fields_ = [
            ("soi_stat", VinfoStat),
            ("soi_so", ctypes.c_uint64),
            ("soi_pcb", ctypes.c_uint64),
            ("soi_type", ctypes.c_int),
            ("soi_protocol", ctypes.c_int),
            ("soi_family", ctypes.c_int),
            ("soi_options", ctypes.c_short),
            ("soi_linger", ctypes.c_short),
            ("soi_state", ctypes.c_short),
            ("soi_qlen", ctypes.c_short),
            ("soi_incqlen", ctypes.c_short),
            ("soi_qlimit", ctypes.c_short),
            ("soi_timeo", ctypes.c_short),
            ("soi_error", ctypes.c_uint16),
            ("soi_oobmark", ctypes.c_uint32),
            ("soi_rcv", SockbufInfo),
            ("soi_snd", SockbufInfo),
            ("soi_kind", ctypes.c_int),
            ("rfu_1", ctypes.c_uint32),
            ("soi_proto", ProtoUnion),
        ]

    class ProcFileInfo(ctypes.Structure):
        _fields_ = [
            ("fi_openflags", ctypes.c_uint32),
            ("fi_status", ctypes.c_uint32),
            ("fi_offset", ctypes.c_int64),
            ("fi_type", ctypes.c_int32),
            ("fi_guardflags", ctypes.c_uint32),
        ]

    class SocketFdInfo(ctypes.Structure):
        _fields_ = [("pfi", ProcFileInfo), ("psi", SocketInfo)]

    class ProcFdInfo(ctypes.Structure):
        _fields_ = [("proc_fd", ctypes.c_int32), ("proc_fdtype", ctypes.c_uint32)]

    return SocketFdInfo, ProcFdInfo, InSockInfo, TcpSockInfo


SocketFdInfo, ProcFdInfo, InSockInfo, TcpSockInfo = _darwin_structs()


def _darwin_connections():
    import ctypes

    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    libc.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
    libc.proc_listpids.restype = ctypes.c_int
    libc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    libc.proc_pidinfo.restype = ctypes.c_int
    libc.proc_pidfdinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
    libc.proc_pidfdinfo.restype = ctypes.c_int
    libc.proc_name.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    libc.proc_name.restype = ctypes.c_int

    proc_all_pids = 1
    proc_pidlistfds = 1
    proc_pidfdsocketinfo = 3
    prox_fdtype_socket = 2
    af_inet = 2
    af_inet6 = 30
    sock_stream = 1
    sock_dgram = 2
    sockinfo_tcp = 2
    ini_ipv4 = 0x1

    names = {}
    seen = set()
    rows = []
    for pid in _darwin_pids(libc, proc_all_pids):
        for fd, fdtype in _darwin_fds(libc, pid, proc_pidlistfds):
            if fdtype != prox_fdtype_socket:
                continue
            info = SocketFdInfo()
            written = libc.proc_pidfdinfo(
                pid,
                fd,
                proc_pidfdsocketinfo,
                ctypes.byref(info),
                ctypes.sizeof(info),
            )
            if written < ctypes.sizeof(info):
                continue
            psi = info.psi
            if psi.soi_family not in (af_inet, af_inet6):
                continue
            if psi.soi_type not in (sock_stream, sock_dgram):
                continue
            ini = psi.soi_proto.pri_tcp.tcpsi_ini
            local_ip = _darwin_address(ini.insi_vflag, ini.insi_laddr, ini_ipv4)
            remote_ip = _darwin_address(ini.insi_vflag, ini.insi_faddr, ini_ipv4)
            local_port = socket.ntohs(ini.insi_lport & 0xFFFF)
            remote_port = socket.ntohs(ini.insi_fport & 0xFFFF)
            proto = "tcp" if psi.soi_type == sock_stream else "udp"
            if psi.soi_family == af_inet6:
                proto += "6"
            if psi.soi_type == sock_stream and psi.soi_kind == sockinfo_tcp:
                state = DARWIN_TCP_STATES.get(int(psi.soi_proto.pri_tcp.tcpsi_state), "UNKNOWN")
            elif remote_port == 0:
                state = "UNCONN"
            else:
                state = "ESTABLISHED"
            key = (proto, local_ip, local_port, remote_ip, remote_port, state)
            if key in seen:
                continue
            seen.add(key)
            if pid not in names:
                names[pid] = _darwin_name(libc, pid)
            rows.append(
                {
                    "proto": proto,
                    "local_ip": local_ip,
                    "local_port": local_port,
                    "remote_ip": remote_ip,
                    "remote_port": remote_port,
                    "state": state,
                    "pid": pid,
                    "program": names[pid],
                }
            )
    return rows


def _darwin_address(vflag, addr, ini_ipv4):
    if vflag & ini_ipv4:
        # in_addr is network order in memory. A native uint32 load swaps it on LE.
        return socket.inet_ntoa(int(addr.ina_46.addr4).to_bytes(4, "little"))
    return socket.inet_ntop(socket.AF_INET6, bytes(addr.ina_6.bytes))


def _darwin_pids(libc, proc_all_pids):
    import ctypes

    needed = libc.proc_listpids(proc_all_pids, 0, None, 0)
    if needed <= 0:
        raise OSError("proc_listpids failed")
    count = needed // ctypes.sizeof(ctypes.c_int) + 64
    buf = (ctypes.c_int * count)()
    used = libc.proc_listpids(proc_all_pids, 0, buf, ctypes.sizeof(buf))
    if used <= 0:
        raise OSError("proc_listpids failed")
    limit = min(count, used // ctypes.sizeof(ctypes.c_int))
    return [buf[index] for index in range(limit) if buf[index] > 0]


def _darwin_fds(libc, pid, proc_pidlistfds):
    import ctypes

    needed = libc.proc_pidinfo(pid, proc_pidlistfds, 0, None, 0)
    if needed <= 0:
        return []
    size = needed + ctypes.sizeof(ProcFdInfo) * 32
    buf = ctypes.create_string_buffer(size)
    written = libc.proc_pidinfo(pid, proc_pidlistfds, 0, buf, size)
    if written <= 0:
        return []
    count = written // ctypes.sizeof(ProcFdInfo)
    array = ctypes.cast(buf, ctypes.POINTER(ProcFdInfo * count)).contents
    return [(int(item.proc_fd), int(item.proc_fdtype)) for item in array]


def _darwin_name(libc, pid):
    import ctypes

    buf = ctypes.create_string_buffer(256)
    if libc.proc_name(pid, buf, 256) <= 0:
        return ""
    return buf.value.decode("utf-8", "replace")


class NetstatPlugin(DropfuPlugin):
    name = "netstat"
    description = "List TCP and UDP sockets from kernel tables"

    def run(self, args):
        options, error = parse_netstat_args(args)
        if error:
            self.error(error)
            return
        try:
            rows = collect_connections()
        except OSError as exc:
            self.error(str(exc))
            return
        rows = filter_connections(
            rows,
            tcp=options["tcp"],
            udp=options["udp"],
            listen_only=options["listen_only"],
            state=options["state"],
        )
        self.output(format_connections(rows))


if __name__ == "__main__":
    main(NetstatPlugin)
