#!/usr/bin/env python3
"""Exercise the libuv adapter from a compiler-free installed app."""

from __future__ import annotations

import json
import os
import pathlib
import platform
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
TIMER = ROOT / "src/genex/libuv_timer"


def invoke(argv: list[str], env: dict[str, str], timeout: int = 180):
    return subprocess.run(argv, cwd=ROOT, env=env, capture_output=True,
                          text=True, timeout=timeout, check=False)


class GenexLibuvTimerTests(unittest.TestCase):
    def test_installed_timer_retires_each_native_handle(self) -> None:
        self.assertEqual(
            (ROOT / "src/gene/native_api.h").read_bytes(),
            (TIMER / "native/gene_native_api.h").read_bytes())
        target = ("arm64-macosx" if platform.system() == "Darwin" else
                  "amd64-linux")
        if (platform.system(), platform.machine()) not in {
            ("Darwin", "arm64"), ("Linux", "x86_64")}:
            self.skipTest("native timer target is not supported")
        if not all(shutil.which(tool) for tool in ("nim", "cc", "pkg-config")):
            self.skipTest("Nim, C compiler, or pkg-config is unavailable")
        env = dict(os.environ)
        if target == "arm64-macosx":
            sdk = json.loads((ROOT / "tests/profiles/native-app/"
                              "cli-toolchain.lock.json").read_text())[
                                  "macosx-arm64"]["sdk_root"]
            if not pathlib.Path(sdk).is_dir():
                self.skipTest("pinned macOS SDK is unavailable")
            env["SDKROOT"] = sdk
        version = invoke(["pkg-config", "--modversion", "libuv"], env)
        if version.returncode or not version.stdout.strip().startswith("1.52."):
            self.skipTest("pinned libuv 1.52.x is unavailable")
        lifetimes = int(os.environ.get("GENE_LIBUV_LIFETIMES", "100"))
        self.assertGreater(lifetimes, 0)
        with tempfile.TemporaryDirectory(prefix="gene-libuv-package-") as tmp:
            base = pathlib.Path(tmp)
            source = base / "source"
            source.mkdir()
            shutil.copytree(TIMER, source / "timer")
            app = source / "app"
            (app / "src").mkdir(parents=True)
            (app / "package.gene").write_text('''
{^format 1 ^name "acme/libuv_timer_installed" ^version "0.1.0"
 ^applications [(application "timer_installed" ^entry "src/main.gene")]
 ^dependencies {^timer (dep "genex/libuv_timer" "0.1.0" ^path "../timer")}}
''')
            (app / "src/main.gene").write_text('''
(import $io [IoResource])
(import [open] ^from "." ^pkg "timer")
(fn main [args] : Int
  (let baseline_roots (/native_roots ($runtime/gc_stats)))
  (let package ($pkg/dependency this_pkg "timer"))
  (let diagnostic_lease ($pkg/native_binary package "native"))
  (let diagnostic_library ($ffi/open (diagnostic_lease .path)))
  (let live_contexts
    ($ffi/bind diagnostic_library "gene_timer_live_contexts" [] C/Int64))
  (let live_handles
    ($ffi/bind diagnostic_library "gene_timer_live_handles" [] C/Int64))
  (let closed_handles
    ($ffi/bind diagnostic_library "gene_timer_closed_handles" [] C/Int64))
  (let received ($cell 0))
  (var successful 0)
  (var next_report 1000)
  (repeat __LIFETIMES__
    (let before (received .get))
    (let timer (open (fn [data]
      (if (== ($binary/to_str data) "tick")
        (received .set (+ (received .get) 1))))))
    (var attempts 0)
    (while (&& (== (received .get) before) (< attempts 100))
      ($sleep 5)
      (set attempts (+ attempts 1)))
    (timer .IoResource:close)
    (await (timer .IoResource:wait_closed))
    (await (timer .IoResource:wait_closed))
    (if (&& (> (received .get) before)
            (== (/state (timer .status)) "closed")
            (== (live_contexts) 0)
            (== (live_handles) 0))
      (set successful (+ successful 1)))
    (if (== successful next_report)
      (do
        ($println ($json/stringify
          {^progress successful ^contexts (live_contexts)
           ^handles (live_handles)
           ^roots (/native_roots ($runtime/gc_stats))}))
        (set next_report (+ next_report 1000)))))
  (let total_closed (closed_handles))
  ($ffi/Library/close diagnostic_library)
  (diagnostic_lease .close)
  ($println ($json/stringify
    {^successful successful ^received (received .get)
     ^closed_handles total_closed
     ^baseline_roots baseline_roots
     ^remaining_roots (/native_roots ($runtime/gc_stats))
     ^materialized_resource_leases
       (/materialized_resource_leases ($runtime/gc_stats))}))
  0)
'''.replace("__LIFETIMES__", str(lifetimes)))
            gene = base / "gene"
            built = invoke(["nim", "c", "-d:geneDebug", "-d:geneRcStats", "--path:src", "--hints:off",
                            f"--nimcache:{base / 'nimcache'}", f"-o:{gene}",
                            "src/gene.nim"], env)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            resolved = invoke([str(gene), "pkg", "resolve", "--package-root",
                               str(app)], env)
            self.assertEqual(resolved.returncode, 0,
                             resolved.stdout + resolved.stderr)
            prefix = base / "prefix"
            installed = invoke([str(gene), "install", "timer_installed",
                                "--prefix", str(prefix), "--package-root",
                                str(app)], env)
            self.assertEqual(installed.returncode, 0,
                             installed.stdout + installed.stderr)
            source.rename(base / "source.hidden")
            launch_env = dict(os.environ,
                              GENE_USER_PACKAGES=str(base / "empty-packages"),
                              GENE_ARTIFACT_STORE=str(base / "empty-artifacts"),
                              GENE_C_COMPILER=str(base / "missing-compiler"))
            launch_env.pop("SDKROOT", None)
            launched = invoke([str(prefix / "bin/timer_installed")], launch_env,
                              timeout=max(120, lifetimes // 20))
            self.assertEqual(launched.returncode, 0,
                             launched.stdout + launched.stderr)
            report = json.loads(launched.stdout.strip().splitlines()[-1])
            self.assertEqual(report["successful"], lifetimes)
            self.assertGreaterEqual(report["received"], lifetimes)
            self.assertEqual(report["closed_handles"], 2 * lifetimes)
            self.assertEqual(report["remaining_roots"], report["baseline_roots"])
            self.assertEqual(report["materialized_resource_leases"], 0)


if __name__ == "__main__":
    unittest.main()
