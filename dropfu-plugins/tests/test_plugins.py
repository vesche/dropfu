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
