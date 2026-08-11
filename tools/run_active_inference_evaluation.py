#!/usr/bin/env python3
"""Run and verify the independently reviewed active-inference experiment.

The treatment runner verifies one frozen candidate, evaluates every frozen
batch exactly once through the capability-limited Gene consumer, preserves raw
canonical results, and applies the preregistered paired analysis. ``verify``
authenticates every artifact and recomputes the analysis from raw summaries.
"""

from __future__ import annotations

import argparse
import copy
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

import prepare_active_inference_freeze as freeze


ROOT = Path(__file__).resolve().parents[1]
TIME = Path("/usr/bin/time")
T_CRITICAL_DF_9 = 2.262
BETA_SPECS = (
    ("beta_0_10", 0.10),
    ("beta_0_25", 0.25),
    ("beta_0_50", 0.50),
)
BETA_SCENARIOS = tuple(item[0] for item in BETA_SPECS)
PREFERENCE_SPECS = (
    ("correct_repair_utility_minus_10_percent", "correct_repair_utility", 0.90),
    ("correct_repair_utility_plus_10_percent", "correct_repair_utility", 1.10),
    (
        "incorrect_repair_utility_minus_10_percent",
        "incorrect_repair_utility",
        0.90,
    ),
    (
        "incorrect_repair_utility_plus_10_percent",
        "incorrect_repair_utility",
        1.10,
    ),
    ("defer_utility_minus_10_percent", "defer_utility", 0.90),
    ("defer_utility_plus_10_percent", "defer_utility", 1.10),
    ("inspection_cost_minus_10_percent", "inspection_cost", 0.90),
    ("inspection_cost_plus_10_percent", "inspection_cost", 1.10),
)
PREFERENCE_SCENARIOS = tuple(item[0] for item in PREFERENCE_SPECS)
EXPECTED_SUMMARY_KEYS = {
    "schema",
    "experiment",
    "prior",
    "episode_seed",
    "random_seed",
    "episode_count",
    "final_episode_state",
    "final_random_state",
    "primary",
    "beta_sensitivities",
    "preference_sensitivities",
}
METRIC_KEYS = {"incorrect", "completed", "inspections", "utility"}
PRIMARY_KEYS = {"greedy", "reward", "random", "active", "planner_elapsed_ms"}
SENSITIVITY_PAIR_KEYS = {"reward", "active", "planner_elapsed_ms"}
EXPECTED_RESULT_MANIFEST_KEYS = {
    "schema",
    "experiment",
    "completed_at_utc",
    "source_freeze_manifest_digest",
    "source_candidate_digest",
    "total_wall_seconds",
    "maximum_peak_rss_bytes",
    "scenario_evaluations",
    "results",
    "analysis_path",
    "analysis_sha256",
    "result_manifest_digest",
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
        "wall_seconds": wall_seconds,
        "peak_rss_bytes": parse_peak_rss(stderr),
    }


def validate_metrics(value: Any, episode_count: int, label: str) -> None:
    if not isinstance(value, dict) or set(value) != METRIC_KEYS:
        raise freeze.FreezeError(f"{label} metrics have unexpected fields")
    for field in ("incorrect", "completed", "inspections"):
        metric = value[field]
        if type(metric) is not int:
            raise freeze.FreezeError(f"{label} {field} must be an integer")
    if not 0 <= value["incorrect"] <= value["completed"] <= episode_count:
        raise freeze.FreezeError(f"{label} repair counts are invalid")
    if not 0 <= value["inspections"] <= 2 * episode_count:
        raise freeze.FreezeError(f"{label} inspection count is invalid")
    utility = value["utility"]
    if not isinstance(utility, (int, float)) or not math.isfinite(utility):
        raise freeze.FreezeError(f"{label} utility must be finite")


