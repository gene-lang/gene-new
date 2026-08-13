#!/usr/bin/env python3
"""Run and analyze the independently reviewed experiment-1 freeze.

This is the treatment-bearing companion to ``prepare_library_induction_freeze``.
It first verifies the freeze against current source, evaluates each frozen setup
exactly once, captures wall time and peak RSS, hashes every raw result, and
applies the preregistered paired eight-seed analysis.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import platform
import re
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

import prepare_library_induction_freeze as freeze


ROOT = Path(__file__).resolve().parents[1]
TIME = Path("/usr/bin/time")
T_CRITICAL_DF_7 = 2.364624251
EXPECTED_SUMMARY_KEYS = {
    "schema",
    "experiment",
    "target_seed",
    "accepted_donor_seed",
    "heldout_tasks",
    "base_solved",
    "induced_solved",
    "unrelated_solved",
    "induced_candidate_executions",
    "unrelated_candidate_executions",
    "induced_verifier_rejections",
    "unrelated_verifier_rejections",
    "induced_abstraction_usage",
}


def timed_prefix() -> list[str]:
    if not TIME.is_file():
        raise freeze.FreezeError("/usr/bin/time is required for peak-RSS capture")
    if platform.system() == "Darwin":
        return [str(TIME), "-l"]
    return [str(TIME), "-v"]


def parse_peak_rss(stderr: str) -> int:
    if platform.system() == "Darwin":
        matched = re.search(
            r"^\s*([0-9]+)\s+maximum resident set size\s*$",
            stderr,
            re.MULTILINE,
        )
        multiplier = 1
    else:
        matched = re.search(
            r"^\s*Maximum resident set size \(kbytes\):\s*([0-9]+)\s*$",
            stderr,
            re.MULTILINE,
        )
        multiplier = 1024
    if not matched:
        raise freeze.FreezeError("cannot parse peak RSS from /usr/bin/time")
    return int(matched.group(1)) * multiplier


def run_timed(argv: list[str], *, timeout: float) -> dict[str, Any]:
    started = time.monotonic()
    process = subprocess.Popen(
        timed_prefix() + argv,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise freeze.FreezeError(
            f"evaluation exceeded its {timeout:.0f}-second process timeout"
        ) from exc
    wall_seconds = time.monotonic() - started
    if process.returncode != 0:
        detail = (stderr or stdout).strip()
        raise freeze.FreezeError(
            f"evaluation failed ({process.returncode}): {detail}"
        )
    return {
        "stdout": stdout,
        "stderr": stderr,
        "wall_seconds": wall_seconds,
        "peak_rss_bytes": parse_peak_rss(stderr),
    }


def parse_summary(stdout: str, expected: dict[str, Any]) -> dict[str, Any]:
    lines = stdout.splitlines()
    if len(lines) != 2 or not lines[0].startswith(
        "(serde_v1 (library_induction_frozen_result "
    ):
        raise freeze.FreezeError("evaluator output is not one canonical result plus JSON")
    try:
        summary = json.loads(lines[1])
    except json.JSONDecodeError as exc:
        raise freeze.FreezeError("evaluator summary line is not JSON") from exc
    if not isinstance(summary, dict) or set(summary) != EXPECTED_SUMMARY_KEYS:
        raise freeze.FreezeError("evaluator summary has unexpected fields")
    if summary["schema"] != 1 or summary["experiment"] != freeze.EXPERIMENT:
        raise freeze.FreezeError("evaluator summary schema or experiment mismatch")
    if summary["target_seed"] != expected["target_seed"]:
        raise freeze.FreezeError("evaluator summary target seed mismatch")
    if summary["accepted_donor_seed"] != expected["accepted_donor_seed"]:
        raise freeze.FreezeError("evaluator summary donor seed mismatch")
    if summary["heldout_tasks"] != expected["heldout_count"]:
        raise freeze.FreezeError("evaluator summary held-out count mismatch")
    for field in ("base_solved", "induced_solved", "unrelated_solved"):
        value = summary[field]
        if not isinstance(value, int) or not 0 <= value <= summary["heldout_tasks"]:
            raise freeze.FreezeError(f"evaluator summary has invalid {field}")
    usage = summary["induced_abstraction_usage"]
    if not isinstance(usage, list) or len(usage) != 4:
        raise freeze.FreezeError("evaluator must report all four induced abstractions")
    names = set()
    for item in usage:
        if not isinstance(item, dict) or set(item) != {"name", "solutions"}:
            raise freeze.FreezeError("abstraction usage entry is malformed")
        if not isinstance(item["name"], str) or item["name"] in names:
            raise freeze.FreezeError("abstraction usage names must be unique strings")
        names.add(item["name"])
        if not isinstance(item["solutions"], int) or not (
            0 <= item["solutions"] <= summary["heldout_tasks"]
        ):
            raise freeze.FreezeError("abstraction usage count is invalid")
    return summary


def analyze_summaries(summaries: list[dict[str, Any]]) -> dict[str, Any]:
    if len(summaries) != freeze.CORPUS_COUNT:
        raise freeze.FreezeError(
            f"analysis requires exactly {freeze.CORPUS_COUNT} corpus summaries"
        )
    differences = [
        (item["induced_solved"] - item["unrelated_solved"])
        / item["heldout_tasks"]
        for item in summaries
    ]
    mean = sum(differences) / len(differences)
    sample_variance = sum((item - mean) ** 2 for item in differences) / (
        len(differences) - 1
    )
    standard_error = math.sqrt(sample_variance / len(differences))
    margin = T_CRITICAL_DF_7 * standard_error
    lower = mean - margin
    upper = mean + margin
    reused_per_corpus = [
        sum(1 for usage in item["induced_abstraction_usage"] if usage["solutions"] >= 5)
        for item in summaries
    ]
    advantage_gate = mean >= 0.15
    interval_gate = lower > 0.0
    reuse_gate = min(reused_per_corpus) >= 3
    return {
        "schema": 1,
        "experiment": freeze.EXPERIMENT,
        "method": {
            "uncertainty_unit": "target_corpus_seed",
            "paired_metric": "induced_solve_rate_minus_unrelated_solve_rate",
            "interval": "two_sided_student_t_95_df_7",
            "t_critical": T_CRITICAL_DF_7,
            "seed_count": len(summaries),
        },
        "seed_differences": differences,
        "mean_advantage": mean,
        "sample_standard_deviation": math.sqrt(sample_variance),
        "standard_error": standard_error,
        "confidence_interval_95": {"lower": lower, "upper": upper},
        "reused_abstractions_per_corpus": reused_per_corpus,
        "minimum_reused_abstractions": min(reused_per_corpus),
        "gates": {
            "mean_advantage_at_least_0_15": advantage_gate,
            "confidence_interval_excludes_zero": interval_gate,
            "every_corpus_has_three_abstractions_used_in_five_solutions": reuse_gate,
        },
        "passed": advantage_gate and interval_gate and reuse_gate,
        "secondary_totals": {
            "base_solved": sum(item["base_solved"] for item in summaries),
            "induced_solved": sum(item["induced_solved"] for item in summaries),
            "unrelated_solved": sum(item["unrelated_solved"] for item in summaries),
            "induced_candidate_executions": sum(
                item["induced_candidate_executions"] for item in summaries
            ),
            "unrelated_candidate_executions": sum(
                item["unrelated_candidate_executions"] for item in summaries
            ),
            "induced_verifier_rejections": sum(
                item["induced_verifier_rejections"] for item in summaries
            ),
            "unrelated_verifier_rejections": sum(
                item["unrelated_verifier_rejections"] for item in summaries
            ),
        },
    }


def write_evaluation_directory(
    destination: Path, freeze_directory: Path, manifest: dict[str, Any]
) -> dict[str, Any]:
    if destination.exists():
        raise freeze.FreezeError(
            f"refusing to overwrite evaluation directory: {destination}"
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="library-induction-evaluation-", dir=destination.parent
    ) as temporary_name:
        temporary = Path(temporary_name)
        records = []
        summaries = []
        for setup in manifest["setups"]:
            setup_path = freeze_directory / setup["path"]
            outcome = run_timed(
                [
                    str(freeze.GENE),
                    "run",
                    "--allow_read_dir",
                    str(freeze_directory),
                    str(freeze.FROZEN_EVALUATOR),
                    str(setup_path),
                ],
                timeout=90.0,
            )
            if outcome["wall_seconds"] > 75.0:
                raise freeze.FreezeError("evaluation exceeded the 75-second ceiling")
            if outcome["peak_rss_bytes"] > 67_108_864:
                raise freeze.FreezeError("evaluation exceeded the 64-MiB RSS ceiling")
            summary = parse_summary(outcome["stdout"], setup)
            summaries.append(summary)
            result_name = f"result-{setup['index']:02d}.txt"
            result_bytes = outcome["stdout"].encode("utf-8")
            (temporary / result_name).write_bytes(result_bytes)
            records.append(
                {
                    "index": setup["index"],
                    "target_seed": setup["target_seed"],
                    "accepted_donor_seed": setup["accepted_donor_seed"],
                    "path": result_name,
                    "bytes": len(result_bytes),
                    "sha256": freeze.sha256_bytes(result_bytes),
                    "wall_seconds": outcome["wall_seconds"],
                    "peak_rss_bytes": outcome["peak_rss_bytes"],
                    "summary": summary,
                }
            )
        analysis = analyze_summaries(summaries)
        analysis_bytes = json.dumps(
            analysis, ensure_ascii=False, indent=2, sort_keys=True
        ).encode("utf-8") + b"\n"
        (temporary / "analysis.json").write_bytes(analysis_bytes)
        result_manifest: dict[str, Any] = {
            "schema": 1,
            "experiment": freeze.EXPERIMENT,
            "completed_at_utc": dt.datetime.now(dt.timezone.utc)
            .isoformat(timespec="seconds")
            .replace("+00:00", "Z"),
            "source_freeze_manifest_digest": manifest["manifest_digest"],
            "source_candidate_digest": manifest["review_packet"]["candidate_digest"],
            "results": records,
            "analysis_path": "analysis.json",
            "analysis_sha256": freeze.sha256_bytes(analysis_bytes),
        }
        result_manifest["result_manifest_digest"] = freeze.sha256_bytes(
            freeze.canonical_json(result_manifest)
        )
        (temporary / "result_manifest.json").write_text(
            json.dumps(
                result_manifest, ensure_ascii=False, indent=2, sort_keys=True
            )
            + "\n",
            encoding="utf-8",
        )
        Path(temporary_name).rename(destination)
    return result_manifest


def run_command(args: argparse.Namespace) -> None:
    freeze.require_clean_worktree()
    freeze_directory = Path(args.freeze_dir)
    manifest = freeze.verify_freeze_directory(
        freeze_directory,
        schedule=freeze.seed_schedule(),
        require_current=True,
    )
    destination = Path(args.output_dir)
    freeze.require_outside_worktree(destination, "evaluation directory")
    result_manifest = write_evaluation_directory(
        destination, freeze_directory, manifest
    )
    verify_results_directory(destination, freeze_directory, manifest)
    analysis = json.loads((destination / "analysis.json").read_text(encoding="utf-8"))
    print(f"evaluation directory: {destination}")
    print(f"result manifest: {result_manifest['result_manifest_digest']}")
    print(f"corpora evaluated: {len(result_manifest['results'])}")
    print(
        "mean advantage: "
        f"{analysis['mean_advantage']:.6f} "
        f"95% CI [{analysis['confidence_interval_95']['lower']:.6f}, "
        f"{analysis['confidence_interval_95']['upper']:.6f}]"
    )
    print(f"passed: {str(analysis['passed']).lower()}")


def verify_results_directory(
    directory: Path,
    freeze_directory: Path,
    source_manifest: dict[str, Any],
) -> dict[str, Any]:
    result_manifest = freeze.load_json_object(
        directory / "result_manifest.json", "result manifest"
    )
    claimed_digest = result_manifest.get("result_manifest_digest")
    body = dict(result_manifest)
    body.pop("result_manifest_digest", None)
    if claimed_digest != freeze.sha256_bytes(freeze.canonical_json(body)):
        raise freeze.FreezeError("result manifest digest mismatch")
    if (
        result_manifest.get("schema") != 1
        or result_manifest.get("experiment") != freeze.EXPERIMENT
    ):
        raise freeze.FreezeError("result manifest schema or experiment mismatch")
    if result_manifest.get("source_freeze_manifest_digest") != source_manifest.get(
        "manifest_digest"
    ):
        raise freeze.FreezeError("result manifest names the wrong freeze")
    if result_manifest.get("source_candidate_digest") != source_manifest[
        "review_packet"
    ]["candidate_digest"]:
        raise freeze.FreezeError("result manifest names the wrong candidate")
    records = result_manifest.get("results")
    if not isinstance(records, list) or len(records) != freeze.CORPUS_COUNT:
        raise freeze.FreezeError("result manifest must contain eight results")
    expected_keys = {
        "index",
        "target_seed",
        "accepted_donor_seed",
        "path",
        "bytes",
        "sha256",
        "wall_seconds",
        "peak_rss_bytes",
        "summary",
    }
    summaries = []
    for record, setup in zip(records, source_manifest["setups"]):
        if not isinstance(record, dict) or set(record) != expected_keys:
            raise freeze.FreezeError("result manifest entry has unexpected fields")
        for key in ("index", "target_seed", "accepted_donor_seed"):
            if record.get(key) != setup[key]:
                raise freeze.FreezeError(f"result layout mismatch for {key}")
        expected_path = f"result-{setup['index']:02d}.txt"
        if record.get("path") != expected_path:
            raise freeze.FreezeError("result path does not match its setup index")
        path = directory / expected_path
        if not path.is_file():
            raise freeze.FreezeError(f"missing raw result: {path}")
        payload = path.read_bytes()
        if len(payload) != record.get("bytes"):
            raise freeze.FreezeError(f"raw result size mismatch: {path}")
        if freeze.sha256_bytes(payload) != record.get("sha256"):
            raise freeze.FreezeError(f"raw result digest mismatch: {path}")
        wall_seconds = record.get("wall_seconds")
        peak_rss_bytes = record.get("peak_rss_bytes")
        if not isinstance(wall_seconds, (int, float)) or not (
            0.0 < wall_seconds <= 75.0
        ):
            raise freeze.FreezeError(f"invalid evaluation wall time: {path}")
        if not isinstance(peak_rss_bytes, int) or not (
            0 < peak_rss_bytes <= 67_108_864
        ):
            raise freeze.FreezeError(f"invalid evaluation peak RSS: {path}")
        summary = parse_summary(payload.decode("utf-8"), setup)
        if summary != record.get("summary"):
            raise freeze.FreezeError(f"embedded and raw summaries differ: {path}")
        summaries.append(summary)
    if result_manifest.get("analysis_path") != "analysis.json":
        raise freeze.FreezeError("result manifest has an invalid analysis path")
    analysis_path = directory / "analysis.json"
    if not analysis_path.is_file():
        raise freeze.FreezeError("result directory lacks analysis.json")
    analysis_bytes = analysis_path.read_bytes()
    if freeze.sha256_bytes(analysis_bytes) != result_manifest.get(
        "analysis_sha256"
    ):
        raise freeze.FreezeError("analysis digest mismatch")
    analysis = freeze.load_json_object(analysis_path, "analysis")
    if analysis != analyze_summaries(summaries):
        raise freeze.FreezeError("analysis does not match the raw result summaries")
    return result_manifest


def verify_command(args: argparse.Namespace) -> None:
    freeze_directory = Path(args.freeze_dir)
    source_manifest = freeze.verify_freeze_directory(
        freeze_directory,
        schedule=freeze.seed_schedule(),
        require_current=True,
    )
    result_manifest = verify_results_directory(
        Path(args.result_dir), freeze_directory, source_manifest
    )
    print(f"verified result manifest: {result_manifest['result_manifest_digest']}")
    print(f"verified results: {len(result_manifest['results'])}")


def self_test_command(_: argparse.Namespace) -> None:
    passing = []
    for index, difference in enumerate([0.20, 0.22, 0.18, 0.24, 0.16, 0.20, 0.22, 0.18]):
        unrelated = 10
        induced = unrelated + round(difference * 50)
        passing.append(
            {
                "heldout_tasks": 50,
                "base_solved": 0,
                "induced_solved": induced,
                "unrelated_solved": unrelated,
                "induced_candidate_executions": 100,
                "unrelated_candidate_executions": 100,
                "induced_verifier_rejections": index,
                "unrelated_verifier_rejections": index,
                "induced_abstraction_usage": [
                    {"name": "induced_0", "solutions": 5},
                    {"name": "induced_1", "solutions": 6},
                    {"name": "induced_2", "solutions": 7},
                    {"name": "induced_3", "solutions": 1},
                ],
            }
        )
    analysis = analyze_summaries(passing)
    if not analysis["passed"]:
        raise freeze.FreezeError("synthetic passing analysis was rejected")
    failing = [dict(item) for item in passing]
    failing[0] = dict(failing[0])
    failing[0]["induced_abstraction_usage"] = [
        {"name": f"induced_{index}", "solutions": 1} for index in range(4)
    ]
    if analyze_summaries(failing)["passed"]:
        raise freeze.FreezeError("synthetic reuse failure was accepted")
    print("analysis self-test: pass and reuse-failure paths verified")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subcommands = root.add_subparsers(dest="command", required=True)
    run = subcommands.add_parser(
        "run", help="execute all treatment arms from one verified freeze"
    )
    run.add_argument("--freeze-dir", required=True)
    run.add_argument("--output-dir", required=True)
    run.set_defaults(handler=run_command)
    verify = subcommands.add_parser(
        "verify", help="verify raw results and recompute the frozen analysis"
    )
    verify.add_argument("--freeze-dir", required=True)
    verify.add_argument("--result-dir", required=True)
    verify.set_defaults(handler=verify_command)
    self_test = subcommands.add_parser(
        "self-test", help="exercise the preregistered analysis with synthetic data"
    )
    self_test.set_defaults(handler=self_test_command)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        args.handler(args)
    except (freeze.FreezeError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"evaluation error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
