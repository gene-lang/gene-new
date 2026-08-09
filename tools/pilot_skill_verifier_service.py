#!/usr/bin/env python3
"""Authenticated verifier-service boundary pilot for experiment 4.

The service owns four authorities that the proposing agent never receives: the
external suite path, an HMAC key, the append-only verification journal, and the
right to invoke the exact Gene verifier kernel. A submitter receives only an
aggregate status and opaque digests. A trusted consumer verifies and reads
promotions from the journal itself; model-supplied receipts are never accepted
as promotion authority.

This demonstrates a capability boundary, not a claim that one Unix user can
hide bytes from another process controlled by that same Unix user. Production
deployment must place this service under a distinct OS/container identity.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
import platform
import re
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
GENE = ROOT / "bin/gene"
TIME = Path("/usr/bin/time")
KERNEL = (
    ROOT
    / "examples/general_intelligence/src/skill_verifier_service_kernel.gene"
)
MODEL_ADAPTER = ROOT / "tools/pilot_verified_skill_agent.py"
VERIFIER_ID = "gene_skill_verifier_service_v1"
GENESIS = "genesis"
MAX_CANDIDATE_BYTES = 16_384
MAX_MESSAGE_BYTES = 32_768
MAX_KERNEL_OUTPUT_BYTES = 262_144
MAX_JOURNAL_BYTES = 16 * 1024 * 1024
MAX_JOURNAL_RECORDS = 10_000
MAX_KERNEL_WALL_SECONDS = 1.0
MAX_KERNEL_PEAK_RSS_BYTES = 67_108_864
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
REQUEST_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
REQUEST_KEYS = {
    "schema",
    "request_id",
    "expected_previous_receipt_digest",
    "candidate_source",
}
SUMMARY_KEYS = {
    "schema",
    "verifier_id",
    "suite_id",
    "candidate_digest",
    "passed",
    "tests_passed",
    "tests_total",
    "failure_codes",
}
PAYLOAD_KEYS = {
    "schema",
    "verifier_id",
    "sequence",
    "request_id",
    "suite_sha256",
    "kernel_sha256",
    "candidate_digest",
    "candidate_source_sha256",
    "passed",
    "tests_passed",
    "tests_total",
    "failure_codes_sha256",
    "previous_receipt_digest",
    "kernel_output_sha256",
    "kernel_wall_seconds",
    "kernel_peak_rss_bytes",
    "verified_at_utc",
}
RECEIPT_KEYS = {"payload", "signature", "receipt_digest"}
JOURNAL_RECORD_KEYS = {
    "schema",
    "receipt",
    "candidate_source",
    "kernel_output",
}
SAFE_RESPONSE_KEYS = {
    "schema",
    "request_id",
    "status",
    "candidate_digest",
    "receipt_digest",
}
ERROR_RESPONSE_KEYS = {"schema", "request_id", "status", "error_code"}


class ServiceError(RuntimeError):
    pass


class AuthorityError(ServiceError):
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


def require_outside_worktree(path: Path, label: str) -> None:
    resolved = path.resolve(strict=False)
    if resolved == ROOT or ROOT in resolved.parents:
        raise ServiceError(f"{label} must be outside the agent worktree")


def require_private_file(path: Path, label: str, *, maximum_bytes: int) -> bytes:
    require_outside_worktree(path, label)
    if path.is_symlink() or not path.is_file():
        raise ServiceError(f"{label} must be a regular non-symlink file")
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        raise ServiceError(f"{label} must not grant group or other permissions")
    if path.stat().st_size > maximum_bytes:
        raise ServiceError(f"{label} exceeds its byte limit")
    return path.read_bytes()


def load_key(path: Path) -> bytes:
    value = require_private_file(path, "verifier key", maximum_bytes=1024)
    if not 32 <= len(value) <= 1024:
        raise ServiceError("verifier key must contain 32..1024 bytes")
    return value


def load_suite(path: Path) -> tuple[bytes, dict[str, Any]]:
    raw = require_private_file(path, "verifier suite", maximum_bytes=262_144)
    try:
        suite = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ServiceError("verifier suite is not valid JSON") from exc
    if not isinstance(suite, dict) or set(suite) != {
        "schema",
        "suite_id",
        "cases",
    }:
        raise ServiceError("verifier suite must use the closed schema")
    if suite["schema"] != 1:
        raise ServiceError("verifier suite schema must be 1")
    if not isinstance(suite["suite_id"], str) or not suite["suite_id"]:
        raise ServiceError("verifier suite_id must be a nonempty string")
    cases = suite["cases"]
    if not isinstance(cases, list) or not 1 <= len(cases) <= 64:
        raise ServiceError("verifier suite must contain 1..64 cases")
    identifiers = set()
    for case in cases:
        if not isinstance(case, dict) or set(case) != {"id", "input", "expected"}:
            raise ServiceError("verifier case must use the closed schema")
        if not all(isinstance(case[field], str) for field in case):
            raise ServiceError("verifier case values must be strings")
        if not case["id"] or len(case["id"].encode("utf-8")) > 128:
            raise ServiceError("verifier case id is invalid")
        if case["id"] in identifiers:
            raise ServiceError("verifier case ids must be unique")
        identifiers.add(case["id"])
        if len(case["input"].encode("utf-8")) > 4096 or len(
            case["expected"].encode("utf-8")
        ) > 4096:
            raise ServiceError("verifier case input or expected output is too large")
    return raw, suite


def minimal_kernel_environment() -> dict[str, str]:
    # Preserve the real home path because Gene initializes its own home layout;
    # do not forward any credential-bearing environment values.
    result = {"PATH": os.defpath, "HOME": str(Path.home())}
    for name in ("LANG", "LC_ALL", "TMPDIR"):
        value = os.environ.get(name)
        if value:
            result[name] = value
    return result


def timed_prefix() -> list[str]:
    if not TIME.is_file():
        raise ServiceError("/usr/bin/time is required for peak-RSS capture")
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
        raise ServiceError("cannot parse verifier peak RSS from /usr/bin/time")
    return int(matched.group(1)) * multiplier


def validate_summary(summary: Any, suite: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(summary, dict) or set(summary) != SUMMARY_KEYS:
        raise ServiceError("verifier kernel summary has unexpected fields")
    if type(summary["schema"]) is not int or summary["schema"] != 1:
        raise ServiceError("verifier kernel summary schema mismatch")
    if summary["verifier_id"] != VERIFIER_ID:
        raise ServiceError("verifier kernel identity mismatch")
    if summary["suite_id"] != suite["suite_id"]:
        raise ServiceError("verifier kernel suite identity mismatch")
    if not isinstance(summary["candidate_digest"], str) or not (
        SHA256_PATTERN.fullmatch(summary["candidate_digest"])
    ):
        raise ServiceError("verifier kernel candidate digest is invalid")
    total = len(suite["cases"])
    if type(summary["tests_total"]) is not int or summary["tests_total"] != total:
        raise ServiceError("verifier kernel test total mismatch")
    if type(summary["tests_passed"]) is not int or not (
        0 <= summary["tests_passed"] <= total
    ):
        raise ServiceError("verifier kernel pass count is invalid")
    if type(summary["passed"]) is not bool or summary["passed"] != (
        summary["tests_passed"] == total
    ):
        raise ServiceError("verifier kernel pass flag is inconsistent")
    failure_codes = summary["failure_codes"]
    case_ids = {case["id"] for case in suite["cases"]}
    if not isinstance(failure_codes, list) or any(
        not isinstance(code, str) or code not in case_ids for code in failure_codes
    ):
        raise ServiceError("verifier kernel failure codes are invalid")
    if len(set(failure_codes)) != len(failure_codes) or len(failure_codes) != (
        total - summary["tests_passed"]
    ):
        raise ServiceError("verifier kernel failure count is inconsistent")
    return summary


def run_kernel(
    candidate_source: str,
    suite_path: Path,
    suite: dict[str, Any],
) -> tuple[str, dict[str, Any], float, int]:
    encoded = candidate_source.encode("utf-8")
    if not encoded or len(encoded) > MAX_CANDIDATE_BYTES or "\0" in candidate_source:
        raise ServiceError("candidate source must contain 1..16384 UTF-8 bytes")
    started = time.monotonic()
    process = subprocess.Popen(
        timed_prefix()
        + [
                str(GENE),
                "run",
                str(KERNEL),
                "--grant",
                "suites=$fs/ReadDir",
                "--",
                candidate_source,
                str(suite_path),
        ],
        cwd=ROOT,
        env=minimal_kernel_environment(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=3.0)
    except subprocess.TimeoutExpired as exc:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise ServiceError("verifier kernel exceeded its process timeout") from exc
    wall_seconds = time.monotonic() - started
    if process.returncode != 0:
        detail = (stderr or stdout).strip()
        raise ServiceError(f"verifier kernel rejected its input: {detail}")
    peak_rss_bytes = parse_peak_rss(stderr)
    if wall_seconds > MAX_KERNEL_WALL_SECONDS:
        raise ServiceError("verifier kernel exceeded its wall-time ceiling")
    if peak_rss_bytes > MAX_KERNEL_PEAK_RSS_BYTES:
        raise ServiceError("verifier kernel exceeded its peak-RSS ceiling")
    output = stdout
    if len(output.encode("utf-8")) > MAX_KERNEL_OUTPUT_BYTES:
        raise ServiceError("verifier kernel output exceeds its byte limit")
    lines = output.splitlines()
    if len(lines) != 2 or not lines[0].startswith(
        "(serde_v1 (verifier_kernel_evidence "
    ):
        raise ServiceError("verifier kernel did not emit canonical evidence")
    try:
        summary = json.loads(lines[1])
    except json.JSONDecodeError as exc:
        raise ServiceError("verifier kernel summary is not JSON") from exc
    return (
        output,
        validate_summary(summary, suite),
        wall_seconds,
        peak_rss_bytes,
    )


def sign_receipt(payload: dict[str, Any], key: bytes) -> dict[str, Any]:
    if set(payload) != PAYLOAD_KEYS:
        raise ServiceError("receipt payload has unexpected fields")
    signature = hmac.new(key, canonical_json(payload), hashlib.sha256).hexdigest()
    body = {"payload": payload, "signature": signature}
    return {
        **body,
        "receipt_digest": sha256_bytes(canonical_json(body)),
    }


def verify_receipt(receipt: dict[str, Any], key: bytes) -> dict[str, Any]:
    if not isinstance(receipt, dict) or set(receipt) != RECEIPT_KEYS:
        raise ServiceError("receipt has unexpected fields")
    payload = receipt["payload"]
    if not isinstance(payload, dict) or set(payload) != PAYLOAD_KEYS:
        raise ServiceError("receipt payload has unexpected fields")
    signature = receipt["signature"]
    digest = receipt["receipt_digest"]
    if not isinstance(signature, str) or not SHA256_PATTERN.fullmatch(signature):
        raise ServiceError("receipt signature is invalid")
    expected_signature = hmac.new(
        key, canonical_json(payload), hashlib.sha256
    ).hexdigest()
    if not hmac.compare_digest(signature, expected_signature):
        raise ServiceError("receipt authentication failed")
    expected_digest = sha256_bytes(
        canonical_json({"payload": payload, "signature": signature})
    )
    if not isinstance(digest, str) or not hmac.compare_digest(digest, expected_digest):
        raise ServiceError("receipt digest mismatch")
    return payload


def journal_records(path: Path) -> list[dict[str, Any]]:
    require_outside_worktree(path, "verification journal")
    if not path.exists():
        return []
    raw = require_private_file(
        path, "verification journal", maximum_bytes=MAX_JOURNAL_BYTES
    )
    if raw and not raw.endswith(b"\n"):
        raise ServiceError("verification journal has a partial final record")
    records = []
    for line in raw.splitlines(keepends=True):
        if len(line) > MAX_KERNEL_OUTPUT_BYTES + MAX_CANDIDATE_BYTES + 16_384:
            raise ServiceError("verification journal record exceeds its byte limit")
        try:
            record = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ServiceError("verification journal contains invalid JSON") from exc
        if line != canonical_json(record) + b"\n":
            raise ServiceError("verification journal record is not canonical JSON")
        records.append(record)
    if len(records) > MAX_JOURNAL_RECORDS:
        raise ServiceError("verification journal exceeds its record limit")
    return records


def verify_journal(
    path: Path,
    key: bytes,
    suite_raw: bytes,
    suite: dict[str, Any],
) -> list[dict[str, Any]]:
    records = journal_records(path)
    expected_previous = GENESIS
    expected_suite_digest = sha256_bytes(suite_raw)
    expected_kernel_digest = sha256_file(KERNEL)
    expected_case_ids = {case["id"] for case in suite["cases"]}
    for sequence, record in enumerate(records):
        if not isinstance(record, dict) or set(record) != JOURNAL_RECORD_KEYS:
            raise ServiceError("verification journal record has unexpected fields")
        if record["schema"] != 1:
            raise ServiceError("verification journal schema mismatch")
        candidate_source = record["candidate_source"]
        kernel_output = record["kernel_output"]
        if not isinstance(candidate_source, str) or not isinstance(kernel_output, str):
            raise ServiceError("verification journal evidence must be strings")
        payload = verify_receipt(record["receipt"], key)
        if type(payload["schema"]) is not int or payload["schema"] != 1:
            raise ServiceError("verification journal receipt schema mismatch")
        if payload["verifier_id"] != VERIFIER_ID:
            raise ServiceError("verification journal verifier identity mismatch")
        if type(payload["sequence"]) is not int or payload["sequence"] != sequence:
            raise ServiceError("verification journal sequence mismatch")
        if payload["previous_receipt_digest"] != expected_previous:
            raise ServiceError("verification journal chain mismatch")
        for digest_field in (
            "suite_sha256",
            "kernel_sha256",
            "candidate_digest",
            "candidate_source_sha256",
            "failure_codes_sha256",
            "previous_receipt_digest",
            "kernel_output_sha256",
        ):
            digest_value = payload[digest_field]
            if digest_field == "previous_receipt_digest" and digest_value == GENESIS:
                continue
            if not isinstance(digest_value, str) or not SHA256_PATTERN.fullmatch(
                digest_value
            ):
                raise ServiceError(
                    f"verification journal {digest_field} is invalid"
                )
        if payload["suite_sha256"] != expected_suite_digest:
            raise ServiceError("verification journal suite digest mismatch")
        if payload["kernel_sha256"] != expected_kernel_digest:
            raise ServiceError("verification journal kernel digest mismatch")
        if payload["candidate_source_sha256"] != sha256_bytes(
            candidate_source.encode("utf-8")
        ):
            raise ServiceError("verification journal candidate source mismatch")
        if payload["kernel_output_sha256"] != sha256_bytes(
            kernel_output.encode("utf-8")
        ):
            raise ServiceError("verification journal kernel evidence mismatch")
        kernel_wall_seconds = payload["kernel_wall_seconds"]
        if not isinstance(kernel_wall_seconds, (int, float)) or isinstance(
            kernel_wall_seconds, bool
        ) or not (0 < kernel_wall_seconds <= MAX_KERNEL_WALL_SECONDS):
            raise ServiceError("verification journal kernel wall time is invalid")
        kernel_peak_rss_bytes = payload["kernel_peak_rss_bytes"]
        if type(kernel_peak_rss_bytes) is not int or not (
            0 < kernel_peak_rss_bytes <= MAX_KERNEL_PEAK_RSS_BYTES
        ):
            raise ServiceError("verification journal kernel peak RSS is invalid")
        lines = kernel_output.splitlines()
        if len(lines) != 2:
            raise ServiceError("verification journal kernel evidence is malformed")
        try:
            summary = json.loads(lines[1])
        except json.JSONDecodeError as exc:
            raise ServiceError("verification journal summary is malformed") from exc
        validate_summary(summary, suite)
        if summary["candidate_digest"] != payload["candidate_digest"]:
            raise ServiceError("verification journal candidate digest mismatch")
        for field in ("passed", "tests_passed", "tests_total"):
            if summary[field] != payload[field]:
                raise ServiceError(f"verification journal {field} mismatch")
        if summary["tests_total"] != len(suite["cases"]):
            raise ServiceError("verification journal test total mismatch")
        if any(code not in expected_case_ids for code in summary["failure_codes"]):
            raise ServiceError("verification journal failure code mismatch")
        if payload["failure_codes_sha256"] != sha256_bytes(
            canonical_json(summary["failure_codes"])
        ):
            raise ServiceError("verification journal failure digest mismatch")
        if not isinstance(payload["request_id"], str) or not REQUEST_ID_PATTERN.fullmatch(
            payload["request_id"]
        ):
            raise ServiceError("verification journal request id is invalid")
        timestamp = payload["verified_at_utc"]
        if not isinstance(timestamp, str) or not timestamp.endswith("Z"):
            raise ServiceError("verification journal timestamp is invalid")
        try:
            dt.datetime.fromisoformat(timestamp[:-1] + "+00:00")
        except ValueError as exc:
            raise ServiceError("verification journal timestamp is invalid") from exc
        expected_previous = record["receipt"]["receipt_digest"]
    return records


def append_journal(path: Path, record: dict[str, Any]) -> None:
    try:
        require_outside_worktree(path, "verification journal")
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists() and (path.is_symlink() or not path.is_file()):
            raise AuthorityError("verification journal must be a regular file")
        flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags, 0o600)
        try:
            os.fchmod(descriptor, 0o600)
            payload = canonical_json(record) + b"\n"
            written = 0
            while written < len(payload):
                count = os.write(descriptor, payload[written:])
                if count <= 0:
                    raise AuthorityError(
                        "verification journal append made no progress"
                    )
                written += count
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except AuthorityError:
        raise
    except (OSError, ServiceError) as exc:
        raise AuthorityError("verification journal append failed") from exc


def read_exact(connection: socket.socket, count: int) -> bytes:
    result = bytearray()
    while len(result) < count:
        chunk = connection.recv(count - len(result))
        if not chunk:
            raise ServiceError("submission channel closed mid-message")
        result.extend(chunk)
    return bytes(result)


def receive_message(connection: socket.socket) -> dict[str, Any]:
    header = read_exact(connection, 4)
    length = struct.unpack(">I", header)[0]
    if length <= 0 or length > MAX_MESSAGE_BYTES:
        raise ServiceError("submission message exceeds its byte limit")
    try:
        value = json.loads(read_exact(connection, length))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ServiceError("submission message is not valid JSON") from exc
    if not isinstance(value, dict):
        raise ServiceError("submission message must be one JSON object")
    return value


def send_message(connection: socket.socket, value: dict[str, Any]) -> None:
    payload = canonical_json(value)
    if len(payload) > MAX_MESSAGE_BYTES:
        raise ServiceError("response exceeds its byte limit")
    connection.sendall(struct.pack(">I", len(payload)) + payload)


def validate_request(request: dict[str, Any], expected_head: str) -> None:
    if set(request) != REQUEST_KEYS or request.get("schema") != 1:
        raise ServiceError("submission request has unexpected fields")
    request_id = request["request_id"]
    if not isinstance(request_id, str) or not REQUEST_ID_PATTERN.fullmatch(request_id):
        raise ServiceError("submission request id is invalid")
    if request["expected_previous_receipt_digest"] != expected_head:
        raise ServiceError("submission expected head is stale")
    candidate_source = request["candidate_source"]
    if not isinstance(candidate_source, str):
        raise ServiceError("candidate source must be a string")
    encoded = candidate_source.encode("utf-8")
    if not encoded or len(encoded) > MAX_CANDIDATE_BYTES or "\0" in candidate_source:
        raise ServiceError("candidate source must contain 1..16384 UTF-8 bytes")


def process_submission(
    request: dict[str, Any],
    *,
    suite_path: Path,
    suite_raw: bytes,
    suite: dict[str, Any],
    key: bytes,
    journal_path: Path,
    existing_records: list[dict[str, Any]],
) -> tuple[dict[str, Any], dict[str, Any]]:
    previous = (
        GENESIS
        if not existing_records
        else existing_records[-1]["receipt"]["receipt_digest"]
    )
    validate_request(request, previous)
    candidate_source = request["candidate_source"]
    kernel_output, summary, kernel_wall_seconds, kernel_peak_rss_bytes = run_kernel(
        candidate_source, suite_path, suite
    )
    verified_at = (
        dt.datetime.now(dt.timezone.utc)
        .isoformat(timespec="microseconds")
        .replace("+00:00", "Z")
    )
    payload = {
        "schema": 1,
        "verifier_id": VERIFIER_ID,
        "sequence": len(existing_records),
        "request_id": request["request_id"],
        "suite_sha256": sha256_bytes(suite_raw),
        "kernel_sha256": sha256_file(KERNEL),
        "candidate_digest": summary["candidate_digest"],
        "candidate_source_sha256": sha256_bytes(candidate_source.encode("utf-8")),
        "passed": summary["passed"],
        "tests_passed": summary["tests_passed"],
        "tests_total": summary["tests_total"],
        "failure_codes_sha256": sha256_bytes(
            canonical_json(summary["failure_codes"])
        ),
        "previous_receipt_digest": previous,
        "kernel_output_sha256": sha256_bytes(kernel_output.encode("utf-8")),
        "kernel_wall_seconds": kernel_wall_seconds,
        "kernel_peak_rss_bytes": kernel_peak_rss_bytes,
        "verified_at_utc": verified_at,
    }
    receipt = sign_receipt(payload, key)
    record = {
        "schema": 1,
        "receipt": receipt,
        "candidate_source": candidate_source,
        "kernel_output": kernel_output,
    }
    append_journal(journal_path, record)
    response = {
        "schema": 1,
        "request_id": request["request_id"],
        "status": "promoted" if summary["passed"] else "rejected",
        "candidate_digest": summary["candidate_digest"],
        "receipt_digest": receipt["receipt_digest"],
    }
    if set(response) != SAFE_RESPONSE_KEYS:
        raise ServiceError("internal response projection changed")
    return record, response


def serve(
    socket_path: Path,
    suite_path: Path,
    key_path: Path,
    journal_path: Path,
    *,
    max_requests: int,
    idle_timeout_seconds: float,
) -> None:
    if not 1 <= max_requests <= MAX_JOURNAL_RECORDS:
        raise ServiceError("max_requests must be in 1..10000")
    if not 1.0 <= idle_timeout_seconds <= 3600.0:
        raise ServiceError("idle_timeout_seconds must be in 1..3600")
    for path, label in (
        (socket_path, "submission socket"),
        (suite_path, "verifier suite"),
        (key_path, "verifier key"),
        (journal_path, "verification journal"),
    ):
        require_outside_worktree(path, label)
    if socket_path.exists() or socket_path.is_symlink():
        raise ServiceError("refusing to replace an existing submission socket")
    suite_raw, suite = load_suite(suite_path)
    key = load_key(key_path)
    records = verify_journal(journal_path, key, suite_raw, suite)
    if not GENE.is_file() or not os.access(GENE, os.X_OK):
        raise ServiceError("Gene verifier executable is unavailable")
    if not KERNEL.is_file():
        raise ServiceError("Gene verifier kernel is unavailable")
    timed_prefix()
    sha256_file(KERNEL)
    if len(records) + max_requests > MAX_JOURNAL_RECORDS:
        raise ServiceError("max_requests would exceed the journal record limit")
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        listener.bind(str(socket_path))
        os.chmod(socket_path, 0o600)
        listener.listen(8)
        listener.settimeout(idle_timeout_seconds)
        for _ in range(max_requests):
            try:
                connection, _ = listener.accept()
            except socket.timeout as exc:
                raise ServiceError("submission service timed out waiting for a request") from exc
            with connection:
                connection.settimeout(5.0)
                request_id = "0" * 32
                try:
                    request = receive_message(connection)
                    if isinstance(request.get("request_id"), str) and (
                        REQUEST_ID_PATTERN.fullmatch(request["request_id"])
                    ):
                        request_id = request["request_id"]
                    record, response = process_submission(
                        request,
                        suite_path=suite_path,
                        suite_raw=suite_raw,
                        suite=suite,
                        key=key,
                        journal_path=journal_path,
                        existing_records=records,
                    )
                    records.append(record)
                except AuthorityError:
                    raise
                except (ServiceError, OSError, UnicodeError) as exc:
                    print(f"rejected submission: {exc}", file=sys.stderr)
                    response = {
                        "schema": 1,
                        "request_id": request_id,
                        "status": "error",
                        "error_code": "invalid_submission",
                    }
                try:
                    send_message(connection, response)
                except OSError as exc:
                    print(f"submission response disconnected: {exc}", file=sys.stderr)
    finally:
        listener.close()
        if socket_path.is_socket():
            socket_path.unlink()


def submit(socket_path: Path, request: dict[str, Any]) -> dict[str, Any]:
    require_outside_worktree(socket_path, "submission socket")
    payload = canonical_json(request)
    if len(payload) > MAX_MESSAGE_BYTES:
        raise ServiceError("submission message exceeds its byte limit")
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.settimeout(5.0)
        connection.connect(str(socket_path))
        connection.sendall(struct.pack(">I", len(payload)) + payload)
        response = receive_message(connection)
    finally:
        connection.close()
    if set(response) == ERROR_RESPONSE_KEYS:
        if (
            response.get("schema") != 1
            or response.get("request_id") != request.get("request_id")
            or response.get("status") != "error"
            or response.get("error_code") != "invalid_submission"
        ):
            raise ServiceError("submission error response is invalid")
        return response
    if set(response) != SAFE_RESPONSE_KEYS:
        raise ServiceError("submission response exposes unexpected fields")
    if response.get("schema") != 1 or response.get("request_id") != request.get(
        "request_id"
    ):
        raise ServiceError("submission response identity mismatch")
    if response.get("status") not in {"promoted", "rejected"}:
        raise ServiceError("submission response status is invalid")
    for field in ("candidate_digest", "receipt_digest"):
        if not isinstance(response.get(field), str) or not SHA256_PATTERN.fullmatch(
            response[field]
        ):
            raise ServiceError(f"submission response {field} is invalid")
    return response


def submit_encoded(socket_path: Path, payload: bytes) -> dict[str, Any]:
    require_outside_worktree(socket_path, "submission socket")
    if not payload or len(payload) > MAX_MESSAGE_BYTES:
        raise ServiceError("encoded submission exceeds its byte limit")
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.settimeout(5.0)
        connection.connect(str(socket_path))
        connection.sendall(struct.pack(">I", len(payload)) + payload)
        return receive_message(connection)
    finally:
        connection.close()


def serve_command(args: argparse.Namespace) -> None:
    serve(
        Path(args.socket),
        Path(args.suite),
        Path(args.key),
        Path(args.journal),
        max_requests=args.max_requests,
        idle_timeout_seconds=args.idle_timeout_seconds,
    )


def submit_command(args: argparse.Namespace) -> None:
    request = {
        "schema": 1,
        "request_id": args.request_id or os.urandom(16).hex(),
        "expected_previous_receipt_digest": args.expected_head,
        "candidate_source": args.candidate_source,
    }
    print(json.dumps(submit(Path(args.socket), request), sort_keys=True))


def verify_command(args: argparse.Namespace) -> None:
    suite_raw, suite = load_suite(Path(args.suite))
    key = load_key(Path(args.key))
    records = verify_journal(Path(args.journal), key, suite_raw, suite)
    head = GENESIS if not records else records[-1]["receipt"]["receipt_digest"]
    promotions = sum(1 for record in records if record["receipt"]["payload"]["passed"])
    print(f"verified records: {len(records)}")
    print(f"verified promotions: {promotions}")
    print(f"verified head: {head}")


def promotions_command(args: argparse.Namespace) -> None:
    suite_raw, suite = load_suite(Path(args.suite))
    key = load_key(Path(args.key))
    records = verify_journal(Path(args.journal), key, suite_raw, suite)
    promotions = [
        {
            "candidate_source": record["candidate_source"],
            "candidate_digest": record["receipt"]["payload"]["candidate_digest"],
            "receipt_digest": record["receipt"]["receipt_digest"],
            "sequence": record["receipt"]["payload"]["sequence"],
        }
        for record in records
        if record["receipt"]["payload"]["passed"]
    ]
    print(json.dumps({"schema": 1, "promotions": promotions}, sort_keys=True))


def write_private(path: Path, value: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        written = 0
        while written < len(value):
            count = os.write(descriptor, value[written:])
            if count <= 0:
                raise ServiceError("private test fixture write made no progress")
            written += count
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def wait_for_socket(path: Path, process: subprocess.Popen[str]) -> None:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if path.is_socket():
            return
        if process.poll() is not None:
            stdout, stderr = process.communicate()
            raise ServiceError(
                "verifier service exited before binding: " + (stderr or stdout).strip()
            )
        time.sleep(0.01)
    process.send_signal(signal.SIGTERM)
    raise ServiceError("verifier service did not bind within five seconds")


def excluded_boundary_suite() -> dict[str, Any]:
    return {
        "schema": 1,
        "suite_id": "excluded_boundary_pilot_v1",
        "cases": [
            {"id": "case_1", "input": " Hello World ", "expected": "hello_world"},
            {"id": "case_2", "input": "MIXED Case", "expected": "mixed_case"},
            {"id": "case_3", "input": "already_clean", "expected": "already_clean"},
            {"id": "case_4", "input": " Two  Spaces ", "expected": "two__spaces"},
        ],
    }


def self_test_command(_: argparse.Namespace) -> None:
    suite = excluded_boundary_suite()
    passing = (
        '(skill_candidate ^id "normalize" ^name "normalize" ^version 1 '
        "^preconditions [] ^effects [] ^provenance [] "
        '(pipeline (trim) (lowercase) (replace ^from " " ^to "_")))'
    )
    failing = (
        '(skill_candidate ^id "trim_only" ^name "trim_only" ^version 1 '
        "^preconditions [] ^effects [] ^provenance [] (pipeline (trim)))"
    )
    with tempfile.TemporaryDirectory(prefix="skill-verifier-service-") as root_name:
        root = Path(root_name)
        suite_path = root / "suite.json"
        key_path = root / "key.bin"
        journal_path = root / "journal.jsonl"
        socket_path = root / "submit.sock"
        suite_bytes = canonical_json(suite) + b"\n"
        write_private(suite_path, suite_bytes)
        write_private(key_path, os.urandom(32))
        process = subprocess.Popen(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "serve",
                "--socket",
                str(socket_path),
                "--suite",
                str(suite_path),
                "--key",
                str(key_path),
                "--journal",
                str(journal_path),
                "--max-requests",
                "4",
            ],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        wait_for_socket(socket_path, process)
        invalid_unicode_request_id = "03" * 16
        invalid_unicode_payload = (
            '{"candidate_source":"\\ud800",'
            '"expected_previous_receipt_digest":"genesis",'
            '"request_id":"'
            + invalid_unicode_request_id
            + '","schema":1}'
        ).encode("ascii")
        invalid_unicode = submit_encoded(socket_path, invalid_unicode_payload)
        if invalid_unicode != {
            "schema": 1,
            "request_id": invalid_unicode_request_id,
            "status": "error",
            "error_code": "invalid_submission",
        }:
            raise ServiceError("invalid-Unicode submission was not safely rejected")
        stale_request = {
            "schema": 1,
            "request_id": "00" * 16,
            "expected_previous_receipt_digest": "not_the_head",
            "candidate_source": passing,
        }
        stale = submit(socket_path, stale_request)
        if stale != {
            "schema": 1,
            "request_id": "00" * 16,
            "status": "error",
            "error_code": "invalid_submission",
        }:
            raise ServiceError("stale-chain submission was not safely rejected")
        first_request = {
            "schema": 1,
            "request_id": "01" * 16,
            "expected_previous_receipt_digest": GENESIS,
            "candidate_source": passing,
        }
        first = submit(socket_path, first_request)
        if first["status"] != "promoted":
            raise ServiceError("passing boundary candidate was not promoted")
        second_request = {
            "schema": 1,
            "request_id": "02" * 16,
            "expected_previous_receipt_digest": first["receipt_digest"],
            "candidate_source": failing,
        }
        second = submit(socket_path, second_request)
        if second["status"] != "rejected":
            raise ServiceError("failing boundary candidate was promoted")
        stdout, stderr = process.communicate(timeout=5.0)
        if process.returncode != 0:
            raise ServiceError("verifier service failed: " + (stderr or stdout).strip())
        response_text = (
            canonical_json(invalid_unicode).decode()
            + canonical_json(stale).decode()
            + canonical_json(first).decode()
            + canonical_json(second).decode()
        )
        if any(case["id"] in response_text for case in suite["cases"]):
            raise ServiceError("safe submitter response exposed a test identifier")
        if "tests_passed" in response_text or str(suite_path) in response_text:
            raise ServiceError("safe submitter response exposed verifier internals")

        suite_raw, loaded_suite = load_suite(suite_path)
        key = load_key(key_path)
        records = verify_journal(journal_path, key, suite_raw, loaded_suite)
        if len(records) != 2:
            raise ServiceError("authenticated journal has the wrong record count")
        if sum(1 for record in records if record["receipt"]["payload"]["passed"]) != 1:
            raise ServiceError("authenticated journal has the wrong promotion count")
        maximum_kernel_wall_seconds = max(
            record["receipt"]["payload"]["kernel_wall_seconds"]
            for record in records
        )
        maximum_kernel_peak_rss_bytes = max(
            record["receipt"]["payload"]["kernel_peak_rss_bytes"]
            for record in records
        )

        candidate_mutation = root / "candidate-mutated.jsonl"
        mutated_records = json.loads(json.dumps(records))
        mutated_records[0]["candidate_source"] += " "
        write_private(
            candidate_mutation,
            b"".join(canonical_json(record) + b"\n" for record in mutated_records),
        )
        candidate_mutation_rejected = False
        try:
            verify_journal(candidate_mutation, key, suite_raw, loaded_suite)
        except ServiceError:
            candidate_mutation_rejected = True
        if not candidate_mutation_rejected:
            raise ServiceError("mutated promoted candidate was accepted")

        signature_mutation = root / "signature-mutated.jsonl"
        forged_records = json.loads(json.dumps(records))
        forged_records[0]["receipt"]["payload"]["passed"] = False
        write_private(
            signature_mutation,
            b"".join(canonical_json(record) + b"\n" for record in forged_records),
        )
        signature_mutation_rejected = False
        try:
            verify_journal(signature_mutation, key, suite_raw, loaded_suite)
        except ServiceError:
            signature_mutation_rejected = True
        if not signature_mutation_rejected:
            raise ServiceError("forged verifier receipt was accepted")

        suite_path.write_bytes(suite_bytes.replace(b"case_4", b"case_x"))
        os.chmod(suite_path, 0o600)
        suite_mutation_rejected = False
        try:
            changed_raw, changed_suite = load_suite(suite_path)
            verify_journal(journal_path, key, changed_raw, changed_suite)
        except ServiceError:
            suite_mutation_rejected = True
        if not suite_mutation_rejected:
            raise ServiceError("mutated verifier suite was accepted")

        in_tree_rejected = False
        try:
            require_outside_worktree(ROOT / "forbidden.sock", "submission socket")
        except ServiceError:
            in_tree_rejected = True
        if not in_tree_rejected:
            raise ServiceError("agent-worktree verifier authority was accepted")

    print("verifier service self-test: promoted=1 rejected=1")
    print("submitter-visible test details: 0")
    print("authenticated journal records: 2")
    print(f"maximum kernel wall seconds: {maximum_kernel_wall_seconds:.6f}")
    print(f"maximum kernel peak RSS bytes: {maximum_kernel_peak_rss_bytes}")
    print("stale chain rejected without service exit: true")
    print("invalid Unicode rejected without service exit: true")
    print("candidate mutation rejected: true")
    print("receipt forgery rejected: true")
    print("suite mutation rejected: true")
    print("in-worktree authority rejected: true")


def model_pilot_command(args: argparse.Namespace) -> None:
    output_path = Path(args.output).resolve()
    if not 1 <= args.max_rounds <= 8:
        raise ServiceError("model pilot max_rounds must be in 1..8")
    suite = excluded_boundary_suite()
    with tempfile.TemporaryDirectory(prefix="skill-verifier-model-pilot-") as root_name:
        root = Path(root_name)
        suite_path = root / "suite.json"
        key_path = root / "key.bin"
        journal_path = root / "journal.jsonl"
        socket_path = root / "submit.sock"
        suite_bytes = canonical_json(suite) + b"\n"
        write_private(suite_path, suite_bytes)
        write_private(key_path, os.urandom(32))
        service = subprocess.Popen(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "serve",
                "--socket",
                str(socket_path),
                "--suite",
                str(suite_path),
                "--key",
                str(key_path),
                "--journal",
                str(journal_path),
                "--max-requests",
                str(args.max_rounds),
                "--idle-timeout-seconds",
                str(min(max(args.timeout_seconds, 60.0), 3600.0)),
            ],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        wait_for_socket(socket_path, service)
        try:
            completed = subprocess.run(
                [
                    sys.executable,
                    str(MODEL_ADAPTER),
                    "--model",
                    args.model,
                    "--output",
                    str(output_path),
                    "--max-rounds",
                    str(args.max_rounds),
                    "--verifier-socket",
                    str(socket_path),
                    "--expected-head",
                    GENESIS,
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=args.timeout_seconds,
                check=False,
            )
        finally:
            if service.poll() is None:
                service.terminate()
            try:
                service_stdout, service_stderr = service.communicate(timeout=5.0)
            except subprocess.TimeoutExpired:
                service.kill()
                service_stdout, service_stderr = service.communicate()
        if completed.returncode != 0:
            detail = (completed.stderr or completed.stdout).strip()
            raise ServiceError(f"model-facing boundary pilot failed: {detail}")
        if service.returncode not in {0, -signal.SIGTERM}:
            detail = (service_stderr or service_stdout).strip()
            raise ServiceError(f"verifier service failed during model pilot: {detail}")
        suite_raw, loaded_suite = load_suite(suite_path)
        key = load_key(key_path)
        records = verify_journal(journal_path, key, suite_raw, loaded_suite)
        if not records or not records[-1]["receipt"]["payload"]["passed"]:
            raise ServiceError("trusted consumer found no final promotion")
        report = json.loads(output_path.read_text(encoding="utf-8"))
        final_receipt_digest = records[-1]["receipt"]["receipt_digest"]
        if report.get("final_receipt_digest") != final_receipt_digest:
            raise ServiceError("model report and authenticated journal head differ")
        serialized_report = canonical_json(report).decode("utf-8")
        for forbidden in (
            "tests_passed",
            "tests_total",
            suite["suite_id"],
            str(suite_path),
            str(key_path),
        ):
            if forbidden in serialized_report:
                raise ServiceError("model-facing report exposes verifier internals")
        report["trusted_consumer"] = {
            "schema": 1,
            "authenticated_records": len(records),
            "authenticated_promotions": sum(
                int(record["receipt"]["payload"]["passed"])
                for record in records
            ),
            "authenticated_head": final_receipt_digest,
            "suite_sha256": sha256_bytes(suite_raw),
            "kernel_sha256": sha256_file(KERNEL),
            "maximum_kernel_wall_seconds": max(
                record["receipt"]["payload"]["kernel_wall_seconds"]
                for record in records
            ),
            "maximum_kernel_peak_rss_bytes": max(
                record["receipt"]["payload"]["kernel_peak_rss_bytes"]
                for record in records
            ),
            "model_visible_test_details": 0,
        }
        output_path.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    print(completed.stdout, end="")
    print(f"authenticated model-service records: {len(records)}")
    print(f"authenticated model-service head: {final_receipt_digest}")
    print("model-visible test details: 0")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subcommands = root.add_subparsers(dest="command", required=True)

    serve_parser = subcommands.add_parser("serve", help="run the private verifier")
    serve_parser.add_argument("--socket", required=True)
    serve_parser.add_argument("--suite", required=True)
    serve_parser.add_argument("--key", required=True)
    serve_parser.add_argument("--journal", required=True)
    serve_parser.add_argument("--max-requests", type=int, required=True)
    serve_parser.add_argument("--idle-timeout-seconds", type=float, default=10.0)
    serve_parser.set_defaults(handler=serve_command)

    submit_parser = subcommands.add_parser(
        "submit", help="submit one candidate over the narrow agent channel"
    )
    submit_parser.add_argument("--socket", required=True)
    submit_parser.add_argument("--candidate-source", required=True)
    submit_parser.add_argument("--expected-head", required=True)
    submit_parser.add_argument("--request-id")
    submit_parser.set_defaults(handler=submit_command)

    verify_parser = subcommands.add_parser(
        "verify-journal", help="authenticate the verifier-owned journal"
    )
    verify_parser.add_argument("--suite", required=True)
    verify_parser.add_argument("--key", required=True)
    verify_parser.add_argument("--journal", required=True)
    verify_parser.set_defaults(handler=verify_command)

    promotions_parser = subcommands.add_parser(
        "list-promotions", help="list trusted promotions after authentication"
    )
    promotions_parser.add_argument("--suite", required=True)
    promotions_parser.add_argument("--key", required=True)
    promotions_parser.add_argument("--journal", required=True)
    promotions_parser.set_defaults(handler=promotions_command)

    self_test = subcommands.add_parser(
        "self-test", help="exercise the boundary with excluded toy cases"
    )
    self_test.set_defaults(handler=self_test_command)

    model_pilot = subcommands.add_parser(
        "model-pilot",
        help="run the qualified model through an ephemeral excluded boundary",
    )
    model_pilot.add_argument("--model", default="gpt-oss:20b")
    model_pilot.add_argument("--output", required=True)
    model_pilot.add_argument("--max-rounds", type=int, default=6)
    model_pilot.add_argument("--timeout-seconds", type=float, default=600.0)
    model_pilot.set_defaults(handler=model_pilot_command)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        args.handler(args)
    except (ServiceError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"verifier service error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
