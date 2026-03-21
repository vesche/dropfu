"""Cross-platform file type identification using filetype."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from base import DropfuPlugin, main

try:
    import filetype
except ImportError:
    filetype = None


def _humanize_size(nbytes):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if nbytes < 1024:
            return f"{nbytes:.1f} {unit}" if unit != "B" else f"{nbytes} {unit}"
        nbytes /= 1024
    return f"{nbytes:.1f} PB"


def identify_file(filepath):
    filepath = os.path.abspath(filepath)

    if not os.path.exists(filepath):
        return f"{filepath}: No such file or directory"

    if os.path.isdir(filepath):
        return f"{filepath}: directory"

    size = os.path.getsize(filepath)
    size_str = _humanize_size(size)

    if size == 0:
        return f"{filepath}: empty file ({size_str})"

    if filetype is None:
        return f"{filepath}: unknown (filetype library not available) ({size_str})"

    kind = filetype.guess(filepath)
    if kind is not None:
        return f"{filepath}: {kind.extension} ({kind.mime}, {size_str})"

    with open(filepath, "rb") as f:
        sample = f.read(512)
    text_chars = set(range(32, 127)) | {9, 10, 13}
    non_text = sum(1 for b in sample if b not in text_chars)
    if (non_text / len(sample)) < 0.05:
        return f"{filepath}: text file (text/plain, {size_str})"
    return f"{filepath}: binary data (application/octet-stream, {size_str})"


class FilePlugin(DropfuPlugin):
    name = "file"
    description = "Identify file type"

    def run(self, args):
        if not args:
            self.error("Usage: file <path> [path2 ...]")
            return

        lines = []
        for path in args:
            lines.append(identify_file(path))
        self.output("\n".join(lines))


if __name__ == "__main__":
    main(FilePlugin)