def validate_sensitivity_pair(value: Any, episode_count: int, label: str) -> None:
    if not isinstance(value, dict) or set(value) != SENSITIVITY_PAIR_KEYS:
        raise freeze.FreezeError(
            f"{label} must contain reward, active, and planner timing"
        )
    validate_metrics(value["reward"], episode_count, f"{label} reward")
    validate_metrics(value["active"], episode_count, f"{label} active")
    if type(value["planner_elapsed_ms"]) is not int or value[
        "planner_elapsed_ms"
    ] < 0:
        raise freeze.FreezeError(f"{label} planner time is invalid")


def validate_primary(value: Any, episode_count: int) -> None:
    if not isinstance(value, dict) or set(value) != PRIMARY_KEYS:
        raise freeze.FreezeError("primary summary has unexpected fields")
    for arm in ("greedy", "reward", "random", "active"):
        validate_metrics(value[arm], episode_count, f"primary {arm}")
    if type(value["planner_elapsed_ms"]) is not int or value[
        "planner_elapsed_ms"
    ] < 0:
        raise freeze.FreezeError("primary planner time is invalid")


def parse_summary(stdout: str, expected: dict[str, Any]) -> dict[str, Any]:
    lines = stdout.splitlines()
    if len(lines) != 2 or not lines[0].startswith(
        "(serde_v1 (active_inference_frozen_result "
    ):
        raise freeze.FreezeError(
            "evaluator output is not one canonical result plus JSON"
        )
    try:
        summary = json.loads(lines[1])
    except json.JSONDecodeError as exc:
        raise freeze.FreezeError("evaluator summary line is not JSON") from exc
    if not isinstance(summary, dict) or set(summary) != EXPECTED_SUMMARY_KEYS:
        raise freeze.FreezeError("evaluator summary has unexpected fields")
    if summary["schema"] != 1 or summary["experiment"] != freeze.EXPERIMENT:
        raise freeze.FreezeError("evaluator summary schema or experiment mismatch")
    for field in ("prior", "episode_seed", "random_seed", "episode_count"):
        if summary[field] != expected[field]:
            raise freeze.FreezeError(f"evaluator summary {field} mismatch")
    for field in ("final_episode_state", "final_random_state"):
        if type(summary[field]) is not int or not 0 < summary[field] < 2_147_483_647:
            raise freeze.FreezeError(f"evaluator summary has invalid {field}")

    episode_count = summary["episode_count"]
    validate_primary(summary["primary"], episode_count)
    beta = summary["beta_sensitivities"]
    preferences = summary["preference_sensitivities"]
    if not isinstance(beta, list) or not isinstance(preferences, list):
        raise freeze.FreezeError("sensitivity summaries must be lists")
    if summary["prior"] == "shifted":
        if beta or preferences:
            raise freeze.FreezeError("shifted batches must contain only primary arms")
    else:
        if len(beta) != len(BETA_SPECS):
            raise freeze.FreezeError("base batches must contain all beta settings")
        for item, (name, expected_beta) in zip(beta, BETA_SPECS):
            if not isinstance(item, dict) or set(item) != {
                "name",
                "beta",
                "reward",
                "active",
                "planner_elapsed_ms",
            }:
                raise freeze.FreezeError("beta sensitivity entry is malformed")
            if item["name"] != name or item["beta"] != expected_beta:
                raise freeze.FreezeError("beta sensitivity metadata mismatch")
            validate_sensitivity_pair(
                {
                    "reward": item["reward"],
                    "active": item["active"],
                    "planner_elapsed_ms": item["planner_elapsed_ms"],
                },
                episode_count,
                name,
            )
        if {
            "reward": beta[1]["reward"],
            "active": beta[1]["active"],
            "planner_elapsed_ms": beta[1]["planner_elapsed_ms"],
        } != {
            "reward": summary["primary"]["reward"],
            "active": summary["primary"]["active"],
            "planner_elapsed_ms": summary["primary"]["planner_elapsed_ms"],
        }:
            raise freeze.FreezeError("beta 0.25 must reuse the primary result")
        if len(preferences) != len(PREFERENCE_SPECS):
            raise freeze.FreezeError(
                "base batches must contain all preference perturbations"
            )
        for item, (name, field, multiplier) in zip(preferences, PREFERENCE_SPECS):
            if not isinstance(item, dict) or set(item) != {
                "name",
                "field",
                "multiplier",
                "reward",
                "active",
                "planner_elapsed_ms",
            }:
                raise freeze.FreezeError("preference sensitivity entry is malformed")
            if (
                item["name"] != name
                or item["field"] != field
                or item["multiplier"] != multiplier
            ):
                raise freeze.FreezeError("preference sensitivity metadata mismatch")
            validate_sensitivity_pair(
                {
                    "reward": item["reward"],
                    "active": item["active"],
                    "planner_elapsed_ms": item["planner_elapsed_ms"],
                },
                episode_count,
                name,
            )
    summary["batch_index"] = expected["batch_index"]
    return summary


