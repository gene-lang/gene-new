#!/usr/bin/env python3
"""Install a real generated genex binding through PKG-2, then run it offline."""

from __future__ import annotations

import hashlib
import base64
import json
import os
import pathlib
import platform
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WEBSOCKET = ROOT / "src/genex/websocket"


def invoke(argv: list[str], *, env: dict[str, str] | None = None,
           timeout: int = 180) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, cwd=ROOT, capture_output=True, text=True,
                          timeout=timeout, check=False, env=env)


class GenexPackageTests(unittest.TestCase):
    def test_generated_websocket_binding_survives_offline_install(self) -> None:
        if platform.system() not in {"Darwin", "Linux"}:
            self.skipTest("native PKG-2 fixture requires macOS or Linux")
        if not all(shutil.which(tool) for tool in ("nim", "cc", "pkg-config")):
            self.skipTest("Nim, C compiler, or pkg-config is unavailable")
        target = ("arm64-macosx" if platform.system() == "Darwin" else
                  "amd64-linux")
        if platform.system() == "Linux" and platform.machine() != "x86_64":
            self.skipTest("Linux fixture currently targets x86_64")
        build_env = dict(os.environ)
        if platform.system() == "Darwin":
            sdk_pin = json.loads((ROOT / "tests/profiles/native-app/"
                                  "cli-toolchain.lock.json").read_text())[
                                      "macosx-arm64"]["sdk_root"]
            curl_pc = pathlib.Path("/opt/homebrew/opt/curl/lib/pkgconfig")
            if not pathlib.Path(sdk_pin).is_dir() or not curl_pc.is_dir():
                self.skipTest("pinned SDK or Homebrew curl is unavailable")
            build_env["SDKROOT"] = sdk_pin
            build_env["GENE_PKG_CONFIG_PATH"] = str(curl_pc)
            pkg_config_path = str(curl_pc)
        else:
            pkg_config_path = os.environ.get("GENE_PKG_CONFIG_PATH", "")
            if pkg_config_path:
                build_env["GENE_PKG_CONFIG_PATH"] = pkg_config_path
        version = invoke(["pkg-config", "--modversion", "libcurl"],
                         env={**build_env,
                              "PKG_CONFIG_PATH": pkg_config_path})
        if version.returncode:
            self.skipTest("libcurl pkg-config metadata is unavailable")
        components = tuple(int(part) for part in version.stdout.strip().split(".")[:2])
        if components < (8, 11):
            self.skipTest("libcurl 8.11+ is required for WebSocket")
        with tempfile.TemporaryDirectory(prefix="gene-genex-package-") as work:
            base = pathlib.Path(work)
            source = base / "source"
            source.mkdir()
            package = source / "websocket"
            shutil.copytree(WEBSOCKET, package,
                            ignore=shutil.ignore_patterns("build", "tests", "tools"))
            gene = base / "gene"
            built = invoke(["nim", "c", "-d:geneDebug", "--path:src", "--hints:off",
                            f"--nimcache:{base / 'nimcache'}", f"-o:{gene}",
                            "src/gene.nim"], timeout=180)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            identity = "gene-phase1/abi-1/sha256:" + hashlib.sha256(
                gene.read_bytes()).hexdigest()
            build_script = f"""
import sys
sys.path.insert(0, {str(ROOT / 'src/genex/tools')!r})
from build_aot import build
build({str(package)!r}, 'gene_websocket', ['curl'],
      ['native/websocket.c'], ['-pthread'])
"""
            generated = invoke([sys.executable, "-c", build_script,
                                "--pkg-config-path", pkg_config_path],
                               env={**build_env, "GENE_EXE": str(gene)},
                               timeout=180)
            self.assertEqual(generated.returncode, 0,
                             generated.stdout + generated.stderr)
            suffix = ".dylib" if platform.system() == "Darwin" else ".so"
            relative = "build/libgene_websocket" + suffix
            library = package / relative
            self.assertTrue(library.is_file())
            digest = "sha256:" + hashlib.sha256(library.read_bytes()).hexdigest()
            manifest = f'''{{^format 1 ^name "genex/websocket" ^version "0.1.0"
 ^library {{^entry "src/websocket.gene" ^uses ["native"]}}
 ^files {{^include ["package.gene" "src/**" "native/**" "{relative}"]}}
 ^system_dependencies {{^curl (system_library ^name "libcurl"
   ^version ">=8.11.0 <9" ^providers [pkg_config] ^linkage either)}}
 ^build [(native_binary "native" ^variants [
   {{^target "{target}" ^file "{relative}" ^digest "{digest}"
    ^abi_kind gene_generated ^abi_version 1
    ^runtime_identity "{identity}" ^system ["curl"]}}])]}}
'''
            (package / "package.gene").write_text(manifest)
            app = source / "app"
            (app / "src").mkdir(parents=True)
            (app / "package.gene").write_text('''
{^format 1 ^name "acme/ws_installed" ^version "1.0.0"
 ^applications [(application "ws_installed" ^entry "src/main.gene")]
 ^dependencies {^ws (dep "genex/websocket" "0.1.0" ^path "../websocket")}}
''')
            (app / "src/main.gene").write_text('''
(import [load connect receive] ^from "." ^pkg "ws")
(fn main [args] : Int
  (let package ($pkg/dependency this_pkg "ws"))
  (let lease ($pkg/native_binary package "native"))
  (let native (load (lease .path)))
  (let socket (connect native args/0))
  (var message (receive native socket))
  (var attempts 0)
  (while (&& (== message nil) (< attempts 1000))
    ($sleep 2)
    (set attempts (+ attempts 1))
    (set message (receive native socket)))
  (let bytes (if (== message nil) [] (message .to_list)))
  ($C/close socket)
  (lease .close)
  ($println ($json/stringify {^kind "websocket" ^bytes bytes
                             ^ok (== bytes [111 107])}))
  0)
''')
            resolved = invoke([str(gene), "pkg", "resolve", "--package-root",
                               str(app)], env=build_env)
            self.assertEqual(resolved.returncode, 0,
                             resolved.stdout + resolved.stderr)
            prefix = base / "prefix"
            installed = invoke([str(gene), "install", "ws_installed",
                                "--prefix", str(prefix), "--package-root",
                                str(app)], env=build_env, timeout=180)
            self.assertEqual(installed.returncode, 0,
                             installed.stdout + installed.stderr)
            source.rename(base / "source.hidden")
            listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            listener.settimeout(10)
            peer_errors: list[str] = []

            def peer() -> None:
                try:
                    with listener.accept()[0] as connection:
                        connection.settimeout(5)
                        headers = b""
                        while b"\r\n\r\n" not in headers and len(headers) < 16384:
                            headers += connection.recv(4096)
                        lines = headers.decode("ascii").split("\r\n")
                        key = next(line.split(":", 1)[1].strip() for line in lines
                                   if line.lower().startswith("sec-websocket-key:"))
                        accept = base64.b64encode(hashlib.sha1(
                            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
                            .encode()).digest()).decode()
                        connection.sendall(
                            ("HTTP/1.1 101 Switching Protocols\r\n"
                             "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                             f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
                        connection.sendall(b"\x82\x02ok")
                        time.sleep(0.2)
                except Exception as exc:
                    peer_errors.append(str(exc))

            peer_thread = threading.Thread(target=peer, daemon=True)
            peer_thread.start()
            launch_env = dict(os.environ, GENE_USER_PACKAGES=str(base / "empty-packages"),
                              GENE_ARTIFACT_STORE=str(base / "empty-artifacts"),
                              GENE_C_COMPILER=str(base / "missing-cc"))
            try:
                launched = invoke([str(prefix / "bin/ws_installed"),
                                   f"ws://127.0.0.1:{listener.getsockname()[1]}/echo"],
                                  env=launch_env, timeout=30)
            finally:
                listener.close()
                peer_thread.join(timeout=3)
            self.assertEqual(launched.returncode, 0,
                             launched.stdout + launched.stderr)
            self.assertEqual(peer_errors, [])
            payload = json.loads(launched.stdout)
            self.assertEqual(payload, {"kind": "websocket", "bytes": [111, 107],
                                       "ok": True})


if __name__ == "__main__":
    unittest.main()
