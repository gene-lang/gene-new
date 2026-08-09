#!/usr/bin/env python3
"""Run the excluded experiment-4 plain-agent difficulty pilot.

Each task starts a fresh qualified-model conversation with only two typed tools.
The host owns the current list, executes one closed primitive per accepted tool
call, and accepts only an exact target trace plus exact output. The 20 default
tasks and both seeds are permanently excluded from treatment.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import resource
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
OLLAMA_URL = "http://127.0.0.1:11434"
EXPORTER = ROOT / "examples/general_intelligence/src/lifelong_task_pilot_export.gene"
SUBJECT = ROOT / "examples/general_intelligence/src/lifelong_task_subject.gene"
INTERPRETER = ROOT / "examples/general_intelligence/src/library_induction.gene"
OPERATIONS = [
    "tail",
    "init",
    "reverse",
    "rotate_left",
    "rotate_right",
    "map_add_one",
    "map_sub_one",
    "map_double",
    "map_negate",
    "keep_even",
    "keep_odd",
    "duplicate_each",
]
SYSTEM_PROMPT = """Execute the user's exact list workflow using only tools.
Call apply_operation once for every described operation, in the stated order,
then call submit_result. The host maintains the current list. Do not calculate
the answer in text, skip a step, add a step, or change the order. Multiple tool
calls in one response are allowed, and only an accepted submit_result counts."""
APPLY_TOOL = {
    "type": "function",
    "function": {
        "name": "apply_operation",
        "description": "Apply one exact operation to the task's current integer list.",
        "parameters": {
            "type": "object",
            "additionalProperties": False,
            "required": ["operation"],
            "properties": {
                "operation": {"type": "string", "enum": OPERATIONS},
            },
        },
    },
}
SUBMIT_TOOL = {
    "type": "function",
    "function": {
        "name": "submit_result",
        "description": "Submit the host-maintained list and exact operation trace.",
        "parameters": {
            "type": "object",
            "additionalProperties": False,
            "properties": {},
        },
    },
}


class PilotError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


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


def load_tasks(
    catalog_seed: int,
    order_seed: int,
    count: int,
    composition_arity: int,
) -> tuple[list[dict[str, Any]], float]:
    started = time.monotonic()
    completed = subprocess.run(
        [
            str(ROOT / "bin/gene"),
            "run",
            str(EXPORTER),
            str(catalog_seed),
            str(order_seed),
            str(count),
            str(composition_arity),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    wall_seconds = time.monotonic() - started
    if completed.returncode != 0:
        raise PilotError((completed.stderr or completed.stdout).strip())
    tasks = []
    for line in completed.stdout.splitlines():
        try:
            task = json.loads(line)
        except json.JSONDecodeError as exc:
            raise PilotError("task exporter emitted invalid JSON") from exc
        if not isinstance(task, dict) or set(task) != {
            "schema",
            "id",
            "goal",
            "input",
            "expected",
            "operations",
        }:
            raise PilotError("task exporter emitted an unexpected schema")
        if task["schema"] != 1 or not isinstance(task["id"], str):
            raise PilotError("task exporter identity is invalid")
        if not isinstance(task["goal"], str) or not task["goal"]:
            raise PilotError("task goal is invalid")
        for field in ("input", "expected"):
            if not isinstance(task[field], list) or any(
                type(item) is not int for item in task[field]
            ):
                raise PilotError(f"task {field} is invalid")
        if not isinstance(task["operations"], list) or len(task["operations"]) != (
            composition_arity * 3
        ):
            raise PilotError("task target operation count does not match its arity")
        if any(operation not in OPERATIONS for operation in task["operations"]):
            raise PilotError("task contains an unknown operation")
        if apply_program(task["input"], task["operations"]) != task["expected"]:
            raise PilotError("Python executor disagrees with Gene task output")
        tasks.append(task)
    if len(tasks) != count:
        raise PilotError("task exporter returned the wrong task count")
    return tasks, wall_seconds


def apply_operation(value: list[int], operation: str) -> list[int]:
    if operation == "tail":
        return value[1:] if len(value) > 1 else []
    if operation == "init":
        return value[:-1] if len(value) > 1 else []
    if operation == "reverse":
        return list(reversed(value))
    if operation == "rotate_left":
        return value[1:] + value[:1] if len(value) > 1 else list(value)
    if operation == "rotate_right":
        return value[-1:] + value[:-1] if len(value) > 1 else list(value)
    if operation == "map_add_one":
        return [item + 1 for item in value]
    if operation == "map_sub_one":
        return [item - 1 for item in value]
    if operation == "map_double":
        return [item * 2 for item in value]
    if operation == "map_negate":
        return [-item for item in value]
    if operation == "keep_even":
        return [item for item in value if item % 2 == 0]
    if operation == "keep_odd":
        return [item for item in value if item % 2 != 0]
    if operation == "duplicate_each":
        return [copy for item in value for copy in (item, item)]
    raise PilotError("unknown operation reached the exact executor")


def apply_program(value: list[int], operations: list[str]) -> list[int]:
    result = list(value)
    for operation in operations:
        result = apply_operation(result, operation)
    return result


def run_task(model: str, task: dict[str, Any], max_rounds: int) -> dict[str, Any]:
    messages: list[dict[str, Any]] = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {
            "role": "user",
            "content": task["goal"] + " Initial list: " + json.dumps(task["input"]),
        },
    ]
    current = list(task["input"])
    trace: list[str] = []
    accepted = False
    schema_conformant_calls = 0
    tool_calls = 0
    prompt_tokens = 0
    generated_tokens = 0
    started = time.monotonic()
    rounds = 0
    for rounds in range(1, max_rounds + 1):
        response = post_json(
            "/api/chat",
            {
                "model": model,
                "messages": messages,
                "tools": [APPLY_TOOL, SUBMIT_TOOL],
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
            tool_calls += 1
            function = call.get("function") if isinstance(call, dict) else None
            name = function.get("name") if isinstance(function, dict) else None
            arguments = function.get("arguments") if isinstance(function, dict) else None
            result: dict[str, Any]
            conformant = False
            if name == "apply_operation":
                conformant = (
                    isinstance(arguments, dict)
                    and set(arguments) == {"operation"}
                    and arguments["operation"] in OPERATIONS
                )
                if conformant:
                    operation = arguments["operation"]
                    current = apply_operation(current, operation)
                    trace.append(operation)
                    result = {
                        "status": "ok",
                        "step_index": len(trace),
                        "current": current,
                    }
                else:
                    result = {"status": "error", "error": "invalid_operation_call"}
            elif name == "submit_result":
                conformant = isinstance(arguments, dict) and not arguments
                accepted = conformant and (
                    trace == task["operations"] and current == task["expected"]
                )
                result = {"status": "accepted" if accepted else "rejected"}
            else:
                result = {"status": "error", "error": "unknown_tool"}
            schema_conformant_calls += int(conformant)
            messages.append(
                {
                    "role": "tool",
                    "tool_name": name if isinstance(name, str) else "invalid_tool",
                    "content": json.dumps(result, sort_keys=True),
                }
            )
            if accepted:
                break
        if accepted:
            break
    return {
        "id": task["id"],
        "accepted": accepted,
        "rounds": rounds,
        "tool_calls": tool_calls,
        "schema_conformant_calls": schema_conformant_calls,
        "prompt_tokens": prompt_tokens,
        "generated_tokens": generated_tokens,
        "wall_seconds": time.monotonic() - started,
        "target_operations": task["operations"],
        "observed_trace": trace,
        "final_value_sha256": hashlib.sha256(
            json.dumps(current, separators=(",", ":")).encode()
        ).hexdigest(),
    }


def peak_rss_bytes() -> int:
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return int(value if platform.system() == "Darwin" else value * 1024)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="gpt-oss:20b")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--catalog-seed", type=int, default=900501)
    parser.add_argument("--order-seed", type=int, default=900502)
    parser.add_argument("--count", type=int, default=20)
    parser.add_argument("--max-rounds", type=int, default=8)
    parser.add_argument("--composition-arity", type=int, default=2)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not 1 <= args.count <= 60:
        raise PilotError("count must be in 1..60")
    if not 1 <= args.max_rounds <= 24:
        raise PilotError("max_rounds must be in 1..24")
    if not 2 <= args.composition_arity <= 8:
        raise PilotError("composition_arity must be in 2..8")
    started = time.monotonic()
    tasks, export_wall_seconds = load_tasks(
        args.catalog_seed,
        args.order_seed,
        args.count,
        args.composition_arity,
    )
    outcomes = []
    for index, task in enumerate(tasks):
        outcome = run_task(args.model, task, args.max_rounds)
        outcomes.append(outcome)
        print(
            f"task={index + 1}/{len(tasks)} accepted={str(outcome['accepted']).lower()} "
            f"rounds={outcome['rounds']} calls={outcome['tool_calls']}",
            flush=True,
        )
    accepted = sum(int(outcome["accepted"]) for outcome in outcomes)
    success_rate = accepted / len(outcomes)
    frontier_passed = 0.25 <= success_rate <= 0.75
    show = post_json("/api/show", {"model": args.model}, timeout=60)
    tags = get_json("/api/tags").get("models", [])
    tag = next((item for item in tags if item.get("name") == args.model), {})
    running = get_json("/api/ps").get("models", [])
    loaded = next((item for item in running if item.get("name") == args.model), {})
    report = {
        "schema": "gene.lifelong_task_difficulty_pilot.v1",
        "date_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "harness_sha256": sha256_file(Path(__file__).resolve()),
        "exporter_sha256": sha256_file(EXPORTER),
        "subject_sha256": sha256_file(SUBJECT),
        "interpreter_sha256": sha256_file(INTERPRETER),
        "model": {
            "name": args.model,
            "manifest_digest": tag.get("digest"),
            "capabilities": show.get("capabilities"),
            "loaded_size_bytes": loaded.get("size"),
            "loaded_vram_bytes": loaded.get("size_vram"),
        },
        "seeds": {
            "catalog": args.catalog_seed,
            "order_and_cases": args.order_seed,
            "permanently_excluded": True,
        },
        "composition_arity": args.composition_arity,
        "decoding": {
            "temperature": 0,
            "seed": 20260809,
            "num_ctx": 32768,
            "num_predict": 1024,
            "max_rounds": args.max_rounds,
        },
        "gate": {
            "minimum_success_rate": 0.25,
            "maximum_success_rate": 0.75,
            "passed": frontier_passed,
        },
        "summary": {
            "tasks": len(outcomes),
            "accepted": accepted,
            "success_rate": success_rate,
            "tool_calls": sum(item["tool_calls"] for item in outcomes),
            "schema_conformant_calls": sum(
                item["schema_conformant_calls"] for item in outcomes
            ),
            "prompt_tokens": sum(item["prompt_tokens"] for item in outcomes),
            "generated_tokens": sum(item["generated_tokens"] for item in outcomes),
            "export_wall_seconds": export_wall_seconds,
            "total_wall_seconds": time.monotonic() - started,
            "harness_peak_rss_bytes": peak_rss_bytes(),
        },
        "outcomes": outcomes,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        f"difficulty gate: accepted={accepted}/{len(outcomes)} "
        f"rate={success_rate:.3f} passed={str(frontier_passed).lower()}"
    )
    return 0 if frontier_passed else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PilotError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"lifelong difficulty pilot error: {exc}", file=sys.stderr)
        raise SystemExit(2)
