#!/usr/bin/env python3
"""Exercise a managed GeneApi C module from a compiler-free installed app."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE = ROOT / "tests/fixtures/native_module_pkg"


def invoke(argv: list[str], env: dict[str, str], timeout: int = 180):
    return subprocess.run(argv, cwd=ROOT, env=env, capture_output=True,
                          text=True, timeout=timeout, check=False)


class NativeModulePackageTests(unittest.TestCase):
    def test_installed_module_keeps_library_until_callbacks_retire(self) -> None:
        self.assertEqual(
            (ROOT / "src/gene/native_api.h").read_bytes(),
            (MODULE / "native/gene_native_api.h").read_bytes())
        if (platform.system(), platform.machine()) != ("Darwin", "arm64"):
            self.skipTest("the installed GeneApi fixture is pinned to macOS arm64")
        if not all(shutil.which(tool) for tool in ("nim", "cc")):
            self.skipTest("Nim or a C compiler is unavailable")
        env = dict(os.environ)
        sdk = json.loads((ROOT / "tests/profiles/native-app/"
                          "cli-toolchain.lock.json").read_text())[
                              "macosx-arm64"]["sdk_root"]
        if not pathlib.Path(sdk).is_dir():
            self.skipTest("pinned macOS SDK is unavailable")
        env["SDKROOT"] = sdk
        lifetimes = int(os.environ.get("GENE_NATIVE_MODULE_LIFETIMES", "100"))
        atomic = os.environ.get("GENE_NATIVE_MODULE_ATOMIC") == "1"
        self.assertGreater(lifetimes, 0)
        with tempfile.TemporaryDirectory(prefix="gene-native-module-") as tmp:
            base = pathlib.Path(tmp)
            source = base / "source"
            source.mkdir()
            shutil.copytree(MODULE, source / "module")
            app = source / "app"
            (app / "src").mkdir(parents=True)
            (app / "package.gene").write_text('''
{^format 1 ^name "acme/native_module_installed" ^version "0.1.0"
 ^applications [(application "native_module_installed" ^entry "src/main.gene")]
 ^dependencies {^module (dep "genex/native_module_probe" "0.1.0" ^path "../module")}}
''')
            (app / "src/main.gene").write_text('''
(import $io [IoResource])
(import [open] ^from "." ^pkg "module")
(fn main [args] : Int
  (let baseline_roots (/native_roots ($runtime/gc_stats)))
  (let package ($pkg/dependency this_pkg "module"))
  (let refused
    (try ($pkg/native_module package "plain") false catch Error true))
  (let failing_lease ($pkg/native_binary package "failing"))
  (let failing_library ($ffi/open (failing_lease .path)))
  (let failed_live ($ffi/bind failing_library "gene_test_module_live_contexts"
                                [] C/UInt32))
  (let failed_retired ($ffi/bind failing_library "gene_test_module_retired_contexts"
                                   [] C/UInt32))
  (let refused_failure
    (try ($pkg/native_module package "failing") false catch Error true))
  (let failure_clean
    (&& refused_failure (== (failed_live) 0) (== (failed_retired) 2)))
  ($ffi/Library/close failing_library)
  (failing_lease .close)
  (let prebuilt_lease ($pkg/native_binary package "prebuilt"))
  (let prebuilt_library ($ffi/open (prebuilt_lease .path)))
  (let prebuilt_live ($ffi/bind prebuilt_library "gene_test_module_live_contexts"
                                 [] C/UInt32))
  (let prebuilt_retired ($ffi/bind prebuilt_library "gene_test_module_retired_contexts"
                                    [] C/UInt32))
  (var prebuilt_owner ($pkg/native_module package "prebuilt"))
  (let prebuilt_exports (prebuilt_owner .module))
  (let prebuilt_answer (prebuilt_exports/increment 41))
  (let prebuilt_doubled (prebuilt_exports/double_value 21))
  (prebuilt_owner .IoResource:close)
  (await (prebuilt_owner .IoResource:wait_closed))
  (let prebuilt_ok
    (&& (== prebuilt_answer 42) (== prebuilt_doubled 42)
        (== (prebuilt_live) 0) (== (prebuilt_retired) 2)))
  (set prebuilt_owner nil)
  ($ffi/Library/close prebuilt_library)
  (prebuilt_lease .close)
  (let diagnostic_lease ($pkg/native_binary package "native"))
  (let diagnostic_library ($ffi/open (diagnostic_lease .path)))
  (let live ($ffi/bind diagnostic_library "gene_test_module_live_contexts"
                         [] C/UInt32))
  (let retired ($ffi/bind diagnostic_library "gene_test_module_retired_contexts"
                            [] C/UInt32))
  (let complete_task ($ffi/bind diagnostic_library "gene_test_module_complete_task"
                                  [] C/UInt32))
  (let submit_copy ($ffi/bind diagnostic_library "gene_test_module_submit_copy"
                                [] C/UInt32))
  (let supports_worker
    ($ffi/bind diagnostic_library "gene_test_module_supports_copy_worker"
      [] C/UInt32))
  (var successful 0)
  (repeat __LIFETIMES__
    (var owner (open))
    (let exports (owner .module))
    (let answer (exports/increment 41))
    (let doubled (exports/double_value 21))
    (let active (live))
    (owner .IoResource:close)
    (await (owner .IoResource:wait_closed))
    (await (owner .IoResource:wait_closed))
    (let closed_module_refused
      (try (owner .module) false catch Error true))
    (if (&& (== answer 42) (== doubled 42)
            (== active 2) (== (live) 0)
            closed_module_refused
            (== (/state (owner .status)) "closed"))
      (set successful (+ successful 1)))
    (set owner nil))
  (var producer_owner (open))
  (let producer_exports (producer_owner .module))
  (let produced_task (producer_exports/increment 98))
  (producer_owner .IoResource:close)
  (let producer_waiting
    (== (/state (producer_owner .status)) "closing"))
  (let producer_completed (== (complete_task) 0))
  (await produced_task)
  (await (producer_owner .IoResource:wait_closed))
  (let producer_close_ok
    (&& producer_waiting producer_completed
        (== (/state (producer_owner .status)) "closed")
        (== (live) 0)))
  (set producer_owner nil)
  (var copy_owner (open))
  (let copy_exports (copy_owner .module))
  (let copied_task (copy_exports/increment 97))
  (let copied_submitted (== (submit_copy) 0))
  (let copied_queued (== (/copied_queued (copy_owner .status)) 1))
  (let copied_value (await copied_task))
  (copy_owner .IoResource:close)
  (await (copy_owner .IoResource:wait_closed))
  (let copied_ok
    (&& copied_submitted copied_queued
        (== copied_value "installed-copy")
        (== (/state (copy_owner .status)) "closed")
        (== (/producers (copy_owner .status)) 0)
        (== (/copied_bytes (copy_owner .status)) 0)
        (== (live) 0)))
  (set copy_owner nil)
  (let worker_ok
    (if (== (supports_worker) 1)
      (do
        (var worker_owner (open))
        (let worker_exports (worker_owner .module))
        (let worker_task (worker_exports/increment 96))
        (let worker_value (await worker_task))
        (worker_owner .IoResource:close)
        (await (worker_owner .IoResource:wait_closed))
        (let ready
          (&& (== ($binary/to_str worker_value) "worker-copy")
              (== (/state (worker_owner .status)) "closed")
              (== (/producers (worker_owner .status)) 0)
              (== (/copied_bytes (worker_owner .status)) 0)
              (== (live) 0)))
        (set worker_owner nil)
        ready)
      true))
  (fn escape_module []
    (let owner (open))
    (owner .module))
  (let abandoned_before (retired))
  (let escaped (escape_module))
  (var attempts 0)
  (while (&& (> (live) 0) (< attempts 100))
    ($sleep 5)
    (set attempts (+ attempts 1)))
  (let abandoned_closed
    (&& (== (live) 0) (== (retired) (+ abandoned_before 2))
        (try (escaped/increment 1) false catch Error true)))
  (let reentrant_before (retired))
  (var reentrant_owner (open))
  (let reentrant_exports (reentrant_owner .module))
  (let close_reentrant (fn [] (reentrant_owner .IoResource:close)))
  (let reentrant_answer (reentrant_exports/increment 99 close_reentrant))
  (await (reentrant_owner .IoResource:wait_closed))
  (let reentrant_closed
    (&& (== reentrant_answer 100) (== (live) 0)
        (== (retired) (+ reentrant_before 2))
        (== (/state (reentrant_owner .status)) "closed")))
  (set reentrant_owner nil)
  (let total_retired (retired))
  (let final_live (live))
  ($ffi/Library/close diagnostic_library)
  (diagnostic_lease .close)
  ($println ($json/stringify
    {^successful successful ^retired total_retired ^live final_live
     ^refused_plain refused ^failure_clean failure_clean
     ^prebuilt_ok prebuilt_ok
     ^abandoned_closed abandoned_closed ^reentrant_closed reentrant_closed
     ^producer_close_ok producer_close_ok ^copied_ok copied_ok
     ^worker_ok worker_ok
     ^baseline_roots baseline_roots
     ^remaining_roots (/native_roots ($runtime/gc_stats))
     ^native_module_records (/native_module_records ($runtime/gc_stats))
     ^materialized_resource_leases
       (/materialized_resource_leases ($runtime/gc_stats))}))
  0)
'''.replace("__LIFETIMES__", str(lifetimes)))
            gene = base / "gene"
            build_args = ["nim", "c", "-d:geneDebug", "-d:geneRcStats", "--path:src", "--hints:off"]
            if atomic:
                build_args += ["--mm:atomicArc", "--threads:on"]
            built = invoke(build_args + [
                            f"--nimcache:{base / 'nimcache'}", f"-o:{gene}",
                            "src/gene.nim"], env)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            prebuilt = source / "module/native/prebuilt.dylib"
            compiled = invoke(["cc", "-dynamiclib", "-fPIC", "-std=c11",
                               f"-I{source / 'module/native'}",
                               str(source / "module/native/module.c"),
                               "-o", str(prebuilt)], env)
            self.assertEqual(compiled.returncode, 0,
                             compiled.stdout + compiled.stderr)
            digest = hashlib.sha256(prebuilt.read_bytes()).hexdigest()
            identity = ("gene-phase1/abi-1/sha256:" +
                        hashlib.sha256(gene.read_bytes()).hexdigest())
            manifest_path = source / "module/package.gene"
            manifest = manifest_path.read_text().replace(
                '^uses ["native" "plain" "failing"]',
                '^uses ["native" "plain" "failing" "prebuilt"]')
            self.assertTrue(manifest.rstrip().endswith(")]}"))
            manifest = manifest.rstrip()[:-2] + '''
         (native_binary "prebuilt" ^variants [{^target "arm64-macosx"
           ^file "native/prebuilt.dylib" ^digest "sha256:%s"
           ^abi_kind gene_api ^abi_version 6
           ^runtime_identity "%s"}])]}\n''' % (digest, identity)
            manifest_path.write_text(manifest)
            resolved = invoke([str(gene), "pkg", "resolve", "--package-root",
                               str(app)], env)
            self.assertEqual(resolved.returncode, 0,
                             resolved.stdout + resolved.stderr)
            prefix = base / "prefix"
            installed = invoke([str(gene), "install", "native_module_installed",
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
            launched = invoke([str(prefix / "bin/native_module_installed")],
                              launch_env, timeout=max(120, lifetimes // 20))
            self.assertEqual(launched.returncode, 0,
                             launched.stdout + launched.stderr)
            report = json.loads(launched.stdout.strip().splitlines()[-1])
            self.assertEqual(report["successful"], lifetimes)
            self.assertEqual(report["retired"],
                             2 * lifetimes + 8 + (2 if atomic else 0))
            self.assertTrue(report["refused_plain"])
            self.assertTrue(report["failure_clean"])
            self.assertTrue(report["prebuilt_ok"])
            self.assertTrue(report["abandoned_closed"])
            self.assertTrue(report["reentrant_closed"])
            self.assertTrue(report["producer_close_ok"])
            self.assertTrue(report["copied_ok"])
            self.assertTrue(report["worker_ok"])
            self.assertEqual(report["live"], 0)
            self.assertEqual(report["remaining_roots"], report["baseline_roots"])
            self.assertEqual(report["native_module_records"], 0)
            self.assertEqual(report["materialized_resource_leases"], 0)


if __name__ == "__main__":
    unittest.main()
