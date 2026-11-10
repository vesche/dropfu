#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "plugins"))

from hash_plugin import hash_file  # noqa: E402
from portscan_plugin import parse_ports  # noqa: E402
from gzip_plugin import compress, decompress  # noqa: E402
from file_plugin import identify_file  # noqa: E402
from netstat_plugin import (  # noqa: E402
    InSockInfo,
    SocketFdInfo,
    TcpSockInfo,
    collect_connections,
    decode_proc_address,
    filter_connections,
    format_connections,
    parse_netstat_args,
    parse_proc_net,
    windows_ipv4,
    windows_port,
)
from tools.build_plugins import find_plugins  # noqa: E402


class HashTests(unittest.TestCase):
    def test_hash_file(self):
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(b"hello")
            path = f.name
        try:
            digest, size = hash_file(path, "sha256")
            self.assertEqual(size, 5)
            self.assertEqual(
                digest,
                "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            )
        finally:
            os.unlink(path)


class PortscanTests(unittest.TestCase):
    def test_parse_ports(self):
        self.assertEqual(parse_ports("22,80,443"), [22, 80, 443])
        self.assertEqual(parse_ports("20-22"), [20, 21, 22])
        self.assertEqual(parse_ports("22,22,65536,0"), [22])
        with self.assertRaises(ValueError):
            parse_ports("not-a-port")
        with self.assertRaises(ValueError):
            parse_ports("1-5000")


class GzipTests(unittest.TestCase):
    def test_roundtrip(self):
        with tempfile.TemporaryDirectory() as td:
            src = os.path.join(td, "data.txt")
            with open(src, "w") as f:
                f.write("dropfu")
            archive = os.path.join(td, "out.tar.gz")
            compress(src, archive)
            outdir = os.path.join(td, "out")
            os.makedirs(outdir)
            decompress(archive, outdir)
            extracted = os.path.join(outdir, "data.txt")
            self.assertTrue(os.path.isfile(extracted))
            with open(extracted) as f:
                self.assertEqual(f.read(), "dropfu")

    def test_rejects_path_traversal(self):
        with tempfile.TemporaryDirectory() as td:
            archive = os.path.join(td, "unsafe.tar.gz")
            payload = os.path.join(td, "payload")
            with open(payload, "w") as f:
                f.write("unsafe")
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(payload, arcname="../escape")
            with self.assertRaises(ValueError):
                decompress(archive, os.path.join(td, "out"))


class FilePluginTests(unittest.TestCase):
    def test_identifies_missing_directory_empty_and_text(self):
        with tempfile.TemporaryDirectory() as td:
            self.assertIn("No such file", identify_file(os.path.join(td, "missing")))
            self.assertIn("directory", identify_file(td))

            empty = os.path.join(td, "empty")
            open(empty, "wb").close()
            self.assertIn("empty file", identify_file(empty))

            text = os.path.join(td, "text.txt")
            with open(text, "w") as f:
                f.write("plain text\n")
            self.assertIn("text", identify_file(text))


class NetstatTests(unittest.TestCase):
    TCP_LINE = (
        "   0: 0100007F:0050 00000000:0000 0A 00000000:00000000 "
        "00:00000000 00000000     0        0 12345 1 00000000 100 0 0 10 0"
    )
    UDP6_LINE = (
        "22027: 000080FE00000000923D2B0BF19B7157:0222 "
        "00000000000000000000000000000000:0000 07 00000000:00000000 "
        "00:00000000 00000000     0        0 64535 2 00000000 0"
    )

    def test_decodes_proc_addresses(self):
        self.assertEqual(decode_proc_address("0100007F"), "127.0.0.1")
        self.assertEqual(
            decode_proc_address("000080FE00000000923D2B0BF19B7157"),
            "fe80::b2b:3d92:5771:9bf1",
        )

    def test_parses_proc_net_tcp_and_udp6(self):
        tcp = parse_proc_net("sl local_address\n" + self.TCP_LINE + "\n", "tcp")
        self.assertEqual(len(tcp), 1)
        self.assertEqual(tcp[0]["local_ip"], "127.0.0.1")
        self.assertEqual(tcp[0]["local_port"], 80)
        self.assertEqual(tcp[0]["remote_port"], 0)
        self.assertEqual(tcp[0]["state"], "LISTEN")
        self.assertEqual(tcp[0]["inode"], 12345)

        udp = parse_proc_net(self.UDP6_LINE, "udp6")
        self.assertEqual(udp[0]["local_port"], 546)
        self.assertEqual(udp[0]["state"], "UNCONN")
        self.assertEqual(udp[0]["remote_ip"], "::")

    def test_filters_listen_and_state(self):
        rows = parse_proc_net(self.TCP_LINE, "tcp") + parse_proc_net(self.UDP6_LINE, "udp6")
        listening = filter_connections(rows, listen_only=True)
        self.assertEqual([row["proto"] for row in listening], ["tcp", "udp6"])
        established = filter_connections(rows, state="ESTABLISHED")
        self.assertEqual(established, [])
        udp_only = filter_connections(rows, tcp=False, udp=True)
        self.assertEqual([row["proto"] for row in udp_only], ["udp6"])

    def test_argument_parser(self):
        options, error = parse_netstat_args(["--tcp", "--listen", "--state", "listen"])
        self.assertIsNone(error)
        self.assertEqual(options["state"], "LISTEN")
        self.assertTrue(options["tcp"])
        self.assertFalse(options["udp"])
        self.assertTrue(options["listen_only"])
        _, error = parse_netstat_args(["--bogus"])
        self.assertIn("Usage", error)

    def test_format_marks_unbound_remote_address(self):
        rows = parse_proc_net(self.TCP_LINE, "tcp")
        text = format_connections(rows)
        self.assertIn("127.0.0.1:80", text)
        self.assertIn("*:*", text)
        self.assertIn("LISTEN", text)
        self.assertIn("1 connection(s)", text)

    def test_windows_address_and_port_helpers(self):
        self.assertEqual(windows_ipv4(0x0100007F), "127.0.0.1")
        self.assertEqual(windows_port(0x5000), 80)

    def test_darwin_socket_struct_matches_proc_info(self):
        import ctypes

        self.assertEqual(ctypes.sizeof(InSockInfo), 80)
        self.assertEqual(InSockInfo.insi_laddr.offset, 48)
        self.assertEqual(TcpSockInfo.tcpsi_state.offset, 80)
        self.assertEqual(SocketFdInfo.psi.offset, 24)
        # proc_fileinfo + socket_info through the unix-socket union arm.
        self.assertGreaterEqual(ctypes.sizeof(SocketFdInfo), 792)

    def test_plugin_does_not_invoke_endpoint_binaries(self):
        path = os.path.join(ROOT, "plugins", "netstat_plugin.py")
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        self.assertNotIn("subprocess", source)
        self.assertNotIn("os.system", source)
        self.assertNotIn("Popen", source)
        for banned in ("netstat.exe", "/usr/bin/netstat", "/bin/netstat"):
            self.assertNotIn(banned, source)

    def test_live_listener_is_attributed_to_this_process(self):
        if not sys.platform.startswith("linux"):
            self.skipTest("live /proc/net check")
        import socket

        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            port = listener.getsockname()[1]
            matches = [
                row
                for row in collect_connections()
                if row["proto"] == "tcp"
                and row["local_ip"] == "127.0.0.1"
                and row["local_port"] == port
                and row["state"] == "LISTEN"
            ]
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0]["pid"], os.getpid())
        self.assertTrue(matches[0]["program"])


