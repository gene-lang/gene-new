#!/usr/bin/env python3
"""Audit native-app workload evidence. The applications under test are Gene."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import shutil
import socket
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
PROFILE_DIR = ROOT / "tests" / "profiles" / "native-app"
VALID_STAGE = {"planned", "experimental", "implemented", "unsupported"}
VALID_DRIVER = {"command", "install", "service", "data"}


def stamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def contained(base: Path, relative: str) -> Path:
    if not relative or Path(relative).is_absolute():
        raise ValueError(f"expected a relative path: {relative!r}")
    result = (base / relative).resolve()
    if result != base.resolve() and base.resolve() not in result.parents:
        raise ValueError(f"path leaves {base}: {relative!r}")
    return result


def load_profile(gene: Path) -> dict:
    exported = subprocess.run(
        [str(gene), "run", str(PROFILE_DIR / "export_manifest.gene"),
         str(PROFILE_DIR / "profile.gene")],
        cwd=ROOT, capture_output=True, text=True, timeout=10, check=False,
    )
    if exported.returncode:
        raise RuntimeError(f"Gene rejected profile.gene: {exported.stderr.strip()}")
    try:
        profile = json.loads(exported.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("manifest exporter did not return JSON") from exc
    if profile.get("profile_format") != 1 or profile.get("name") != "native-app":
        raise ValueError("unsupported native-app manifest identity/format")
    stages = profile.get("stages")
    if not isinstance(stages, dict) or not stages:
        raise ValueError("profile stages must be a nonempty map")
    for stage, state in stages.items():
        if not re.fullmatch(r"[a-z][a-z0-9_]*", stage) or state not in VALID_STAGE:
            raise ValueError(f"invalid stage: {stage}={state}")
    workloads = profile.get("workloads")
    if not isinstance(workloads, list) or not workloads:
        raise ValueError("profile workloads must be a nonempty list")
    seen: set[str] = set()
    for workload in workloads:
        if not isinstance(workload, dict):
            raise ValueError("workload must be a map")
        wid = workload.get("id")
        if not isinstance(wid, str) or not re.fullmatch(r"[a-z][a-z0-9_]*", wid):
            raise ValueError(f"invalid workload ID: {wid!r}")
        if wid in seen:
            raise ValueError(f"duplicate workload ID: {wid}")
        seen.add(wid)
        if workload.get("driver") not in VALID_DRIVER:
            raise ValueError(f"invalid driver for {wid}")
        package = contained(ROOT, workload.get("package", ""))
        entry = contained(package, workload.get("entry", ""))
        if not entry.is_file() or not (package / "package.gene").is_file():
            raise ValueError(f"missing package or entry for {wid}")
        if wid == "lifetime":
            for field in ("witness_entry", "cancellation_entry", "mixed_cancellation_entry",
                          "selection_entry", "service_entry",
                          "service_cancel_entry", "generation_entry",
                          "generation_failure_entry", "retained_entry",
                          "retained_function_entry", "retained_instance_entry"):
                scenario_entry = contained(package, workload.get(field, ""))
                if not scenario_entry.is_file():
                    raise ValueError(f"lifetime {field} is missing")
            plugin = contained(package, workload.get("generation_plugin", ""))
            if not plugin.is_dir() or any(not (plugin / filename).is_file()
                    for filename in ("simple.gene", "plugin.gene",
                                     "failing.gene", "retained_item.gene")):
                raise ValueError("lifetime generation plugin is missing")
        required = workload.get("required_stages")
        if not isinstance(required, list) or not required or any(
            stage not in stages for stage in required
        ):
            raise ValueError(f"invalid required stages for {wid}")
        if not isinstance(workload.get("args"), list) or any(
            not isinstance(arg, str) for arg in workload["args"]
        ):
            raise ValueError(f"invalid argv for {wid}")
        timeout = workload.get("timeout_ms")
        if not isinstance(timeout, int) or not 1 <= timeout <= 300_000:
            raise ValueError(f"invalid timeout for {wid}")
        sizes = workload.get("dataset_sizes")
        if not isinstance(sizes, list) or any(
            not isinstance(size, int) or size < 0 for size in sizes
        ):
            raise ValueError(f"invalid dataset sizes for {wid}")
        budget = workload.get("budget")
        if not isinstance(budget, dict):
            raise ValueError(f"missing budget for {wid}")
        stdout_cap = budget.get("max_stdout_bytes", 65_536)
        if not isinstance(stdout_cap, int) or not 1 <= stdout_cap <= 10_485_760:
            raise ValueError(f"invalid stdout budget for {wid}")
    return profile


def sampled_resident_bytes(pid: int) -> int | None:
    sample = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                            capture_output=True, text=True, check=False)
    try:
        return int(sample.stdout.strip()) * 1024
    except ValueError:
        return None


def run_command(gene: Path, workload: dict, extra_args: list[str] | None = None,
                extra_env: dict[str, str] | None = None,
                sample_rss: bool = False) -> dict:
    package = contained(ROOT, workload["package"])
    entry = contained(package, workload["entry"])
    argv = [str(gene), "run", "--package-root", str(package), str(entry)]
    argv.extend(workload["args"])
    argv.extend(extra_args or [])
    if workload["id"] == "lifetime":
        argv.append(str(workload["dataset_sizes"][0]))
    stdout_cap = workload["budget"].get("max_stdout_bytes", 65_536)
    peak_rss: int | None = None
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        try:
            if sample_rss:
                with subprocess.Popen(
                    argv, cwd=ROOT, stdout=out, stderr=err,
                    env={**os.environ, **(extra_env or {})},
                ) as process:
                    deadline = time.monotonic() + workload["timeout_ms"] / 1000
                    while process.poll() is None:
                        rss = sampled_resident_bytes(process.pid)
                        if rss is not None:
                            peak_rss = max(peak_rss or 0, rss)
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            process.kill()
                            process.wait()
                            return {"outcome": "timeout", "argv": argv,
                                    "sampled_peak_rss_bytes": peak_rss}
                        try:
                            process.wait(timeout=min(0.1, remaining))
                        except subprocess.TimeoutExpired:
                            pass
                    result = subprocess.CompletedProcess(argv, process.returncode)
            else:
                result = subprocess.run(
                    argv, cwd=ROOT, stdout=out, stderr=err,
                    env={**os.environ, **(extra_env or {})},
                    timeout=workload["timeout_ms"] / 1000, check=False,
                )
        except subprocess.TimeoutExpired as exc:
            return {"outcome": "timeout", "error": str(exc), "argv": argv}
        out.seek(0)
        err.seek(0)
        output = out.read(stdout_cap + 1)
        errors = err.read(8193)
    stdout = output[:stdout_cap].decode("utf-8", errors="replace")
    detail = {"exit_code": result.returncode, "stdout": stdout,
              "stderr": errors[:8192].decode("utf-8", errors="replace"),
              "stdout_truncated": len(output) > stdout_cap,
              "stderr_truncated": len(errors) > 8192, "argv": argv}
    if sample_rss:
        detail["sampled_peak_rss_bytes"] = peak_rss
    if detail["stdout_truncated"]:
        return {"outcome": "failure", "reason": "stdout_limit", **detail}
    try:
        payload = json.loads(stdout.strip())
    except json.JSONDecodeError:
        return {"outcome": "failure", "reason": "no_single_json_result", **detail}
    if result.returncode != 0 or not isinstance(payload, dict) or (
        payload.get("workload") != workload["id"] or payload.get("ok") is not True
    ):
        return {"outcome": "failure", "reason": "wrong_exit_or_result", **detail}
    return {"outcome": "pass", "result": payload, **detail}


def run_lifetime(workload: dict) -> dict:
    """Build the test-only RC surface and compare quiescent batch snapshots."""
    nim = shutil.which("nim")
    if not nim:
        return {"outcome": "blocked", "reason": "nim_compiler_unavailable"}
    package = contained(ROOT, workload["package"])
    entry = contained(package, workload["entry"])
    batches = workload["dataset_sizes"]
    if batches != [1, 100, 1000, 10000]:
        return {"outcome": "failure", "reason": "lifetime_batch_contract_changed"}
    build_env = dict(os.environ)
    sdk_pin = ""
    if platform.system() == "Darwin" and platform.machine() == "arm64":
        toolchains = json.loads((PROFILE_DIR / "cli-toolchain.lock.json").read_text())
        sdk_pin = toolchains["macosx-arm64"]["sdk_root"]
        if not Path(sdk_pin).is_dir():
            return {"outcome": "blocked", "reason": "pinned_sdk_unavailable",
                    "sdk_root": sdk_pin}
        build_env["SDKROOT"] = sdk_pin
    with tempfile.TemporaryDirectory(prefix="gene-vm3-lifetime-") as temp:
        instrumented = Path(temp) / "gene-rc"
        command = [nim, "c", "-d:geneRcStats", "--mm:orc", "--path:src",
                   "--hints:off", f"--nimcache:{Path(temp) / 'nimcache'}",
                   f"-o:{instrumented}", "src/gene.nim"]
        try:
            built = subprocess.run(command, cwd=ROOT, env=build_env,
                                   capture_output=True, text=True,
                                   check=False, timeout=180)
        except subprocess.TimeoutExpired:
            return {"outcome": "failure", "reason": "instrumented_build_timeout",
                    "build_argv": command}
        if built.returncode:
            return {"outcome": "failure", "reason": "instrumented_build_failed",
                    "build_argv": command, "build_stderr": built.stderr[-8192:]}
        argv = [str(instrumented), "run", "--package-root", str(package),
                str(entry), str(batches[-1])]
        peak_rss: int | None = None
        with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
            with subprocess.Popen(argv, cwd=ROOT, stdout=out, stderr=err,
                                  env=build_env) as process:
                deadline = time.monotonic() + workload["timeout_ms"] / 1000
                while process.poll() is None:
                    rss = sampled_resident_bytes(process.pid)
                    if rss is not None:
                        peak_rss = max(peak_rss or 0, rss)
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        process.kill()
                        process.wait()
                        out.seek(0)
                        err.seek(0)
                        partial = out.read(65536).decode(errors="replace")
                        markers = [line for line in partial.splitlines()
                                   if '"phase":"starting"' in line]
                        return {"outcome": "timeout", "reason": "lifetime_deadline",
                                "argv": argv, "last_progress": markers[-1]
                                if markers else "", "stdout_tail": partial[-4096:],
                                "stderr_tail": err.read(8192).decode(errors="replace"),
                                "sampled_peak_rss_bytes": peak_rss}
                    try:
                        process.wait(timeout=min(0.1, remaining))
                    except subprocess.TimeoutExpired:
                        pass
                exit_code = process.returncode
            out.seek(0)
            err.seek(0)
            output = out.read(workload["budget"]["max_stdout_bytes"] + 1)
            errors = err.read(8193)
        if len(output) > workload["budget"]["max_stdout_bytes"]:
            return {"outcome": "failure", "reason": "lifetime_stdout_limit",
                    "argv": argv}
        if exit_code:
            return {"outcome": "failure", "reason": "lifetime_exit",
                    "exit_code": exit_code, "stdout": output.decode(errors="replace"),
                    "stderr": errors[:8192].decode(errors="replace")}
        try:
            snapshots = [json.loads(line) for line in output.decode().splitlines()]
        except (UnicodeDecodeError, json.JSONDecodeError):
            return {"outcome": "failure", "reason": "lifetime_snapshot_parse",
                    "stdout": output.decode(errors="replace")}
        expected = [("warm", 100)]
        for size in batches:
            expected += [("starting", size), ("after", size)]
        expected.append(("final", batches[-1]))
        observed = [(item.get("phase"), item.get("batch"))
                    for item in snapshots if isinstance(item, dict)]
        if observed != expected:
            return {"outcome": "failure", "reason": "lifetime_progress_sequence",
                    "expected": expected, "observed": observed}
        baseline = snapshots[0]
        classes = baseline.get("managed_classes")
        if baseline.get("rc_stats") is not True or not isinstance(classes, dict) or (
                not classes or any(not isinstance(n, int) for n in classes.values()) or
                sum(classes.values()) != baseline.get("live_managed")):
            return {"outcome": "failure", "reason": "lifetime_counters_unavailable"}
        for key in ("native_roots", "io_cleanup_leases", "io_root_tasks",
                    "io_root_cleanup_tasks", "io_open_resources"):
            if baseline.get(key) != 0:
                return {"outcome": "failure", "reason": "lifetime_warm_owner",
                        "counter": key, "baseline": baseline}
        checked = [item for item in snapshots if item["phase"] in {"after", "final"}]
        growth = workload["budget"]["max_managed_growth"]
        for item in checked:
            measured = item.get("managed_classes")
            if not isinstance(measured, dict) or set(measured) != set(classes):
                return {"outcome": "failure", "reason": "lifetime_class_counter_missing",
                        "snapshot": item}
            if sum(measured.values()) != item.get("live_managed"):
                return {"outcome": "failure", "reason": "lifetime_class_count_mismatch",
                        "snapshot": item}
            if item.get("live_managed") != baseline.get("live_managed") or any(
                    measured[name] - baseline_value > growth or
                    measured[name] != baseline_value
                    for name, baseline_value in classes.items()):
                return {"outcome": "failure", "reason": "lifetime_managed_growth",
                        "baseline": baseline, "snapshot": item}
            for key, limit in (
                ("native_roots", workload["budget"]["max_native_roots"]),
                ("io_cleanup_leases", workload["budget"]["max_io_cleanup_leases"]),
                ("io_root_tasks", 0), ("io_root_cleanup_tasks", 0),
                ("io_open_resources", 0),
            ):
                if not isinstance(item.get(key), int) or item[key] > limit:
                    return {"outcome": "failure", "reason": "lifetime_owner_growth",
                            "counter": key, "snapshot": item}
        extra_results = {}
        plugin = contained(package, workload["generation_plugin"])
        for label, field, scenario_args in (
                ("witness", "witness_entry", [str(batches[-1])]),
                ("cancellation", "cancellation_entry", [str(batches[-1])]),
                ("mixed_cancellation", "mixed_cancellation_entry", [str(batches[-1])]),
                ("selection", "selection_entry", [str(batches[-1])]),
                ("service", "service_entry",
                 [str(free_loopback_port()), str(batches[-1])]),
                ("service_cancel", "service_cancel_entry",
                 [str(free_loopback_port()), str(batches[-1])]),
                ("generation", "generation_entry",
                 [str(plugin), str(batches[-1]), "simple.gene"]),
                ("generation_rich", "generation_entry",
                 [str(plugin), str(batches[-1]), "plugin.gene"]),
                ("generation_failure", "generation_failure_entry",
                 [str(plugin), str(batches[-1])])):
            scenario_entry = contained(package, workload[field])
            scenario_argv = [str(instrumented), "run", "--package-root",
                             str(package), str(scenario_entry), *scenario_args]
            try:
                scenario_run = subprocess.run(
                    scenario_argv, cwd=ROOT, env=build_env,
                    capture_output=True, text=True, check=False,
                    timeout=workload["timeout_ms"] / 1000)
            except subprocess.TimeoutExpired as exc:
                partial = exc.stdout.decode(errors="replace") if isinstance(
                    exc.stdout, bytes) else (exc.stdout or "")
                markers = [line for line in partial.splitlines()
                           if '"phase":"starting"' in line]
                return {"outcome": "timeout", "reason": label + "_deadline",
                        "argv": scenario_argv,
                        "last_progress": markers[-1] if markers else "",
                        "stdout_tail": partial[-4096:]}
            if scenario_run.returncode or len(scenario_run.stdout) > workload[
                    "budget"]["max_stdout_bytes"]:
                return {"outcome": "failure",
                        "reason": label + "_exit_or_output",
                        "exit_code": scenario_run.returncode,
                        "stdout_tail": scenario_run.stdout[-4096:],
                        "stderr_tail": scenario_run.stderr[-4096:]}
            try:
                scenario_snapshots = [json.loads(line)
                                      for line in scenario_run.stdout.splitlines()]
            except json.JSONDecodeError:
                return {"outcome": "failure",
                        "reason": label + "_snapshot_parse",
                        "stdout_tail": scenario_run.stdout[-4096:]}
            scenario_expected = [("warm", 100)]
            for size in batches:
                scenario_expected += [("starting", size), ("after", size)]
            if ([(item.get("phase"), item.get("iterations"))
                 for item in scenario_snapshots] != scenario_expected):
                return {"outcome": "failure",
                        "reason": label + "_progress_sequence",
                        "observed": scenario_snapshots}
            scenario_baseline = scenario_snapshots[0]
            scenario_classes = scenario_baseline.get("managed_classes")
            if (scenario_baseline.get("rc_stats") is not True or
                    scenario_baseline.get("native_roots") != 0 or
                    not isinstance(scenario_classes, dict) or
                    not scenario_classes or
                    any(not isinstance(n, int) for n in scenario_classes.values()) or
                    sum(scenario_classes.values()) != scenario_baseline.get(
                        "live_managed")):
                return {"outcome": "failure",
                        "reason": label + "_counters_unavailable"}
            generation_counters = (
                "sandbox_generation_records", "sandbox_transaction_records",
                "module_cache_entries", "module_compile_headers",
                "module_compile_artifacts", "canonical_impls",
                "active_impl_assemblies", "released_generation_roots",
                "base_scopes")
            service_counters = (
                "io_open_resources", "http_client_open_resources",
                "http_client_pending_requests", "in_flight_requests")
            selection_counters = (
                "active_impl_assemblies", "canonical_impls",
                "impl_scope_index_entries", "impl_scope_index_scopes",
                "base_scopes")
            if label.startswith("generation") and any(
                    not isinstance(scenario_baseline.get(counter), int)
                    for counter in generation_counters):
                return {"outcome": "failure",
                        "reason": "generation_owners_unavailable"}
            if label == "selection" and any(
                    not isinstance(scenario_baseline.get(counter), int)
                    for counter in selection_counters):
                return {"outcome": "failure",
                        "reason": "selection_owners_unavailable"}
            if label in ("service", "service_cancel") and any(
                    not isinstance(scenario_baseline.get(counter), int)
                    for counter in service_counters):
                return {"outcome": "failure",
                        "reason": "service_owners_unavailable"}
            scenario_checked = [item for item in scenario_snapshots
                                if item["phase"] == "after"]
            if label == "mixed_cancellation":
                completed = 100
                for item in [scenario_baseline, *scenario_checked]:
                    if item["phase"] == "after":
                        completed += item["iterations"]
                    if (item.get("retained_control_checked") is not True or
                            item.get("cleanup_runs") != completed * 3 or
                            item.get("nested_cleanup_runs") != completed or
                            any(item.get(counter) != 0 for counter in (
                                "io_root_tasks", "io_root_cleanup_tasks",
                                "io_open_resources", "scheduler_runnable_fibers",
                                "scheduler_waiting_fibers", "io_cleanup_leases",
                                "io_retained_bytes", "io_waiting_readiness"))):
                        return {"outcome": "failure",
                                "reason": "mixed_cancellation_cleanup_or_control",
                                "snapshot": item}
            if label == "service_cancel":
                completed = 100
                for item in [scenario_baseline, *scenario_checked]:
                    if item["phase"] == "after":
                        completed += item["iterations"]
                    if (item.get("handler_graph_cleanups") != completed * 2 or
                            any(item.get(counter) != 0 for counter in (
                                "scheduler_runnable_fibers",
                                "scheduler_waiting_fibers", "io_cleanup_leases",
                                "io_retained_bytes", "io_waiting_readiness"))):
                        return {"outcome": "failure",
                                "reason": "service_cancel_graph_cleanup",
                                "snapshot": item}
            for item in scenario_checked:
                if (item.get("rc_stats") is not True or
                        item.get("native_roots") != 0 or
                        item.get("live_managed") != scenario_baseline[
                            "live_managed"] or
                        item.get("managed_classes") != scenario_classes or
                        (label in ("cancellation", "mixed_cancellation", "selection", "service",
                                   "service_cancel") and (
                            item.get("io_root_tasks") != 0 or
                            item.get("io_root_cleanup_tasks") != 0)) or
                        (label.startswith("generation") and any(
                            item.get(counter) != scenario_baseline.get(counter)
                            for counter in generation_counters)) or
                        (label == "selection" and any(
                            item.get(counter) != scenario_baseline.get(counter)
                            for counter in selection_counters)) or
                        (label in ("service", "service_cancel") and any(
                            item.get(counter) != 0
                            for counter in service_counters))):
                    return {"outcome": "failure",
                            "reason": label + "_retention",
                            "baseline": scenario_baseline, "snapshot": item}
            extra_results[label + "_baseline"] = scenario_baseline
            extra_results[label + "_checkpoints"] = scenario_checked
        controls = {}
        for label, field in (("module", "retained_entry"),
                             ("function", "retained_function_entry"),
                             ("instance", "retained_instance_entry")):
            retained_entry = contained(package, workload[field])
            retained_argv = [str(instrumented), "run", "--package-root",
                             str(package), str(retained_entry), str(plugin)]
            try:
                retained = subprocess.run(retained_argv, cwd=ROOT,
                    env=build_env, capture_output=True, text=True,
                    check=False, timeout=10)
            except subprocess.TimeoutExpired:
                return {"outcome": "timeout",
                        "reason": "retained_" + label + "_deadline",
                        "argv": retained_argv}
            if retained.returncode:
                return {"outcome": "failure",
                        "reason": "retained_" + label + "_broken",
                        "stderr_tail": retained.stderr[-4096:]}
            controls["retained_" + label + "_control"] = True
        toolchain = subprocess.run([nim, "--version"], capture_output=True,
                                   text=True, check=False)
        return {"outcome": "pass", "result": {
            "workload": "lifetime", "ok": True,
            "covered_classes": ["eval_types", "closures", "cells",
                                "self_cycles", "failure_unwind",
                                "impl_failure_unwind", "compile_failure",
                                "escaped_type_witnesses",
                                "cancelled_type_tasks",
                                "cancelled_mixed_mutable_graphs",
                                "cancelled_partial_selection",
                                "failed_partial_selection",
                                "in_process_service_requests",
                                "cancelled_service_handlers_mixed_graphs",
                                "released_scalar_modules",
                                "released_type_protocol_impl_modules",
                                "discarded_generations",
                                "failed_generation_prepare",
                                "retained_module_self",
                                "retained_function_scope",
                                "retained_instance_type"],
            "baseline": baseline, "checkpoints": checked,
            **extra_results,
            **controls,
            "instrumented_gene_sha256": hashlib.sha256(
                instrumented.read_bytes()).hexdigest(),
            "instrumented_flags": ["-d:geneRcStats", "--mm:orc"],
            "nim_version": toolchain.stdout.splitlines()[0]
            if toolchain.stdout else "unavailable",
            "sdk_root": sdk_pin, "sampled_peak_rss_bytes": peak_rss,
        }, "argv": argv, "stderr": errors[:8192].decode(errors="replace")}


def run_script(gene: Path, workload: dict) -> dict:
    class LocalApi(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            status = 503 if self.path == "/unavailable" else 200
            body = b'{"result":"ok"}' if status == 200 else b'{"error":"unavailable"}'
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format: str, *args: object) -> None:
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), LocalApi) as server:
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix="native-app-script-",
                                             dir=ROOT / "tmp") as work:
                output = Path(work) / "result.json"
                url = f"http://127.0.0.1:{server.server_port}/value"
                normal = run_command(gene, workload, [url, str(output)])
                expected = {"name": "Ada", "total": 8,
                            "files": ["bad.csv", "input.json", "people.csv"],
                            "api": "ok", "process_result": "5"}
                if normal["outcome"] != "pass" or not output.is_file():
                    return {"outcome": "failure", "reason": "normal_script",
                            "normal": normal}
                try:
                    saved = json.loads(output.read_text())
                except (OSError, json.JSONDecodeError):
                    return {"outcome": "failure", "reason": "invalid_atomic_output",
                            "normal": normal}
                if saved != expected or normal["result"].get("output") != expected:
                    return {"outcome": "failure", "reason": "wrong_script_result",
                            "saved": saved, "normal": normal}
                faults = []
                bad_csv = ROOT / "tests/profiles/native-app/script/fixtures/bad.csv"
                cases = [
                    ("bad_csv", [url, str(Path(work) / "bad.csv.json"), str(bad_csv)],
                     {}, "CsvError"),
                    ("api_failure", [f"http://127.0.0.1:{server.server_port}/unavailable",
                                     str(Path(work) / "api.json")], {}, "ScriptError"),
                    ("child_failure", [url, str(Path(work) / "child.json")],
                     {"GENE_PROFILE_CHILD_FAIL": "1"}, "ScriptError"),
                ]
                for name, argv, env, error_type in cases:
                    fault = run_command(gene, workload, argv, env)
                    leaked_output = Path(argv[1]).exists()
                    faults.append({"name": name, "exit_code": fault.get("exit_code"),
                                   "typed_error": error_type in fault.get("stderr", ""),
                                   "output_published": leaked_output})
                    if (fault.get("exit_code") in (None, 0) or leaked_output or
                            error_type not in fault.get("stderr", "")):
                        return {"outcome": "failure", "reason": "fault_case",
                                "fault": fault, "faults": faults}
                return {"outcome": "pass", "result": normal["result"],
                        "faults": faults}
        finally:
            server.shutdown()
            thread.join(timeout=5)


def run_data(gene: Path, workload: dict) -> dict:
    groups = min(32, workload["budget"]["max_groups"])
    seed = workload["dataset_seed"]
    cases = []
    faults = []
    with tempfile.TemporaryDirectory(prefix="native-app-data-",
                                     dir=ROOT / "tmp") as work:
        source = Path(work) / "input.csv"
        for target_size in workload["dataset_sizes"]:
            expected = {f"g{i:02d}": 0 for i in range(groups)}
            header = b"group,value,pad\n"
            with source.open("wb") as stream:
                stream.write(header)
                written = len(header)
                row_count = 0
                while written < target_size:
                    group = f"g{row_count % groups:02d}"
                    amount = (row_count * 17 + seed) % 10
                    prefix = f"{group},{amount},".encode("ascii")
                    line_size = min(1024, target_size - written)
                    if line_size < len(prefix) + 1:
                        raise ValueError("data size leaves an incomplete CSV row")
                    stream.write(prefix + b"x" * (line_size - len(prefix) - 1) + b"\n")
                    written += line_size
                    expected[group] += amount
                    row_count += 1
            result = run_command(gene, workload, [str(source)], sample_rss=True)
            case = {"input_bytes": target_size, "rows": row_count, **result}
            cases.append(case)
            if result["outcome"] != "pass":
                return {"outcome": "failure", "reason": "data_process", "cases": cases}
            metrics = result["result"]
            if any(not isinstance(metrics.get(key), int) or metrics[key] < 0
                   for key in ("parser_peak_bytes", "parser_retained_at_eof",
                               "parser_retained_after_close",
                               "io_peak_bytes", "io_retained_at_eof",
                               "io_retained_after_close",
                               "io_cleanup_leases_after_close")) or any(
                metrics[key] != 0 for key in ("parser_retained_after_close",
                                             "io_retained_at_eof",
                                             "io_retained_after_close",
                                             "io_cleanup_leases_after_close")):
                return {"outcome": "failure", "reason": "data_retirement",
                        "cases": cases}
            actual = result["result"].get("groups")
            wanted = [[key, expected[key]] for key in sorted(expected)]
            if actual != wanted:
                return {"outcome": "failure", "reason": "data_result",
                        "expected": wanted, "cases": cases}
        parser_eof_growth = (cases[-1]["result"]["parser_retained_at_eof"] -
                             cases[0]["result"]["parser_retained_at_eof"])
        parser_peak_growth = (cases[-1]["result"]["parser_peak_bytes"] -
                              cases[0]["result"]["parser_peak_bytes"])
        if max(parser_eof_growth, parser_peak_growth) > workload["budget"]["max_growth_bytes"]:
            return {"outcome": "failure", "reason": "data_parser_growth",
                    "parser_retained_at_eof_growth_bytes": parser_eof_growth,
                    "parser_peak_growth_bytes": parser_peak_growth,
                    "cases": cases}
        with source.open("wb") as stream:
            stream.write(b"group,value,pad\n")
            for index in range(101):
                stream.write(f"g{index:03d},1,\n".encode("ascii"))
        faults.append(("group_limit", "DataLimitError", run_command(
            gene, workload, [str(source)])))
        with source.open("wb") as stream:
            stream.write(b"group,value," + b",".join(
                f"p{index}".encode("ascii") for index in range(10)) + b"\n")
            stream.write(b"g00,1," + b",".join([b"x" * 900_000] * 10) + b"\n")
        faults.append(("record_limit", "CsvError", run_command(
            gene, workload, [str(source)])))
        checked_faults = []
        for name, error_type, result in faults:
            typed = error_type in result.get("stderr", "")
            checked_faults.append({"name": name, "outcome": result["outcome"],
                                   "exit_code": result.get("exit_code"),
                                   "typed_error": typed})
            if result["outcome"] == "pass" or not typed:
                return {"outcome": "failure", "reason": "data_fault",
                        "cases": cases, "faults": checked_faults}
    rss = [case.get("sampled_peak_rss_bytes") for case in cases]
    growth = rss[-1] - rss[0] if len(rss) == 2 and all(
        isinstance(value, int) for value in rss) else None
    return {"outcome": "pass", "cases": cases, "faults": checked_faults,
            "parser_retained_at_eof_growth_bytes": parser_eof_growth,
            "parser_peak_growth_bytes": parser_peak_growth,
            "sampled_peak_rss_growth_bytes": growth}


def free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def run_service(gene: Path, workload: dict) -> dict:
    workload_deadline = time.monotonic() + workload["timeout_ms"] / 1000
    caddy = shutil.which("caddy")
    openssl = shutil.which("openssl")
    if not caddy or not openssl:
        return {"outcome": "blocked", "reason": "caddy_or_openssl_missing",
                "caddy": caddy, "openssl": openssl}
    package = contained(ROOT, workload["package"])
    entry = contained(package, workload["entry"])
    with tempfile.TemporaryDirectory(prefix="native-app-service-",
                                     dir=ROOT / "tmp") as work:
        base = Path(work)
        gene_port = free_loopback_port()
        proxy_port = free_loopback_port()
        cert, key = base / "cert.pem", base / "key.pem"
        generated = subprocess.run(
            [openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-days", "1", "-keyout", str(key), "-out", str(cert),
             "-subj", "/CN=localhost",
             "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
            capture_output=True, text=True, timeout=20, check=False)
        if generated.returncode:
            return {"outcome": "failure", "reason": "certificate_generation",
                    "stderr": generated.stderr[-4096:]}
        caddyfile = base / "Caddyfile"
        template = (package / "Caddyfile.template").read_text()
        caddyfile.write_text(template.replace("{{PROXY_PORT}}", str(proxy_port))
                             .replace("{{GENE_PORT}}", str(gene_port))
                             .replace("{{CERT_FILE}}", str(cert))
                             .replace("{{KEY_FILE}}", str(key)))
        database = base / "service.sqlite"
        gene_log, proxy_log = base / "gene.log", base / "caddy.log"
        trusted = ssl.create_default_context(cafile=str(cert))
        url = f"https://127.0.0.1:{proxy_port}"
        plain = f"http://127.0.0.1:{gene_port}"

        def fetch(path: str, *, data: bytes | None = None,
                  headers: dict[str, str] | None = None,
                  context: ssl.SSLContext = trusted) -> tuple[int, bytes, float]:
            request = urllib.request.Request(url + path, data=data,
                                             headers=headers or {})
            started = time.monotonic()
            with urllib.request.urlopen(request, context=context,
                                        timeout=5) as response:
                return response.status, response.read(), time.monotonic() - started

        def wait_ready(address: str, context: ssl.SSLContext | None,
                       process: subprocess.Popen[bytes]) -> bool:
            deadline = min(workload_deadline, time.monotonic() + 12)
            while time.monotonic() < deadline and process.poll() is None:
                try:
                    with urllib.request.urlopen(address + "/health",
                                                context=context,
                                                timeout=0.5) as response:
                        if response.status == 200 and response.read() == b"ready":
                            return True
                except (OSError, urllib.error.URLError):
                    time.sleep(0.05)
            return False

        version = subprocess.run([caddy, "version"], capture_output=True,
                                 text=True, timeout=5, check=False).stdout.strip()
        expected_version = json.loads(
            (package / "proxy.lock.json").read_text())["version"]
        if version != expected_version:
            return {"outcome": "blocked", "reason": "proxy_version_mismatch",
                    "expected": expected_version, "actual": version}
        with gene_log.open("wb") as gene_out, proxy_log.open("wb") as proxy_out:
            gene_proc = subprocess.Popen(
                [str(gene), "run", "--package-root", str(package), str(entry),
                 str(gene_port), str(database)], cwd=ROOT,
                stdin=subprocess.DEVNULL, stdout=gene_out, stderr=gene_out)
            proxy_proc: subprocess.Popen[bytes] | None = None
            try:
                if not wait_ready(plain, None, gene_proc):
                    return {"outcome": "failure", "reason": "gene_not_ready",
                            "gene_log": gene_log.read_text(errors="replace")[-8192:]}
                proxy_proc = subprocess.Popen(
                    [caddy, "run", "--config", str(caddyfile),
                     "--adapter", "caddyfile"], cwd=base,
                    stdin=subprocess.DEVNULL, stdout=proxy_out,
                    stderr=proxy_out,
                    env={**os.environ, "XDG_DATA_HOME": str(base / "data"),
                         "XDG_CONFIG_HOME": str(base / "config")})
                if not wait_ready(url, trusted, proxy_proc):
                    return {"outcome": "failure", "reason": "proxy_not_ready",
                            "gene_log": gene_log.read_text(errors="replace")[-8192:],
                            "proxy_log": proxy_log.read_text(errors="replace")[-8192:]}
                plain_latencies = []
                proxy_latencies = []
                for _ in range(10):
                    started = time.monotonic()
                    with urllib.request.urlopen(plain + "/health",
                                                timeout=5) as response:
                        if response.read() != b"ready":
                            return {"outcome": "failure", "reason": "plain_baseline"}
                    plain_latencies.append((time.monotonic() - started) * 1000)
                    proxy_latencies.append(fetch("/health")[2] * 1000)
                plain_baseline_ms = sorted(plain_latencies)[5]
                proxy_baseline_ms = sorted(proxy_latencies)[5]
                untrusted_rejected = False
                try:
                    fetch("/health", context=ssl.create_default_context())
                except urllib.error.URLError as exc:
                    untrusted_rejected = isinstance(exc.reason, ssl.SSLError)
                if not untrusted_rejected:
                    return {"outcome": "failure", "reason": "tls_trust_not_enforced"}
                status, raw_meta, _ = fetch("/meta", headers={
                    "X-Forwarded-For": "203.0.113.7",
                    "X-Forwarded-Proto": "http",
                    "X-Forwarded-Host": "attacker.invalid"})
                meta = json.loads(raw_meta)
                if status != 200 or meta.get("path") != "/meta" or (
                    meta.get("forwarded_proto") != "https" or
                    meta.get("forwarded_host") != f"127.0.0.1:{proxy_port}" or
                    "203.0.113.7" in meta.get("forwarded_for", "")
                ):
                    return {"outcome": "failure", "reason": "forwarded_header_policy",
                            "meta": meta}
                upload = b"x" * 65536
                status, body, _ = fetch("/upload", data=upload)
                if status != 200 or body != b"65536":
                    return {"outcome": "failure", "reason": "streamed_upload",
                            "status": status, "body": body[:100].decode(errors="replace")}
                status, body, _ = fetch("/stream")
                if status != 200 or body != b"stream-ok":
                    return {"outcome": "failure", "reason": "streamed_response",
                            "status": status, "body": body[:100].decode(errors="replace")}
                db_results = [fetch("/db")[1] for _ in range(2)]
                if db_results != [b"1", b"2"]:
                    return {"outcome": "failure", "reason": "sqlite_workload",
                            "results": [x.decode(errors="replace") for x in db_results]}
                with ThreadPoolExecutor(max_workers=8) as pool:
                    slow = pool.submit(fetch, "/slow")
                    time.sleep(0.05)
                    fast = [pool.submit(fetch, "/health") for _ in range(7)]
                    fast_results = [future.result(timeout=5) for future in fast]
                    slow_result = slow.result(timeout=5)
                if slow_result[1] != b"slow" or any(
                    status != 200 or body != b"ready" or latency > 0.25
                    for status, body, latency in fast_results
                ):
                    return {"outcome": "failure", "reason": "slow_peer_fairness",
                            "fast_latencies_ms": [round(x[2] * 1000, 2)
                                                  for x in fast_results],
                            "slow_latency_ms": round(slow_result[2] * 1000, 2)}
                target_rate = workload["budget"]["requests_per_second"]
                duration = workload["budget"]["duration_seconds"]
                target_count = target_rate * duration
                if target_rate < 1 or duration < 1 or target_count > workload.get(
                        "request_cap", 10_000):
                    return {"outcome": "failure", "reason": "invalid_service_budget"}

                def load_one(index: int) -> tuple[str, float, float, bool]:
                    if index % 150 == 0:
                        path, payload, expected = "/slow", None, b"slow"
                    elif index % 60 == 0:
                        path, payload, expected = "/upload", b"z" * 4096, b"4096"
                    elif index % 20 == 0:
                        path, payload, expected = "/stream", None, b"stream-ok"
                    elif index % 10 == 0:
                        path, payload, expected = "/db", None, None
                    else:
                        path, payload, expected = "/health", None, b"ready"
                    code, content, latency = fetch(path, data=payload)
                    valid = code == 200 and (
                        content == expected if expected is not None else
                        content.isdigit())
                    return path, latency, time.monotonic(), valid

                load_started = time.monotonic()
                samples: list[tuple[str, float, float, bool]] = []
                peak_rss = sampled_resident_bytes(gene_proc.pid)
                pool = ThreadPoolExecutor(max_workers=8)
                try:
                    futures = []
                    for index in range(target_count):
                        if time.monotonic() >= workload_deadline:
                            return {"outcome": "failure",
                                    "reason": "service_workload_timeout"}
                        scheduled = load_started + index / target_rate
                        delay = scheduled - time.monotonic()
                        if delay > 0:
                            time.sleep(delay)
                        futures.append(pool.submit(load_one, index))
                        if index % target_rate == 0:
                            rss = sampled_resident_bytes(gene_proc.pid)
                            if rss is not None:
                                peak_rss = max(peak_rss or 0, rss)
                    for index, future in enumerate(futures):
                        try:
                            remaining = workload_deadline - time.monotonic()
                            if remaining <= 0:
                                return {"outcome": "failure",
                                        "reason": "service_workload_timeout",
                                        "completed": len(samples)}
                            samples.append(future.result(timeout=min(5, remaining)))
                        except Exception as exc:
                            return {"outcome": "failure", "reason": "load_request",
                                    "index": index, "error": str(exc)}
                finally:
                    pool.shutdown(wait=False, cancel_futures=True)
                elapsed = time.monotonic() - load_started
                fast_samples = sorted(sample[1] * 1000 for sample in samples
                                      if sample[0] != "/slow")
                fast_completed = sorted(sample[2] for sample in samples
                                        if sample[0] != "/slow")
                def percentile(values: list[float], fraction: float) -> float:
                    return values[max(0, math.ceil(len(values) * fraction) - 1)]
                p50 = percentile(fast_samples, 0.50)
                p95 = percentile(fast_samples, 0.95)
                p99 = percentile(fast_samples, 0.99)
                max_gap = max((later - earlier) * 1000 for earlier, later in
                              zip(fast_completed, fast_completed[1:]))
                gap_index = max(range(len(fast_completed) - 1), key=lambda i:
                                fast_completed[i + 1] - fast_completed[i])
                load_metrics = {
                    "requests": len(samples), "duration_seconds": round(elapsed, 3),
                    "rate_per_second": round(len(samples) / elapsed, 2),
                    "p50_ms": round(p50, 2), "p95_ms": round(p95, 2),
                    "p99_ms": round(p99, 2),
                    "max_fast_completion_gap_ms": round(max_gap, 2),
                    "max_fast_completion_gap_at_seconds": round(
                        fast_completed[gap_index] - load_started, 3),
                    "sampled_peak_rss_bytes": peak_rss,
                    "slow_requests": sum(x[0] == "/slow" for x in samples),
                }
                if (len(samples) != target_count or
                    not all(sample[3] for sample in samples) or
                    elapsed > duration + 5 or
                    p95 > workload["budget"]["p95_ms"]):
                    return {"outcome": "failure", "reason": "service_budget",
                            "metrics": load_metrics,
                            "invalid_results": sum(not x[3] for x in samples)}
                status, body, _ = fetch("/stop")
                if status != 200 or body != b"stopping":
                    return {"outcome": "failure", "reason": "stop_response"}
                try:
                    gene_proc.wait(timeout=max(0.001, min(7,
                        workload_deadline - time.monotonic())))
                except subprocess.TimeoutExpired:
                    return {"outcome": "failure", "reason": "shutdown_timeout"}
                output = gene_log.read_text(errors="replace")
                stopped = None
                for line in output.splitlines():
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(event, dict) and event.get("event") == "stopped":
                        stopped = event
                if gene_proc.returncode != 0 or stopped is None:
                    return {"outcome": "failure", "reason": "shutdown_result",
                            "exit_code": gene_proc.returncode,
                            "gene_log": output[-8192:]}
                heartbeat_gap = stopped.get("max_heartbeat_gap_ms")
                tick_count = stopped.get("tick_count")
                # What the root lane was doing just before the largest gap.
                heartbeat_cause = {key: stopped.get("max_heartbeat_" + key)
                                   for key in ("loop_work_ms",
                                               "loop_work_cpu_ms",
                                               "wait_overrun_ms")}
                if (not isinstance(heartbeat_gap, int) or
                    not isinstance(tick_count, int) or
                    heartbeat_gap > 250 or tick_count < duration * 10):
                    return {"outcome": "failure", "reason": "host_loop_stall",
                            "max_heartbeat_gap_ms": heartbeat_gap,
                            "max_heartbeat_at_ms": stopped.get(
                                "max_heartbeat_at_ms"),
                            "max_heartbeat_active_connections": stopped.get(
                                "max_heartbeat_active_connections"),
                            "max_heartbeat_in_flight": stopped.get(
                                "max_heartbeat_in_flight"),
                            "heartbeat_cause": heartbeat_cause,
                            "max_db_ms": stopped.get("max_db_ms"),
                            "max_db_at_ms": stopped.get("max_db_at_ms"),
                            "tick_count": tick_count,
                            "load": load_metrics}
                # Sustained-service heap slope (VM-3): only a geneRcStats build
                # samples live_managed. Minimums of the first and last thirds
                # filter out the requests in flight at each sample.
                heap_samples = stopped.get("managed_samples")
                heap_slope = None
                if isinstance(heap_samples, list) and len(heap_samples) >= 6 and all(
                        isinstance(x, int) for x in heap_samples):
                    third = len(heap_samples) // 3
                    heap_slope = {"samples": heap_samples,
                                  "early_min": min(heap_samples[:third]),
                                  "late_min": min(heap_samples[-third:])}
                    heap_slope["growth"] = (heap_slope["late_min"] -
                                            heap_slope["early_min"])
                    if heap_slope["growth"] > workload["budget"].get(
                            "max_managed_slope", 0):
                        return {"outcome": "failure",
                                "reason": "service_heap_slope",
                                "heap_slope": heap_slope, "load": load_metrics}
                cleanup = {key: stopped.get(key) for key in
                           ("io_cleanup_leases", "io_open_resources",
                            "io_retained_bytes")}
                shutdown = stopped.get("shutdown")
                if (any(value != 0 for value in cleanup.values()) or
                    not isinstance(shutdown, dict) or
                    shutdown.get("complete") is not True or
                    shutdown.get("graceful") is not True or
                    shutdown.get("cleanup_leases") != 0 or
                    shutdown.get("open_io_resources") != 0 or
                    shutdown.get("pending_cleanup_tasks") != 0 or
                    shutdown.get("close_failed") is not False):
                    return {"outcome": "failure", "reason": "shutdown_cleanup",
                            "cleanup": cleanup, "shutdown": shutdown,
                            "load": load_metrics}
                with sqlite3.connect(database) as conn:
                    count = conn.execute("select count(*) from hits").fetchone()[0]
                expected_rows = 2 + sum(x[0] == "/db" for x in samples)
                if count != expected_rows:
                    return {"outcome": "failure", "reason": "sqlite_persistence",
                            "count": count, "expected": expected_rows}
                return {"outcome": "pass", "result": {
                    "workload": "service", "ok": True, "tls_rejected_untrusted": True,
                    "forwarded_headers_overwritten": True,
                    "uploaded_bytes": len(upload), "sqlite_rows": count,
                    "fast_latencies_ms": [round(x[2] * 1000, 2)
                                          for x in fast_results],
                    "slow_latency_ms": round(slow_result[2] * 1000, 2),
                    "caddy_version": version, "load": load_metrics,
                    "plain_baseline_ms": round(plain_baseline_ms, 2),
                    "proxy_baseline_ms": round(proxy_baseline_ms, 2),
                    "proxy_overhead_ms": round(proxy_baseline_ms -
                                               plain_baseline_ms, 2),
                    "max_heartbeat_gap_ms": heartbeat_gap,
                    "max_heartbeat_at_ms": stopped.get("max_heartbeat_at_ms"),
                    "heartbeat_cause": heartbeat_cause,
                    "heap_slope": heap_slope,
                    "max_db_ms": stopped.get("max_db_ms"),
                    "max_db_at_ms": stopped.get("max_db_at_ms"),
                    "tick_count": tick_count, "cleanup": cleanup,
                    "shutdown": shutdown}}
            except (OSError, urllib.error.URLError, TimeoutError, ValueError,
                    sqlite3.Error) as exc:
                return {"outcome": "failure", "reason": "service_exception",
                        "error": str(exc),
                        "gene_log": gene_log.read_text(errors="replace")[-8192:],
                        "proxy_log": proxy_log.read_text(errors="replace")[-8192:]}
            finally:
                if proxy_proc is not None and proxy_proc.poll() is None:
                    proxy_proc.terminate()
                    try: proxy_proc.wait(timeout=5)
                    except subprocess.TimeoutExpired: proxy_proc.kill()
                if gene_proc.poll() is None:
                    gene_proc.terminate()
                    try: gene_proc.wait(timeout=5)
                    except subprocess.TimeoutExpired: gene_proc.kill()


def run_install(gene: Path, workload: dict) -> dict:
    build_env = dict(os.environ)
    sdk_pin = ""
    if platform.system() == "Darwin" and platform.machine() == "arm64":
        toolchains = json.loads(
            (PROFILE_DIR / "cli-toolchain.lock.json").read_text())
        sdk_pin = toolchains["macosx-arm64"]["sdk_root"]
        if not Path(sdk_pin).is_dir():
            return {"outcome": "blocked", "reason": "pinned_sdk_missing",
                    "sdk_root": sdk_pin}
        build_env["SDKROOT"] = sdk_pin
    with tempfile.TemporaryDirectory(prefix="native-app-install-",
                                     dir=ROOT / "tmp") as work:
        base = Path(work)
        source = base / "source"
        source.mkdir()
        fixture = PROFILE_DIR
        for name in ("cli", "support"):
            shutil.copytree(fixture / name, source / name,
                            ignore=shutil.ignore_patterns(".gene"))
        package = source / "cli"
        prefix = base / "prefix"

        def invoke(args: list[str]) -> subprocess.CompletedProcess[str]:
            return subprocess.run([str(gene), *args], cwd=ROOT,
                                  env=build_env,
                                  capture_output=True, text=True, timeout=60,
                                  check=False)

        def launch(expected: str) -> bool:
            cache = base / "empty-packages"
            artifacts = base / "empty-artifacts"
            shutil.rmtree(cache, ignore_errors=True)
            shutil.rmtree(artifacts, ignore_errors=True)
            env = dict(os.environ, GENE_USER_PACKAGES=str(cache),
                       GENE_ARTIFACT_STORE=str(artifacts),
                       GENE_C_COMPILER=str(base / "missing-compiler"))
            result = subprocess.run([str(prefix / "bin" / "cli")], cwd="/tmp",
                                    env=env, capture_output=True, text=True,
                                    timeout=30, check=False)
            if result.returncode:
                return False
            try:
                payload = json.loads(result.stdout)
            except json.JSONDecodeError:
                return False
            return payload.get("workload") == "cli" and payload.get("ok") is True and (
                payload.get("label") == expected and
                payload.get("native_result") == 42
            )

        if not (package / "package.gene.lock").is_file():
            return {"outcome": "failure", "reason": "missing_committed_lock"}
        command = ["install", "cli", "--prefix", str(prefix),
                   "--package-root", str(package)]
        first = invoke(command)
        if first.returncode:
            return {"outcome": "failure", "reason": "first_install",
                    "stderr": first.stderr[-8192:]}
        current = prefix / "apps" / "gene_native_app_cli-cli" / "current"
        old = current.readlink()
        absent = base / "source.hidden"
        source.rename(absent)
        try:
            independent = launch("report: Native app profile")
        finally:
            absent.rename(source)
        if not independent:
            return {"outcome": "failure", "reason": "source_or_cache_dependency"}
        (package / "data" / "schema.json").write_text('{"title":"Updated"}\n')
        resolved = invoke(["pkg", "resolve", "--package-root", str(package)])
        second = invoke(command) if resolved.returncode == 0 else resolved
        unchanged = current.readlink() == old
        old_exists = (prefix / "apps" / "gene_native_app_cli-cli" / old).is_dir()
        updated_launch = launch("report: Updated")
        if second.returncode or unchanged or not old_exists or not updated_launch:
            return {"outcome": "failure", "reason": "update",
                    "exit_code": second.returncode,
                    "stdout": second.stdout[-8192:], "stderr": second.stderr[-8192:],
                    "unchanged": unchanged, "old_exists": old_exists,
                    "updated_launch": updated_launch}
        updated = current.readlink()
        manifest = package / "package.gene"
        manifest.write_text(manifest.read_text().replace(
            "data/schema.json", "data/missing.json"))
        resolved = invoke(["pkg", "resolve", "--package-root", str(package)])
        failed = invoke(command) if resolved.returncode == 0 else resolved
        if failed.returncode == 0 or current.readlink() != updated or not (
            launch("report: Updated")
        ):
            return {"outcome": "failure", "reason": "failed_update_changed_current",
                    "stderr": failed.stderr[-8192:]}
        return {"outcome": "pass", "result": {"workload": "cli", "ok": True,
                "independent": True, "generation_changed": True,
                "failed_update_kept_current": True,
                "toolchain_sdk_root": sdk_pin}}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gene", type=Path, default=ROOT / "bin" / "gene")
    parser.add_argument("--workload", action="append", help="workload ID to audit")
    parser.add_argument("--probe-blocked", action="store_true")
    parser.add_argument("--require-supported", action="store_true")
    parser.add_argument("--report", type=Path)
    parser.add_argument(
        "--service-duration", type=int, metavar="SECONDS",
        help="soak: run the service load for SECONDS instead of the profile's "
             "duration_seconds (the report records the override)")
    args = parser.parse_args()
    gene = args.gene.resolve()
    # Workload scratch lives under the ignored tmp/, which a fresh checkout lacks.
    (ROOT / "tmp").mkdir(exist_ok=True)
    if not gene.is_file():
        parser.error(f"Gene executable is missing: {gene}")
    profile = load_profile(gene)
    if args.service_duration is not None:
        # A soak keeps the profile's rate and gates; only the load window, the
        # workload deadline, and the request cap grow with it.
        if not 1 <= args.service_duration <= 86_400:
            parser.error("--service-duration must be 1..86400 seconds")
        for workload in profile["workloads"]:
            if workload["driver"] != "service":
                continue
            budget = workload["budget"]
            extra = args.service_duration - budget["duration_seconds"]
            budget["duration_seconds"] = args.service_duration
            workload["timeout_ms"] += max(0, extra) * 1000
            workload["request_cap"] = (budget["requests_per_second"] *
                                       args.service_duration)
    selected = set(args.workload or [w["id"] for w in profile["workloads"]])
    known = {w["id"] for w in profile["workloads"]}
    if selected - known:
        parser.error(f"unknown workload(s): {', '.join(sorted(selected - known))}")
    # None when the tree is not a git checkout (e.g. a `git archive` copy);
    # tools/linux-x86_64/run.sh records the revision beside the report.
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True,
        text=True, check=False,
    )
    revision = head.stdout.strip() if head.returncode == 0 else None
    status = subprocess.run(
        ["git", "status", "--porcelain"], cwd=ROOT, capture_output=True,
        text=True, check=False,
    )
    dirty = bool(status.stdout) if status.returncode == 0 else None
    report = {
        "profile": profile["name"], "profile_format": profile["profile_format"],
        "started_at": stamp(), "revision": revision,
        "worktree_dirty": dirty,
        "platform": {"system": platform.system(), "machine": platform.machine()},
        "gene": str(gene), "gene_sha256": hashlib.sha256(gene.read_bytes()).hexdigest(),
        "stages": profile["stages"], "workloads": [],
        "service_duration_override": args.service_duration,
    }
    for workload in profile["workloads"]:
        if workload["id"] not in selected:
            continue
        missing = [stage for stage in workload["required_stages"]
                   if profile["stages"][stage] != "implemented"]
        record = {"id": workload["id"], "required_stages": workload["required_stages"],
                  "missing_stages": missing, "dataset_seed": workload["dataset_seed"],
                  "dataset_sizes": workload["dataset_sizes"],
                  "budget": workload["budget"], "started_at": stamp()}
        if missing and not args.probe_blocked:
            record.update(outcome="blocked", reason="required_stage_incomplete")
        elif workload["driver"] == "command" and workload["id"] == "script":
            executed = run_script(gene, workload)
            if missing:
                executed["outcome"] = "probe_" + executed["outcome"]
            record.update(executed)
        elif workload["driver"] == "install":
            executed = run_install(gene, workload)
            if missing:
                executed["outcome"] = "probe_" + executed["outcome"]
            record.update(executed)
        elif workload["driver"] == "data":
            executed = run_data(gene, workload)
            if missing:
                executed["outcome"] = "probe_" + executed["outcome"]
            record.update(executed)
        elif workload["driver"] == "service":
            executed = run_service(gene, workload)
            if missing and executed["outcome"] in {"pass", "failure"}:
                executed["outcome"] = "probe_" + executed["outcome"]
            record.update(executed)
        elif workload["id"] == "lifetime":
            executed = run_lifetime(workload)
            if missing and executed["outcome"] in {"pass", "failure"}:
                executed["outcome"] = "probe_" + executed["outcome"]
            record.update(executed)
        elif workload["driver"] != "command":
            record.update(outcome="blocked", reason="fixture_driver_pending")
        else:
            executed = run_command(gene, workload)
            if missing:
                executed["outcome"] = "probe_" + executed["outcome"]
            record.update(executed)
        record["finished_at"] = stamp()
        report["workloads"].append(record)
        print(f"{record['id']}: {record['outcome']}")
    report["finished_at"] = stamp()
    destination = args.report or (
        ROOT / "tmp" / "native-app-profile" /
        f"audit-{datetime.now(timezone.utc):%Y%m%dT%H%M%S}-{os.getpid()}.json"
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"report: {destination}")
    if args.require_supported and any(
        row["outcome"] != "pass" for row in report["workloads"]
    ):
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"native-app audit: {exc}", file=sys.stderr)
        sys.exit(2)
