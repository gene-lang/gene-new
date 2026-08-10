#!/usr/bin/env python3
"""Run the frozen-candidate 20-task local-model qualification gate.

The harness uses only Python's standard library and Ollama's native chat API.
Every task starts with a fresh conversation and can reach only three mock
tools. The authoritative result is an accepted submit_artifact call; free-form
model text is never treated as success.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


OLLAMA_URL = "http://127.0.0.1:11434"
OPERATIONS = {
    "uppercase",
    "lowercase",
    "reverse",
    "sort_csv",
    "unique_csv",
    "sum_ints",
    "join",
    "replace",
    "count_words",
}

FACTS = {
    "color_primary": "cobalt",
    "greek_letter": "λ",
    "phrase_mixed": "Gene Nodes",
    "reverse_source": "drawer",
    "csv_fruits": "pear,apple,pear,plum",
    "numbers_a": "17,4,23,6",
    "left_word": "exact",
    "right_word": "evidence",
    "pointer_start": "pointer_target",
    "pointer_target": "durable_skill",
    "current_alpha": "recovered",
    "current_beta": "second_recovery",
    "template": "hello {name}",
    "word_phrase": "belief before harmful action",
    "part_a": "learned",
    "part_b": "proposal",
    "part_c": "verified",
    "operation_spec": "sort",
    "operation_payload": "zeta,alpha,beta",
    "needs_transform": "mixed Case",
    "transform_rule": "uppercase",
    "number_left": "19",
    "number_right": "23",
    "chain_one": "exact",
    "chain_two": "symbolic",
    "chain_three": "state",
    "final_key": "qualified",
}

MISSING_SUGGESTIONS = {
    "stale_alpha": "current_alpha",
    "stale_beta": "current_beta",
    "legacy_final": "final_key",
}


@dataclass(frozen=True)
class Task:
    task_id: str
    category: str
    prompt: str
    expected: str


TASKS = [
    Task("q01", "typed_call", "Fetch color_primary and submit its exact value.", "cobalt"),
    Task("q02", "typed_call", "Fetch greek_letter and submit its exact value.", "λ"),
    Task(
        "q03",
        "typed_call",
        "Fetch phrase_mixed, uppercase it with run_operation, and submit the result.",
        "GENE NODES",
    ),
    Task(
        "q04",
        "typed_call",
        "Fetch phrase_mixed, lowercase it with run_operation, and submit the result.",
        "gene nodes",
    ),
    Task(
        "q05",
        "typed_call",
        "Fetch reverse_source, reverse it with run_operation, and submit the result.",
        "reward",
    ),
    Task(
        "q06",
        "multi_step",
        "Fetch csv_fruits, sort its comma-separated items with run_operation, and submit.",
        "apple,pear,pear,plum",
    ),
    Task(
        "q07",
        "multi_step",
        "Fetch csv_fruits, remove duplicate comma-separated items with run_operation, and submit.",
        "pear,apple,plum",
    ),
    Task(
        "q08",
        "multi_step",
        "Fetch numbers_a, sum its comma-separated integers with run_operation, and submit.",
        "50",
    ),
    Task(
        "q09",
        "multi_step",
        "Fetch left_word and right_word, join their values with | using run_operation, and submit.",
        "exact|evidence",
    ),
    Task(
        "q10",
        "multi_step",
        "Fetch pointer_start. Its value is another fact key; fetch that key and submit the final value.",
        "durable_skill",
    ),
    Task(
        "q11",
        "error_recovery",
        "Fetch stale_alpha. Follow any tool error suggestion, then submit the recovered value.",
        "recovered",
    ),
    Task(
        "q12",
        "error_recovery",
        "Fetch stale_beta. Follow any tool error suggestion, uppercase the recovered value, and submit.",
        "SECOND_RECOVERY",
    ),
    Task(
        "q13",
        "multi_step",
        "Fetch template and replace {name} with Gene using run_operation, then submit.",
        "hello Gene",
    ),
    Task(
        "q14",
        "typed_call",
        "Fetch word_phrase, count its whitespace-separated words with run_operation, and submit the count.",
        "4",
    ),
    Task(
        "q15",
        "multi_step",
        "Fetch part_a, part_b, and part_c; join them in that order with / and submit.",
        "learned/proposal/verified",
    ),
    Task(
        "q16",
        "error_recovery",
        "Fetch operation_spec and operation_payload. Try the named operation on the payload; if the tool rejects it, follow its suggestion and submit the result.",
        "alpha,beta,zeta",
    ),
    Task(
        "q17",
        "submission_recovery",
        "Fetch needs_transform and submit its raw value first. If submission is rejected, fetch transform_rule, apply that operation, and resubmit.",
        "MIXED CASE",
    ),
    Task(
        "q18",
        "multi_step",
        "Fetch number_left and number_right, sum both values with run_operation, and submit.",
        "42",
    ),
    Task(
        "q19",
        "multi_step",
        "Fetch chain_one, chain_two, and chain_three; join them in order with a single space and submit.",
        "exact symbolic state",
    ),
    Task(
        "q20",
        "error_recovery",
        "Fetch legacy_final. Follow any tool error suggestion, uppercase the recovered value, and submit.",
        "QUALIFIED",
    ),
]


TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_fact",
            "description": "Fetch one exact string value by key. Unknown keys return a recovery suggestion when one exists.",
            "parameters": {
                "type": "object",
                "additionalProperties": False,
                "required": ["key"],
                "properties": {"key": {"type": "string"}},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_operation",
            "description": "Run a deterministic string operation. Supported operations: uppercase, lowercase, reverse, sort_csv, unique_csv, sum_ints, join, replace, count_words.",
            "parameters": {
                "type": "object",
                "additionalProperties": False,
                "required": ["operation", "inputs"],
                "properties": {
                    "operation": {"type": "string"},
                    "inputs": {"type": "array", "items": {"type": "string"}},
                    "separator": {"type": "string"},
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "submit_artifact",
            "description": "Submit the exact final artifact to the isolated verifier. A rejected artifact may be corrected and resubmitted.",
            "parameters": {
                "type": "object",
                "additionalProperties": False,
                "required": ["task_id", "artifact"],
                "properties": {
                    "task_id": {"type": "string"},
                    "artifact": {"type": "string"},
                },
            },
        },
    },
]


SYSTEM_PROMPT = """You are in a deterministic local-model qualification loop.
Use the supplied tools to solve the task. Do not guess fact values. The only
successful completion is an accepted submit_artifact call with the task_id from
the user message. If a tool or submission returns an error, inspect it, correct
the call, and continue. Keep tool arguments exactly within their schemas."""


def post_json(path: str, payload: dict[str, Any], timeout: int = 300) -> dict[str, Any]:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        OLLAMA_URL + path,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def get_json(path: str, timeout: int = 30) -> dict[str, Any]:
    with urllib.request.urlopen(OLLAMA_URL + path, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def validate_arguments(name: str, arguments: Any) -> tuple[bool, str]:
    if not isinstance(arguments, dict):
        return False, "arguments must be an object"
    if name == "get_fact":
        if set(arguments) != {"key"} or not isinstance(arguments.get("key"), str):
            return False, "get_fact expects exactly string key"
        return True, ""
    if name == "run_operation":
        if not {"operation", "inputs"} <= set(arguments):
            return False, "run_operation requires operation and inputs"
        if set(arguments) - {"operation", "inputs", "separator"}:
            return False, "run_operation got extra fields"
        if not isinstance(arguments["operation"], str):
            return False, "operation must be a string"
        if not isinstance(arguments["inputs"], list) or not all(
            isinstance(item, str) for item in arguments["inputs"]
        ):
            return False, "inputs must be a string array"
        if "separator" in arguments and not isinstance(arguments["separator"], str):
            return False, "separator must be a string"
        return True, ""
    if name == "submit_artifact":
        if set(arguments) != {"task_id", "artifact"}:
            return False, "submit_artifact expects exactly task_id and artifact"
        if not all(isinstance(arguments[key], str) for key in arguments):
            return False, "submission fields must be strings"
        return True, ""
    return False, "unknown tool"


def operation_result(arguments: dict[str, Any]) -> dict[str, Any]:
    operation = arguments["operation"]
    inputs = arguments["inputs"]
    if operation not in OPERATIONS:
        suggestion = "sort_csv" if operation == "sort" else None
        result = {"ok": False, "error": f"unsupported operation: {operation}"}
        if suggestion:
            result["suggestion"] = suggestion
        return result
    try:
        if operation == "uppercase" and len(inputs) == 1:
            value = inputs[0].upper()
        elif operation == "lowercase" and len(inputs) == 1:
            value = inputs[0].lower()
        elif operation == "reverse" and len(inputs) == 1:
            value = inputs[0][::-1]
        elif operation == "sort_csv" and len(inputs) == 1:
            value = ",".join(sorted(inputs[0].split(",")))
        elif operation == "unique_csv" and len(inputs) == 1:
            value = ",".join(dict.fromkeys(inputs[0].split(",")))
        elif operation == "sum_ints" and inputs:
            values = []
            for item in inputs:
                values.extend(int(part) for part in item.split(","))
            value = str(sum(values))
        elif operation == "join" and inputs:
            value = arguments.get("separator", "").join(inputs)
        elif operation == "replace" and len(inputs) == 3:
            value = inputs[0].replace(inputs[1], inputs[2])
        elif operation == "count_words" and len(inputs) == 1:
            value = str(len(inputs[0].split()))
        else:
            return {"ok": False, "error": "wrong input count for operation"}
    except (TypeError, ValueError) as error:
        return {"ok": False, "error": str(error)}
    return {"ok": True, "value": value}


def execute_tool(
    task: Task, name: str, arguments: dict[str, Any]
) -> tuple[dict[str, Any], bool, bool]:
    """Return result, accepted submission, and rejected submission."""
    if name == "get_fact":
        key = arguments["key"]
        if key in FACTS:
            return {"ok": True, "key": key, "value": FACTS[key]}, False, False
        result = {"ok": False, "error": f"unknown fact key: {key}"}
        if key in MISSING_SUGGESTIONS:
            result["suggestion"] = MISSING_SUGGESTIONS[key]
        return result, False, False
    if name == "run_operation":
        return operation_result(arguments), False, False
    if name == "submit_artifact":
        accepted = (
            arguments["task_id"] == task.task_id
            and arguments["artifact"] == task.expected
        )
        if accepted:
            return {"ok": True, "accepted": True}, True, False
        return {
            "ok": False,
            "accepted": False,
            "error": "artifact rejected",
        }, False, True
    raise AssertionError(name)


def chat_payload(
    model: str,
    messages: list[dict[str, Any]],
    think: str | None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "tools": TOOLS,
        "stream": False,
        "keep_alive": "10m",
        "options": {
            "temperature": 0,
            "seed": 20260809,
            "num_ctx": 32768,
            "num_predict": 1024,
        },
    }
    # Reasoning-effort control, added after the stage-two gate showed liveness
    # depends on it. Omitted entirely at default effort, so a default-effort
    # request stays byte-identical to the 2026-08-09 qualification run.
    if think is not None:
        payload["think"] = think
    return payload


def run_task(
    model: str,
    task: Task,
    max_rounds: int,
    think: str | None = None,
) -> dict[str, Any]:
    messages: list[dict[str, Any]] = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {
            "role": "user",
            "content": f"task_id={task.task_id}\n{task.prompt}",
        },
    ]
    valid_calls = 0
    total_calls = 0
    rejected_submissions = 0
    accepted = False
    context_failure = False
    errors: list[str] = []
    rounds = 0
    prompt_tokens = 0
    generated_tokens = 0
    total_duration_ns = 0
    started = time.monotonic()

    for rounds in range(1, max_rounds + 1):
        try:
            response = post_json(
                "/api/chat", chat_payload(model, messages, think)
            )
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
            detail = str(error)
            if isinstance(error, urllib.error.HTTPError):
                detail += ": " + error.read().decode("utf-8", errors="replace")
            errors.append(detail)
            context_failure = "context" in detail.lower()
            break

        prompt_tokens += int(response.get("prompt_eval_count", 0))
        generated_tokens += int(response.get("eval_count", 0))
        total_duration_ns += int(response.get("total_duration", 0))
        message = response.get("message")
        if not isinstance(message, dict):
            errors.append("response message missing")
            break
        messages.append(message)
        calls = message.get("tool_calls") or []
        if not isinstance(calls, list):
            errors.append("tool_calls was not a list")
            break
        if not calls:
            errors.append("model stopped without accepted submission")
            break

        for call in calls:
            total_calls += 1
            function = call.get("function") if isinstance(call, dict) else None
            name = function.get("name") if isinstance(function, dict) else None
            arguments = function.get("arguments") if isinstance(function, dict) else None
            valid, validation_error = validate_arguments(name, arguments)
            if valid:
                valid_calls += 1
                result, call_accepted, call_rejected = execute_tool(
                    task, name, arguments
                )
                accepted = accepted or call_accepted
                rejected_submissions += int(call_rejected)
            else:
                result = {"ok": False, "error": validation_error}
                errors.append(f"invalid typed call {name!r}: {validation_error}")
            messages.append(
                {
                    "role": "tool",
                    "tool_name": name if isinstance(name, str) else "invalid_tool",
                    "content": canonical_json(result),
                }
            )
        if accepted:
            break

    return {
        "task_id": task.task_id,
        "category": task.category,
        "passed": accepted,
        "rounds": rounds,
        "valid_typed_calls": valid_calls,
        "total_tool_calls": total_calls,
        "rejected_submissions": rejected_submissions,
        "context_failure": context_failure,
        "errors": errors,
        "prompt_tokens": prompt_tokens,
        "generated_tokens": generated_tokens,
        "ollama_duration_ns": total_duration_ns,
        "wall_seconds": time.monotonic() - started,
    }


def sysctl(name: str) -> str | None:
    completed = subprocess.run(
        ["sysctl", "-n", name], capture_output=True, text=True, check=False
    )
    return completed.stdout.strip() if completed.returncode == 0 else None


def model_metadata(model: str) -> dict[str, Any]:
    show = post_json("/api/show", {"model": model}, timeout=60)
    tags = get_json("/api/tags").get("models", [])
    tag = next(
        (
            item
            for item in tags
            if item.get("name") == model or item.get("model") == model
        ),
        {},
    )
    manifest_path = None
    manifest_sha256 = None
    manifest_config = None
    manifest_layers = None
    parts = model.split(":", 1)
    model_name = parts[0]
    model_tag = parts[1] if len(parts) == 2 else "latest"
    candidate = (
        Path.home()
        / ".ollama/models/manifests/registry.ollama.ai/library"
        / model_name
        / model_tag
    )
    if candidate.is_file():
        manifest_path = str(candidate)
        manifest_bytes = candidate.read_bytes()
        manifest_sha256 = hashlib.sha256(manifest_bytes).hexdigest()
        manifest = json.loads(manifest_bytes)
        manifest_config = manifest.get("config")
        manifest_layers = manifest.get("layers")
    return {
        "requested_name": model,
        "resolved_name": tag.get("name"),
        "manifest_digest": tag.get("digest"),
        "size_bytes": tag.get("size"),
        "details": tag.get("details"),
        "capabilities": show.get("capabilities"),
        "model_info": show.get("model_info"),
        "parameters": show.get("parameters"),
        "template_sha256": hashlib.sha256(
            str(show.get("template", "")).encode("utf-8")
        ).hexdigest(),
        "manifest_path": manifest_path,
        "manifest_sha256": manifest_sha256,
        "manifest_config": manifest_config,
        "manifest_layers": manifest_layers,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--max-rounds", type=int, default=8)
    # Reasoning-effort control. Omitting it reproduces the default-effort
    # 2026-08-09 qualification request exactly.
    parser.add_argument("--think", choices=["low", "medium"], default=None)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.max_rounds < 1:
        raise SystemExit("--max-rounds must be positive")
    version = get_json("/api/version").get("version")
    metadata = model_metadata(args.model)
    results = []
    started = time.monotonic()
    for task in TASKS:
        result = run_task(args.model, task, args.max_rounds, args.think)
        results.append(result)
        status = "PASS" if result["passed"] else "FAIL"
        print(
            f"{task.task_id} {status} rounds={result['rounds']} "
            f"typed={result['valid_typed_calls']}/{result['total_tool_calls']} "
            f"wall={result['wall_seconds']:.2f}s",
            flush=True,
        )

    passed = sum(int(result["passed"]) for result in results)
    valid_calls = sum(result["valid_typed_calls"] for result in results)
    total_calls = sum(result["total_tool_calls"] for result in results)
    conformance = valid_calls / total_calls if total_calls else 0.0
    context_failures = sum(int(result["context_failure"]) for result in results)
    wall_seconds = time.monotonic() - started
    task_walls = sorted(result["wall_seconds"] for result in results)
    p95_wall_seconds = task_walls[math.ceil(0.95 * len(task_walls)) - 1]
    generated_tokens = sum(result["generated_tokens"] for result in results)
    running_models = get_json("/api/ps").get("models", [])
    running = next(
        (
            item
            for item in running_models
            if item.get("name") == metadata.get("resolved_name")
            or item.get("model") == metadata.get("resolved_name")
        ),
        {},
    )
    gib = 1024**3
    artifact_ok = int(metadata.get("size_bytes") or 0) <= 20_000_000_000
    allocation_bytes = int(running.get("size_vram") or running.get("size") or 0)
    resources_ok = (
        artifact_ok
        and allocation_bytes <= 36 * gib
        and wall_seconds <= 3600
        and p95_wall_seconds <= 180
        and generated_tokens <= 40000
    )
    report = {
        "schema": "gene.local_model_qualification.v1",
        "date_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "ollama": {
            "version": version,
            "url": OLLAMA_URL,
            "chat_endpoint": "/api/chat",
        },
        "model": metadata,
        "decoding": {
            "temperature": 0,
            "seed": 20260809,
            "num_ctx": 32768,
            "num_predict": 1024,
            "reasoning_effort": args.think or "default",
            "max_tool_rounds": args.max_rounds,
        },
        "hardware": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "mac_model": sysctl("hw.model"),
            "memory_bytes": int(sysctl("hw.memsize") or 0),
        },
        "summary": {
            "passed_tasks": passed,
            "total_tasks": len(TASKS),
            "valid_typed_calls": valid_calls,
            "total_tool_calls": total_calls,
            "typed_call_conformance": conformance,
            "context_failures": context_failures,
            "generated_tokens": generated_tokens,
            "wall_seconds": wall_seconds,
            "p95_task_wall_seconds": p95_wall_seconds,
            "loaded_allocation_bytes": allocation_bytes,
            "resources_within_envelope": resources_ok,
            "eligible": (
                passed >= 12
                and conformance >= 0.95
                and context_failures == 0
                and resources_ok
            ),
        },
        "tasks": results,
    }
    output = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output, encoding="utf-8")
    else:
        print(output)
    return 0 if report["summary"]["eligible"] else 1


if __name__ == "__main__":
    sys.exit(main())
