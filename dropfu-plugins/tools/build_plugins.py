#!/usr/bin/env python3
"""Build script that packages each dropfu plugin as a standalone zipapp.

Each plugin is compiled to bytecode and bundled as a .pyz zipapp with a
__main__.py entry point. Pure-Python pip dependencies are bundled inside
the zipapp. Output goes to dist/.

Usage:
    python3 tools/build_plugins.py
"""

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

# Pure-Python packages to bundle inside each plugin's zipapp.
# Packages with C extensions (psutil) must be installed system-wide.
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


def compile_file(src_path, dest_dir):
    """Compile a .py file to .pyc and place it in dest_dir."""
    basename = os.path.basename(src_path)
    module_name = basename.removesuffix(".py") if hasattr(basename, "removesuffix") else basename[:-3]
    pyc_path = py_compile.compile(src_path, doraise=True)
    dest_path = os.path.join(dest_dir, module_name + ".pyc")
    shutil.copy2(pyc_path, dest_path)
    return dest_path


def install_deps(deps, target_dir):
    """pip install pure-Python deps into target_dir."""
    if not deps:
        return
    cmd = [
        sys.executable, "-m", "pip", "install",
        "--target", target_dir,
        "--no-compile",
        "--quiet",
    ] + deps
    subprocess.check_call(cmd)
    # Remove dist-info and __pycache__ dirs to keep the zipapp small
    for item in os.listdir(target_dir):
        path = os.path.join(target_dir, item)
        if item.endswith(".dist-info") or item == "__pycache__":
            shutil.rmtree(path)


def build_zipapp(plugin_file):
    """Build a zipapp (.pyz) for a single plugin."""
    plugin_name = plugin_file.replace("_plugin.py", "")
    plugin_module = plugin_file.removesuffix(".py") if hasattr(plugin_file, "removesuffix") else plugin_file[:-3]

    with tempfile.TemporaryDirectory() as tmpdir:
        # Install pip dependencies into staging dir
        deps = PLUGIN_DEPS.get(plugin_file, [])
        if deps:
            install_deps(deps, tmpdir)

        # Compile base and plugin
        compile_file(os.path.join(PLUGINS_DIR, "base.py"), tmpdir)
        compile_file(os.path.join(PLUGINS_DIR, plugin_file), tmpdir)

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

        pyz_path = os.path.join(DIST_DIR, f"{plugin_name}.pyz")

        with zipfile.ZipFile(pyz_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for dirpath, dirnames, filenames in os.walk(tmpdir):
                for fname in filenames:
                    fpath = os.path.join(dirpath, fname)
                    arcname = os.path.relpath(fpath, tmpdir)
                    zf.write(fpath, arcname)

        return pyz_path


def main_build():
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