def paired_interval(values: list[float]) -> dict[str, float]:
    if len(values) != freeze.BATCH_COUNT:
        raise freeze.FreezeError(
            f"paired analysis requires exactly {freeze.BATCH_COUNT} batches"
        )
    mean = sum(values) / len(values)
    sample_variance = sum((value - mean) ** 2 for value in values) / (
        len(values) - 1
    )
    standard_deviation = math.sqrt(sample_variance)
    standard_error = standard_deviation / math.sqrt(len(values))
    margin = T_CRITICAL_DF_9 * standard_error
    return {
        "mean": mean,
        "sample_standard_deviation": standard_deviation,
        "standard_error": standard_error,
        "lower": mean - margin,
        "upper": mean + margin,
    }


def metric_difference(summary: dict[str, Any], field: str) -> float:
    primary = summary["primary"]
    episode_count = summary["episode_count"]
    if field == "incorrect":
        return (
            primary["reward"]["incorrect"] - primary["active"]["incorrect"]
        ) / episode_count
    if field == "completed":
        return (
            primary["active"]["completed"] - primary["reward"]["completed"]
        ) / episode_count
    raise freeze.FreezeError(f"unsupported paired metric: {field}")


def scenario_directions(
    summaries: list[dict[str, Any]], field: str, expected: tuple[str, ...]
) -> dict[str, float]:
    total_episodes = sum(item["episode_count"] for item in summaries)
    directions: dict[str, float] = {}
    for name in expected:
        total = 0
        for summary in summaries:
            matches = [item for item in summary[field] if item["name"] == name]
            if len(matches) != 1:
                raise freeze.FreezeError(
                    f"each batch must contain one {field} entry named {name}"
                )
            scenario = matches[0]
            total += (
                scenario["reward"]["incorrect"]
                - scenario["active"]["incorrect"]
            )
        directions[name] = total / total_episodes
    return directions


