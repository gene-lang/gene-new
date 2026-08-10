#!/usr/bin/env python3
"""Stage-two local-model qualification: can a candidate finish one round's
inference inside one round's generation budget?

The 2026-08-09 stage-one gate passed `gpt-oss:20b` at roughly 62 generated
tokens per call on shallow mock-tool tasks. The same model then fell silent on
79 to 80 percent of rounds across two experiment-4 version-3 runs, because each
round required inverting a three-operation program from three examples. This
stage isolates exactly that round.

Each task shows three input/output demonstrations of a hidden three-operation
program over the closed 12-primitive integer-list catalog. The model has one
tool. The host checks a candidate against only those three public
demonstrations, so this stage inherits version 3's public-only checker and adds
no hidden oracle. The twelve tasks are fixed here, cover all 12 primitives, and
are permanently excluded from every experiment.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import resource
import statistics
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any


OLLAMA_URL = "http://127.0.0.1:11434"
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
OPERATION_HELP = {
    "tail": "remove the first item",
    "init": "remove the last item",
    "reverse": "reverse item order",
    "rotate_left": "move the first item to the end",
    "rotate_right": "move the last item to the front",
    "map_add_one": "add one to every item",
    "map_sub_one": "subtract one from every item",
    "map_double": "double every item",
    "map_negate": "negate every item",
    "keep_even": "keep only even items",
    "keep_odd": "keep only odd items",
    "duplicate_each": "duplicate every item in place",
}
PROGRAM_LENGTH = 3
# Demonstration inputs are fixed and disjoint from every experiment-4
# demonstration pack.
DEMONSTRATION_INPUTS = [
    [2, -1, 3, 0, 4],
    [-2, 5, 1, -3],
    [3, 3, -2, 1, 0],
]
# Twelve hidden programs, covering all 12 primitives, permanently excluded from
# every experiment.
HIDDEN_PROGRAMS = [
    ("tail", "reverse", "map_add_one"),
    ("init", "map_double", "keep_even"),
    ("rotate_left", "map_negate", "duplicate_each"),
    ("rotate_right", "keep_odd", "map_sub_one"),
    ("map_double", "map_add_one", "reverse"),
    ("duplicate_each", "tail", "map_negate"),
    ("keep_even", "rotate_right", "map_double"),
    ("map_sub_one", "keep_odd", "init"),
    ("reverse", "rotate_left", "map_sub_one"),
    ("map_negate", "duplicate_each", "keep_even"),
    ("tail", "init", "rotate_right"),
    ("keep_odd", "map_add_one", "rotate_left"),
]
ATTEMPTS_PER_TASK = 2
ROUND_CEILING = 5
SILENT_ROUND_CAP = 3
NUM_PREDICT = 1024
MINIMUM_LIVENESS_RATE = 0.90
MINIMUM_SOLVE_RATE = 0.50
SYSTEM_PROMPT = """Infer a hidden list transformation from three examples.
The transformation is exactly three operations from this catalog, applied in
order:
{catalog}
Send your three operations with submit_program. They are checked against the
three examples you were given and nothing else. If they do not reproduce all
three, you get status inconsistent and one more attempt.
Your response is cut off at a hard generation limit, so keep reasoning short and
return a tool call in every response; a response with no tool call wastes a
round.""".format(
    catalog="; ".join(f"{name}: {OPERATION_HELP[name]}" for name in OPERATIONS)
)
SILENT_ROUND_REMINDER = (
    "Your previous response reached the generation limit without a tool call. "
    "Do not restate your reasoning. Send submit_program now with your best "
    "three operations."
)
SUBMIT_TOOL = {
    "type": "function",
    "function": {
        "name": "submit_program",
        "description": "Submit the three catalog operations, in order.",
        "parameters": {
            "type": "object",
            "additionalProperties": False,
            "required": ["operations"],
            "properties": {
                "operations": {
                    "type": "array",
                    "description": "Exactly three catalog operations, in order.",
                    "items": {"type": "string", "enum": OPERATIONS},
                },
            },
        },
    },
}
TOOLS = [SUBMIT_TOOL]


class QualificationError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


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
    raise QualificationError("unknown operation reached the exact executor")


def apply_program(value: list[int], operations: list[str]) -> list[int]:
    result = list(value)
    for operation in operations:
        result = apply_operation(result, operation)
    return result


def enumerate_programs(maximum_length: int = PROGRAM_LENGTH) -> list[tuple]:
    programs: list[tuple] = [()]
    frontier: list[tuple] = [()]
    for _ in range(maximum_length):
        extended = [prefix + (name,) for prefix in frontier for name in OPERATIONS]
        programs.extend(extended)
        frontier = extended
    return programs


ALL_PROGRAMS = enumerate_programs()


def build_tasks() -> list[dict[str, Any]]:
    tasks = []
    for index, program in enumerate(HIDDEN_PROGRAMS):
        demonstrations = [
            {"input": value, "output": apply_program(value, list(program))}
            for value in DEMONSTRATION_INPUTS
        ]
        admissible = [
            candidate
            for candidate in ALL_PROGRAMS
            if all(
                apply_program(item["input"], list(candidate)) == item["output"]
                for item in demonstrations
            )
        ]
        tasks.append(
            {
                "id": f"depth_{index:02d}",
                "demonstrations": demonstrations,
                "hidden_program": list(program),
                "admissible_candidates": len(admissible),
            }
        )
    return tasks


def public_projection(task: dict[str, Any]) -> dict[str, Any]:
    return {
        "task_id": task["id"],
        "examples": task["demonstrations"],
        "operations_per_program": PROGRAM_LENGTH,
        "attempts": ATTEMPTS_PER_TASK,
    }


def schema_conformant(name: Any, arguments: Any) -> bool:
    return (
        name == "submit_program"
        and isinstance(arguments, dict)
        and set(arguments) == {"operations"}
        and isinstance(arguments["operations"], list)
        and len(arguments["operations"]) == PROGRAM_LENGTH
        and all(
            isinstance(item, str) and item in OPERATIONS
            for item in arguments["operations"]
        )
    )


def consistent(task: dict[str, Any], operations: list[str]) -> bool:
    return all(
        apply_program(item["input"], operations) == item["output"]
        for item in task["demonstrations"]
    )


def chat_payload(
    model: str,
    messages: list[dict[str, Any]],
    num_predict: int,
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
            "num_predict": num_predict,
        },
    }
    # Reasoning-effort control. Omitted entirely at default effort so the
    # baseline request stays byte-identical to the 2026-08-10 run.
    if think is not None:
        payload["think"] = think
    return payload


def run_task(
    model: str,
    task: dict[str, Any],
    num_predict: int,
    think: str | None = None,
) -> dict[str, Any]:
    user_message = canonical_json(public_projection(task))
    messages: list[dict[str, Any]] = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": user_message},
    ]
    accepted = False
    attempts = 0
    silent_rounds = 0
    tool_calls = 0
    conformant_calls = 0
    prompt_tokens = 0
    generated_tokens = 0
    round_tokens: list[int] = []
    end_reason = "round_limit"
    rounds = 0
    started = time.monotonic()
    finished = False
    for rounds in range(1, ROUND_CEILING + 1):
        response = post_json(
            "/api/chat", chat_payload(model, messages, num_predict, think)
        )
        prompt_tokens += int(response.get("prompt_eval_count", 0))
        emitted = int(response.get("eval_count", 0))
        generated_tokens += emitted
        round_tokens.append(emitted)
        message = response.get("message")
        if not isinstance(message, dict):
            end_reason = "empty_response"
            break
        messages.append(message)
        calls = message.get("tool_calls") or []
        if not isinstance(calls, list) or not calls:
            silent_rounds += 1
            if silent_rounds > SILENT_ROUND_CAP:
                end_reason = "silent_round_limit"
                break
            messages.append({"role": "user", "content": SILENT_ROUND_REMINDER})
            continue
        for call in calls:
            tool_calls += 1
            function = call.get("function") if isinstance(call, dict) else None
            name = function.get("name") if isinstance(function, dict) else None
            arguments = function.get("arguments") if isinstance(function, dict) else None
            if not schema_conformant(name, arguments):
                result = {"status": "invalid_request"}
            else:
                conformant_calls += 1
                attempts += 1
                if consistent(task, list(arguments["operations"])):
                    accepted = True
                    result = {"status": "accepted"}
                    end_reason = "accepted"
                    finished = True
                elif attempts >= ATTEMPTS_PER_TASK:
                    result = {"status": "attempts_exhausted"}
                    end_reason = "attempts_exhausted"
                    finished = True
                else:
                    result = {
                        "status": "inconsistent",
                        "attempts_remaining": ATTEMPTS_PER_TASK - attempts,
                    }
            messages.append(
                {
                    "role": "tool",
                    "tool_name": name if isinstance(name, str) else "invalid_tool",
                    "content": json.dumps(result, sort_keys=True),
                }
            )
            if finished:
                break
        if finished:
            break
    return {
        "id": task["id"],
        "accepted": accepted,
        "end_reason": end_reason,
        "rounds": rounds,
        "silent_rounds": silent_rounds,
        "attempts": attempts,
        "tool_calls": tool_calls,
        "schema_conformant_calls": conformant_calls,
        "prompt_tokens": prompt_tokens,
        "generated_tokens": generated_tokens,
        "generated_tokens_per_round": round_tokens,
        "admissible_candidates": task["admissible_candidates"],
        "wall_seconds": time.monotonic() - started,
    }


def peak_rss_bytes() -> int:
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return int(value if platform.system() == "Darwin" else value * 1024)


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))
    return float(ordered[index])


def self_test(tasks: list[dict[str, Any]]) -> None:
    if len(tasks) != 12:
        raise QualificationError("the stage must hold exactly twelve tasks")
    covered = {name for program in HIDDEN_PROGRAMS for name in program}
    if covered != set(OPERATIONS):
        raise QualificationError("the fixed programs do not cover every primitive")
    if len({tuple(task["hidden_program"]) for task in tasks}) != len(tasks):
        raise QualificationError("two fixed programs are identical")
    maximum_admissible = 0
    for task in tasks:
        projection = canonical_json(public_projection(task))
        for name in task["hidden_program"]:
            if f'"{name}"' in projection:
                raise QualificationError("the public projection named a hidden operation")
        if not consistent(task, task["hidden_program"]):
            raise QualificationError("a hidden program misses its own examples")
        for demonstration in task["demonstrations"]:
            if demonstration["output"] == demonstration["input"]:
                raise QualificationError("a demonstration is ineffective")
        if task["admissible_candidates"] < 1:
            raise QualificationError("a task has no admissible candidate")
        maximum_admissible = max(maximum_admissible, task["admissible_candidates"])
        # An inconsistent candidate is refused generically and costs one attempt.
        wrong = ["reverse", "reverse", "reverse"]
        if consistent(task, wrong):
            wrong = ["tail", "tail", "tail"]
        if consistent(task, wrong):
            raise QualificationError("could not construct an inconsistent candidate")
    if not schema_conformant("submit_program", {"operations": ["tail", "init", "reverse"]}):
        raise QualificationError("the schema check rejects a valid call")
    for bad in (
        {"operations": ["tail", "init"]},
        {"operations": ["tail", "init", "nope"]},
        {"operations": "tail"},
        {"operations": ["tail", "init", "reverse"], "extra": 1},
    ):
        if schema_conformant("submit_program", bad):
            raise QualificationError("the schema check accepts a malformed call")
    print(
        "inference depth gate self-test: "
        f"tasks={len(tasks)} primitives_covered={len(covered)} "
        f"max_admissible={maximum_admissible} "
        f"round_ceiling={ROUND_CEILING} attempts={ATTEMPTS_PER_TASK} "
        f"minimum_liveness={MINIMUM_LIVENESS_RATE} "
        f"minimum_solve={MINIMUM_SOLVE_RATE} public_hidden_fields=0"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--model", default="gpt-oss:20b")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--num-predict", type=int, default=NUM_PREDICT)
    # The bounded search rule permits low first, then medium only if low fails
    # liveness. Omitting the flag reproduces the default-effort baseline.
    parser.add_argument("--think", choices=["low", "medium"], default=None)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.self_test and args.output is None:
        raise QualificationError("--output is required outside --self-test")
    tasks = build_tasks()
    if args.self_test:
        self_test(tasks)
        return 0

    started = time.monotonic()
    outcomes = []
    for index, task in enumerate(tasks):
        outcome = run_task(args.model, task, args.num_predict, args.think)
        outcomes.append(outcome)
        print(
            f"task={index + 1}/{len(tasks)} "
            f"accepted={str(outcome['accepted']).lower()} "
            f"rounds={outcome['rounds']} silent={outcome['silent_rounds']} "
            f"attempts={outcome['attempts']} reason={outcome['end_reason']}",
            flush=True,
        )
    accepted = sum(int(outcome["accepted"]) for outcome in outcomes)
    solve_rate = accepted / len(outcomes)
    live_episodes = sum(
        int(outcome["schema_conformant_calls"] > 0) for outcome in outcomes
    )
    liveness_rate = live_episodes / len(outcomes)
    rounds = sum(outcome["rounds"] for outcome in outcomes)
    silent_rounds = sum(outcome["silent_rounds"] for outcome in outcomes)
    per_round = [
        value for outcome in outcomes for value in outcome["generated_tokens_per_round"]
    ]
    liveness_passed = liveness_rate >= MINIMUM_LIVENESS_RATE
    solve_passed = solve_rate >= MINIMUM_SOLVE_RATE
    show = post_json("/api/show", {"model": args.model}, timeout=60)
    tags = get_json("/api/tags").get("models", [])
    tag = next((item for item in tags if item.get("name") == args.model), {})
    running = get_json("/api/ps").get("models", [])
    loaded = next((item for item in running if item.get("name") == args.model), {})
    report = {
        "schema": "gene.inference_depth_qualification.v1",
        "date_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "harness_sha256": sha256_file(Path(__file__).resolve()),
        "model": {
            "name": args.model,
            "manifest_digest": tag.get("digest"),
            "capabilities": show.get("capabilities"),
            "loaded_size_bytes": loaded.get("size"),
            "loaded_vram_bytes": loaded.get("size_vram"),
        },
        "stage": {
            "tasks": len(tasks),
            "operations_per_program": PROGRAM_LENGTH,
            "attempts_per_task": ATTEMPTS_PER_TASK,
            "round_ceiling": ROUND_CEILING,
            "silent_round_cap": SILENT_ROUND_CAP,
            "permanently_excluded": True,
        },
        "decoding": {
            "temperature": 0,
            "seed": 20260809,
            "num_ctx": 32768,
            "num_predict": args.num_predict,
            "reasoning_effort": args.think or "default",
        },
        "gate": {
            "minimum_liveness_rate": MINIMUM_LIVENESS_RATE,
            "liveness_rate": liveness_rate,
            "liveness_passed": liveness_passed,
            "minimum_solve_rate": MINIMUM_SOLVE_RATE,
            "solve_rate": solve_rate,
            "solve_passed": solve_passed,
            "passed": liveness_passed and solve_passed,
        },
        "summary": {
            "tasks": len(outcomes),
            "accepted": accepted,
            "live_episodes": live_episodes,
            "rounds": rounds,
            "silent_rounds": silent_rounds,
            "silent_round_fraction": silent_rounds / rounds if rounds else 0.0,
            "tool_calls": sum(item["tool_calls"] for item in outcomes),
            "schema_conformant_calls": sum(
                item["schema_conformant_calls"] for item in outcomes
            ),
            "prompt_tokens": sum(item["prompt_tokens"] for item in outcomes),
            "generated_tokens": sum(item["generated_tokens"] for item in outcomes),
            "generated_tokens_per_round_mean": (
                statistics.fmean(per_round) if per_round else 0.0
            ),
            "generated_tokens_per_round_p95": percentile(per_round, 0.95),
            "generated_tokens_per_round_max": max(per_round) if per_round else 0,
            "total_wall_seconds": time.monotonic() - started,
            "harness_peak_rss_bytes": peak_rss_bytes(),
        },
        "outcomes": outcomes,
    }
    assert args.output is not None
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        f"liveness: live={live_episodes}/{len(outcomes)} "
        f"rate={liveness_rate:.3f} passed={str(liveness_passed).lower()}"
    )
    print(
        f"solve: accepted={accepted}/{len(outcomes)} "
        f"rate={solve_rate:.3f} passed={str(solve_passed).lower()}"
    )
    print(
        "tokens per round: "
        f"mean={report['summary']['generated_tokens_per_round_mean']:.1f} "
        f"p95={report['summary']['generated_tokens_per_round_p95']:.0f} "
        f"max={report['summary']['generated_tokens_per_round_max']}"
    )
    return 0 if liveness_passed and solve_passed else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (QualificationError, OSError) as exc:
        print(f"inference depth qualification error: {exc}", file=sys.stderr)
        raise SystemExit(2)
