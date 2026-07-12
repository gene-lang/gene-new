#!/usr/bin/env python3
"""Stdlib-only Python counterpart to ``tui.gene``.

The module intentionally exposes its configuration, tools, transports, context
helpers, event log, and Session as ordinary Python values for tests and REPL use.
"""

from __future__ import annotations

import code
import copy
import dataclasses
import difflib
import hashlib
import json
import os
import re
import signal
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Callable, Iterable, Iterator, Mapping, MutableMapping, Sequence


CODEX_BASE = "https://chatgpt.com/backend-api/codex"
AUTH_ENV_NAMES = ("OPENAI_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN")
TRUE_WORDS = {"1", "true", "yes", "on"}
MAX_HTTP_BYTES = 4_000_000
MAX_SSE_PENDING_BYTES = 262_144
MAX_STATE_BYTES = 4_000_000
TOOL_OUTPUT_BYTES = 65_536
MAX_TOOL_CALLS_PER_RESPONSE = 32
MAX_TOOL_CALLS_PER_TURN = 128
MAX_DIFF_INPUT_BYTES = 1_000_000
MAX_DIFF_LINE_BYTES = 1_000
MAX_DIFF_CHANGE_BYTES = 65_536
MAX_DIFF_REPORT_BYTES = 262_144
WIRE_INTERNAL_FIELDS = {"context_summary", "context_limit_warning", "workspace_instructions"}


def flag_enabled(value: str) -> bool:
    return value.strip().lower() in TRUE_WORDS


def positive_env_int(env: Mapping[str, str], name: str, fallback: int) -> int:
    try:
        value = int(env.get(name, str(fallback)))
        return value if value > 0 else fallback
    except (TypeError, ValueError):
        return fallback


@dataclasses.dataclass(frozen=True)
class Config:
    auth_token: str | None
    base: str
    model: str
    api_flavor: str
    approve_all: str
    state_dir: str
    resume: str
    guard: str
    context_max_bytes: int
    context_max_items: int
    context_keep_turns: int
    max_tool_rounds: int
    shell: str
    workspace_root: str = "."
    secrets: tuple[str, ...] = dataclasses.field(default=(), repr=False)

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "Config":
        source = os.environ if env is None else env
        token = next((source[k] for k in AUTH_ENV_NAMES if k in source), None)
        base = source.get("OPENAI_BASE_URL", CODEX_BASE)
        return cls(
            auth_token=token,
            base=base,
            model=source.get("OPENAI_MODEL", "gpt-5.4-mini"),
            api_flavor=source.get("OPENAI_API", "responses" if base == CODEX_BASE else "chat"),
            approve_all=source.get("GENE_AGENT_APPROVE_ALL", "1"),
            state_dir=source.get("GENE_AGENT_STATE", ""),
            resume=source.get("GENE_AGENT_RESUME", "1"),
            guard=source.get("GENE_AGENT_GUARD", "1"),
            context_max_bytes=positive_env_int(source, "GENE_AGENT_CONTEXT_MAX_BYTES", 750_000),
            context_max_items=positive_env_int(source, "GENE_AGENT_CONTEXT_MAX_ITEMS", 200),
            context_keep_turns=positive_env_int(source, "GENE_AGENT_CONTEXT_KEEP_TURNS", 8),
            max_tool_rounds=positive_env_int(source, "GENE_AGENT_MAX_TOOL_ROUNDS", 12),
            shell=source.get("SHELL", "sh"),
            secrets=tuple(dict.fromkeys(source[k] for k in AUTH_ENV_NAMES if source.get(k))),
        )

    def public_dict(self) -> dict[str, Any]:
        return {
            "model": self.model,
            "base": self.base,
            "api_flavor": self.api_flavor,
            "workspace_root": self.workspace_root,
            "approve_all": self.approve_all,
            "max_tool_rounds": self.max_tool_rounds,
            "context_max_bytes": self.context_max_bytes,
            "context_max_items": self.context_max_items,
            "context_keep_turns": self.context_keep_turns,
        }


class Redactor:
    def __init__(self, secrets: Iterable[str] = ()) -> None:
        self.secrets = tuple(sorted({s for s in secrets if s}, key=len, reverse=True))

    def text(self, value: str) -> str:
        for secret in self.secrets:
            value = value.replace(secret, "auth-***REDACTED***")
        return value

    def any(self, value: Any) -> Any:
        if isinstance(value, str):
            return self.text(value)
        if isinstance(value, dict):
            return {self.text(str(k)): self.any(v) for k, v in value.items()}
        if isinstance(value, (list, tuple)):
            return [self.any(v) for v in value]
        return value


class EventSequence(Sequence[Mapping[str, Any]]):
    """Live, read-only snapshots of an event log."""

    def __init__(self, source: list[dict[str, Any]], lock: threading.RLock) -> None:
        self._source = source
        self._lock = lock

    def __len__(self) -> int:
        with self._lock:
            return len(self._source)

    def __getitem__(self, index: int | slice) -> Any:
        with self._lock:
            if isinstance(index, slice):
                return tuple(copy.deepcopy(event) for event in self._source[index])
            return copy.deepcopy(self._source[index])


class EventLog:
    """Append-only, monotonically versioned event collection."""

    def __init__(self, redactor: Redactor, events: Sequence[Mapping[str, Any]] = ()) -> None:
        self.redactor = redactor
        self._events = [dict(e) for e in events if isinstance(e, Mapping)
                        and isinstance(e.get("v"), int) and not isinstance(e.get("v"), bool)
                        and isinstance(e.get("turn"), int) and not isinstance(e.get("turn"), bool)
                        and isinstance(e.get("type"), str)]
        versions = [e["v"] for e in self._events]
        turns = [e["turn"] for e in self._events]
        self.next_v = max(versions, default=0) + 1
        self.turn = max(turns, default=0)
        self.subscriptions: set[str] = set()
        self.echo: Callable[[str], None] | None = None
        self._lock = threading.RLock()
        self._view = EventSequence(self._events, self._lock)

    @property
    def events(self) -> EventSequence:
        return self._view

    def begin_turn(self) -> int:
        with self._lock:
            self.turn += 1
            return self.turn

    def emit(self, event_type: str, **props: Any) -> dict[str, Any]:
        with self._lock:
            safe_props = self.redactor.any(props)
            event = {**safe_props, "v": self.next_v, "turn": self.turn, "type": event_type}
            self.next_v += 1
            self._events.append(event)
        if event_type in self.subscriptions and self.echo:
            self.echo(format_event(event))
        return copy.deepcopy(event)

    def trace(self, filters: str = "") -> list[dict[str, Any]]:
        parsed = parse_trace_filters(filters)
        return [copy.deepcopy(e) for e in self._events if event_matches(e, parsed)]

    def report(self, filters: str = "") -> str:
        matches = self.trace(filters)
        return "\n".join(format_event(e) for e in matches) if matches else "no matching events"


