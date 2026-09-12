#!/usr/bin/env python3
"""Build and run miclone's native shell; --smoke owns an isolated server/world."""
from pathlib import Path
import argparse
import json
import os
import platform
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib

MICLONE = Path(__file__).resolve().parents[1]
ROOT = MICLONE.parents[1]
NATIVE = MICLONE / "native"
GENE = str(ROOT / "bin/gene")
URL = "ws://127.0.0.1:8790/"


def port_open():
    try:
        with socket.create_connection(("127.0.0.1", 8790), timeout=0.2):
            return True
    except OSError:
        return False


def capture_png(raw):
    metadata = json.loads(Path(str(raw) + ".json").read_text())
    width, height = metadata["width"], metadata["height"]
    pixels = raw.read_bytes()
    if len(pixels) != width * height * 4:
        raise RuntimeError("framebuffer capture has the wrong byte count")
    rows = b"".join(b"\0" + pixels[y*width*4:(y+1)*width*4] for y in range(height-1, -1, -1))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    png = raw.with_suffix("").with_suffix(".form.png") if raw.suffix == ".form" else raw.with_suffix(".png")
    png.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                    + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
    return png


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--font", default=os.environ.get("GENEX_FONT"))
    parser.add_argument("--url", default=URL)
    parser.add_argument("--world", default="/tmp/miclone_native_world")
    parser.add_argument("--pkg-config-path", action="append", default=[])
    args = parser.parse_args()
    if args.smoke and (args.url != URL or port_open()):
        parser.error("--smoke requires the default local URL and a free port 8790")
    font = args.font
    if not font:
        for candidate in ["/System/Library/Fonts/Menlo.ttc",
                          "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"]:
            if Path(candidate).is_file():
                font = candidate
                break
    if not font or not Path(font).is_file():
        parser.error("supply an installed TrueType/OpenType font with --font")
    if not args.no_build:
        command = [sys.executable, str(ROOT / "src/genex/tools/build.py")]
        for path in args.pkg_config_path:
            command += ["--pkg-config-path", str(Path(path).resolve())]
        subprocess.run(command, cwd=ROOT, check=True)
    subprocess.run([GENE, "pkg", "resolve"], cwd=NATIVE, check=True)
    (NATIVE / ".gene").mkdir(exist_ok=True)
    raw = NATIVE / ".gene/native-smoke.rgba"
    if args.smoke:
        for path in [raw, Path(str(raw)+".json"), raw.with_suffix(".png"),
                     Path(str(raw)+".form"), Path(str(raw)+".form.json"),
                     raw.with_suffix(".form.png")]:
            path.unlink(missing_ok=True)
    temporary = tempfile.TemporaryDirectory(prefix="miclone-native-smoke-") if args.smoke else None
    world = Path(temporary.name if temporary else args.world).resolve()
    server = None
    log_path = NATIVE / ".gene/native-server.log"
    try:
        if args.url == URL and not port_open():
            world.mkdir(parents=True, exist_ok=True)
            with log_path.open("w") as log:
                server = subprocess.Popen([GENE, "run", "--allow_read_write_dir", str(world), "server"],
                    cwd=MICLONE, env={**os.environ, "GENE_MICLONE_WORLD": str(world)},
                    stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            print(f"Starting server on {world}", flush=True)
            deadline = time.monotonic() + 300
            while not port_open():
                if server.poll() is not None:
                    raise RuntimeError("server exited before listening:\n" + log_path.read_text())
                if time.monotonic() >= deadline:
                    raise RuntimeError("server startup timed out:\n" + log_path.read_text())
                time.sleep(0.25)
        suffix = ".dylib" if platform.system() == "Darwin" else ".so"
        command = [GENE, "run", "main.gene",
                   str(ROOT / "src/genex/sdl2/build" / ("libgene_sdl2" + suffix)),
                   str(ROOT / "src/genex/websocket/build" / ("libgene_websocket" + suffix)), font, args.url]
        if args.smoke:
            command += ["--smoke", str(raw)]
        subprocess.run(command, cwd=NATIVE, check=True, timeout=900 if args.smoke else None)
        if args.smoke:
            print("Framebuffer:", capture_png(raw), flush=True)
            print("Crafting UI:", capture_png(Path(str(raw) + ".form")), flush=True)
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
        if temporary is not None:
            temporary.cleanup()


if __name__ == "__main__":
    main()
