"""Cross-platform file hashing using stdlib hashlib."""

import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from base import DropfuPlugin, main

ALGOS = {
    "md5": hashlib.md5,
    "sha1": hashlib.sha1,
    "sha256": hashlib.sha256,
    "sha512": hashlib.sha512,
}


def hash_file(path, algo="sha256", chunk_size=1024 * 1024):
    path = os.path.abspath(path)
    if not os.path.isfile(path):
        raise FileNotFoundError(f"not a file: {path}")
    h = ALGOS[algo]()
    total = 0
    with open(path, "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            total += len(chunk)
            if total > 100 * 1024 * 1024:
                raise ValueError("file too large (limit 100MB)")
            h.update(chunk)
    return h.hexdigest(), total


class HashPlugin(DropfuPlugin):
    name = "hash"
    description = "Compute cryptographic digests of files"

    def run(self, args):
        algo = "sha256"
        paths = []
        i = 0
        while i < len(args):
            if args[i] == "--algo" and i + 1 < len(args):
                algo = args[i + 1].lower()
                if algo not in ALGOS:
                    self.error(f"unsupported algo: {algo} (use {', '.join(ALGOS)})")
                    return
                i += 2
            else:
                paths.append(args[i])
                i += 1

        if not paths:
            self.error("Usage: hash [--algo sha256|md5|sha1|sha512] <path> [path2 ...]")
            return

        lines = []
        for path in paths:
            try:
                digest, size = hash_file(path, algo)
                lines.append(f"{algo} ({size} bytes)  {digest}  {path}")
            except Exception as e:
                lines.append(f"error: {path}: {e}")
        self.output("\n".join(lines))


if __name__ == "__main__":
    main(HashPlugin)
