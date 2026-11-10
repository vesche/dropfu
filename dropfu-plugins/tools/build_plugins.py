#!/usr/bin/env python3
"""Build script that packages each dropfu plugin as a standalone zipapp.

Each plugin is compiled to bytecode and bundled as a .pyz zipapp with a
__main__.pyc entry point. Pure-Python pip dependencies are bundled inside
the zipapp. Output goes to dist/.

Usage:
    python3 tools/build_plugins.py
"""

import json
import os
import py_compile
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGINS_DIR = os.path.join(ROOT, "plugins")
DIST_DIR = os.path.join(ROOT, "dist")

SKIP_FILES = {"__init__.py", "base.py"}
PYTHON_VERSION = (3, 14)

# Pure-Python packages compiled and bundled inside each plugin zipapp.
# Native extensions are rejected; plugins cannot depend on endpoint packages.
PLUGIN_DEPS = {
    "file_plugin.py": ["filetype==1.2.0"],
    "ipconfig_plugin.py": ["ifaddr==0.2.0"],
    "ping_plugin.py": ["ping3==4.0.8"],
    # hash_plugin.py and portscan_plugin.py are stdlib-only
}


def find_plugins():
    plugins = []
    for fname in sorted(os.listdir(PLUGINS_DIR)):
        if fname.endswith("_plugin.py") and fname not in SKIP_FILES:
            plugins.append(fname)
    return plugins


def install_deps(deps, target_dir):
    """pip install pure-Python deps into target_dir."""
    if not deps:
        return
    cmd = [
        sys.executable, "-m", "pip", "install",
        "--target", target_dir,
        "--no-compile",
        "--only-binary=:all:",
        "--quiet",
    ] + deps
    subprocess.check_call(cmd)
    # Remove dist-info and __pycache__ dirs to keep the zipapp small
    for item in os.listdir(target_dir):
        path = os.path.join(target_dir, item)
        if item.endswith(".dist-info") or item == "__pycache__":
            shutil.rmtree(path)


def compile_tree(root):
    """Compile every Python source file in-place, then remove the source."""
    sources = []
    for dirpath, _, filenames in os.walk(root):
        for filename in filenames:
            if filename.endswith(".py"):
                sources.append(os.path.join(dirpath, filename))

    for source in sorted(sources):
        relative = os.path.relpath(source, root)
        py_compile.compile(
            source,
            cfile=source + "c",
            dfile=relative,
            doraise=True,
            invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH,
        )
        os.unlink(source)

    native_suffixes = (".so", ".pyd", ".dylib", ".dll")
    native_files = []
    for dirpath, _, filenames in os.walk(root):
        for filename in filenames:
            if filename.lower().endswith(native_suffixes):
                native_files.append(os.path.relpath(os.path.join(dirpath, filename), root))
    if native_files:
        raise RuntimeError(
            "plugins must be platform-independent; native extensions found: "
            + ", ".join(sorted(native_files))
        )


def build_zipapp(plugin_file):
    """Build a zipapp (.pyz) for a single plugin."""
    plugin_name = plugin_file.replace("_plugin.py", "")
    plugin_module = plugin_file.removesuffix(".py") if hasattr(plugin_file, "removesuffix") else plugin_file[:-3]

    with tempfile.TemporaryDirectory() as tmpdir:
        # Install pip dependencies into staging dir
        deps = PLUGIN_DEPS.get(plugin_file, [])
        if deps:
            install_deps(deps, tmpdir)

        # Stage base and plugin sources. compile_tree below converts these and
        # all bundled dependencies to deterministic, sourceless bytecode.
        shutil.copy2(os.path.join(PLUGINS_DIR, "base.py"), tmpdir)
        shutil.copy2(os.path.join(PLUGINS_DIR, plugin_file), tmpdir)

        # Generate __main__.py entry point
        main_py = os.path.join(tmpdir, "__main__.py")
        with open(main_py, "w") as f:
            f.write(f"import sys, os\n")
            f.write(f"sys.path.insert(0, os.path.dirname(__file__))\n")
            f.write(f"from base import main, DropfuPlugin\n")
            f.write(f"import {plugin_module}\n")
            f.write(f"_cls = None\n")
            f.write(f"for _name in dir({plugin_module}):\n")
            f.write(f"    _obj = getattr({plugin_module}, _name)\n")
            f.write(f"    if isinstance(_obj, type) and issubclass(_obj, DropfuPlugin) and _obj is not DropfuPlugin:\n")
            f.write(f"        _cls = _obj\n")
            f.write(f"        break\n")
            f.write(f"if _cls:\n")
            f.write(f"    main(_cls)\n")
            f.write(f"else:\n")
            f.write(f"    print('No plugin class found')\n")
            f.write(f"    sys.exit(1)\n")

        with open(os.path.join(tmpdir, "dropfu-plugin.json"), "w") as manifest:
            json.dump(
                {
                    "format": 1,
                    "name": plugin_name,
                    "python": f"{PYTHON_VERSION[0]}.{PYTHON_VERSION[1]}",
                    "platform": "any",
                },
                manifest,
                sort_keys=True,
                separators=(",", ":"),
            )

        compile_tree(tmpdir)

        pyz_path = os.path.join(DIST_DIR, f"{plugin_name}.pyz")

        with zipfile.ZipFile(pyz_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for dirpath, dirnames, filenames in os.walk(tmpdir):
                for fname in filenames:
                    fpath = os.path.join(dirpath, fname)
                    arcname = os.path.relpath(fpath, tmpdir)
                    zf.write(fpath, arcname)

        return pyz_path


def main_build():
    if sys.version_info[:2] != PYTHON_VERSION:
        print(
            "Plugin bytecode must be built with the same CPython minor version "
            f"embedded in dropfu-agent ({PYTHON_VERSION[0]}.{PYTHON_VERSION[1]}); "
            f"got {sys.version_info.major}.{sys.version_info.minor}.",
            file=sys.stderr,
        )
        sys.exit(2)

    os.makedirs(DIST_DIR, exist_ok=True)

    plugins = find_plugins()
    if not plugins:
        print("No plugins found in", PLUGINS_DIR)
        sys.exit(1)

    print(f"Found {len(plugins)} plugin(s) to build:\n")

    built = []
    failed = []

    for plugin_file in plugins:
        plugin_name = plugin_file.replace("_plugin.py", "")
        deps = PLUGIN_DEPS.get(plugin_file, [])
        dep_str = f" [deps: {', '.join(deps)}]" if deps else ""
        sys.stdout.write(f"  Building {plugin_name}{dep_str}... ")
        sys.stdout.flush()
        try:
            path = build_zipapp(plugin_file)
            size = os.path.getsize(path)
            print(f"OK ({size} bytes) -> {os.path.relpath(path, ROOT)}")
            built.append(plugin_name)
        except Exception as e:
            print(f"FAILED: {e}")
            failed.append((plugin_name, str(e)))

    print(f"\nBuild complete: {len(built)} succeeded, {len(failed)} failed")
    if built:
        print(f"Output directory: {os.path.relpath(DIST_DIR, ROOT)}/")

    if failed:
        print("\nFailed plugins:")
        for name, err in failed:
            print(f"  {name}: {err}")
        sys.exit(1)


if __name__ == "__main__":
    main_build()
