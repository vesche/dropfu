#!/usr/bin/env python3
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "plugins"))

from hash_plugin import hash_file  # noqa: E402
from portscan_plugin import parse_ports  # noqa: E402
from gzip_plugin import compress, decompress  # noqa: E402


class HashTests(unittest.TestCase):
    def test_hash_file(self):
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(b"hello")
            path = f.name
        try:
            digest, size = hash_file(path, "sha256")
            self.assertEqual(size, 5)
            self.assertEqual(len(digest), 64)
        finally:
            os.unlink(path)


class PortscanTests(unittest.TestCase):
    def test_parse_ports(self):
        self.assertEqual(parse_ports("22,80,443"), [22, 80, 443])
        self.assertEqual(parse_ports("20-22"), [20, 21, 22])
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


if __name__ == "__main__":
    unittest.main()