def parse_trace_filters(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for token in text.strip().split():
        if "=" in token:
            key, value = token.split("=", 1)
            result[key] = value
        else:
            result["type"] = token
    return result


def event_matches(event: Mapping[str, Any], filters: Mapping[str, str]) -> bool:
    if "type" in filters and event.get("type") != filters["type"]:
        return False
    if "tool" in filters and event.get("name") != filters["tool"]:
        return False
    if "turn" in filters and str(event.get("turn")) != filters["turn"]:
        return False
    try:
        if "from" in filters and int(event.get("v", 0)) < int(filters["from"]):
            return False
        if "to" in filters and int(event.get("v", 0)) > int(filters["to"]):
            return False
    except ValueError:
        return False
    if "path" in filters:
        path = event.get("path", "")
        if isinstance(event.get("args"), dict):
            path = event["args"].get("path", path)
        if filters["path"] not in str(path):
            return False
    return True


def first_line(text: Any) -> str:
    line = str(text or "").split("\n", 1)
    return line[0] + (" ..." if len(line) > 1 else "")


def format_event(event: Mapping[str, Any]) -> str:
    kind = event.get("type", "")
    if kind in {"user_input", "agent_text", "text_delta", "turn_done", "memory", "error"}:
        summary = first_line(event.get("text", ""))
    elif kind == "tool_call":
        summary = f"{event.get('name', '')} {json.dumps(event.get('args'), ensure_ascii=False)}"
    elif kind == "tool_result":
        flag = " [truncated]" if event.get("truncated") else ""
        summary = f"{event.get('name', '')}{flag}: {first_line(event.get('value'))}"
    elif kind == "file_change":
        summary = (f"undo #{event['undo_of']}: {event.get('path', '')}" if "undo_of" in event
                   else f"#{event.get('id')} {event.get('op')}: {event.get('path', '')}")
    elif kind == "check":
        summary = f"{event.get('scope')} status={event.get('status')} {event.get('duration_ms')}ms: {first_line(event.get('command'))}"
    elif kind == "confirmation":
        summary = f"{event.get('risk')} {event.get('decision')}: {first_line(event.get('target'))}"
    elif kind == "tool_registered":
        summary = f"{event.get('name')} ({event.get('risk')})"
    elif kind == "context_compacted":
        summary = (f"{event.get('removed_turns', 0)} turns / {event.get('removed_items', 0)} items removed; "
                   f"{event.get('elided_tool_outputs', 0)} tool outputs elided; {event.get('bytes_after')} bytes retained")
    elif kind == "context_limit_warning":
        summary = f"context remains over its configured floor: {event.get('bytes')} bytes / {event.get('items')} items"
    else:
        summary = first_line(event.get("item", {}).get("type", "") if isinstance(event.get("item"), dict) else "")
    return f"#{event.get('v')} t{event.get('turn')} {kind} {summary}".rstrip()


@dataclasses.dataclass(frozen=True)
class Param:
    name: str
    type: str
    required: bool = False
    doc: str = ""

    def schema(self) -> dict[str, Any]:
        value: dict[str, Any] = {"type": self.type}
        if self.doc:
            value["description"] = self.doc
        return value


ToolHandler = Callable[[MutableMapping[str, Any], "Session"], Any]


@dataclasses.dataclass
class Tool:
    name: str
    description: str
    risk: str
    params: Sequence[Param]
    handler: ToolHandler

    def schema(self) -> dict[str, Any]:
        parameters: dict[str, Any] = {
            "type": "object",
            "properties": {p.name: p.schema() for p in self.params},
        }
        required = [p.name for p in self.params if p.required]
        if required:
            parameters["required"] = required
        return {"type": "function", "name": self.name, "description": self.description, "parameters": parameters}

    def chat_schema(self) -> dict[str, Any]:
        schema = self.schema()
        return {"type": "function", "function": {k: schema[k] for k in ("name", "description", "parameters")}}

    def validate(self, args: Any) -> str | None:
        if not isinstance(args, dict):
            return "tool arguments must be a JSON object"
        expected = {"string": str, "integer": int, "boolean": bool}
        problems: list[str] = []
        for param in self.params:
            if param.name not in args:
                if param.required:
                    problems.append(f"missing required argument {param.name}")
                continue
            value = args[param.name]
            okay = isinstance(value, expected.get(param.type, object))
            if param.type == "integer" and isinstance(value, bool):
                okay = False
            if not okay:
                problems.append(f"argument {param.name} must be a {param.type}")
        return "; ".join(problems) or None


def command_segments(command: str) -> list[str]:
    return [part.strip() for part in re.split(r"&&|;|\|", command)]


def classify_command(command: str, workspace_real: str | None = None) -> str:
    worst = "normal"
    recursive_rm = any(x in command for x in ("rm -rf", "rm -fr", "rm -r ", "rm -f -r"))
    if recursive_rm:
        worst = "destructive"
        protected = {"/", "/*", "~", "~/", "$HOME", "${HOME}", ".", "..", ".git", ".git/"}
        if workspace_real:
            protected.update({workspace_real, workspace_real + "/"})
        for token in command.split():
            if token in protected or (token.startswith("/") and len(token.split("/")) <= 2):
                worst = "catastrophic"
    catastrophic_starts = ("mkfs", "shutdown", "reboot", "poweroff", "halt", "init 0")
    for segment in command_segments(command):
        value = segment.lower()
        catastrophic = (value.startswith(catastrophic_starts) or ":(){" in value
                         or " of=/dev/" in value or "drop database" in value)
        destructive = any(p in value for p in (
            "git reset --hard", "git clean -fd", "git push --force", "git push -f",
            "drop table", "truncate table", "terraform destroy",
            "kubectl delete namespace", "kubectl delete ns ", "kubectl delete cluster",
        )) or "git branch -D" in segment
        destructive = destructive or ("where" not in value and (
            "delete from" in value or ("update " in value and " set " in value)))
        if catastrophic:
            worst = "catastrophic"
        elif destructive and worst != "catastrophic":
            worst = "destructive"
    return worst


@dataclasses.dataclass
class ProcessResult:
    status: int | None
    stdout: str
    stderr: str
    timed_out: bool
    truncated: bool
    duration_ms: int


def run_bounded_process(
    argv: Sequence[str], cwd: Path, timeout_ms: int, max_bytes: int,
    cancel_event: threading.Event | None = None,
    on_process: Callable[[subprocess.Popen[bytes] | None], None] | None = None,
) -> ProcessResult:
    started = time.monotonic()
    process = subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=os.name == "posix")
    if on_process:
        on_process(process)
    lock = threading.Lock()
    remaining = [max_bytes]
    truncated = [False]
    outputs: dict[str, bytearray] = {"stdout": bytearray(), "stderr": bytearray()}

    def drain(name: str, pipe: Any) -> None:
        try:
            while True:
                chunk = pipe.read(8192)
                if not chunk:
                    break
                with lock:
                    take = min(len(chunk), remaining[0])
                    outputs[name].extend(chunk[:take])
                    remaining[0] -= take
                    if take < len(chunk):
                        truncated[0] = True
        except (OSError, ValueError):
            pass
        finally:
            pipe.close()

    def stop(sig: int) -> None:
        try:
            if os.name == "posix":
                os.killpg(process.pid, sig)
            elif process.poll() is not None:
                return
            elif sig == signal.SIGTERM:
                process.terminate()
            else:
                process.kill()
        except (OSError, ProcessLookupError):
            pass

    threads = [threading.Thread(target=drain, args=(name, pipe), daemon=True)
               for name, pipe in (("stdout", process.stdout), ("stderr", process.stderr))]
    for thread in threads:
        thread.start()
    deadline = started + timeout_ms / 1000
    timed_out = False
    try:
        while True:
            if cancel_event and cancel_event.is_set():
                stop(signal.SIGTERM)
                break
            if process.poll() is not None:
                break
            if time.monotonic() >= deadline:
                timed_out = True
                stop(signal.SIGTERM)
                break
            time.sleep(0.025)
    except BaseException:
        stop(signal.SIGTERM)
        raise
    finally:
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            stop(signal.SIGKILL)
            process.wait()
        # A shell leader may exit while background descendants keep running or
        # retain our pipes. The subprocess contract owns the whole process group.
        if os.name == "posix":
            stop(signal.SIGTERM)
            time.sleep(0.05)
            stop(signal.SIGKILL)
        for thread in threads:
            thread.join(timeout=1)
        for pipe in (process.stdout, process.stderr):
            if pipe and not pipe.closed:
                pipe.close()
        for thread in threads:
            thread.join(timeout=1)
        if on_process:
            on_process(None)
    duration = int((time.monotonic() - started) * 1000)
    return ProcessResult(
        process.returncode,
        outputs["stdout"].decode("utf-8", "replace"),
        outputs["stderr"].decode("utf-8", "replace"),
        timed_out,
        truncated[0],
        duration,
    )


@dataclasses.dataclass
class FileChange:
    id: int
    op: str
    path: str
    before_exists: bool
    before: str
    after_exists: bool
    after: str
    undone: bool = False


class InstructionLoader:
    def __init__(self, session: "Session", records: Sequence[Mapping[str, Any]] = ()) -> None:
        self.session = session
        self.records: list[dict[str, Any]] = []
        self.loaded: set[str] = set()
        self.total_bytes = 0
        for record in records:
            if (not isinstance(record, Mapping)
                    or not all(isinstance(record.get(key), str) for key in ("scope", "source"))):
                continue
            try:
                self._load(record["scope"], record["source"])
            except ValueError:
                continue

    def _load(self, scope: str, source: str) -> dict[str, Any] | None:
        if source in self.loaded:
            return None
        path = self.session.safe_path(source)
        if not path.exists():
            return None
        self.loaded.add(source)
        try:
            data = path.read_bytes()
        except OSError:
            return {"scope": scope, "source": source, "skipped": "unreadable"}
        if len(data) > 32_768:
            return {"scope": scope, "source": source, "skipped": "file exceeds byte cap", "bytes": len(data)}
        if self.total_bytes + len(data) > 65_536:
            return {"scope": scope, "source": source, "skipped": "total byte cap reached", "bytes": len(data)}
        record = {"scope": scope, "source": source, "text": data.decode("utf-8", "replace"), "bytes": len(data)}
        self.total_bytes += len(data)
        self.records.append(record)
        return record

    def ensure(self, relative: str, include_leaf: bool) -> list[dict[str, Any]]:
        before = set(self.loaded)
        self._load(".", "AGENTS.md")
        parts = list(Path(relative).parts)
        count = len(parts) if include_leaf else max(0, len(parts) - 1)
        scope = Path(".")
        for part in parts[:min(count, 8)]:
            if part in ("", "."):
                continue
            scope /= part
            source = str(scope / "AGENTS.md")
            self._load(str(scope), source)
        return [r for r in self.records if r["source"] not in before]

    @staticmethod
    def format(records: Sequence[Mapping[str, Any]]) -> str:
        return "\n\n".join(
            f"[{r['source']} scope={r['scope']}]\n{r['text']}" for r in records if "skipped" not in r
        )

    def newly_loaded_text(self, relative: str, include_leaf: bool = False) -> str:
        records = self.ensure(relative, include_leaf)
        if records:
            self.session.refresh_workspace_instructions()
        return self.format(records)


def approximate_bytes(value: Any) -> int:
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":"), default=str).encode("utf-8"))


def context_turns(items: Sequence[Mapping[str, Any]]) -> list[list[dict[str, Any]]]:
    turns: list[list[dict[str, Any]]] = []
    current: list[dict[str, Any]] = []
    for raw in items:
        item = dict(raw)
        if item.get("role") == "system":
            continue
        if item.get("role") == "user":
            if current:
                turns.append(current)
            current = [item]
        else:
            current.append(item)
    if current:
        turns.append(current)
    return turns


def context_stats(items: Sequence[Mapping[str, Any]], memory: Sequence[str], config: Config) -> dict[str, Any]:
    size = approximate_bytes(items)
    return {
        "bytes": size, "approx_tokens": (size + 3) // 4, "items": len(items),
        "retained_turns": len(context_turns(items)), "memory_items": len(memory),
        "memory_bytes": approximate_bytes(memory), "max_bytes": config.context_max_bytes,
        "max_items": config.context_max_items, "keep_turns": config.context_keep_turns,
        "over_limit": size > config.context_max_bytes or len(items) > config.context_max_items,
    }


def compact_context(items: Sequence[Mapping[str, Any]], memory: Sequence[str], config: Config,
                    emit: Callable[..., Any]) -> list[dict[str, Any]]:
    original = [dict(item) for item in items]
    before = context_stats(original, memory, config)
    warning_present = any(item.get("context_limit_warning") is True for item in original)
    if not before["over_limit"]:
        return [item for item in original if not item.get("context_limit_warning")]
    systems = [item for item in original if item.get("role") == "system"
               and not item.get("context_summary") and not item.get("context_limit_warning")]
    turns = context_turns(original)
    remove_turns = max(0, len(turns) - config.context_keep_turns)
    result = list(systems)
    if remove_turns:
        result.append({
            "role": "system", "context_summary": True,
            "content": f"Context compacted: {remove_turns} older turns were removed. Persistent memory, "
                       "explicit remembered decisions, and workspace instructions remain in the preceding system content.",
        })
    for turn in turns[remove_turns:]:
        result.extend(turn)
    elided_count = elided_bytes = 0
    for index, item in enumerate(result):
        if approximate_bytes(result) <= config.context_max_bytes:
            break
        if item.get("type") == "function_call_output" and isinstance(item.get("output"), str):
            old = approximate_bytes(item)
            replacement = dict(item)
            output_size = len(item["output"].encode("utf-8"))
            replacement["output"] = (
                f"[tool output omitted during context compaction: {output_size} bytes; rerun the tool "
                "with a narrower request if supported and the content is still needed]"
            )
            new = approximate_bytes(replacement)
            if new < old:
                result[index] = replacement
                elided_count += 1
                elided_bytes += old - new
    after = context_stats(result, memory, config)
    irreducible = after["over_limit"]
    if irreducible:
        result.append({
            "role": "system", "context_limit_warning": True,
            "content": "Context remains above its configured floor after whole-turn compaction and tool-output "
                       "elision. Irreducible system/user content was preserved; use narrower tool reads or start "
                       "a fresh session if more room is required.",
        })
        after = context_stats(result, memory, config)
        if not warning_present:
            emit("context_limit_warning", bytes=after["bytes"], items=after["items"],
                 max_bytes=config.context_max_bytes, max_items=config.context_max_items,
                 irreducible_over_limit=True)
    source_items = before["items"] - (1 if warning_present else 0)
    removed_items = source_items - after["items"]
    if removed_items > 0 or elided_count:
        emit("context_compacted", bytes_before=before["bytes"], bytes_after=after["bytes"],
             items_before=before["items"], items_after=after["items"], removed_items=removed_items,
             removed_turns=remove_turns, retained_turns=after["retained_turns"],
             elided_tool_outputs=elided_count, elided_output_bytes=elided_bytes,
             irreducible_over_limit=irreducible, over_limit=after["over_limit"])
    return result


