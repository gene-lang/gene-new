#!/usr/bin/env python3
"""Review, freeze, and verify experiment-1 setup artifacts without running arms.

``packet`` hashes the complete candidate and its unopened seed schedule.
``attest`` records a reviewer's approval and notes against that exact digest.
``freeze`` requires the resulting attestation before it generates target
corpora and matched donor libraries. ``verify`` authenticates the source
revision, review record, manifest, and every setup artifact.

The tool cannot establish reviewer independence; it records the external
reviewer's assertion. Only the ``self-test`` command evaluates a permanently
excluded pilot setup so the trusted-consumer path can be tested.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
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


ROOT = Path(__file__).resolve().parents[1]
EXPERIMENT = "library_induction_v1"
GENE = ROOT / "bin/gene"
TIME = Path("/usr/bin/time")
EXPORTER = (
    ROOT
    / "examples/general_intelligence/src/library_induction_export.gene"
)
FROZEN_EVALUATOR = (
    ROOT
    / "examples/general_intelligence/src/library_induction_frozen_evaluation.gene"
)
MECHANISM_SMOKE = (
    ROOT
    / "examples/general_intelligence/tests/library_induction_smoke.gene"
)

REVIEWED_ARTIFACTS = [
    {
        "path": "docs/proposals/general_intelligence/architecture.md",
        "roles": ["claim_boundary", "experiment_order"],
    },
    {
        "path": (
            "docs/proposals/general_intelligence/protocols/"
            "01_library_induction.md"
        ),
        "roles": ["protocol", "pass_rule", "analysis_plan"],
    },
    {
        "path": "examples/general_intelligence/src/library_induction.gene",
        "roles": [
            "interpreter",
            "corpus_generator",
            "induction",
            "donor_matcher",
            "hidden_verifier",
            "arm_executor",
        ],
    },
    {
        "path": (
            "examples/general_intelligence/src/"
            "library_induction_export.gene"
        ),
        "roles": ["canonical_setup_exporter"],
    },
    {
        "path": (
            "examples/general_intelligence/src/"
            "library_induction_frozen_evaluation.gene"
        ),
        "roles": ["frozen_setup_evaluator", "result_projection"],
    },
    {
        "path": (
            "examples/general_intelligence/tests/"
            "library_induction_smoke.gene"
        ),
        "roles": ["mechanism_smoke"],
    },
    {
        "path": (
            "examples/general_intelligence/tests/"
            "library_induction_corpus_pilot.gene"
        ),
        "roles": ["excluded_compute_pilot"],
    },
    {
        "path": (
            "examples/general_intelligence/tests/"
            "library_induction_control_pilot.gene"
        ),
        "roles": ["excluded_donor_pilot"],
    },
    {
        "path": (
            "examples/general_intelligence/tests/"
            "library_induction_evaluation_pilot.gene"
        ),
        "roles": ["excluded_evaluation_pilot"],
    },
    {
        "path": "tools/prepare_library_induction_freeze.py",
        "roles": ["freeze_procedure"],
    },
    {
        "path": "tools/run_library_induction_evaluation.py",
        "roles": ["treatment_runner", "resource_meter", "statistical_analysis"],
    },
]

TARGET_SEED_BASE = 31_000_019
TARGET_SEED_STRIDE = 10_007
DONOR_SEED_BASE = 41_000_021
DONOR_SEED_STRIDE = 10_009
DONOR_OFFSETS = (0, 97, 193)
CORPUS_COUNT = 8
LEARNING_COUNT = 100
MODEL_SELECTION_COUNT = 25
HELDOUT_COUNT = 50
PILOT_SEEDS = {
    900001,
    900002,
    900101,
    900201,
    900202,
    900203,
    900301,
    900401,
    900402,
    900403,
}
EXPECTED_ATTESTATION_KEYS = {
    "schema",
    "experiment",
    "candidate_digest",
    "reviewer_id",
    "reviewed_at_utc",
    "approved",
    "notes",
}


class FreezeError(RuntimeError):
    pass


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_checked(
    argv: list[str], *, timeout: float = 30.0
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        argv,
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise FreezeError(f"command failed ({completed.returncode}): {detail}")
    return completed


def timed_prefix() -> list[str]:
    if not TIME.is_file():
        raise FreezeError("/usr/bin/time is required for peak-RSS capture")
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
        raise FreezeError("cannot parse peak RSS from /usr/bin/time")
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
        raise FreezeError(
            f"setup export exceeded its {timeout:.0f}-second process timeout"
        ) from exc
    wall_seconds = time.monotonic() - started
    if process.returncode != 0:
        detail = (stderr or stdout).strip()
        raise FreezeError(f"setup export failed ({process.returncode}): {detail}")
    return {
        "stdout": stdout,
        "wall_seconds": wall_seconds,
        "peak_rss_bytes": parse_peak_rss(stderr),
    }


def git_revision() -> str:
    return run_checked(["git", "rev-parse", "HEAD"]).stdout.strip()


def git_status() -> str:
    return run_checked(
        ["git", "status", "--porcelain", "--untracked-files=all"]
    ).stdout


def require_clean_worktree() -> None:
    status = git_status()
    if status:
        raise FreezeError(
            "freeze inputs must come from a clean worktree; first change: "
            + status.splitlines()[0]
        )


def require_outside_worktree(path: Path, label: str) -> None:
    resolved = path.resolve()
    if resolved == ROOT or ROOT in resolved.parents:
        raise FreezeError(f"{label} must be outside the experiment worktree")


def seed_schedule() -> list[dict[str, Any]]:
    schedule = []
    for index in range(CORPUS_COUNT):
        donor_base = DONOR_SEED_BASE + DONOR_SEED_STRIDE * index
        schedule.append(
            {
                "index": index,
                "path": f"setup-{index:02d}.gene",
                "target_seed": TARGET_SEED_BASE + TARGET_SEED_STRIDE * index,
                "donor_seeds": [donor_base + offset for offset in DONOR_OFFSETS],
                "learning_count": LEARNING_COUNT,
                "model_selection_count": MODEL_SELECTION_COUNT,
                "heldout_count": HELDOUT_COUNT,
            }
        )
    return schedule


def validate_schedule(schedule: list[dict[str, Any]]) -> None:
    if len(schedule) != CORPUS_COUNT:
        raise FreezeError(f"seed schedule must contain {CORPUS_COUNT} corpora")
    all_seeds: list[int] = []
    for expected_index, record in enumerate(schedule):
        if record["index"] != expected_index:
            raise FreezeError("seed schedule indices are not contiguous")
        donors = record["donor_seeds"]
        if len(donors) != len(DONOR_OFFSETS):
            raise FreezeError("every target must have exactly three donor seeds")
        all_seeds.append(record["target_seed"])
        all_seeds.extend(donors)
    if len(set(all_seeds)) != len(all_seeds):
        raise FreezeError("target and donor seeds must be globally disjoint")
    if set(all_seeds) & PILOT_SEEDS:
        raise FreezeError("evaluation schedule overlaps a permanently excluded seed")
    if any(seed <= 0 or seed >= 2_147_483_647 for seed in all_seeds):
        raise FreezeError("every seed must be in 1..2147483646")


def artifact_records() -> list[dict[str, Any]]:
    records = []
    for declaration in REVIEWED_ARTIFACTS:
        relative = declaration["path"]
        path = ROOT / relative
        if not path.is_file():
            raise FreezeError(f"missing reviewed artifact: {relative}")
        records.append(
            {
                "path": relative,
                "roles": declaration["roles"],
                "sha256": sha256_file(path),
                "bytes": path.stat().st_size,
            }
        )
    return records


def gene_version() -> str:
    if not GENE.is_file():
        raise FreezeError("bin/gene is missing; build the pinned runtime first")
    source = (ROOT / "gene.nimble").read_text(encoding="utf-8")
    matched = re.search(r'^version\s*=\s*"([^"]+)"', source, re.MULTILINE)
    if not matched:
        raise FreezeError("gene.nimble does not declare a version")
    return matched.group(1)


def build_packet(*, require_clean: bool) -> dict[str, Any]:
    status = git_status()
    if require_clean and status:
        require_clean_worktree()
    schedule = seed_schedule()
    validate_schedule(schedule)
    packet: dict[str, Any] = {
        "schema": 1,
        "experiment": EXPERIMENT,
        "protocol_version": "candidate_v1",
        "git_revision": git_revision(),
        "git_clean": not bool(status),
        "runtime": {
            "gene_version": gene_version(),
            "gene_sha256": sha256_file(GENE),
        },
        "platform": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "artifacts": artifact_records(),
        "corpus_design": {
            "corpus_count": CORPUS_COUNT,
            "learning_count": LEARNING_COUNT,
            "model_selection_count": MODEL_SELECTION_COUNT,
            "heldout_count": HELDOUT_COUNT,
            "target_depth": 4,
            "public_cases": 4,
            "hidden_cases": 24,
            "structural_bank_inputs": 16,
            "shorter_program_count": 1885,
            "generator": "park_miller_48271_mod_2147483647",
        },
        "search_design": {
            "primitive_count": 12,
            "library_items": 4,
            "library_definition_mdl_ceiling": 20,
            "search_token_depth": 3,
            "candidate_ceiling": 4369,
            "primary_arms": ["base", "induced", "unrelated"],
            "model_token_budget": 0,
        },
        "seed_schedule": schedule,
        "analysis": {
            "uncertainty_unit": "target_corpus_seed",
            "seed_count": 8,
            "paired_metric": "induced_solve_rate_minus_unrelated_solve_rate",
            "interval": "two_sided_student_t_95_df_7",
            "t_critical": 2.364624251,
            "minimum_advantage": 0.15,
            "reuse_aggregation": "minimum_across_corpora",
            "minimum_reused_abstractions": 3,
            "minimum_solutions_per_reused_abstraction": 5,
        },
        "resource_ceilings": {
            "mechanism_smoke_seconds": 1,
            "mechanism_smoke_max_rss_bytes": 67_108_864,
            "setup_export_seconds_per_corpus": 60,
            "evaluation_seconds_per_corpus": 75,
            "per_process_max_rss_bytes": 67_108_864,
        },
        "commands": {
            "mechanism_smoke": (
                "bin/gene run examples/general_intelligence/tests/"
                "library_induction_smoke.gene"
            ),
            "setup_export": (
                "bin/gene run examples/general_intelligence/src/"
                "library_induction_export.gene TARGET_SEED DONOR_SEED..."
            ),
            "frozen_evaluation": (
                "bin/gene run --allow_read_dir FREEZE_DIR "
                "examples/general_intelligence/src/"
                "library_induction_frozen_evaluation.gene SETUP_FILE"
            ),
            "full_evaluation": (
                "python3 tools/run_library_induction_evaluation.py run "
                "--freeze-dir FREEZE_DIR --output-dir RESULT_DIR"
            ),
        },
        "review_requirements": {
            "independent": True,
            "evaluation_output_unopened": True,
            "seed_schedule_selected_without_results": True,
            "attestation_schema": 2,
            "reviewer_inputs": ["approved", "notes"],
            "approval_semantics": (
                "approval attests independent review, unopened evaluation "
                "output, and result-free seed-schedule selection"
            ),
        },
    }
    packet["candidate_digest"] = sha256_bytes(canonical_json(packet))
    return packet


def validate_packet_digest(packet: dict[str, Any]) -> None:
    claimed = packet.get("candidate_digest")
    body = dict(packet)
    body.pop("candidate_digest", None)
    actual = sha256_bytes(canonical_json(body))
    if claimed != actual:
        raise FreezeError(
            f"candidate packet digest mismatch: expected {claimed}, got {actual}"
        )


def validate_attestation(
    attestation: dict[str, Any], candidate_digest: str
) -> None:
    if set(attestation) != EXPECTED_ATTESTATION_KEYS:
        missing = sorted(EXPECTED_ATTESTATION_KEYS - set(attestation))
        extra = sorted(set(attestation) - EXPECTED_ATTESTATION_KEYS)
        raise FreezeError(
            f"attestation fields mismatch; missing={missing}, extra={extra}"
        )
    if attestation["schema"] != 2:
        raise FreezeError("attestation schema must be 2")
    if attestation["experiment"] != EXPERIMENT:
        raise FreezeError("attestation names the wrong experiment")
    if attestation["candidate_digest"] != candidate_digest:
        raise FreezeError("attestation does not cover the current candidate digest")
    if not isinstance(attestation["reviewer_id"], str) or not attestation[
        "reviewer_id"
    ].strip():
        raise FreezeError("attestation reviewer_id must be a nonempty string")
    if not isinstance(attestation["notes"], str):
        raise FreezeError("attestation notes must be a string")
    if attestation["approved"] is not True:
        raise FreezeError("attestation must explicitly approve the candidate")
    timestamp = attestation["reviewed_at_utc"]
    if not isinstance(timestamp, str) or not timestamp.endswith("Z"):
        raise FreezeError("reviewed_at_utc must be an ISO-8601 UTC timestamp")
    try:
        dt.datetime.fromisoformat(timestamp[:-1] + "+00:00")
    except ValueError as exc:
        raise FreezeError("reviewed_at_utc is not a valid timestamp") from exc


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise FreezeError(f"cannot read {label}: {exc}") from exc
    if not isinstance(value, dict):
        raise FreezeError(f"{label} must contain one JSON object")
    return value


def reviewer_identity() -> str:
    name = run_checked(["git", "config", "user.name"]).stdout.strip()
    email = run_checked(["git", "config", "user.email"]).stdout.strip()
    if not name or not email:
        raise FreezeError("git user.name and user.email must identify the reviewer")
    return f"{name} <{email}>"


def build_attestation(
    packet: dict[str, Any],
    notes: str,
    *,
    reviewer_id: str | None = None,
    reviewed_at_utc: str | None = None,
) -> dict[str, Any]:
    return {
        "schema": 2,
        "experiment": EXPERIMENT,
        "candidate_digest": packet["candidate_digest"],
        "reviewer_id": reviewer_id or reviewer_identity(),
        "reviewed_at_utc": reviewed_at_utc
        or dt.datetime.now(dt.timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z"),
        "approved": True,
        "notes": notes,
    }


def validate_setup_payload(
    payload: bytes, expected: dict[str, Any]
) -> int:
    if not payload.endswith(b"\n"):
        raise FreezeError("setup exporter did not emit one newline-terminated form")
    if not payload.startswith(b"(serde_v1 (library_induction_setup "):
        raise FreezeError("setup exporter emitted an unexpected envelope")
    expected_tasks = (
        expected["learning_count"]
        + expected["model_selection_count"]
        + expected["heldout_count"]
    )
    if payload.count(b"(corpus_task ") != expected_tasks:
        raise FreezeError("setup exporter emitted the wrong corpus task count")
    if b"(exact_enumerator_evaluation " in payload:
        raise FreezeError("setup exporter executed an evaluation arm")
    if b"(library_arm_result " in payload:
        raise FreezeError("setup exporter leaked an arm result")
    matched = re.search(rb"\^accepted_donor_seed ([0-9]+)", payload)
    if not matched:
        raise FreezeError("setup exporter omitted the accepted donor seed")
    accepted = int(matched.group(1))
    if accepted not in expected["donor_seeds"]:
        raise FreezeError("setup exporter accepted a non-predeclared donor seed")
    return accepted


def export_setup(expected: dict[str, Any]) -> tuple[bytes, int, float, int]:
    completed = run_timed(
        [
            str(GENE),
            "run",
            str(EXPORTER),
            str(expected["target_seed"]),
            *(str(seed) for seed in expected["donor_seeds"]),
        ],
        timeout=75.0,
    )
    if completed["wall_seconds"] > 60.0:
        raise FreezeError("setup export exceeded the 60-second ceiling")
    if completed["peak_rss_bytes"] > 67_108_864:
        raise FreezeError("setup export exceeded the 64-MiB RSS ceiling")
    payload = completed["stdout"].encode("utf-8")
    return (
        payload,
        validate_setup_payload(payload, expected),
        completed["wall_seconds"],
        completed["peak_rss_bytes"],
    )


def packet_command(args: argparse.Namespace) -> None:
    packet = build_packet(require_clean=not args.allow_dirty)
    rendered = json.dumps(packet, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.output == "-":
        sys.stdout.write(rendered)
        return
    destination = Path(args.output)
    require_outside_worktree(destination, "review packet")
    if destination.exists():
        raise FreezeError(f"refusing to overwrite review packet: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(rendered, encoding="utf-8")
    print(f"review packet: {destination}")
    print(f"candidate digest: {packet['candidate_digest']}")


def attest_command(args: argparse.Namespace) -> None:
    current_packet = build_packet(require_clean=not args.allow_dirty)
    packet_path = Path(args.packet)
    require_outside_worktree(packet_path, "review packet")
    reviewed_packet = load_json_object(packet_path, "review packet")
    validate_packet_digest(reviewed_packet)
    if reviewed_packet["candidate_digest"] != current_packet["candidate_digest"]:
        raise FreezeError("review packet does not cover the current candidate")
    attestation = build_attestation(reviewed_packet, args.notes)
    validate_attestation(attestation, current_packet["candidate_digest"])
    destination = Path(args.output)
    require_outside_worktree(destination, "review attestation")
    if destination.exists():
        raise FreezeError(f"refusing to overwrite review attestation: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        json.dumps(attestation, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"review attestation: {destination}")
    print(f"candidate digest: {attestation['candidate_digest']}")
    print(f"reviewer: {attestation['reviewer_id']}")
    print("approved: true")


def write_freeze_directory(
    destination: Path,
    packet: dict[str, Any],
    attestation: dict[str, Any],
    attestation_bytes: bytes,
    *,
    schedule: list[dict[str, Any]],
) -> dict[str, Any]:
    if destination.exists():
        raise FreezeError(f"refusing to overwrite freeze directory: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="library-induction-freeze-", dir=destination.parent
    ) as temporary_name:
        temporary = Path(temporary_name)
        attestation_filename = "review_attestation.json"
        (temporary / attestation_filename).write_bytes(attestation_bytes)
        setup_records: list[dict[str, Any]] = []
        for expected in schedule:
            payload, accepted_donor_seed, wall_seconds, peak_rss_bytes = (
                export_setup(expected)
            )
            path = temporary / expected["path"]
            path.write_bytes(payload)
            setup_records.append(
                {
                    **expected,
                    "accepted_donor_seed": accepted_donor_seed,
                    "wall_seconds": wall_seconds,
                    "peak_rss_bytes": peak_rss_bytes,
                    "bytes": len(payload),
                    "sha256": sha256_bytes(payload),
                }
            )
        manifest: dict[str, Any] = {
            "schema": 1,
            "experiment": EXPERIMENT,
            "frozen_at_utc": dt.datetime.now(dt.timezone.utc)
            .isoformat(timespec="seconds")
            .replace("+00:00", "Z"),
            "review_packet": packet,
            "review_attestation": attestation,
            "review_attestation_path": attestation_filename,
            "review_attestation_sha256": sha256_bytes(attestation_bytes),
            "setups": setup_records,
            "evaluation_state": {
                "heldout_task_searches_executed": 0,
                "treatment_arms_executed": 0,
            },
        }
        manifest["manifest_digest"] = sha256_bytes(canonical_json(manifest))
        (temporary / "freeze_manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        Path(temporary_name).rename(destination)
    return manifest


def freeze_command(args: argparse.Namespace) -> None:
    require_clean_worktree()
    packet = build_packet(require_clean=True)
    validate_packet_digest(packet)
    attestation_path = Path(args.attestation)
    require_outside_worktree(attestation_path, "review attestation")
    attestation = load_json_object(attestation_path, "review attestation")
    validate_attestation(attestation, packet["candidate_digest"])
    destination = Path(args.output_dir)
    require_outside_worktree(destination, "freeze directory")
    manifest = write_freeze_directory(
        destination,
        packet,
        attestation,
        attestation_path.read_bytes(),
        schedule=seed_schedule(),
    )
    print(f"freeze directory: {destination}")
    print(f"candidate digest: {packet['candidate_digest']}")
    print(f"manifest digest: {manifest['manifest_digest']}")
    print(f"frozen setups: {len(manifest['setups'])}")
    print("heldout task searches executed: 0")
    print("treatment arms executed: 0")


def verify_freeze_directory(
    directory: Path,
    *,
    schedule: list[dict[str, Any]],
    require_current: bool,
) -> dict[str, Any]:
    manifest = load_json_object(directory / "freeze_manifest.json", "freeze manifest")
    claimed_manifest_digest = manifest.get("manifest_digest")
    manifest_body = dict(manifest)
    manifest_body.pop("manifest_digest", None)
    if claimed_manifest_digest != sha256_bytes(canonical_json(manifest_body)):
        raise FreezeError("freeze manifest digest mismatch")
    if manifest.get("schema") != 1 or manifest.get("experiment") != EXPERIMENT:
        raise FreezeError("freeze manifest schema or experiment mismatch")
    if manifest.get("evaluation_state") != {
        "heldout_task_searches_executed": 0,
        "treatment_arms_executed": 0,
    }:
        raise FreezeError("freeze manifest claims unexpected evaluation work")

    packet = manifest.get("review_packet")
    attestation = manifest.get("review_attestation")
    if not isinstance(packet, dict) or not isinstance(attestation, dict):
        raise FreezeError("freeze manifest lacks packet or attestation objects")
    validate_packet_digest(packet)
    validate_attestation(attestation, packet["candidate_digest"])
    if packet.get("seed_schedule") != seed_schedule():
        raise FreezeError("frozen packet does not contain the candidate schedule")
    if manifest.get("review_attestation_path") != "review_attestation.json":
        raise FreezeError("freeze manifest has an invalid attestation path")
    frozen_attestation_path = directory / "review_attestation.json"
    if not frozen_attestation_path.is_file():
        raise FreezeError("freeze directory lacks its review attestation")
    attestation_bytes = frozen_attestation_path.read_bytes()
    if sha256_bytes(attestation_bytes) != manifest.get(
        "review_attestation_sha256"
    ):
        raise FreezeError("review attestation digest mismatch")
    if load_json_object(
        frozen_attestation_path, "frozen review attestation"
    ) != attestation:
        raise FreezeError("embedded and frozen review attestations differ")
    if require_current:
        current_packet = build_packet(require_clean=False)
        if current_packet["candidate_digest"] != packet["candidate_digest"]:
            raise FreezeError(
                "current implementation does not match the frozen candidate"
            )

    setups = manifest.get("setups")
    if not isinstance(setups, list) or len(setups) != len(schedule):
        raise FreezeError(
            f"freeze manifest must contain exactly {len(schedule)} setups"
        )
    expected_keys = {
        "index",
        "path",
        "target_seed",
        "donor_seeds",
        "accepted_donor_seed",
        "wall_seconds",
        "peak_rss_bytes",
        "learning_count",
        "model_selection_count",
        "heldout_count",
        "bytes",
        "sha256",
    }
    for record, expected in zip(setups, schedule):
        if not isinstance(record, dict) or set(record) != expected_keys:
            raise FreezeError("setup manifest entry has unexpected fields")
        for key, value in expected.items():
            if record.get(key) != value:
                raise FreezeError(f"setup layout mismatch for {key}: {record}")
        path = directory / expected["path"]
        if not path.is_file():
            raise FreezeError(f"missing frozen setup file: {path}")
        payload = path.read_bytes()
        if sha256_bytes(payload) != record.get("sha256"):
            raise FreezeError(f"setup digest mismatch: {path}")
        if len(payload) != record.get("bytes"):
            raise FreezeError(f"setup size mismatch: {path}")
        accepted = validate_setup_payload(payload, expected)
        if accepted != record.get("accepted_donor_seed"):
            raise FreezeError(f"accepted donor mismatch: {path}")
        wall_seconds = record.get("wall_seconds")
        peak_rss_bytes = record.get("peak_rss_bytes")
        if not isinstance(wall_seconds, (int, float)) or not (
            0.0 < wall_seconds <= 60.0
        ):
            raise FreezeError(f"invalid setup wall time: {path}")
        if not isinstance(peak_rss_bytes, int) or not (
            0 < peak_rss_bytes <= 67_108_864
        ):
            raise FreezeError(f"invalid setup peak RSS: {path}")
    return manifest


def verify_command(args: argparse.Namespace) -> None:
    manifest = verify_freeze_directory(
        Path(args.freeze_dir),
        schedule=seed_schedule(),
        require_current=True,
    )
    print(f"verified manifest: {manifest['manifest_digest']}")
    print(f"verified candidate: {manifest['review_packet']['candidate_digest']}")
    print(f"verified setups: {len(manifest['setups'])}")


def self_test_command(_: argparse.Namespace) -> None:
    packet = build_packet(require_clean=False)
    validate_packet_digest(packet)
    attestation = build_attestation(
        packet,
        "schema and excluded-pilot self-test only",
        reviewer_id="self_test_only_not_an_independent_review",
        reviewed_at_utc="2026-08-09T00:00:00Z",
    )
    validate_attestation(attestation, packet["candidate_digest"])
    smoke = run_checked([str(GENE), "run", str(MECHANISM_SMOKE)], timeout=2.0)
    if "hidden_verifier_rejected_public_false_positive=true" not in smoke.stdout:
        raise FreezeError("mechanism smoke did not exercise the verifier boundary")
    pilot_schedule = [
        {
            "index": 0,
            "path": "setup-00.gene",
            "target_seed": 900301,
            "donor_seeds": [900401, 900402, 900403],
            "learning_count": LEARNING_COUNT,
            "model_selection_count": MODEL_SELECTION_COUNT,
            "heldout_count": HELDOUT_COUNT,
        }
    ]
    with tempfile.TemporaryDirectory(prefix="library-induction-self-test-") as root:
        directory = Path(root) / "freeze"
        manifest = write_freeze_directory(
            directory,
            packet,
            attestation,
            canonical_json(attestation) + b"\n",
            schedule=pilot_schedule,
        )
        verify_freeze_directory(
            directory,
            schedule=pilot_schedule,
            require_current=True,
        )
        setup_path = directory / manifest["setups"][0]["path"]
        evaluated = run_checked(
            [
                str(GENE),
                "run",
                "--allow_read_dir",
                str(directory),
                str(FROZEN_EVALUATOR),
                str(setup_path),
            ],
            timeout=90.0,
        )
        lines = evaluated.stdout.splitlines()
        if len(lines) != 2 or not lines[0].startswith(
            "(serde_v1 (library_induction_frozen_result "
        ):
            raise FreezeError("frozen pilot evaluator did not emit canonical data")
        try:
            summary = json.loads(lines[1])
        except json.JSONDecodeError as exc:
            raise FreezeError("frozen pilot evaluator summary is not JSON") from exc
        if summary.get("target_seed") != 900301:
            raise FreezeError("frozen pilot evaluator used the wrong target seed")
        if summary.get("induced_solved") != 44:
            raise FreezeError("frozen pilot induced outcome changed")
        if summary.get("unrelated_solved") != 12:
            raise FreezeError("frozen pilot unrelated outcome changed")

        original = setup_path.read_bytes()
        setup_path.write_bytes(original + b"tampered\n")
        mutation_rejected = False
        try:
            verify_freeze_directory(
                directory,
                schedule=pilot_schedule,
                require_current=True,
            )
        except FreezeError:
            mutation_rejected = True
        if not mutation_rejected:
            raise FreezeError("mutated frozen setup was accepted")

    print(f"freeze tooling self-test: candidate={packet['candidate_digest']}")
    print("pilot setups exported: 1")
    print("evaluation setups exported: 0")
    print("pilot treatment arms executed: 3")
    print("evaluation treatment arms executed: 0")
    print("mutation rejected: true")
    print("reviewer inputs: approved, notes")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subcommands = root.add_subparsers(dest="command", required=True)

    packet = subcommands.add_parser(
        "packet", help="write the current independent-review packet"
    )
    packet.add_argument("--output", default="-", help="path or - for stdout")
    packet.add_argument(
        "--allow-dirty",
        action="store_true",
        help="development inspection only; a dirty packet cannot be frozen",
    )
    packet.set_defaults(handler=packet_command)

    attest = subcommands.add_parser(
        "attest", help="record approval and notes for a review packet"
    )
    attest.add_argument("--packet", required=True)
    attest.add_argument("--approve", action="store_true", required=True)
    attest.add_argument("--notes", required=True)
    attest.add_argument("--output", required=True)
    attest.add_argument(
        "--allow-dirty",
        action="store_true",
        help="development inspection only; a dirty attestation cannot be frozen",
    )
    attest.set_defaults(handler=attest_command)

    freeze = subcommands.add_parser(
        "freeze", help="generate setup artifacts after independent review"
    )
    freeze.add_argument("--attestation", required=True)
    freeze.add_argument("--output-dir", required=True)
    freeze.set_defaults(handler=freeze_command)

    verify = subcommands.add_parser(
        "verify", help="verify source, review, manifest, and setup artifacts"
    )
    verify.add_argument("--freeze-dir", required=True)
    verify.set_defaults(handler=verify_command)

    self_test = subcommands.add_parser(
        "self-test", help="exercise the workflow using excluded pilot seeds"
    )
    self_test.set_defaults(handler=self_test_command)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        args.handler(args)
    except (FreezeError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"freeze error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
