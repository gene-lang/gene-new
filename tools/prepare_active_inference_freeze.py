#!/usr/bin/env python3
"""Prepare and verify the exact-belief experiment freeze without running arms.

The tool has four deliberately separate phases:

* ``packet`` hashes the review candidate and prints its stable digest;
* ``attest`` records a reviewer's approval and notes against that exact digest;
* ``freeze`` requires an independent attestation for that exact digest, then
  generates canonical episode batches without executing a treatment arm; and
* ``verify`` re-hashes the current implementation and every frozen artifact.

It cannot establish that a reviewer is independent. That is a social and
organizational fact recorded by the attestation, not something this repository
can self-certify.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import platform
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
EXPERIMENT = "active_inference_v1"
GENE = ROOT / "bin/gene"
EXPORTER = (
    ROOT
    / "examples/general_intelligence/src/active_inference_export.gene"
)
FROZEN_BATCH_EVALUATOR = (
    ROOT
    / "examples/general_intelligence/src/active_inference_frozen_batch.gene"
)
SMOKE = (
    ROOT
    / "examples/general_intelligence/tests/active_inference_smoke.gene"
)
PILOT = (
    ROOT
    / "examples/general_intelligence/tests/active_inference_pilot.gene"
)

REVIEWED_ARTIFACTS = [
    {
        "path": "docs/proposals/general_intelligence/protocols/02_active_inference.md",
        "roles": ["protocol"],
    },
    {
        "path": "examples/general_intelligence/src/exact_belief.gene",
        "roles": ["subject", "planner", "structural_verifier"],
    },
    {
        "path": "examples/general_intelligence/src/active_inference_experiment.gene",
        "roles": ["episode_generator", "arm_executor", "evaluator"],
    },
    {
        "path": "examples/general_intelligence/src/active_inference_export.gene",
        "roles": ["canonical_episode_exporter"],
    },
    {
        "path": "examples/general_intelligence/src/active_inference_frozen_batch.gene",
        "roles": ["frozen_batch_evaluator"],
    },
    {
        "path": "examples/general_intelligence/tests/active_inference_smoke.gene",
        "roles": ["mechanism_smoke"],
    },
    {
        "path": "examples/general_intelligence/tests/active_inference_pilot.gene",
        "roles": ["disjoint_seed_compute_pilot"],
    },
    {
        "path": "tools/prepare_active_inference_freeze.py",
        "roles": ["freeze_procedure"],
    },
    {
        "path": "tools/run_active_inference_evaluation.py",
        "roles": ["treatment_runner", "preregistered_analysis"],
    },
]

SEED_GROUPS = [
    {
        "prior": "base",
        "episode_seed_base": 1_000_003,
        "random_seed_base": 2_000_003,
    },
    {
        "prior": "shifted",
        "episode_seed_base": 1_104_732,
        "random_seed_base": 2_104_732,
    },
]
BATCH_COUNT = 10
EPISODES_PER_BATCH = 100
SEED_STRIDE = 7_919
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
    argv: list[str], *, timeout: float = 30.0, text: bool = True
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        argv,
        cwd=ROOT,
        capture_output=True,
        text=text,
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise FreezeError(f"command failed ({completed.returncode}): {detail}")
    return completed


def git_revision() -> str:
    return run_checked(["git", "rev-parse", "HEAD"]).stdout.strip()


def git_status() -> str:
    return run_checked(
        ["git", "status", "--porcelain", "--untracked-files=all"]
    ).stdout


def require_clean_worktree() -> None:
    status = git_status()
    if status:
        first = status.splitlines()[0]
        raise FreezeError(
            "freeze inputs must come from a clean worktree; first change: "
            + first
        )


def require_outside_worktree(path: Path, label: str) -> None:
    resolved = path.resolve()
    if resolved == ROOT or ROOT in resolved.parents:
        raise FreezeError(f"{label} must be outside the experiment worktree")


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
    nimble_source = (ROOT / "gene.nimble").read_text(encoding="utf-8")
    matched = re.search(r'^version\s*=\s*"([^"]+)"', nimble_source, re.MULTILINE)
    if not matched:
        raise FreezeError("gene.nimble does not declare a version")
    return matched.group(1)


def build_packet(*, require_clean: bool) -> dict[str, Any]:
    status = git_status()
    if require_clean and status:
        require_clean_worktree()
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
        "episode_design": {
            "seed_groups": SEED_GROUPS,
            "batch_count": BATCH_COUNT,
            "episodes_per_batch": EPISODES_PER_BATCH,
            "seed_stride": SEED_STRIDE,
            "draws_per_episode": 3,
        },
        "resource_ceilings": {
            "readiness_seconds": 2,
            "readiness_max_rss_bytes": 67_108_864,
            "evaluation_seconds_per_batch": 30,
            "evaluation_max_rss_bytes_per_process": 134_217_728,
        },
        "analysis": {
            "uncertainty_unit": "matched_batch_seed",
            "batch_count_per_prior": BATCH_COUNT,
            "episodes_per_batch": EPISODES_PER_BATCH,
            "paired_incorrect_repair_metric": "reward_rate_minus_active_rate",
            "paired_completion_metric": "active_rate_minus_reward_rate",
            "interval": "two_sided_student_t_95_df_9",
            "t_critical": 2.262,
            "minimum_relative_incorrect_repair_reduction": 0.30,
            "minimum_completion_ci_lower": -0.02,
            "beta_values": [0.10, 0.25, 0.50],
            "preference_multipliers": [0.90, 1.10],
            "preference_fields": [
                "correct_repair_utility",
                "incorrect_repair_utility",
                "defer_utility",
                "inspection_cost",
            ],
        },
        "commands": {
            "mechanism_smoke": (
                "bin/gene run examples/general_intelligence/tests/"
                "active_inference_smoke.gene"
            ),
            "compute_pilot": (
                "bin/gene run examples/general_intelligence/tests/"
                "active_inference_pilot.gene"
            ),
            "episode_export": (
                "bin/gene run examples/general_intelligence/src/"
                "active_inference_export.gene PRIOR EPISODE_SEED "
                "RANDOM_SEED 100"
            ),
            "frozen_batch_evaluation": (
                "bin/gene run --allow_read_dir FREEZE_DIR "
                "examples/general_intelligence/src/"
                "active_inference_frozen_batch.gene PRIOR EPISODE_FILE"
            ),
            "full_evaluation": (
                "python3 tools/run_active_inference_evaluation.py run "
                "--freeze-dir FREEZE_DIR --output-dir RESULT_DIR"
            ),
        },
        "review_requirements": {
            "independent": True,
            "evaluation_output_unopened": True,
            "attestation_schema": 2,
            "reviewer_inputs": ["approved", "notes"],
            "approval_semantics": (
                "approval attests independent review and unopened "
                "evaluation output"
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


def export_batch(
    prior: str, episode_seed: int, random_seed: int, episode_count: int
) -> bytes:
    completed = run_checked(
        [
            str(GENE),
            "run",
            str(EXPORTER),
            prior,
            str(episode_seed),
            str(random_seed),
            str(episode_count),
        ],
        timeout=2.0,
    )
    payload = completed.stdout.encode("utf-8")
    if not payload.endswith(b"\n"):
        raise FreezeError("episode exporter did not emit one newline-terminated form")
    if payload.count(b"(episode ^index ") != episode_count:
        raise FreezeError("episode exporter emitted the wrong episode count")
    expected_prefix = b"(serde_v1 (episode_batch "
    if not payload.startswith(expected_prefix):
        raise FreezeError("episode exporter emitted an unexpected envelope")
    return payload


def episode_layout(
    seed_groups: list[dict[str, Any]],
    batch_count: int,
    episode_count: int,
    seed_stride: int,
) -> list[dict[str, Any]]:
    layout = []
    for group in seed_groups:
        for batch_index in range(batch_count):
            layout.append(
                {
                    "path": f"episodes-{group['prior']}-{batch_index:02d}.gene",
                    "prior": group["prior"],
                    "batch_index": batch_index,
                    "episode_seed": (
                        group["episode_seed_base"] + seed_stride * batch_index
                    ),
                    "random_seed": (
                        group["random_seed_base"] + seed_stride * batch_index
                    ),
                    "episode_count": episode_count,
                }
            )
    return layout


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
    seed_groups: list[dict[str, Any]],
    batch_count: int,
    episode_count: int,
    seed_stride: int,
) -> dict[str, Any]:
    if destination.exists():
        raise FreezeError(f"refusing to overwrite freeze directory: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(
        prefix="active-inference-freeze-", dir=destination.parent
    ) as temporary_name:
        temporary = Path(temporary_name)
        attestation_filename = "review_attestation.json"
        (temporary / attestation_filename).write_bytes(attestation_bytes)
        episode_records: list[dict[str, Any]] = []
        for expected in episode_layout(
            seed_groups, batch_count, episode_count, seed_stride
        ):
            payload = export_batch(
                expected["prior"],
                expected["episode_seed"],
                expected["random_seed"],
                expected["episode_count"],
            )
            path = temporary / expected["path"]
            path.write_bytes(payload)
            episode_records.append(
                {
                    **expected,
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
            "episodes": episode_records,
            "evaluation_state": {
                "batches_evaluated": 0,
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
        seed_groups=SEED_GROUPS,
        batch_count=BATCH_COUNT,
        episode_count=EPISODES_PER_BATCH,
        seed_stride=SEED_STRIDE,
    )

    print(f"freeze directory: {destination}")
    print(f"candidate digest: {packet['candidate_digest']}")
    print(f"manifest digest: {manifest['manifest_digest']}")
    print(f"episode batches: {len(manifest['episodes'])}")
    print("evaluation batches executed: 0")
    print("treatment arms executed: 0")


def verify_freeze_directory(
    directory: Path,
    *,
    seed_groups: list[dict[str, Any]],
    batch_count: int,
    episode_count: int,
    seed_stride: int,
    require_current: bool,
) -> dict[str, Any]:
    manifest_path = directory / "freeze_manifest.json"
    manifest = load_json_object(manifest_path, "freeze manifest")
    claimed_manifest_digest = manifest.get("manifest_digest")
    manifest_body = dict(manifest)
    manifest_body.pop("manifest_digest", None)
    actual_manifest_digest = sha256_bytes(canonical_json(manifest_body))
    if claimed_manifest_digest != actual_manifest_digest:
        raise FreezeError("freeze manifest digest mismatch")
    if manifest.get("schema") != 1 or manifest.get("experiment") != EXPERIMENT:
        raise FreezeError("freeze manifest schema or experiment mismatch")
    if manifest.get("evaluation_state") != {
        "batches_evaluated": 0,
        "treatment_arms_executed": 0,
    }:
        raise FreezeError("freeze manifest claims unexpected evaluation work")

    packet = manifest.get("review_packet")
    attestation = manifest.get("review_attestation")
    if not isinstance(packet, dict) or not isinstance(attestation, dict):
        raise FreezeError("freeze manifest lacks packet or attestation objects")
    validate_packet_digest(packet)
    validate_attestation(attestation, packet["candidate_digest"])
    if manifest.get("review_attestation_path") != "review_attestation.json":
        raise FreezeError("freeze manifest has an invalid attestation path")
    frozen_attestation_path = directory / "review_attestation.json"
    if not frozen_attestation_path.is_file():
        raise FreezeError("freeze directory lacks its review attestation")
    frozen_attestation_bytes = frozen_attestation_path.read_bytes()
    if sha256_bytes(frozen_attestation_bytes) != manifest.get(
        "review_attestation_sha256"
    ):
        raise FreezeError("review attestation digest mismatch")
    frozen_attestation = load_json_object(
        frozen_attestation_path, "frozen review attestation"
    )
    if frozen_attestation != attestation:
        raise FreezeError("embedded and frozen review attestations differ")

    if require_current:
        current_packet = build_packet(require_clean=False)
        if current_packet["candidate_digest"] != packet["candidate_digest"]:
            raise FreezeError(
                "current implementation does not match the frozen candidate"
            )

    expected_layout = episode_layout(
        seed_groups, batch_count, episode_count, seed_stride
    )
    episodes = manifest.get("episodes")
    if not isinstance(episodes, list) or len(episodes) != len(expected_layout):
        raise FreezeError(
            "freeze manifest must contain exactly "
            f"{len(expected_layout)} episode batches"
        )
    expected_record_keys = {
        "path",
        "prior",
        "batch_index",
        "episode_seed",
        "random_seed",
        "episode_count",
        "bytes",
        "sha256",
    }
    for record, expected in zip(episodes, expected_layout):
        if not isinstance(record, dict):
            raise FreezeError("episode manifest entry must be an object")
        if set(record) != expected_record_keys:
            raise FreezeError("episode manifest entry has unexpected fields")
        for key, value in expected.items():
            if record.get(key) != value:
                raise FreezeError(f"episode layout mismatch for {key}: {record}")
        path = directory / expected["path"]
        if not path.is_file():
            raise FreezeError(f"missing frozen episode file: {path}")
        payload = path.read_bytes()
        if sha256_bytes(payload) != record.get("sha256"):
            raise FreezeError(f"episode digest mismatch: {path}")
        if len(payload) != record.get("bytes"):
            raise FreezeError(f"episode size mismatch: {path}")
        if payload.count(b"(episode ^index ") != record.get("episode_count"):
            raise FreezeError(f"episode count mismatch: {path}")
    return manifest


def verify_command(args: argparse.Namespace) -> None:
    directory = Path(args.freeze_dir)
    manifest = verify_freeze_directory(
        directory,
        seed_groups=SEED_GROUPS,
        batch_count=BATCH_COUNT,
        episode_count=EPISODES_PER_BATCH,
        seed_stride=SEED_STRIDE,
        require_current=True,
    )

    print(f"verified manifest: {manifest['manifest_digest']}")
    print(f"verified candidate: {manifest['review_packet']['candidate_digest']}")
    print(f"verified episode batches: {len(manifest['episodes'])}")


def self_test_command(_: argparse.Namespace) -> None:
    packet = build_packet(require_clean=False)
    validate_packet_digest(packet)
    attestation = build_attestation(
        packet,
        "schema self-test only",
        reviewer_id="self_test_only_not_an_independent_review",
        reviewed_at_utc="2026-08-09T00:00:00Z",
    )
    validate_attestation(attestation, packet["candidate_digest"])

    smoke = run_checked([str(GENE), "run", str(SMOKE)], timeout=2.0)
    if "policies=804 branches=2884" not in smoke.stdout:
        raise FreezeError("mechanism smoke did not produce pinned enumeration")
    pilot = run_checked([str(GENE), "run", str(PILOT)], timeout=2.0)
    if "final_episode_state=264756247" not in pilot.stdout:
        raise FreezeError("compute pilot episode stream changed")
    if "final_random_state=2017023388" not in pilot.stdout:
        raise FreezeError("compute pilot random stream changed")
    with tempfile.TemporaryDirectory(prefix="active-inference-self-test-") as root:
        directory = Path(root) / "freeze"
        manifest = write_freeze_directory(
            directory,
            packet,
            attestation,
            canonical_json(attestation) + b"\n",
            seed_groups=[
                {
                    "prior": "base",
                    "episode_seed_base": 3_000_001,
                    "random_seed_base": 4_000_001,
                }
            ],
            batch_count=1,
            episode_count=100,
            seed_stride=SEED_STRIDE,
        )
        verify_freeze_directory(
            directory,
            seed_groups=[
                {
                    "prior": "base",
                    "episode_seed_base": 3_000_001,
                    "random_seed_base": 4_000_001,
                }
            ],
            batch_count=1,
            episode_count=100,
            seed_stride=SEED_STRIDE,
            require_current=True,
        )
        batch = (directory / manifest["episodes"][0]["path"]).read_bytes()
        if b"^final_episode_state 264756247" not in batch:
            raise FreezeError("canonical exporter episode stream changed")
        if b"^final_random_state 2017023388" not in batch:
            raise FreezeError("canonical exporter random stream changed")
        evaluated = run_checked(
            [
                str(GENE),
                "run",
                "--allow_read_dir",
                str(directory),
                str(FROZEN_BATCH_EVALUATOR),
                "base",
                str(directory / manifest["episodes"][0]["path"]),
            ],
            timeout=30.0,
        )
        if "(serde_v1 (active_inference_frozen_result " not in evaluated.stdout:
            raise FreezeError("frozen pilot batch did not evaluate canonically")
        episode_path = directory / manifest["episodes"][0]["path"]
        episode_path.write_bytes(batch + b"tampered\n")
        mutation_rejected = False
        try:
            verify_freeze_directory(
                directory,
                seed_groups=[
                    {
                        "prior": "base",
                        "episode_seed_base": 3_000_001,
                        "random_seed_base": 4_000_001,
                    }
                ],
                batch_count=1,
                episode_count=100,
                seed_stride=SEED_STRIDE,
                require_current=True,
            )
        except FreezeError:
            mutation_rejected = True
        if not mutation_rejected:
            raise FreezeError("mutated frozen episode was accepted")

    print(f"freeze tooling self-test: candidate={packet['candidate_digest']}")
    print("pilot batches exported: 1")
    print("evaluation batches exported: 0")
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
        "freeze", help="generate canonical batches after independent review"
    )
    freeze.add_argument("--attestation", required=True)
    freeze.add_argument("--output-dir", required=True)
    freeze.set_defaults(handler=freeze_command)

    verify = subcommands.add_parser(
        "verify", help="verify a freeze against current source and episode files"
    )
    verify.add_argument("--freeze-dir", required=True)
    verify.set_defaults(handler=verify_command)

    self_test = subcommands.add_parser(
        "self-test", help="exercise tooling with pilot seeds only"
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