SYSTEM_PROMPT = """You are a coding agent working in the Gene language repository. You can read,
write, and edit files, list directories, grep, and run shell commands after user
approval.

When writing Gene code, use the current repo's language, not generic Lisp:

- Programs are s-expressions. Calls are callable-first: `(f x y)`.
- Top-level forms run in order. `gene run file.gene` calls `(fn main [...])` if
  present; scripts may also do work at top level.
- Comments start with `#`. Modules may start with `(mod name @doc "...")`.
- Imports use forms such as `(import str [join split trim lower])`.
- Bind with `(var name value)`; reassign with `(set name value)`. Avoid duplicate
  local declarations in loops or branches.
- Functions use `(fn name [a : Type, b] : Return body...)`; the last expression
  is returned. Control forms include `do`, `if`, `while`, `loop`, `repeat`, `for`,
  and `match`; boolean operators are `&&`, `||`, and `!`.
- Recoverable errors use `try`/`catch`/`ensure` and `fail`; reserve `panic` for bugs.
- Lists use `[a b]`, maps use `{^key value}`, and nodes use `(tag ^prop value ...)`.
  Grow owned lists with `List/push!`; repeated copy-and-append in loops is quadratic.
- `nil` is absence; `void` is a missing selector or omitted storage.
- `x/key` is selector access, `xs/~size` sends a message, and `(x ~ msg arg)` is a
  message send. User-facing names use snake_case; `-` remains a symbol character.
- Types, enums, protocols, and implementations use `type`, `enum`, `protocol`, and
  `impl`; single data inheritance is `^is` and behavioral composition is `^inherit`.
- Streams are pull-based and skip `void`; common operators are `map`, `filter`,
  `each`, and `into` from `std/stream`.
- Useful references are `examples/todo_app.gene`, `examples/web_demo.gene`,
  `examples/protocol_demo.gene`, `docs/design.md`, `docs/core.md`, and `docs/stdlib.md`.

Before changing Gene code, inspect nearby examples or docs if uncertain. After
writing Gene code, verify with at least `bin/gene parse file.gene` or
`bin/gene compile file.gene`; use `bin/gene run file.gene` when behavior matters.
Only claim verification that a successful command result directly supports.
State that broader behavior is unverified when no matching successful check ran."""


def user_item(text: str) -> dict[str, Any]:
    return {"role": "user", "content": text}


def system_item(text: str) -> dict[str, Any]:
    return {"role": "system", "content": text}


def workspace_instruction_item(text: str) -> dict[str, Any]:
    return {"role": "system", "content": "Workspace instructions (parent-to-child):\n" + text,
            "workspace_instructions": True}


