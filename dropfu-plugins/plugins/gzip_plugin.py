"""Cross-platform gzip compress/decompress using stdlib gzip and tarfile."""

import os
import sys
import tarfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from base import DropfuPlugin, main


def _humanize_size(nbytes):
    for unit in ("B", "KB", "MB", "GB"):
        if nbytes < 1024:
            return f"{nbytes:.1f} {unit}" if unit != "B" else f"{nbytes} {unit}"
        nbytes /= 1024
    return f"{nbytes:.1f} TB"


def compress(source_path, output_path):
    source_path = os.path.abspath(source_path)
    output_path = os.path.abspath(output_path)

    if not os.path.exists(source_path):
        raise FileNotFoundError(f"Source not found: {source_path}")

    if not output_path.endswith(".tar.gz") and not output_path.endswith(".tgz"):
        output_path += ".tar.gz"

    arcname = os.path.basename(source_path)

    with tarfile.open(output_path, "w:gz") as tar:
        tar.add(source_path, arcname=arcname)

    size = os.path.getsize(output_path)
    return f"Compressed {source_path} -> {output_path} ({_humanize_size(size)})"


def decompress(archive_path, dest_dir=None):
    archive_path = os.path.abspath(archive_path)

    if not os.path.isfile(archive_path):
        raise FileNotFoundError(f"Archive not found: {archive_path}")

    if dest_dir is None:
        dest_dir = os.path.dirname(archive_path) or "."
    dest_dir = os.path.abspath(dest_dir)

    with tarfile.open(archive_path, "r:gz") as tar:
        members = tar.getnames()
        for member in members:
            norm = os.path.normpath(member)
            if norm.startswith("..") or os.path.isabs(norm):
                raise ValueError(f"Unsafe path in archive: {member}")
        tar.extractall(path=dest_dir)

    lines = [f"Extracted {archive_path} -> {dest_dir}", f"{len(members)} file(s):"]
    for m in members:
        lines.append(f"  {m}")
    return "\n".join(lines)


class GzipPlugin(DropfuPlugin):
    name = "gzip"
    description = "Compress and decompress files with gzip/tar"

    def run(self, args):
        if len(args) < 1:
            self.error("Usage: gzip compress <path> <output> | gzip decompress <archive> [dest_dir]")
            return

        cmd = args[0].lower()

        if cmd == "compress":
            if len(args) < 3:
                self.error("Usage: gzip compress <source_path> <output_path>")
                return
            self.output(compress(args[1], args[2]))

        elif cmd == "decompress":
            if len(args) < 2:
                self.error("Usage: gzip decompress <archive_path> [dest_dir]")
                return
            dest = args[2] if len(args) >= 3 else None
            self.output(decompress(args[1], dest))

        else:
            self.error(f"Unknown subcommand: {cmd}. Use 'compress' or 'decompress'.")


if __name__ == "__main__":
    main(GzipPlugin)