class BuildArtifactTests(unittest.TestCase):
    def test_every_plugin_has_a_runnable_zipapp(self):
        dist = os.path.join(ROOT, "dist")
        expected = [name.replace("_plugin.py", "") for name in find_plugins()]
        self.assertTrue(expected)
        for name in expected:
            with self.subTest(plugin=name):
                artifact = os.path.join(dist, f"{name}.pyz")
                self.assertTrue(os.path.isfile(artifact), f"missing {artifact}")
                self.assertGreater(os.path.getsize(artifact), 0)
                with zipfile.ZipFile(artifact) as archive:
                    names = archive.namelist()
                    self.assertIn("__main__.pyc", names)
                    self.assertIn("base.pyc", names)
                    self.assertIn(f"{name}_plugin.pyc", names)
                    self.assertIn("dropfu-plugin.json", names)
                    manifest = json.loads(archive.read("dropfu-plugin.json"))
                    self.assertEqual(manifest["format"], 1)
                    self.assertEqual(manifest["python"], "3.14")
                    self.assertFalse(
                        any(entry.endswith(".py") for entry in names),
                        f"{artifact} contains Python source",
                    )
                result = subprocess.run(
                    [sys.executable, artifact],
                    capture_output=True,
                    text=True,
                    timeout=10,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