def analyze_summaries(summaries: list[dict[str, Any]]) -> dict[str, Any]:
    base = [item for item in summaries if item["prior"] == "base"]
    shifted = [item for item in summaries if item["prior"] == "shifted"]
    if len(base) != freeze.BATCH_COUNT or len(shifted) != freeze.BATCH_COUNT:
        raise freeze.FreezeError("analysis requires ten base and ten shifted batches")
    expected_indices = list(range(freeze.BATCH_COUNT))
    if sorted(item["batch_index"] for item in base) != expected_indices or sorted(
        item["batch_index"] for item in shifted
    ) != expected_indices:
        raise freeze.FreezeError("batch indices must be complete within each prior")

    incorrect_differences = [metric_difference(item, "incorrect") for item in base]
    completion_differences = [metric_difference(item, "completed") for item in base]
    incorrect_interval = paired_interval(incorrect_differences)
    completion_interval = paired_interval(completion_differences)
    reward_incorrect = sum(item["primary"]["reward"]["incorrect"] for item in base)
    active_incorrect = sum(item["primary"]["active"]["incorrect"] for item in base)
    if reward_incorrect <= 0:
        raise freeze.FreezeError("relative reduction requires reward-only errors")
    relative_reduction = (reward_incorrect - active_incorrect) / reward_incorrect

    shifted_direction = sum(
        item["primary"]["reward"]["incorrect"]
        - item["primary"]["active"]["incorrect"]
        for item in shifted
    ) / sum(item["episode_count"] for item in shifted)
    beta_directions = scenario_directions(
        base, "beta_sensitivities", BETA_SCENARIOS
    )
    preference_directions = scenario_directions(
        base, "preference_sensitivities", PREFERENCE_SCENARIOS
    )
    robustness_gate = (
        shifted_direction > 0.0
        and all(value > 0.0 for value in beta_directions.values())
        and all(value > 0.0 for value in preference_directions.values())
    )
    gates = {
        "relative_incorrect_repair_reduction_at_least_0_30": (
            relative_reduction >= 0.30
        ),
        "incorrect_repair_improvement_ci_lower_above_zero": (
            incorrect_interval["lower"] > 0.0
        ),
        "completion_difference_ci_lower_at_least_minus_0_02": (
            completion_interval["lower"] >= -0.02
        ),
        "all_robustness_directions_positive": robustness_gate,
    }
    base_episode_total = sum(item["episode_count"] for item in base)
    arm_metrics = {}
    for arm in ("greedy", "reward", "random", "active"):
        arm_metrics[arm] = {
            "incorrect_repair_rate": sum(
                item["primary"][arm]["incorrect"] for item in base
            )
            / base_episode_total,
            "completion_rate": sum(
                item["primary"][arm]["completed"] for item in base
            )
            / base_episode_total,
            "mean_inspections": sum(
                item["primary"][arm]["inspections"] for item in base
            )
            / base_episode_total,
            "mean_normalized_utility": sum(
                item["primary"][arm]["utility"] for item in base
            )
            / base_episode_total,
        }
    planner_elapsed_total = sum(
        item["primary"]["planner_elapsed_ms"] for item in base
    )
    return {
        "schema": 1,
        "experiment": freeze.EXPERIMENT,
        "method": {
            "uncertainty_unit": "matched_batch_seed",
            "batch_count_per_prior": freeze.BATCH_COUNT,
            "episodes_per_batch": freeze.EPISODES_PER_BATCH,
            "interval": "two_sided_student_t_95_df_9",
            "t_critical": T_CRITICAL_DF_9,
        },
        "incorrect_repair_differences": incorrect_differences,
        "incorrect_repair_improvement": incorrect_interval,
        "completion_differences": completion_differences,
        "completion_difference": completion_interval,
        "pooled_relative_incorrect_repair_reduction": relative_reduction,
        "shifted_prior_incorrect_repair_improvement": shifted_direction,
        "beta_incorrect_repair_improvements": beta_directions,
        "preference_incorrect_repair_improvements": preference_directions,
        "primary_arm_metrics": arm_metrics,
        "primary_planner_timing": {
            "total_elapsed_ms": planner_elapsed_total,
            "mean_elapsed_ms_per_batch": planner_elapsed_total / len(base),
        },
        "gates": gates,
        "passed": all(gates.values()),
        "primary_totals": {
            "reward_incorrect": reward_incorrect,
            "active_incorrect": active_incorrect,
            "reward_completed": sum(
                item["primary"]["reward"]["completed"] for item in base
            ),
            "active_completed": sum(
                item["primary"]["active"]["completed"] for item in base
            ),
        },
    }


def scenario_count(prior: str) -> int:
    if prior == "base":
        return 1 + 2 + len(PREFERENCE_SPECS)
    return 1