class StateStore:
    def __init__(self, root: str, redactor: Redactor) -> None:
        self.root = Path(root).expanduser() if root.strip() else None
        self.redactor = redactor
        if self.root:
            try:
                self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
                if os.name == "posix":
                    os.chmod(self.root, 0o700)
            except OSError as error:
                print(f"agent state disabled: {error}", file=sys.stderr)
                self.root = None

    def get(self, name: str, default: Any) -> Any:
        if not self.root:
            return default
        try:
            with (self.root / f"{name}.json").open("rb") as handle:
                raw = handle.read(MAX_STATE_BYTES + 1)
            if len(raw) > MAX_STATE_BYTES:
                return default
            return json.loads(raw.decode("utf-8"))
        except (OSError, UnicodeError, ValueError):
            return default

    def put(self, name: str, value: Any) -> bool:
        if not self.root:
            return False
        safe = self.redactor.any(value)
        target = self.root / f"{name}.json"
        temporary = self.root / f".{name}.{uuid.uuid4().hex}.tmp"
        try:
            payload = (json.dumps(safe, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
            if len(payload) > MAX_STATE_BYTES:
                raise ValueError(f"record exceeds {MAX_STATE_BYTES} byte cap")
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(payload)
            os.replace(temporary, target)
            if os.name == "posix":
                os.chmod(target, 0o600)
            return True
        except (OSError, TypeError, ValueError) as error:
            print(f"agent state save failed ({name}): {error}", file=sys.stderr)
            try:
                temporary.unlink()
            except OSError:
                pass
            return False


class Session:
    """Stable live control surface exposed as ``session`` by ``/repl``."""

    def __init__(self, config: Config | None = None, workspace: str | Path | None = None) -> None:
        self.config = config or Config.from_env()
        self.workspace = Path(workspace or self.config.workspace_root).resolve()
        self.redactor = Redactor(self.config.secrets)
        self.store = StateStore(self.config.state_dir, self.redactor)
        restore = flag_enabled(self.config.resume)
        loaded_session = self.store.get("session", None) if restore else None
        saved_session = loaded_session if isinstance(loaded_session, dict) else None
        event_record = self.store.get("events", {}) if saved_session else {}
        saved_events = event_record.get("events", []) if isinstance(event_record, dict) else []
        if not isinstance(saved_events, list):
            saved_events = []
        self.event_log = EventLog(self.redactor, saved_events)
        self.events = self.event_log.events
        loaded_memory = self.store.get("memory", [])
        self.memory = [value for value in loaded_memory if isinstance(value, str)] if isinstance(loaded_memory, list) else []
        self.items: list[dict[str, Any]] = []
        self.transcript = f"Gene AI agent - model {self.config.model}\n"
        if saved_session:
            saved_items = saved_session.get("items", [])
            self.items = [dict(item) for item in saved_items if isinstance(item, Mapping)] if isinstance(saved_items, list) else []
            saved_transcript = saved_session.get("transcript")
            if isinstance(saved_transcript, str):
                self.transcript = saved_transcript
            self.transcript += f"[restored session from {self.config.state_dir}]\n"
        self.tools: dict[str, Tool] = {}
        self.changes: list[FileChange] = []
        self.evidence: list[dict[str, Any]] = [e for e in self.events if e.get("type") in {"file_change", "check"}]
        self.current_task: Any = None
        self._active_process: subprocess.Popen[bytes] | None = None
        self._active_response: Any = None
        self._cancel_event = threading.Event()
        self.prompt_handler: Callable[[str], str] | None = None
        self.resume_requested = False
        saved_instructions = saved_session.get("instructions", []) if saved_session else []
        if not isinstance(saved_instructions, list):
            saved_instructions = []
        self.instructions_loader = InstructionLoader(self, saved_instructions)
        self.instructions = self.instructions_loader.records
        self.instructions_loader.ensure("__root_probe__", False)
        self.system_prompt = SYSTEM_PROMPT
        root_instructions = InstructionLoader.format(
            [record for record in self.instructions if record.get("source") == "AGENTS.md"])
        if root_instructions:
            self.system_prompt += "\n\nWorkspace instructions (root scope):\n" + root_instructions
        if not self.items:
            self.items = self.initial_items()
        else:
            self.refresh_system_memory()
            self.refresh_workspace_instructions()
        persisted_change_ids = [event.get("id") for event in self.events
                                if event.get("type") == "file_change"
                                and isinstance(event.get("id"), int)
                                and not isinstance(event.get("id"), bool)]
        self._next_change_id = max(persisted_change_ids, default=0) + 1
        for tool in builtin_tools():
            self.add_tool(tool, emit=saved_session is None)
        self.save_config()

    def initial_items(self) -> list[dict[str, Any]]:
        items = [system_item(self.prompt_with_memory())]
        instructions = self._nested_instruction_text()
        if instructions:
            items.append(workspace_instruction_item(instructions))
        return items

    def prompt_with_memory(self) -> str:
        if not self.memory:
            return self.system_prompt
        return self.system_prompt + "\n\nPersistent memory:\n" + "\n".join(self.memory) + "\n"

    def refresh_system_memory(self) -> None:
        replacement = system_item(self.prompt_with_memory())
        self.items = [replacement, *self.items[1:]] if self.items else [replacement]

    def refresh_workspace_instructions(self) -> None:
        self.items = self.with_workspace_instructions(self.items)

    def with_workspace_instructions(self, items: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
        retained = [dict(item) for item in items if not item.get("workspace_instructions")]
        instructions = self._nested_instruction_text()
        if not instructions:
            return retained
        if retained:
            return [retained[0], workspace_instruction_item(instructions), *retained[1:]]
        return [workspace_instruction_item(instructions)]

    def _nested_instruction_text(self) -> str:
        return InstructionLoader.format(
            [record for record in self.instructions if record.get("source") != "AGENTS.md"])

    def safe_path(self, path: str) -> Path:
        if Path(path).is_absolute():
            raise ValueError(f"unsafe path rejected (absolute): {path}")
        if ".." in path:
            raise ValueError(f"unsafe path rejected (escapes workspace): {path}")
        candidate = (self.workspace / path).resolve(strict=False)
        try:
            candidate.relative_to(self.workspace)
        except ValueError as error:
            raise ValueError(f"unsafe path rejected (resolves outside workspace): {path}") from error
        return candidate

    def emit(self, event_type: str, **props: Any) -> dict[str, Any]:
        event = self.event_log.emit(event_type, **props)
        if event_type in {"file_change", "check"}:
            self.evidence.append(event)
        return event

    def add_tool(self, tool: Tool, emit: bool = True) -> str:
        if not isinstance(tool, Tool):
            raise TypeError("add_tool expects a Tool")
        if not re.fullmatch(r"[a-z][a-z0-9]*(?:_[a-z0-9]+)*", tool.name):
            raise ValueError("user-facing tool names must use valid snake_case")
        if not isinstance(tool.description, str) or tool.risk not in {"read", "write", "execute"}:
            raise ValueError(f"tool {tool.name} has invalid metadata")
        if not callable(tool.handler) or not isinstance(tool.params, Sequence):
            raise ValueError(f"tool {tool.name} has an invalid handler or parameter list")
        if any(not isinstance(param, Param) for param in tool.params):
            raise ValueError(f"tool {tool.name} parameters must be Param values")
        names = [param.name for param in tool.params]
        if any(not re.fullmatch(r"[a-z][a-z0-9]*(?:_[a-z0-9]+)*", name) for name in names):
            raise ValueError(f"tool {tool.name} parameter names must use valid snake_case")
        if len(names) != len(set(names)):
            raise ValueError(f"tool {tool.name} has duplicate parameter names")
        unsupported = sorted({param.type for param in tool.params} - {"string", "integer", "boolean"})
        if unsupported:
            raise ValueError(f"tool {tool.name} has unsupported parameter type(s): {', '.join(unsupported)}")
        self.tools[tool.name] = tool
        if emit:
            self.emit("tool_registered", name=tool.name, risk=tool.risk)
        return f"tool {tool.name} registered"

    def remember(self, note: str) -> str:
        self.memory.append(note)
        self.refresh_system_memory()
        self.emit("memory", action="remember", text=note)
        self.save()
        return f"remembered: {note}"

    def subscribe(self, event_type: str) -> str:
        self.event_log.subscriptions.add(str(event_type))
        return f"subscribed to {event_type} events"

    def trace(self, filters: str = "") -> str:
        return self.event_log.report(filters)

    def diff(self) -> str:
        active = [change for change in self.changes if not change.undone]
        if not active:
            return "no attributable file changes"
        reports: list[str] = []
        report_bytes = 0
        for change in active:
            before_bytes = len(change.before.encode("utf-8"))
            after_bytes = len(change.after.encode("utf-8"))
            header = f"change #{change.id} {change.op} {change.path}\n"
            if max(before_bytes, after_bytes) > MAX_DIFF_INPUT_BYTES:
                patch = (f"[diff omitted: snapshots are {before_bytes} and {after_bytes} bytes; "
                         f"per-change input cap is {MAX_DIFF_INPUT_BYTES} bytes]")
            else:
                patch_lines: list[str] = []
                patch_bytes = 0
                truncated = False
                for line in difflib.unified_diff(change.before.splitlines(), change.after.splitlines(),
                                                 "before", "after", lineterm=""):
                    encoded = line.encode("utf-8")
                    if len(encoded) > MAX_DIFF_LINE_BYTES:
                        line = f"[diff line omitted: {len(encoded)} bytes]"
                    line_bytes = len(line.encode("utf-8")) + 1
                    if patch_bytes + line_bytes > MAX_DIFF_CHANGE_BYTES:
                        truncated = True
                        break
                    patch_lines.append(line)
                    patch_bytes += line_bytes
                if truncated:
                    patch_lines.append(f"... [diff truncated at {MAX_DIFF_CHANGE_BYTES} bytes] ...")
                patch = "\n".join(patch_lines)
            report = header + patch
            size = len(report.encode("utf-8")) + 2
            if report_bytes + size > MAX_DIFF_REPORT_BYTES:
                reports.append(f"... [remaining changes omitted at {MAX_DIFF_REPORT_BYTES} byte report cap] ...")
                break
            reports.append(report)
            report_bytes += size
        return "\n\n".join(reports)

    def undo(self, change_id: int | None = None) -> str:
        choices = [c for c in self.changes if not c.undone and (change_id is None or c.id == change_id)]
        change = choices[-1] if choices else None
        if not change:
            return "nothing to undo" if change_id is None else f"no active file change #{change_id}"
        path = self.safe_path(change.path)
        exists = path.exists()
        current = path.read_text(encoding="utf-8") if exists else ""
        if exists != change.after_exists or current != change.after:
            return f"refused: {change.path} changed after agent change #{change.id}; current content was preserved"
        if change.before_exists:
            path.write_text(change.before, encoding="utf-8")
        elif path.exists():
            path.unlink()
        change.undone = True
        self.emit("file_change", id=self._allocate_change_id(), op="undo", path=change.path, undo_of=change.id,
                  before_exists=change.after_exists, after_exists=change.before_exists)
        return f"undid change #{change.id} ({change.path})"

    def cancel(self) -> str:
        if self.current_task is None and self._active_process is None and self._active_response is None:
            return "no turn in flight"
        self._cancel_event.set()
        if self._active_process and self._active_process.poll() is None:
            try:
                if os.name == "posix":
                    os.killpg(self._active_process.pid, signal.SIGTERM)
                else:
                    self._active_process.terminate()
            except (OSError, ProcessLookupError):
                pass
        if self._active_response:
            try:
                self._active_response.close()
            except Exception:
                pass
        return "cancellation requested"

    def resume(self) -> str:
        self.resume_requested = True
        return "resume requested: exit the REPL (exit/quit) to continue the current turn"

    def save_config(self) -> None:
        self.store.put("config", self.config.public_dict())

    def save(self) -> None:
        self.save_config()
        self.store.put("memory", self.memory)
        persisted_events: list[Mapping[str, Any]] = []
        event_bytes = 0
        for event in reversed(self.events):
            size = len(json.dumps(event, ensure_ascii=False, default=str).encode("utf-8")) + 2
            if event_bytes + size > MAX_STATE_BYTES * 3 // 4:
                break
            persisted_events.append(event)
            event_bytes += size
        persisted_events.reverse()
        self.store.put("events", {"events": persisted_events, "next_v": self.event_log.next_v,
                                  "turn": self.event_log.turn})
        self.store.put("session", {"items": self.items, "transcript": self.transcript,
                                   "instructions": self.instructions})

    def status(self) -> str:
        stats = context_stats(self.items, self.memory, self.config)
        state = self.config.state_dir if self.store.root else "off"
        return (f"state: {state}\nmodel: {self.config.model}\napi: {self.config.api_flavor}\n"
                f"tool rounds: max {self.config.max_tool_rounds}\n"
                f"context: {stats['bytes']} bytes (~{stats['approx_tokens']} tokens), {stats['items']} items, "
                f"{stats['retained_turns']} turns\ncontext limits: {stats['max_bytes']} bytes, "
                f"{stats['max_items']} items, keep {stats['keep_turns']} turns\n"
                f"memory: {stats['memory_items']} items, {stats['memory_bytes']} bytes\n"
                f"events: {len(self.events)}\ninstructions: {len(self.instructions)}\n"
                f"guard: {'on' if flag_enabled(self.config.guard) else 'off'}")

    def approve(self, tool: str, detail: str) -> bool:
        if flag_enabled(self.config.approve_all):
            return True
        try:
            prompt = f"approve {tool}: {self.redactor.text(detail)}? [y/N] "
            answer = self.prompt_handler(prompt) if self.prompt_handler else input(prompt)
        except EOFError:
            return False
        return answer.strip().lower() in {"y", "yes"}

    def guard_shell(self, command: str) -> str | None:
        if not flag_enabled(self.config.guard):
            return None
        risk = classify_command(command, str(self.workspace))
        if risk == "catastrophic":
            self.emit("confirmation", risk=risk, decision="deny", target=command)
            return "denied by catastrophe guard (GENE_AGENT_GUARD=0 outside the session overrides)"
        if risk == "destructive":
            try:
                prompt = f"destructive command: {self.redactor.text(command)}\nrun it once? [y/N] "
                answer = self.prompt_handler(prompt) if self.prompt_handler else input(prompt)
            except EOFError:
                answer = ""
            allowed = answer.strip().lower() in {"y", "yes"}
            self.emit("confirmation", risk=risk, decision="allow" if allowed else "deny", target=command)
            return None if allowed else "denied: destructive command was not confirmed"
        return None

    def record_change(self, op: str, relative: str, before_exists: bool, before: str,
                      after_exists: bool, after: str) -> FileChange:
        change = FileChange(self._allocate_change_id(), op, relative, before_exists, before, after_exists, after)
        self.changes.append(change)
        self.emit("file_change", id=change.id, op=op, path=relative, before_exists=before_exists,
                  before_hash=hashlib.sha256(before.encode()).hexdigest(), before_bytes=len(before.encode()),
                  after_exists=after_exists, after_hash=hashlib.sha256(after.encode()).hexdigest(),
                  after_bytes=len(after.encode()))
        return change

    def _allocate_change_id(self) -> int:
        value = self._next_change_id
        self._next_change_id += 1
        return value

    def run_process(self, tool: str, command: str, argv: Sequence[str], timeout_ms: int,
                    max_bytes: int = TOOL_OUTPUT_BYTES) -> ProcessResult:
        result = run_bounded_process(argv, self.workspace, timeout_ms, max_bytes, self._cancel_event,
                                     lambda process: setattr(self, "_active_process", process))
        scope = command_scope(command)
        self.emit("check", tool=tool, command=command, scope=scope, status=result.status,
                  duration_ms=result.duration_ms, timed_out=result.timed_out, truncated=result.truncated,
                  cancelled=self._cancel_event.is_set(), verified=result.status == 0 and not result.timed_out)
        return result


def command_scope(command: str) -> str:
    value = command.strip().lower()
    for prefix, scope in (("nimble test", "test"), ("nimble spec", "spec"),
                          ("nimble perf", "benchmark"), ("nimble wasm", "wasm")):
        if value.startswith(prefix):
            return scope
    return "command"


def _read_range(path: Path, start_line: int, max_lines: int, start_byte: int, max_bytes: int) -> str:
    # First pass computes line boundaries with bounded memory; second pass reads only the requested bytes.
    line = 1
    position = 0
    selected_start = 0 if start_line == 1 else None
    selected_end: int | None = None
    stop_line = start_line + max_lines - 1
    with path.open("rb") as handle:
        while chunk := handle.read(65_536):
            offset = 0
            while True:
                found = chunk.find(b"\n", offset)
                if found < 0:
                    break
                absolute = position + found
                if line == stop_line and selected_end is None:
                    selected_end = absolute
                line += 1
                if line == start_line and selected_start is None:
                    selected_start = absolute + 1
                offset = found + 1
            position += len(chunk)
    total_lines = line
    if selected_start is None:
        return f"error: start_line {start_line} is beyond the file's {total_lines} lines"
    end = position if selected_end is None else selected_end
    selected_bytes = max(0, end - selected_start)
    if start_byte > selected_bytes:
        return f"error: start_byte {start_byte} is beyond the selected range's {selected_bytes} bytes"
    amount = min(max_bytes, selected_bytes - start_byte)
    with path.open("rb") as handle:
        handle.seek(selected_start + start_byte)
        raw = handle.read(amount)
    had_bytes = bool(raw)
    # Avoid returning a partial UTF-8 sequence at either byte boundary.
    while raw and raw[0] & 0xC0 == 0x80:
        raw = raw[1:]
    while raw:
        try:
            text = raw.decode("utf-8")
            break
        except UnicodeDecodeError as error:
            if error.end == len(raw):
                raw = raw[:-1]
            else:
                raise ValueError(f"file is not valid UTF-8 near byte {selected_start + start_byte + error.start}") from error
    else:
        text = ""
    if had_bytes and not raw:
        return "error: max_bytes is too small to include the next complete UTF-8 character"
    end_byte = start_byte + len(raw)
    headers: list[str] = []
    last_line = min(total_lines, start_line + max_lines - 1)
    if start_line > 1 or last_line < total_lines:
        headers.append(f"lines {start_line}-{last_line} of {total_lines}")
    if start_byte > 0 or end_byte < selected_bytes:
        headers.append(f"bytes {start_byte}-{end_byte} of {selected_bytes}")
    if headers:
        return f"[{'; '.join(headers)}; request start_line/max_lines and start_byte/max_bytes for another range]\n{text}"
    return text


def _edit_hint(current: str, old_text: str) -> str:
    anchor = next((line for line in old_text.split("\n") if line.strip()), "")
    if not anchor:
        return "No nonblank anchor was available; read the current file and retry."
    lines = current.split("\n")
    windows: list[str] = []
    for index, line in enumerate(lines):
        if line != anchor or len(windows) >= 3:
            continue
        excerpt = []
        for number in range(max(0, index - 3), min(len(lines), index + 4)):
            shown = lines[number]
            if len(shown.encode()) > 1000:
                shown = f"[line omitted: {len(shown.encode())} bytes]"
            excerpt.append(f"{number + 1} | {shown}")
        windows.append(f"candidate near line {index + 1}:\n" + "\n".join(excerpt))
    if not windows:
        shown = anchor if len(anchor.encode()) <= 1000 else f"[line omitted: {len(anchor.encode())} bytes]"
        return f"No current line equals the anchor `{shown}`; read the current file and retry."
    return "Re-anchor against the current file:\n" + "\n\n".join(windows)


def _gene_parse_warning(path: Path, session: Session) -> str:
    if path.suffix != ".gene":
        return ""
    executable = session.workspace / "bin" / "gene"
    if not executable.is_file():
        found = shutil.which("gene")
        if not found:
            return ""
        executable = Path(found)
    try:
        result = run_bounded_process([str(executable), "parse", str(path)], session.workspace, 5_000, 8_192)
    except OSError:
        return ""
    if result.status == 0:
        return ""
    diagnostic = first_line(result.stderr or result.stdout or "parse failed")
    return f"\nwarning: file does not parse: {session.redactor.text(diagnostic)}"


def _read_file(args: MutableMapping[str, Any], session: Session) -> str:
    relative = args["path"]
    path = session.safe_path(relative)
    start_line = args.get("start_line", 1)
    max_lines = args.get("max_lines", 400)
    start_byte = args.get("start_byte", 0)
    max_bytes = args.get("max_bytes", 65_536)
    if start_line < 1:
        return "error: start_line must be at least 1"
    if not 1 <= max_lines <= 2_000:
        return "error: max_lines must be between 1 and 2000"
    if start_byte < 0:
        return "error: start_byte must be non-negative"
    if not 1 <= max_bytes <= 262_144:
        return "error: max_bytes must be between 1 and 262144"
    instructions = session.instructions_loader.newly_loaded_text(relative)
    content = _read_range(path, start_line, max_lines, start_byte, max_bytes)
    return (f"New applicable instructions (parent-to-child):\n{instructions}\n--- file ---\n{content}"
            if instructions else content)


def _write_file(args: MutableMapping[str, Any], session: Session) -> str:
    relative, content = args["path"], args["content"]
    path = session.safe_path(relative)
    instructions = session.instructions_loader.newly_loaded_text(relative)
    if instructions:
        return f"write deferred: apply these newly discovered instructions, then retry:\n{instructions}"
    if not session.approve("write_file", relative):
        return "denied by user policy"
    before_exists = path.exists()
    before = path.read_text(encoding="utf-8") if before_exists else ""
    path.write_text(content, encoding="utf-8")
    session.record_change("write", relative, before_exists, before, True, content)
    return f"wrote {relative}{_gene_parse_warning(path, session)}"


def _edit_file(args: MutableMapping[str, Any], session: Session) -> str:
    relative, old_text, new_text = args["path"], args["old_text"], args["new_text"]
    path = session.safe_path(relative)
    instructions = session.instructions_loader.newly_loaded_text(relative)
    if instructions:
        return f"edit deferred: apply these newly discovered instructions, then retry:\n{instructions}"
    if not old_text:
        return "error: old_text must not be empty"
    if not session.approve("edit_file", relative):
        return "denied by user policy"
    current = path.read_text(encoding="utf-8")
    matches = current.count(old_text)
    if matches == 0:
        return f"error: old_text not found\n{_edit_hint(current, old_text)}"
    if matches > 1:
        return f"error: old_text matched {matches} times; provide a larger unique old_text"
    after = current.replace(old_text, new_text, 1)
    path.write_text(after, encoding="utf-8")
    session.record_change("edit", relative, True, current, True, after)
    return f"edited {relative}{_gene_parse_warning(path, session)}"


def _list_dir(args: MutableMapping[str, Any], session: Session) -> str:
    relative = args.get("path", ".")
    path = session.safe_path(relative)
    instructions = session.instructions_loader.newly_loaded_text(relative, True)
    listing = "\n".join(sorted(entry.name for entry in path.iterdir()))
    return (f"New applicable instructions (parent-to-child):\n{instructions}\n--- listing ---\n{listing}"
            if instructions else listing)


def _run_shell(args: MutableMapping[str, Any], session: Session) -> dict[str, Any] | str:
    command = args["command"]
    timeout_ms = args.get("timeout_ms", 10_000)
    if not 1 <= timeout_ms <= 120_000:
        return "error: timeout_ms must be between 1 and 120000"
    denial = session.guard_shell(command)
    if denial:
        return denial
    if not session.approve("run_shell", command):
        return "denied by user policy"
    result = session.run_process("run_shell", command, ["sh", "-c", command], timeout_ms)
    tail = (f"\n[timed out after {result.duration_ms} ms; requested cap {timeout_ms} ms. Retry with "
            "timeout_ms up to 120000 only when the command is expected to be slow.]" if result.timed_out else "")
    timing = (f"\n[execution: duration_ms={result.duration_ms} timeout_ms={timeout_ms} "
              f"timed_out={str(result.timed_out).lower()}]")
    return {"text": result.stdout + result.stderr + tail + timing, "truncated": result.truncated}


def _grep(args: MutableMapping[str, Any], session: Session) -> dict[str, Any]:
    relative = args.get("path", ".")
    path = session.safe_path(relative)
    command = f"grep -rn {args['pattern']} {relative}"
    result = session.run_process("grep", command, ["grep", "-rn", args["pattern"], str(path)], 10_000)
    tail = "\n[timed out]" if result.timed_out else ""
    return {"text": result.stdout + result.stderr + tail, "truncated": result.truncated}


def builtin_tools() -> list[Tool]:
    return [
        Tool("read_file", "Read a bounded line range from a UTF-8 text file inside the workspace.", "read", [
            Param("path", "string", True, "workspace-relative file path"),
            Param("start_line", "integer", doc="one-based first line; defaults to 1"),
            Param("max_lines", "integer", doc="maximum lines selected; defaults to 400, maximum 2000"),
            Param("start_byte", "integer", doc="zero-based UTF-8 byte offset; defaults to 0"),
            Param("max_bytes", "integer", doc="maximum bytes returned; defaults to 65536, maximum 262144"),
        ], _read_file),
        Tool("write_file", "Write a UTF-8 text file inside the workspace.", "write", [
            Param("path", "string", True, "workspace-relative file path"), Param("content", "string", True),
        ], _write_file),
        Tool("edit_file", "Replace one exact text span in a UTF-8 text file inside the workspace.", "write", [
            Param("path", "string", True, "workspace-relative file path"),
            Param("old_text", "string", True, "exact text to replace; must match exactly once"),
            Param("new_text", "string", True),
        ], _edit_file),
        Tool("list_dir", "List directory entries inside the workspace.", "read", [
            Param("path", "string", doc="workspace-relative directory; defaults to the workspace root"),
        ], _list_dir),
        Tool("run_shell", "Run a shell command in the workspace (10s default, 120s maximum timeout).", "execute", [
            Param("command", "string", True, "command line passed to sh -c"),
            Param("timeout_ms", "integer", doc="timeout in milliseconds; defaults to 10000, maximum 120000"),
        ], _run_shell),
        Tool("grep", "Search files in the workspace with grep -rn.", "read", [
            Param("pattern", "string", True),
            Param("path", "string", doc="workspace-relative directory or file; defaults to the workspace root"),
        ], _grep),
    ]


def message_item_text(item: Mapping[str, Any]) -> str:
    return "".join(str(part.get("text", "")) for part in item.get("content", [])
                   if isinstance(part, dict) and part.get("type") == "output_text")


def response_text(response: Mapping[str, Any]) -> str:
    if "output_text" in response:
        return str(response.get("output_text") or "")
    return "".join(message_item_text(item) for item in response.get("output", [])
                   if isinstance(item, dict) and item.get("type") == "message")


def response_calls(response: Mapping[str, Any]) -> list[dict[str, Any]]:
    return [dict(item) for item in response.get("output", [])
            if isinstance(item, dict) and item.get("type") == "function_call"]


def items_to_chat_messages(items: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    messages: list[dict[str, Any]] = []
    pending_text: str | None = None
    pending_calls: list[dict[str, Any]] = []

    def flush() -> None:
        nonlocal pending_text, pending_calls
        if pending_text is not None or pending_calls:
            message: dict[str, Any] = {"role": "assistant", "content": pending_text}
            if pending_calls:
                message["tool_calls"] = pending_calls
            messages.append(message)
            pending_text, pending_calls = None, []

    for item in items:
        item_type = item.get("type")
        if item_type is None:
            flush()
            messages.append({key: value for key, value in item.items() if key not in WIRE_INTERNAL_FIELDS})
        elif item_type == "message":
            pending_text = (pending_text or "") + message_item_text(item)
        elif item_type == "function_call":
            pending_calls.append({"id": item.get("call_id"), "type": "function", "function": {
                "name": item.get("name"), "arguments": item.get("arguments", "{}")}})
        elif item_type == "function_call_output":
            flush()
            messages.append({"role": "tool", "tool_call_id": item.get("call_id"), "content": item.get("output", "")})
    flush()
    return messages


class ChatStreamAssembler:
    def __init__(self, on_text: Callable[[str], None]) -> None:
        self.on_text = on_text
        self.text = ""
        self.calls: dict[int, dict[str, str]] = {}
        self.error: str | None = None

    def feed(self, chunk: Mapping[str, Any]) -> None:
        if isinstance(chunk.get("error"), dict):
            self.error = str(chunk["error"].get("message", "unknown API error"))
            return
        base = chunk.get("base_resp")
        if isinstance(base, dict) and base.get("status_code") not in (None, 0):
            self.error = f"API error {base.get('status_code')}: {base.get('status_msg')}"
            return
        choices = chunk.get("choices") or []
        if not isinstance(choices, list) or any(not isinstance(choice, Mapping) for choice in choices):
            raise ValueError("chat stream choices must be an array of objects")
        delta = choices[0].get("delta", {}) if choices else {}
        if not isinstance(delta, Mapping):
            raise ValueError("chat stream delta must be an object")
        content = delta.get("content")
        if content:
            self.text += str(content)
            self.on_text(str(content))
        fragments = delta.get("tool_calls") or []
        if not isinstance(fragments, list):
            raise ValueError("chat stream tool_calls must be an array")
        for fragment in fragments:
            if not isinstance(fragment, Mapping):
                raise ValueError("chat stream tool-call fragment must be an object")
            index = int(fragment.get("index", 0))
            entry = self.calls.setdefault(index, {"id": "", "name": "", "arguments": ""})
            if fragment.get("id") is not None:
                entry["id"] = str(fragment["id"])
            function = fragment.get("function") or {}
            if not isinstance(function, Mapping):
                raise ValueError("chat stream tool-call function must be an object")
            entry["name"] += str(function.get("name", ""))
            entry["arguments"] += str(function.get("arguments", ""))

    def response(self) -> dict[str, Any]:
        if self.error:
            return {"agent_error": self.error}
        output: list[dict[str, Any]] = []
        if self.text:
            output.append({"type": "message", "role": "assistant",
                           "content": [{"type": "output_text", "text": self.text}]})
        for index in sorted(self.calls):
            call = self.calls[index]
            output.append({"type": "function_call", "name": call["name"],
                           "call_id": call["id"], "arguments": call["arguments"]})
        return {"output": output, "output_text": self.text}


def sse_payloads(source: Any, max_bytes: int = MAX_HTTP_BYTES,
                 pending_cap: int = MAX_SSE_PENDING_BYTES) -> Iterator[str]:
    consumed = 0
    pending = bytearray()
    data: list[str] = []
    data_bytes = 0

    def chunks() -> Iterator[bytes]:
        if callable(getattr(source, "read", None)):
            while True:
                chunk = source.read(8192)
                if not chunk:
                    break
                yield chunk
        else:
            yield from source

    for raw in chunks():
        if not isinstance(raw, bytes):
            raise ValueError("HTTP streaming response yielded a non-byte chunk")
        consumed += len(raw)
        if consumed > max_bytes:
            raise ValueError("HTTP streaming response exceeded byte cap")
        pending.extend(raw)
        if len(pending) > pending_cap:
            raise ValueError("HTTP streaming response exceeded pending-event byte cap")
        while (newline := pending.find(b"\n")) >= 0:
            raw_line = bytes(pending[:newline]).rstrip(b"\r")
            del pending[:newline + 1]
            line = raw_line.decode("utf-8")
            if not line:
                if data:
                    yield "\n".join(data)
                    data, data_bytes = [], 0
            elif line.startswith("data:"):
                value = line[5:].lstrip(" ")
                data_bytes += len(value.encode("utf-8"))
                if data_bytes > pending_cap:
                    raise ValueError("HTTP streaming event exceeded byte cap")
                data.append(value)
    if pending:
        line = bytes(pending).rstrip(b"\r").decode("utf-8")
        if line.startswith("data:"):
            value = line[5:].lstrip(" ")
            data_bytes += len(value.encode("utf-8"))
            if data_bytes > pending_cap:
                raise ValueError("HTTP streaming event exceeded byte cap")
            data.append(value)
    if data:
        yield "\n".join(data)


class NoPostRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req: Any, fp: Any, code: int, msg: str,
                         headers: Any, newurl: str) -> None:
        return None


class HttpTransport:
    def __init__(self, session: Session) -> None:
        self.session = session

    def __call__(self, body: Mapping[str, Any], on_text: Callable[[str], None]) -> dict[str, Any]:
        flavor = self.session.config.api_flavor
        suffix = "/chat/completions" if flavor == "chat" else "/responses"
        url = self.session.config.base.rstrip("/") + suffix
        parsed_url = urllib.parse.urlsplit(url)
        if (self.session.config.auth_token is not None and parsed_url.scheme.lower() == "http"
                and (parsed_url.hostname or "").lower() not in {"localhost", "127.0.0.1", "::1"}):
            return {"agent_error": "credentialed plaintext HTTP is allowed only for loopback endpoints"}
        headers = {"Authorization": f"Bearer {self.session.config.auth_token}",
                   "Content-Type": "application/json", "Accept": "text/event-stream"}
        if self.session.config.base == CODEX_BASE:
            headers.update({"User-Agent": "codex_cli_rs/0.0.0 (Gene AI Agent)", "originator": "codex_cli_rs"})
        safe_body = self.session.redactor.any(body)
        request = urllib.request.Request(url, json.dumps(safe_body).encode(), headers=headers, method="POST")
        timeout = 120 if flavor == "chat" else 60
        try:
            response = urllib.request.build_opener(NoPostRedirect()).open(request, timeout=timeout)
            self.session._active_response = response
            content_type = response.headers.get("Content-Type", "")
            if "text/event-stream" in content_type:
                result = self._chat_sse(response, on_text) if flavor == "chat" else self._responses_sse(response, on_text)
            else:
                raw = response.read(MAX_HTTP_BYTES + 1)
                if len(raw) > MAX_HTTP_BYTES:
                    raise ValueError("HTTP response exceeded byte cap")
                parsed = json.loads(raw)
                if not isinstance(parsed, dict):
                    raise ValueError("API returned a non-object JSON response")
                result = chat_response_from_json(parsed) if flavor == "chat" else parsed
                if flavor != "chat" and (result.get("error") or result.get("status") == "failed"):
                    result = {"agent_error": api_error_text(result)}
            return self.session.redactor.any(result)
        except urllib.error.HTTPError as error:
            try:
                raw = error.read(65_536).decode("utf-8", "replace")
                if 300 <= error.code < 400:
                    return {"agent_error": self.session.redactor.text(f"HTTP redirect rejected ({error.code})")}
                try:
                    parsed = json.loads(raw)
                    message = api_error_text(parsed)
                except ValueError:
                    message = f"HTTP {error.code}: {raw}"
                return {"agent_error": self.session.redactor.text(message)}
            finally:
                error.close()
        except (OSError, ValueError, json.JSONDecodeError) as error:
            return {"agent_error": self.session.redactor.text(f"HTTP transport failed: {error}")}
        finally:
            if self.session._active_response:
                try:
                    self.session._active_response.close()
                except Exception:
                    pass
            self.session._active_response = None

    def _responses_sse(self, response: Any, on_text: Callable[[str], None]) -> dict[str, Any]:
        output: list[dict[str, Any]] = []
        text = ""
        final: dict[str, Any] | None = None
        terminal: str | None = None
        done = False
        for payload in sse_payloads(response):
            if payload == "[DONE]":
                done = True
                continue
            if done or terminal is not None:
                raise ValueError("SSE stream contained data after its terminal event")
            try:
                event = json.loads(payload)
            except json.JSONDecodeError as error:
                raise ValueError(f"malformed SSE JSON event: {error}") from error
            if not isinstance(event, Mapping):
                raise ValueError("SSE event must decode to an object")
            kind = event.get("type")
            if kind == "response.output_text.delta":
                delta = str(event.get("delta", ""))
                text += delta
                on_text(self.session.redactor.text(delta))
            elif kind == "response.output_item.done":
                if not isinstance(event.get("item"), Mapping):
                    raise ValueError("response output item must be an object")
                output.append(dict(event["item"]))
            elif kind == "response.output_text.done":
                text = str(event.get("text", text))
            elif kind in {"response.completed", "response.failed", "response.incomplete"}:
                if not isinstance(event.get("response"), Mapping):
                    raise ValueError("terminal response event must contain an object response")
                terminal = str(kind)
                final = dict(event["response"])
        if terminal != "response.completed":
            if terminal in {"response.failed", "response.incomplete"}:
                return {"agent_error": api_error_text(final or {"status": terminal.removeprefix("response.")})}
            raise ValueError("stream ended before response.completed")
        result = dict(final or {})
        result.update({"output": output, "output_text": text})
        if result.get("error") or result.get("status") in {"failed", "incomplete"}:
            return {"agent_error": api_error_text(result)}
        return result

    @staticmethod
    def _chat_sse(response: Any, on_text: Callable[[str], None]) -> dict[str, Any]:
        assembler = ChatStreamAssembler(on_text)
        done = False
        for payload in sse_payloads(response):
            if payload == "[DONE]":
                done = True
                continue
            if done:
                raise ValueError("chat stream contained data after [DONE]")
            try:
                chunk = json.loads(payload)
            except json.JSONDecodeError as error:
                raise ValueError(f"malformed SSE JSON chunk: {error}") from error
            if not isinstance(chunk, Mapping):
                raise ValueError("SSE chat chunk must decode to an object")
            assembler.feed(chunk)
        if not done:
            raise ValueError("chat stream ended before [DONE]")
        return assembler.response()


def api_error_text(response: Mapping[str, Any]) -> str:
    error = response.get("error") if isinstance(response.get("error"), dict) else {}
    message = error.get("message", response.get("detail", "unknown API error"))
    code_value = error.get("code")
    code_text = f" ({code_value})" if code_value is not None else ""
    return f"OpenAI API error {response.get('status', '?')}: {message}{code_text}"


def chat_response_from_json(response: Mapping[str, Any]) -> dict[str, Any]:
    if isinstance(response.get("error"), dict):
        return {"agent_error": api_error_text(response)}
    base = response.get("base_resp")
    if isinstance(base, dict) and base.get("status_code") not in (None, 0):
        return {"agent_error": f"API error {base.get('status_code')}: {base.get('status_msg')}"}
    choices = response.get("choices") or []
    message = choices[0].get("message", {}) if choices else {}
    text = str(message.get("content") or "")
    output: list[dict[str, Any]] = []
    if text:
        output.append({"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": text}]})
    for call in message.get("tool_calls") or []:
        function = call.get("function") or {}
        output.append({"type": "function_call", "name": function.get("name", ""),
                       "call_id": call.get("id", ""), "arguments": function.get("arguments", "")})
    return {"output": output, "output_text": text}


class DemoTransport:
    def __init__(self) -> None:
        self.calls = 0

    def __call__(self, body: Mapping[str, Any], on_text: Callable[[str], None]) -> dict[str, Any]:
        self.calls += 1
        if self.calls == 1:
            return {"output": [{"type": "function_call", "name": "list_dir", "call_id": "call_1",
                                "arguments": '{"path":"."}'}]}
        return {"output": [{"type": "message", "role": "assistant",
                            "content": [{"type": "output_text",
                                         "text": "I listed the workspace via the list_dir tool."}]}]}


Transport = Callable[[Mapping[str, Any], Callable[[str], None]], dict[str, Any]]


class TurnCancelled(Exception):
    pass


class Agent:
    def __init__(self, session: Session, transport: Transport | None = None) -> None:
        self.session = session
        self.transport = transport or (HttpTransport(session) if session.config.auth_token is not None else DemoTransport())

    def request_body(self, items: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
        if self.session.config.api_flavor == "chat":
            return {"model": self.session.config.model, "messages": items_to_chat_messages(items),
                    "tools": [tool.chat_schema() for tool in self.session.tools.values()],
                    "tool_choice": "auto", "stream": True}
        safe_items = [{key: value for key, value in item.items() if key not in WIRE_INTERNAL_FIELDS}
                      for item in items]
        return {"model": self.session.config.model, "store": False, "stream": True, "input": safe_items,
                "tools": [tool.schema() for tool in self.session.tools.values()], "tool_choice": "auto",
                "parallel_tool_calls": True}

    def run_tool_call(self, call: Mapping[str, Any]) -> dict[str, Any]:
        name, call_id = str(call.get("name", "")), str(call.get("call_id", ""))
        raw_arguments = call.get("arguments", "{}")
        try:
            args = json.loads(raw_arguments) if isinstance(raw_arguments, str) else raw_arguments
            parse_error = None
        except json.JSONDecodeError as error:
            args, parse_error = raw_arguments, str(error)
        self.session.emit("tool_call", id=call_id, name=name, args=args)
        tool = self.session.tools.get(name)
        if not tool:
            result: Any = f"error: unknown tool {name}"
        elif parse_error:
            result = f"error: bad tool arguments: {parse_error}"
        else:
            validation = tool.validate(args)
            if validation:
                result = f"error: {validation}"
            else:
                try:
                    result = tool.handler(args, self.session)
                except (OSError, ValueError, UnicodeError) as error:
                    result = f"error: {error}"
                except Exception as error:
                    result = f"error: tool failed: {error}"
        if isinstance(result, str):
            text, truncated = result, False
        elif isinstance(result, dict) and isinstance(result.get("text"), str):
            text, truncated = result["text"], result.get("truncated") is True
        else:
            text, truncated = "error: tool returned an invalid result shape", False
        text = self.session.redactor.text(text)
        shown = text + ("\n[output truncated]" if truncated else "")
        self.session.emit("tool_result", id=call_id, name=name, value=shown, truncated=truncated)
        return {"type": "function_call_output", "call_id": call_id, "output": shown}

    def run_turn(self, items: Sequence[Mapping[str, Any]], render: Callable[[str], None],
                 render_stream: Callable[[str], None]) -> list[dict[str, Any]]:
        active = compact_context(items, self.session.memory, self.session.config, self.session.emit)
        budget = self.session.config.max_tool_rounds
        total_tool_calls = 0
        seen_call_ids: set[str] = set()
        self.session.current_task = threading.current_thread()
        self.session._cancel_event.clear()

        def check_cancelled() -> None:
            if self.session._cancel_event.is_set():
                raise TurnCancelled

        try:
            while True:
                check_cancelled()
                request_items = list(active)
                if budget == 2:
                    request_items.append(system_item("Two executable tool rounds remain. Plan the landing now: avoid "
                                                     "exploratory edits and leave the final round for verification."))
                elif budget == 1:
                    request_items.append(system_item("One executable tool round remains. Prioritize verification and "
                                                     "avoid further writes unless absolutely necessary."))
                elif budget <= 0:
                    request_items.append(system_item("The executable tool-round budget is exhausted. Do not request "
                                                     "tools; give an honest final status with unverified work stated."))
                streamed = False

                def on_text(text: str) -> None:
                    nonlocal streamed
                    streamed = True
                    safe = self.session.redactor.text(text)
                    self.session.emit("text_delta", text=safe)
                    render_stream(safe)

                response = self.transport(self.request_body(request_items), on_text)
                check_cancelled()
                if not isinstance(response, Mapping):
                    response = {"agent_error": "transport returned an invalid response shape"}
                if response.get("agent_error") is not None:
                    error = str(response["agent_error"])
                    self.session.emit("error", text=error)
                    render(error)
                    self.session.emit("turn_done")
                    return active
                output = [dict(item) for item in response.get("output", []) if isinstance(item, dict)]
                for item in output:
                    self.session.emit("model_item", item=item)
                calls = response_calls(response)
                if not calls:
                    text = response_text(response)
                    self.session.emit("agent_text", text=text)
                    render("" if streamed else self.session.redactor.text(text))
                    self.session.emit("turn_done", text=text)
                    return [*active, *output]
                call_ids = [str(call.get("call_id", "")) for call in calls]
                invalid_calls = (len(calls) > MAX_TOOL_CALLS_PER_RESPONSE
                                 or total_tool_calls + len(calls) > MAX_TOOL_CALLS_PER_TURN
                                 or any(not call_id for call_id in call_ids)
                                 or len(call_ids) != len(set(call_ids))
                                 or any(call_id in seen_call_ids for call_id in call_ids))
                if invalid_calls:
                    error = (f"tool-call limits or identities rejected: maximum {MAX_TOOL_CALLS_PER_RESPONSE} "
                             f"calls per response and {MAX_TOOL_CALLS_PER_TURN} per turn; call ids must be "
                             "non-empty and unique")
                    self.session.emit("error", kind="tool_call_policy", text=error)
                    render(error)
                    self.session.emit("turn_done", failed=True)
                    return active
                if budget <= 0:
                    render("[stopped: tool_call budget exhausted]")
                    self.session.emit("turn_done")
                    return active
                total_tool_calls += len(calls)
                seen_call_ids.update(call_ids)
                outputs = []
                for call in calls:
                    check_cancelled()
                    outputs.append(self.run_tool_call(call))
                    active = self.session.with_workspace_instructions(active)
                    check_cancelled()
                    safe_arguments = self.session.redactor.any(call.get("arguments"))
                    render(f"  · tool {call.get('name')} {safe_arguments}")
                active.extend(output)
                active.extend(outputs)
                active = compact_context(active, self.session.memory, self.session.config, self.session.emit)
                budget -= 1
        except (KeyboardInterrupt, TurnCancelled):
            self.session.emit("error", kind="cancelled", text="turn cancelled")
            self.session.emit("turn_done", cancelled=True)
            render("[turn cancelled; enter steering to continue]")
            return active
        finally:
            self.session.current_task = None
            self.session._active_process = None
            self.session._active_response = None

    def submit(self, text: str, render: Callable[[str], None],
               render_stream: Callable[[str], None]) -> list[dict[str, Any]]:
        self.session.event_log.begin_turn()
        self.session.emit("user_input", text=text)
        self.session.items = self.run_turn([*self.session.items, user_item(text)], render, render_stream)
        self.session.save()
        return self.session.items


class LineTerminal:
    def __init__(self, session: Session) -> None:
        self.session = session

    def read(self) -> str | None:
        try:
            return input("you> ")
        except EOFError:
            return None

    def append(self, text: str) -> None:
        self.session.transcript += text
        print(text, end="", flush=True)

    def close(self) -> None:
        pass


class CursesTerminal:
    """Small persistent transcript editor with history, multiline input, and scrolling."""

    STATUS = "Mouse/PgUp/PgDn scroll | Enter sends | Alt+Enter/Ctrl-O newline | Up/Down history | /quit"

    def __init__(self, session: Session) -> None:
        import curses
        self.curses = curses
        self.session = session
        self.screen = curses.initscr()
        curses.noecho()
        curses.cbreak()
        self.screen.keypad(True)
        try:
            curses.mousemask(curses.ALL_MOUSE_EVENTS)
        except curses.error:
            pass
        try:
            curses.curs_set(1)
        except curses.error:
            pass
        self.history: list[str] = []
        self.scroll = 0

    def _draw(self, buffer: list[str], cursor: int) -> None:
        curses = self.curses
        self.screen.erase()
        rows, cols = self.screen.getmaxyx()
        input_text = "".join(buffer)
        input_lines = input_text.split("\n") or [""]
        input_rows = min(max(1, len(input_lines)), max(1, rows // 3))
        output_rows = max(1, rows - input_rows - 3)
        visual: list[str] = []
        width = max(1, cols - 1)
        for line in self.session.transcript.splitlines():
            visual.extend(line[i:i + width] or "" for i in range(0, max(1, len(line)), width))
        end = max(0, len(visual) - self.scroll)
        start = max(0, end - output_rows)
        for row, line in enumerate(visual[start:end]):
            self.screen.addnstr(row, 0, line, width)
        separator = "─" * width
        self.screen.addnstr(output_rows, 0, separator, width)
        for offset, line in enumerate(input_lines[-input_rows:]):
            self.screen.addnstr(output_rows + 1 + offset, 0, line, width)
        self.screen.addnstr(rows - 2, 0, separator, width)
        status = self.STATUS + (f" [SCROLL +{self.scroll}]" if self.scroll else "")
        self.screen.addnstr(rows - 1, 0, status, width)
        before = input_text[:cursor]
        cursor_row = output_rows + 1 + min(input_rows - 1, before.count("\n"))
        cursor_col = len(before.rsplit("\n", 1)[-1]) % width
        self.screen.move(cursor_row, cursor_col)
        self.screen.refresh()

    def read(self) -> str | None:
        curses = self.curses
        buffer: list[str] = []
        cursor = 0
        history_index = len(self.history)
        while True:
            self._draw(buffer, cursor)
            try:
                key = self.screen.get_wch()
            except KeyboardInterrupt:
                buffer, cursor = [], 0
                continue
            if key in ("\n", "\r") or key == curses.KEY_ENTER:
                value = "".join(buffer)
                if value:
                    self.history.append(value)
                return value
            if key == "\x04" and not buffer:
                return None
            if key == "\x0f":
                buffer.insert(cursor, "\n")
                cursor += 1
            elif key == "\x1b":
                self.screen.nodelay(True)
                try:
                    following = self.screen.get_wch()
                except curses.error:
                    following = None
                finally:
                    self.screen.nodelay(False)
                if following in ("\n", "\r", curses.KEY_ENTER):
                    buffer.insert(cursor, "\n")
                    cursor += 1
                elif isinstance(following, str) and following.isprintable():
                    buffer.insert(cursor, following)
                    cursor += 1
            elif key in (curses.KEY_BACKSPACE, "\b", "\x7f") and cursor:
                cursor -= 1
                buffer.pop(cursor)
            elif key == curses.KEY_DC and cursor < len(buffer):
                buffer.pop(cursor)
            elif key == curses.KEY_LEFT:
                cursor = max(0, cursor - 1)
            elif key == curses.KEY_RIGHT:
                cursor = min(len(buffer), cursor + 1)
            elif key == curses.KEY_HOME:
                cursor = 0
            elif key == curses.KEY_END:
                cursor = len(buffer)
            elif key == curses.KEY_PPAGE:
                self.scroll += max(1, self.screen.getmaxyx()[0] - 5)
            elif key == curses.KEY_NPAGE:
                self.scroll = max(0, self.scroll - max(1, self.screen.getmaxyx()[0] - 5))
            elif key == curses.KEY_MOUSE:
                try:
                    _id, _x, _y, _z, state = curses.getmouse()
                    if state & (getattr(curses, "BUTTON4_PRESSED", 0) | getattr(curses, "BUTTON4_CLICKED", 0)):
                        self.scroll += 3
                    elif state & (getattr(curses, "BUTTON5_PRESSED", 0) | getattr(curses, "BUTTON5_CLICKED", 0)):
                        self.scroll = max(0, self.scroll - 3)
                except curses.error:
                    pass
            elif key in (curses.KEY_UP, curses.KEY_DOWN) and self.history:
                history_index += -1 if key == curses.KEY_UP else 1
                history_index = max(0, min(len(self.history), history_index))
                value = self.history[history_index] if history_index < len(self.history) else ""
                buffer, cursor = list(value), len(value)
            elif isinstance(key, str) and key.isprintable():
                buffer.insert(cursor, key)
                cursor += 1

    def append(self, text: str) -> None:
        self.session.transcript += text
        self.scroll = 0
        self._draw([], 0)

    def close(self) -> None:
        curses = self.curses
        try:
            self.screen.keypad(False)
            curses.echo()
            curses.nocbreak()
            curses.endwin()
        except curses.error:
            pass


class Cli:
    def __init__(self, session: Session, agent: Agent | None = None) -> None:
        self.session = session
        self.agent = agent or Agent(session)
        self.terminal: LineTerminal | CursesTerminal | None = None
        self.streaming = False
        self.session.prompt_handler = self._prompt_outside_curses

    def _prompt_outside_curses(self, prompt: str) -> str:
        reopen = isinstance(self.terminal, CursesTerminal)
        if reopen:
            self.terminal.close()
            self.terminal = None
        try:
            return input(prompt)
        finally:
            if reopen:
                self.terminal = self._open_terminal()

    def _open_terminal(self) -> LineTerminal | CursesTerminal:
        if sys.stdin.isatty() and sys.stdout.isatty():
            try:
                return CursesTerminal(self.session)
            except Exception:
                pass
        return LineTerminal(self.session)

    def render_stream(self, text: str) -> None:
        if not text:
            return
        if not self.streaming:
            self.terminal.append("agent> ")
            self.streaming = True
        self.terminal.append(text)

    def render(self, text: str) -> None:
        if self.streaming:
            self.terminal.append("\n")
            self.streaming = False
        if text:
            self.terminal.append(f"agent> {text}\n")

    def run_repl(self) -> bool:
        if self.terminal:
            self.terminal.close()
        self.session.resume_requested = False
        console = code.InteractiveConsole({"session": self.session, "Tool": Tool, "Param": Param,
                                           "classify_command": classify_command})
        print("Entering Python REPL. `session`, `Tool`, `Param`, and `classify_command` are bound. "
              "Use session.add_tool/remember/subscribe/trace/diff/undo/cancel/resume; Ctrl-D returns.")
        try:
            console.interact(banner="", exitmsg="")
        except SystemExit:
            pass
        self.terminal = self._open_terminal()
        return self.session.resume_requested

    def shell(self) -> None:
        if self.terminal:
            self.terminal.close()
        print(f"Entering shell ({self.session.config.shell}). exit/quit or Ctrl-D returns.")
        try:
            if sys.stdin.isatty():
                subprocess.run([self.session.config.shell], cwd=self.session.workspace, check=False)
            else:
                for line in sys.stdin:
                    command = line.rstrip("\n")
                    if command in {"exit", "quit"}:
                        break
                    denial = self.session.guard_shell(command)
                    if denial:
                        print(denial)
                        continue
                    result = self.session.run_process("sh", command,
                                                      [self.session.config.shell, "-lc", command], 60_000, 400_000)
                    print(self.session.redactor.text(result.stdout), end="")
                    print(self.session.redactor.text(result.stderr), end="", file=sys.stderr)
                    if result.timed_out:
                        print("[timed out]")
        except KeyboardInterrupt:
            print("\n[returning to agent]")
        finally:
            self.terminal = self._open_terminal()

    def command(self, line: str) -> bool:
        if line == "/quit":
            return False
        if line == "/sh":
            self.shell()
        elif line == "/repl":
            if self.run_repl():
                self.session.items = self.agent.run_turn(self.session.items, self.render, self.render_stream)
                self.session.save()
        elif line == "/memory":
            self.render("memory is empty" if not self.session.memory else "memory:\n" + "\n".join(self.session.memory))
        elif line == "/forget-memory":
            self.session.memory.clear()
            self.session.refresh_system_memory()
            self.session.emit("memory", action="clear", text="memory cleared")
            self.session.save()
            self.render("memory cleared")
        elif line.startswith("/remember "):
            note = line[len("/remember "):].strip()
            self.render(self.session.remember(note) if note else "usage: /remember <note>")
        elif line == "/status":
            self.render(self.session.status())
        elif line == "/diff":
            self.render(self.session.diff())
        elif line == "/undo" or line.startswith("/undo "):
            try:
                wanted = int(line[len("/undo "):].strip()) if line.startswith("/undo ") else None
                self.render(self.session.undo(wanted))
            except ValueError:
                self.render("usage: /undo [change-id]")
        elif line == "/trace" or line.startswith("/trace "):
            self.render(self.session.trace(line[len("/trace"):].strip()))
        else:
            self.agent.submit(line, self.render, self.render_stream)
        return True

    def run(self) -> None:
        self.terminal = self._open_terminal()
        self.session.event_log.echo = lambda text: self.render(f"[event] {text}")
        try:
            while True:
                line = self.terminal.read()
                if line is None:
                    break
                if not line.strip():
                    continue
                self.session.transcript += f"──────\n{line}\n"
                if not self.command(line):
                    break
        finally:
            self.session.save()
            self.terminal.close()


def run_one_shot(task: str, session: Session | None = None) -> Session:
    session = session or Session()
    print(f"Gene AI agent - model {session.config.model}")
    print(f"user> {task}")
    if session.config.auth_token is None:
        print("No OPENAI_AUTH_TOKEN, OPENAI_API_KEY, or CODEX_ACCESS_TOKEN set - using offline demo transport.")
    agent = Agent(session)
    streaming = [False]

    def stream(text: str) -> None:
        if not streaming[0]:
            print("agent> ", end="", flush=True)
            streaming[0] = True
        print(text, end="", flush=True)

    def render(text: str) -> None:
        if streaming[0]:
            print()
            streaming[0] = False
        if text:
            print(f"agent> {text}")

    agent.submit(task, render, stream)
    session.transcript += f"user> {task}\n"
    session.save()
    return session


def run_demo() -> Session:
    print("No OPENAI_AUTH_TOKEN, OPENAI_API_KEY, or CODEX_ACCESS_TOKEN set — running the offline demo.")
    print("user> what's in this directory?")
    session = Session()
    agent = Agent(session, DemoTransport())
    agent.submit("what's in this directory?",
                 lambda text: print(f"agent> {text}") if text else None,
                 lambda text: print(text, end="", flush=True))
    print("Demo complete. Set OPENAI_AUTH_TOKEN, OPENAI_API_KEY, or CODEX_ACCESS_TOKEN to go live.")
    return session


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    task = " ".join(args).strip()
    config = Config.from_env()
    if task:
        run_one_shot(task, Session(config))
    elif config.auth_token is None:
        run_demo()
    else:
        session = Session(config)
        print(f"Gene AI agent - model {config.model}. Type /quit to exit.")
        Cli(session).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())