#!/usr/bin/env python3
"""Build all genex native libraries with explicit SDK search paths."""
from pathlib import Path
import argparse
import platform
import shutil
import subprocess
import sys

GENEX = Path(__file__).resolve().parents[1]
ROOT = GENEX.parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pkg-config-path", action="append", default=[])
    args = parser.parse_args()
    paths = [str(Path(path).resolve()) for path in args.pkg_config_path]
    # Homebrew's WebSocket-enabled curl is separate from Apple's system curl.
    # Query its location and pass it explicitly to the dependency resolver.
    if platform.system() == "Darwin" and shutil.which("brew"):
        prefix = subprocess.run(["brew", "--prefix", "curl"], capture_output=True, text=True)
        if prefix.returncode == 0:
            path = Path(prefix.stdout.strip()) / "lib/pkgconfig"
            if path.is_dir() and str(path) not in paths:
                paths.append(str(path))
    for package in ["sdl2", "websocket"]:
        command = [sys.executable, str(GENEX / package / "tools/build.py")]
        for path in paths:
            command += ["--pkg-config-path", path]
        subprocess.run(command, cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