def evaluate_records(
    destination: Path, freeze_directory: Path, manifest: dict[str, Any]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], float]:
    records = []
    summaries = []
    started = time.monotonic()
    ceilings = manifest["review_packet"]["resource_ceilings"]
    process_seconds = ceilings["evaluation_seconds_per_batch"]
    maximum_rss = ceilings["evaluation_max_rss_bytes_per_process"]
    for expected in manifest["episodes"]:
        outcome = run_timed(
            [
                str(freeze.GENE),
                "run",
                str(freeze.FROZEN_BATCH_EVALUATOR),
                "--grant",
                "episodes=$fs/ReadDir",
                "--",
                expected["prior"],
                str(freeze_directory / expected["path"]),
            ],
            timeout=float(process_seconds) + 5.0,
        )
        if outcome["wall_seconds"] > process_seconds:
            raise freeze.FreezeError("batch evaluation exceeded its time ceiling")
        if outcome["peak_rss_bytes"] > maximum_rss:
            raise freeze.FreezeError("batch evaluation exceeded its RSS ceiling")
        summary = parse_summary(outcome["stdout"], expected)
        summaries.append(summary)
        result_name = (
            f"result-{expected['prior']}-{expected['batch_index']:02d}.txt"
        )
        result_bytes = outcome["stdout"].encode("utf-8")
        (destination / result_name).write_bytes(result_bytes)
        records.append(
            {
                "path": result_name,
                "prior": expected["prior"],
                "batch_index": expected["batch_index"],
                "episode_seed": expected["episode_seed"],
                "random_seed": expected["random_seed"],
                "episode_count": expected["episode_count"],
                "bytes": len(result_bytes),
                "sha256": freeze.sha256_bytes(result_bytes),
                "wall_seconds": outcome["wall_seconds"],
                "peak_rss_bytes": outcome["peak_rss_bytes"],
                "scenario_evaluations": scenario_count(expected["prior"]),
                "summary": summary,
            }
        )
    return records, summaries, time.monotonic() - started


