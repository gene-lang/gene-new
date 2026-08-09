#!/usr/bin/env python3
"""Run the non-evaluation local-model -> exact-verifier skill pilot.

The model receives one typed submit_skill tool and no file, shell, or test
capability. A separate Gene process owns the toy cases and is authoritative:
model text never counts as promotion. This is a mechanism pilot, not the
lifelong experiment or its production deployment boundary.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any


OLLAMA_URL = "http://127.0.0.1:11434"
VERIFIER = Path("examples/general_intelligence/src/skill_verifier_pilot.gene")
RECEIPT_PATTERN = re.compile(r'\^receipt_digest "([0-9a-f]{64})"')

SYSTEM_PROMPT = """You propose one reusable declarative skill. You have only
submit_skill; you cannot read files, run commands, or inspect verifier tests.
Solve the user's requested transformation by submitting a bounded pipeline.
Only the verifier's accepted response counts as success. If rejected, revise
the candidate using the safe aggregate result. Keep all fields inside schema."""

USER_PROMPT = """Create skill normalize_words version 1. It must take a string,
trim surrounding whitespace, lowercase it, and replace every space with an
underscore. Declare the precondition and effect plainly, cite mechanism_pilot
as provenance. The steps field must be exactly the string array
["trim", "lowercase", "replace"]. Submit it for verification."""

TOOL = {
    "type": "function",
    "function": {
        "name": "submit_skill",
        "description": "Submit a bounded declarative string pipeline to the independent verifier.",
        "parameters": {
            "type": "object",
            "additionalProperties": False,
            "required": [
                "id",
                "name",
                "version",
                "precondition",
                "effect",
                "provenance",
                "steps",
                "replace_from",
                "replace_to",
            ],
            "properties": {
                "id": {"type": "string"},
                "name": {"type": "string"},
                "version": {"type": "integer"},
                "precondition": {"type": "string"},
                "effect": {"type": "string"},
                "provenance": {"type": "string"},
                "steps": {
                    "type": "array",
                    "description": "Use exactly [trim, lowercase, replace] in that order.",
                    "items": {
                        "type": "string",
                        "enum": ["trim", "lowercase", "replace"],
                    },
                },
                "replace_from": {"type": "string"},
                "replace_to": {"type": "string"},
            },
        },
    },
}


def post_json(path: str, payload: dict[str, Any], timeout: int = 300) -> dict[str, Any]:
    request = urllib.request.Request(
        OLLAMA_URL + path,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def get_json(path: str) -> dict[str, Any]:
    with urllib.request.urlopen(OLLAMA_URL + path, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def gene_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def validate_candidate(arguments: Any) -> str | None:
    if not isinstance(arguments, dict):
        return "arguments must be an object"
    required = {
        "id",
        "name",
        "version",
        "precondition",
        "effect",
        "provenance",
        "steps",
        "replace_from",
        "replace_to",
    }
    if set(arguments) != required:
        return "arguments must contain exactly the declared fields"
    string_fields = required - {"version", "steps"}
    if not all(isinstance(arguments[key], str) for key in string_fields):
        return "every field except version must be a string"
    if not isinstance(arguments["version"], int) or isinstance(
        arguments["version"], bool
    ):
        return "version must be an integer"
    steps = arguments["steps"]
    if not isinstance(steps, list) or not all(isinstance(item, str) for item in steps):
        return "steps must be a string array"
    if any(item not in {"trim", "lowercase", "replace"} for item in steps):
        return 'steps may contain only "trim", "lowercase", and "replace"'
    return None


def candidate_source(arguments: dict[str, Any]) -> str:
    steps = []
    for operation in arguments["steps"]:
        if operation == "replace":
            steps.append(
                "(replace ^from "
                + gene_string(arguments["replace_from"])
                + " ^to "
                + gene_string(arguments["replace_to"])
                + ")"
            )
        else:
            steps.append(f"({operation})")
    return (
        "(skill_candidate"
        f" ^id {gene_string(arguments['id'])}"
        f" ^name {gene_string(arguments['name'])}"
        f" ^version {arguments['version']}"
        f" ^preconditions [{gene_string(arguments['precondition'])}]"
        f" ^effects [{gene_string(arguments['effect'])}]"
        f" ^provenance [{gene_string(arguments['provenance'])}]"
        " (pipeline "
        + " ".join(steps)
        + "))"
    )


def submit(arguments: Any) -> tuple[dict[str, Any], dict[str, Any]]:
    problem = validate_candidate(arguments)
    if problem:
        return {"accepted": False, "error": problem}, {
            "schema_conformant": False,
            "error": problem,
        }
    source = candidate_source(arguments)
    started = time.monotonic()
    completed = subprocess.run(
        ["bin/gene", "run", str(VERIFIER), source, "genesis"],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    wall_seconds = time.monotonic() - started
    promoted = completed.returncode == 0 and '^status "promoted"' in completed.stdout
    tests_match = re.search(r"\^tests_passed (\d+) \^tests_total (\d+)", completed.stdout)
    receipt_match = RECEIPT_PATTERN.search(completed.stdout)
    safe_result: dict[str, Any] = {
        "accepted": promoted,
        "tests_passed": int(tests_match.group(1)) if tests_match else 0,
        "tests_total": int(tests_match.group(2)) if tests_match else 0,
    }
    if receipt_match:
        safe_result["receipt_digest"] = receipt_match.group(1)
    if completed.returncode != 0:
        safe_result["error"] = "verifier process failed"
    audit = {
        "schema_conformant": True,
        "candidate_source": source,
        "candidate_source_sha256": hashlib.sha256(source.encode()).hexdigest(),
        "verifier_exit_code": completed.returncode,
        "verifier_output_sha256": hashlib.sha256(completed.stdout.encode()).hexdigest(),
        "verifier_wall_seconds": wall_seconds,
        "accepted": promoted,
        "tests_passed": safe_result["tests_passed"],
        "tests_total": safe_result["tests_total"],
        "receipt_digest": safe_result.get("receipt_digest"),
    }
    return safe_result, audit


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="gpt-oss:20b")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-rounds", type=int, default=6)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    messages: list[dict[str, Any]] = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": USER_PROMPT},
    ]
    submissions: list[dict[str, Any]] = []
    accepted = False
    prompt_tokens = 0
    generated_tokens = 0
    rounds = 0
    started = time.monotonic()

    for rounds in range(1, args.max_rounds + 1):
        response = post_json(
            "/api/chat",
            {
                "model": args.model,
                "messages": messages,
                "tools": [TOOL],
                "stream": False,
                "keep_alive": "10m",
                "options": {
                    "temperature": 0,
                    "seed": 20260809,
                    "num_ctx": 32768,
                    "num_predict": 1024,
                },
            },
        )
        prompt_tokens += int(response.get("prompt_eval_count", 0))
        generated_tokens += int(response.get("eval_count", 0))
        message = response.get("message")
        if not isinstance(message, dict):
            break
        messages.append(message)
        calls = message.get("tool_calls") or []
        if not isinstance(calls, list) or not calls:
            break
        for call in calls:
            function = call.get("function") if isinstance(call, dict) else None
            name = function.get("name") if isinstance(function, dict) else None
            arguments = function.get("arguments") if isinstance(function, dict) else None
            if name == "submit_skill":
                result, audit = submit(arguments)
            else:
                result = {"accepted": False, "error": "unknown tool"}
                audit = {"schema_conformant": False, "error": "unknown tool"}
            submissions.append(audit)
            messages.append(
                {
                    "role": "tool",
                    "tool_name": name if isinstance(name, str) else "invalid_tool",
                    "content": json.dumps(result, sort_keys=True),
                }
            )
            if result.get("accepted") is True:
                accepted = True
                break
        print(
            f"round={rounds} submissions={len(submissions)} accepted={str(accepted).lower()}",
            flush=True,
        )
        if accepted:
            break

    show = post_json("/api/show", {"model": args.model}, timeout=60)
    tags = get_json("/api/tags").get("models", [])
    tag = next((item for item in tags if item.get("name") == args.model), {})
    report = {
        "schema": "gene.verified_skill_agent_pilot.v3",
        "date_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "verifier_sha256": hashlib.sha256(VERIFIER.read_bytes()).hexdigest(),
        "model": {
            "name": args.model,
            "manifest_digest": tag.get("digest"),
            "capabilities": show.get("capabilities"),
        },
        "decoding": {
            "temperature": 0,
            "seed": 20260809,
            "num_ctx": 32768,
            "num_predict": 1024,
            "max_rounds": args.max_rounds,
        },
        "summary": {
            "accepted": accepted,
            "rounds": rounds,
            "submissions": len(submissions),
            "schema_conformant_submissions": sum(
                int(item.get("schema_conformant") is True) for item in submissions
            ),
            "prompt_tokens": prompt_tokens,
            "generated_tokens": generated_tokens,
            "wall_seconds": time.monotonic() - started,
        },
        "submissions": submissions,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return 0 if accepted else 1


if __name__ == "__main__":
    sys.exit(main())
