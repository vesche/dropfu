#!/usr/bin/env python3
"""Fetch and normalize the CPython runtime embedded in dropfu-agent.

This script runs on the build machine. The resulting tar.gz is embedded in the
agent executable; it is never required on the endpoint as a separate artifact.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import os
from pathlib import Path
import shutil
import stat
import tarfile
import tempfile
import urllib.request


PYTHON_VERSION = "3.14.10"
RELEASE = "20261026"
RELEASE_BASE = (
    "https://github.com/astral-sh/python-build-standalone/releases/download/"
    f"{RELEASE}"
)

# Pinned immutable python-build-standalone release assets.
RUNTIMES = {
    "aarch64-apple-darwin": (
        "aarch64-apple-darwin",
        "95eb8c87d16af37c54e9765e31d8c56c0d8ffa9968ea0f704f73a9b83f84e9f9",
    ),
    "aarch64-pc-windows-msvc": (
        "aarch64-pc-windows-msvc",
        "2b6cf82a67cb99ef0db0932dd69ee24080077add6f98435cea5de850c144327d",
    ),
    "aarch64-unknown-linux-gnu": (
        "aarch64-unknown-linux-gnu",
        "90f48337bc3dd4ae6eda81e001e4c981236d403b6b5a07778bbdf94ee423dc00",
    ),
    "aarch64-unknown-linux-musl": (
        "aarch64-unknown-linux-musl",
        "d96d9e66e1e4f6465114ed239681bf6e45bca63724453675fd9bdf30a6475873",
    ),
    "x86_64-apple-darwin": (
        "x86_64-apple-darwin",
        "2fd8becd48cf0ff5f0a15df3c0db7cae7aa708dcaacf901bd30d6cdd6229370b",
    ),
    "x86_64-pc-windows-msvc": (
        "x86_64-pc-windows-msvc",
        "c1876a9795d3a94ee49a1499a69cd91e26ca3e2829593f93fa6e4db90d05402b",
    ),
    "x86_64-unknown-linux-gnu": (
        "x86_64-unknown-linux-gnu",
        "4d3c16c59ed0802a3d1d34d8bce504b15ceeaff39d62dadecc6a9fa803412aed",
    ),
    "x86_64-unknown-linux-musl": (
        "x86_64-unknown-linux-musl",
        "f6dc25dc87ec05c1600ff49ad169adcec449b9ca563d274ba143f5e13b41fe42",
    ),
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def download(target: str, cache_dir: Path) -> Path:
    runtime = RUNTIMES.get(target)
    if runtime is None:
        supported = ", ".join(sorted(RUNTIMES))
        raise SystemExit(f"unsupported Python runtime target {target!r}; supported: {supported}")

    asset_target, expected_digest = runtime
    asset = (
        f"cpython-{PYTHON_VERSION}+{RELEASE}-{asset_target}"
        "-install_only_stripped.tar.gz"
    )
    url = f"{RELEASE_BASE}/{asset.replace('+', '%2B')}"
    cache_dir.mkdir(parents=True, exist_ok=True)
    cached = cache_dir / asset

    if cached.is_file() and sha256(cached) == expected_digest:
        return cached

    partial = cached.with_name(cached.name + f".{os.getpid()}.part")
    partial.unlink(missing_ok=True)
    print(f"downloading embedded CPython {PYTHON_VERSION} for {target}", flush=True)
    request = urllib.request.Request(url, headers={"User-Agent": "dropfu-build/1"})
    with urllib.request.urlopen(request, timeout=120) as response, partial.open("wb") as dest:
        shutil.copyfileobj(response, dest)

    actual_digest = sha256(partial)
    if actual_digest != expected_digest:
        partial.unlink(missing_ok=True)
        raise SystemExit(
            f"runtime checksum mismatch for {asset}: "
            f"expected {expected_digest}, got {actual_digest}"
        )
    partial.replace(cached)
    return cached


def safe_extract(archive: Path, destination: Path) -> Path:
    with tarfile.open(archive, "r:gz") as source:
        for member in source.getmembers():
            member_path = Path(member.name)
            if member_path.is_absolute() or ".." in member_path.parts:
                raise SystemExit(f"unsafe path in Python runtime archive: {member.name!r}")
        source.extractall(destination, filter="data")

    root = destination / "python"
    if not root.is_dir():
        raise SystemExit("Python runtime archive does not contain a python/ directory")
    return root


def normalized_info(path: Path, archive_name: str) -> tarfile.TarInfo:
    resolved = path.resolve(strict=True)
    info = tarfile.TarInfo(archive_name)
    mode = stat.S_IMODE(resolved.stat().st_mode)
    info.mode = mode
    info.mtime = 0
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    if resolved.is_dir():
        info.type = tarfile.DIRTYPE
    elif resolved.is_file():
        info.type = tarfile.REGTYPE
        info.size = resolved.stat().st_size
    else:
        raise SystemExit(f"unsupported file in Python runtime: {path}")
    return info


def repack(source_archive: Path, output: Path) -> None:
    """Create a deterministic, symlink-free runtime archive for Zig extraction."""
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dropfu-python-build-") as temp:
        runtime_root = safe_extract(source_archive, Path(temp))

        # These are build/development assets and are not used by the embedded
        # interpreter. The standard library and all bundled extension modules
        # remain intact.
        for relative in ("include", "share", "lib/pkgconfig"):
            path = runtime_root / relative
            if path.is_dir():
                shutil.rmtree(path)
            elif path.exists():
                path.unlink()

        partial = output.with_suffix(output.suffix + ".part")
        partial.unlink(missing_ok=True)
        with partial.open("wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, compresslevel=9) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as dest:
                    root_info = normalized_info(runtime_root, "python")
                    dest.addfile(root_info)
                    for path in sorted(runtime_root.rglob("*")):
                        archive_name = "python/" + path.relative_to(runtime_root).as_posix()
                        info = normalized_info(path, archive_name)
                        if info.isfile():
                            with path.resolve(strict=True).open("rb") as file_data:
                                dest.addfile(info, file_data)
                        else:
                            dest.addfile(info)
        partial.replace(output)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True, choices=sorted(RUNTIMES))
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--cache-dir",
        type=Path,
        default=Path(
            os.environ.get(
                "DROPFU_PYTHON_CACHE",
                Path.home() / ".cache" / "dropfu" / "python-runtime",
            )
        ),
    )
    args = parser.parse_args()
    source = download(args.target, args.cache_dir)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    repack(source, args.output_dir / "dropfu-python-runtime.tar.gz")
    (args.output_dir / "python_runtime_data.zig").write_text(
        'pub const archive: []const u8 = @embedFile("dropfu-python-runtime.tar.gz");\n',
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