def write_evaluation_directory(
    destination: Path, freeze_directory: Path, source_manifest: dict[str, Any]
) -> dict[str, Any]:
    if destination.exists():
        raise freeze.FreezeError(
            f"refusing to overwrite evaluation directory: {destination}"
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="active-inference-evaluation-", dir=destination.parent
    ) as temporary_name:
        temporary = Path(temporary_name)
        records, summaries, total_wall_seconds = evaluate_records(
            temporary, freeze_directory, source_manifest
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
            "source_freeze_manifest_digest": source_manifest["manifest_digest"],
            "source_candidate_digest": source_manifest["review_packet"][
                "candidate_digest"
            ],
            "total_wall_seconds": total_wall_seconds,
            "maximum_peak_rss_bytes": max(
                record["peak_rss_bytes"] for record in records
            ),
            "scenario_evaluations": sum(
                record["scenario_evaluations"] for record in records
            ),
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
        verify_results_directory(temporary, source_manifest)
        Path(temporary_name).rename(destination)
    return result_manifest


def verify_raw_records(
    directory: Path,
    records: Any,
    source_manifest: dict[str, Any],
) -> list[dict[str, Any]]:
    episodes = source_manifest["episodes"]
    if not isinstance(records, list) or len(records) != len(episodes):
        raise freeze.FreezeError("result manifest has the wrong result count")
    expected_keys = {
        "path",
        "prior",
        "batch_index",
        "episode_seed",
        "random_seed",
        "episode_count",
        "bytes",
        "sha256",
        "wall_seconds",
        "peak_rss_bytes",
        "scenario_evaluations",
        "summary",
    }
    ceilings = source_manifest["review_packet"]["resource_ceilings"]
    summaries = []
    for record, expected in zip(records, episodes):
        if not isinstance(record, dict) or set(record) != expected_keys:
            raise freeze.FreezeError("result manifest entry has unexpected fields")
        for field in (
            "prior",
            "batch_index",
            "episode_seed",
            "random_seed",
            "episode_count",
        ):
            if record[field] != expected[field]:
                raise freeze.FreezeError(f"result layout mismatch for {field}")
        expected_path = (
            f"result-{expected['prior']}-{expected['batch_index']:02d}.txt"
        )
        if record["path"] != expected_path:
            raise freeze.FreezeError("result path does not match its frozen batch")
        path = directory / expected_path
        if not path.is_file():
            raise freeze.FreezeError(f"missing raw result: {path}")
        payload = path.read_bytes()
        if len(payload) != record["bytes"]:
            raise freeze.FreezeError(f"raw result size mismatch: {path}")
        if freeze.sha256_bytes(payload) != record["sha256"]:
            raise freeze.FreezeError(f"raw result digest mismatch: {path}")
        if not isinstance(record["wall_seconds"], (int, float)) or not (
            0.0
            < record["wall_seconds"]
            <= ceilings["evaluation_seconds_per_batch"]
        ):
            raise freeze.FreezeError(f"invalid evaluation wall time: {path}")
        if type(record["peak_rss_bytes"]) is not int or not (
            0
            < record["peak_rss_bytes"]
            <= ceilings["evaluation_max_rss_bytes_per_process"]
        ):
            raise freeze.FreezeError(f"invalid evaluation peak RSS: {path}")
        if record["scenario_evaluations"] != scenario_count(expected["prior"]):
            raise freeze.FreezeError(f"scenario count mismatch: {path}")
        summary = parse_summary(payload.decode("utf-8"), expected)
        if summary != record["summary"]:
            raise freeze.FreezeError(f"embedded and raw summaries differ: {path}")
        summaries.append(summary)
    return summaries


def verify_results_directory(
    directory: Path, source_manifest: dict[str, Any]
) -> dict[str, Any]:
    result_manifest = freeze.load_json_object(
        directory / "result_manifest.json", "result manifest"
    )
    if set(result_manifest) != EXPECTED_RESULT_MANIFEST_KEYS:
        raise freeze.FreezeError("result manifest has unexpected fields")
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
    completed_at = result_manifest.get("completed_at_utc")
    if not isinstance(completed_at, str) or not completed_at.endswith("Z"):
        raise freeze.FreezeError("result completion time must be UTC")
    try:
        dt.datetime.fromisoformat(completed_at[:-1] + "+00:00")
    except ValueError as exc:
        raise freeze.FreezeError("result completion time is invalid") from exc
    if result_manifest.get("source_freeze_manifest_digest") != source_manifest.get(
        "manifest_digest"
    ):
        raise freeze.FreezeError("result manifest names the wrong freeze")
    if result_manifest.get("source_candidate_digest") != source_manifest[
        "review_packet"
    ]["candidate_digest"]:
        raise freeze.FreezeError("result manifest names the wrong candidate")
    summaries = verify_raw_records(
        directory, result_manifest.get("results"), source_manifest
    )
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
        raise freeze.FreezeError("analysis does not match raw result summaries")
    maximum_rss = max(
        record["peak_rss_bytes"] for record in result_manifest["results"]
    )
    if result_manifest.get("maximum_peak_rss_bytes") != maximum_rss:
        raise freeze.FreezeError("result manifest maximum RSS mismatch")
    scenario_evaluations = sum(
        record["scenario_evaluations"] for record in result_manifest["results"]
    )
    if result_manifest.get("scenario_evaluations") != scenario_evaluations:
        raise freeze.FreezeError("result manifest scenario count mismatch")
    if not isinstance(result_manifest.get("total_wall_seconds"), (int, float)) or (
        result_manifest["total_wall_seconds"] <= 0.0
    ):
        raise freeze.FreezeError("result manifest total wall time is invalid")
    return result_manifest


def run_command(args: argparse.Namespace) -> None:
    freeze.require_clean_worktree()
    freeze_directory = Path(args.freeze_dir)
    source_manifest = freeze.verify_freeze_directory(
        freeze_directory,
        seed_groups=freeze.SEED_GROUPS,
        batch_count=freeze.BATCH_COUNT,
        episode_count=freeze.EPISODES_PER_BATCH,
        seed_stride=freeze.SEED_STRIDE,
        require_current=True,
    )
    destination = Path(args.output_dir)
    freeze.require_outside_worktree(destination, "evaluation directory")
    result_manifest = write_evaluation_directory(
        destination, freeze_directory, source_manifest
    )
    verify_results_directory(destination, source_manifest)
    analysis = freeze.load_json_object(destination / "analysis.json", "analysis")
    improvement = analysis["incorrect_repair_improvement"]
    print(f"evaluation directory: {destination}")
    print(f"result manifest: {result_manifest['result_manifest_digest']}")
    print(f"batches evaluated: {len(result_manifest['results'])}")
    print(f"scenario evaluations: {result_manifest['scenario_evaluations']}")
    print(
        "mean incorrect-repair improvement: "
        f"{improvement['mean']:.6f} "
        f"95% CI [{improvement['lower']:.6f}, {improvement['upper']:.6f}]"
    )
    print(
        "pooled relative incorrect-repair reduction: "
        f"{analysis['pooled_relative_incorrect_repair_reduction']:.6f}"
    )
    print(f"passed: {str(analysis['passed']).lower()}")


def verify_command(args: argparse.Namespace) -> None:
    freeze_directory = Path(args.freeze_dir)
    source_manifest = freeze.verify_freeze_directory(
        freeze_directory,
        seed_groups=freeze.SEED_GROUPS,
        batch_count=freeze.BATCH_COUNT,
        episode_count=freeze.EPISODES_PER_BATCH,
        seed_stride=freeze.SEED_STRIDE,
        require_current=True,
    )
    result_manifest = verify_results_directory(
        Path(args.result_dir), source_manifest
    )
    print(f"verified result manifest: {result_manifest['result_manifest_digest']}")
    print(f"verified results: {len(result_manifest['results'])}")


def metrics(incorrect: int, completed: int) -> dict[str, int | float]:
    return {
        "incorrect": incorrect,
        "completed": completed,
        "inspections": 100,
        "utility": 1.0,
    }


def synthetic_summary(prior: str, batch_index: int) -> dict[str, Any]:
    primary = {
        "greedy": metrics(25, 100),
        "reward": metrics(20, 90),
        "random": metrics(30, 80),
        "active": metrics(10, 90),
        "planner_elapsed_ms": 2,
    }
    beta = [
        {
            "name": name,
            "beta": beta_value,
            "reward": metrics(20, 90),
            "active": metrics(11, 90),
            "planner_elapsed_ms": 2,
        }
        for name, beta_value in BETA_SPECS
    ]
    beta[1]["reward"] = dict(primary["reward"])
    beta[1]["active"] = dict(primary["active"])
    beta[1]["planner_elapsed_ms"] = primary["planner_elapsed_ms"]
    preferences = [
        {
            "name": name,
            "field": field,
            "multiplier": multiplier,
            "reward": metrics(20, 90),
            "active": metrics(12, 90),
            "planner_elapsed_ms": 2,
        }
        for name, field, multiplier in PREFERENCE_SPECS
    ]
    if prior == "shifted":
        primary = {
            "greedy": metrics(24, 100),
            "reward": metrics(18, 90),
            "random": metrics(30, 80),
            "active": metrics(10, 90),
            "planner_elapsed_ms": 2,
        }
        beta = []
        preferences = []
    return {
        "schema": 1,
        "experiment": freeze.EXPERIMENT,
        "prior": prior,
        "batch_index": batch_index,
        "episode_seed": batch_index + 1,
        "random_seed": batch_index + 101,
        "episode_count": 100,
        "primary": primary,
        "beta_sensitivities": beta,
        "preference_sensitivities": preferences,
    }


def run_real_pilot_self_test() -> tuple[int, int, int, bool]:
    packet = freeze.build_packet(require_clean=False)
    attestation = freeze.build_attestation(
        packet,
        "excluded-pilot treatment-runner self-test only",
        reviewer_id="self_test_only_not_an_independent_review",
        reviewed_at_utc="2026-08-09T00:00:00Z",
    )
    pilot_groups = [
        {
            "prior": "base",
            "episode_seed_base": 3_000_001,
            "random_seed_base": 4_000_001,
        },
        {
            "prior": "shifted",
            "episode_seed_base": 3_104_730,
            "random_seed_base": 4_104_730,
        },
    ]
    with tempfile.TemporaryDirectory(prefix="active-inference-runner-self-test-") as root:
        root_path = Path(root)
        freeze_directory = root_path / "freeze"
        manifest = freeze.write_freeze_directory(
            freeze_directory,
            packet,
            attestation,
            freeze.canonical_json(attestation) + b"\n",
            seed_groups=pilot_groups,
            batch_count=1,
            episode_count=10,
            seed_stride=freeze.SEED_STRIDE,
        )
        freeze.verify_freeze_directory(
            freeze_directory,
            seed_groups=pilot_groups,
            batch_count=1,
            episode_count=10,
            seed_stride=freeze.SEED_STRIDE,
            require_current=True,
        )
        result_directory = root_path / "results"
        result_directory.mkdir()
        records, _, _ = evaluate_records(
            result_directory, freeze_directory, manifest
        )
        verify_raw_records(result_directory, records, manifest)
        scenario_evaluations = sum(
            record["scenario_evaluations"] for record in records
        )
        base_raw = (result_directory / records[0]["path"]).read_text(
            encoding="utf-8"
        )
        canonical_random_records = base_raw.splitlines()[0].count(
            "^random (arm_metrics"
        )
        raw_path = result_directory / records[0]["path"]
        raw_path.write_bytes(raw_path.read_bytes() + b"tampered\n")
        mutation_rejected = False
        try:
            verify_raw_records(result_directory, records, manifest)
        except freeze.FreezeError:
            mutation_rejected = True
        return (
            len(records),
            scenario_evaluations,
            canonical_random_records,
            mutation_rejected,
        )


def self_test_command(_: argparse.Namespace) -> None:
    passing = [
        synthetic_summary(prior, index)
        for prior in ("base", "shifted")
        for index in range(freeze.BATCH_COUNT)
    ]
    analysis = analyze_summaries(passing)
    if not analysis["passed"]:
        raise freeze.FreezeError("synthetic passing analysis was rejected")
    if abs(analysis["incorrect_repair_improvement"]["mean"] - 0.10) > 1e-12:
        raise freeze.FreezeError("known paired improvement changed")

    failing = copy.deepcopy(passing)
    for summary in failing:
        if summary["prior"] == "base":
            summary["preference_sensitivities"][0]["active"]["incorrect"] = 21
    if analyze_summaries(failing)["passed"]:
        raise freeze.FreezeError("synthetic robustness reversal was accepted")

    batches, scenarios, random_records, mutation_rejected = (
        run_real_pilot_self_test()
    )
    if (
        batches != 2
        or scenarios != 12
        or random_records != 1
        or not mutation_rejected
    ):
        raise freeze.FreezeError("real pilot runner self-test failed")
    print("known mean incorrect-repair improvement: 0.100000")
    print(
        "known reward completion rate: "
        f"{analysis['primary_arm_metrics']['reward']['completion_rate']:.6f}"
    )
    print("analysis self-test: pass and robustness-failure paths verified")
    print(f"pilot batches evaluated: {batches}")
    print(f"pilot scenario evaluations: {scenarios}")
    print(
        "pilot canonical random-arm records per base batch: "
        f"{random_records}"
    )
    print(f"raw result mutation rejected: {str(mutation_rejected).lower()}")


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
        "self-test", help="exercise analysis and runner on excluded pilot seeds"
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
