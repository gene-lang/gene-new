from __future__ import annotations

import dataclasses
import io
import json
import os
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from examples.ai_agent import tui


def config_for(**env: str) -> tui.Config:
    return tui.Config.from_env({"GENE_AGENT_STATE": "", **env})


class FakeResponsesServer:
    def __init__(self) -> None:
        self.requests: list[dict] = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                owner.requests.append(json.loads(self.rfile.read(length)))
                if len(owner.requests) == 1:
                    item = {"type": "function_call", "name": "list_dir",
                            "call_id": "call_1", "arguments": "{\"path\":\".\"}"}
                    events = [
                        {"type": "response.output_item.done", "item": item},
                        {"type": "response.completed", "response": {"status": "completed"}},
                    ]
                else:
                    item = {"type": "message", "role": "assistant",
                            "content": [{"type": "output_text", "text": "done"}]}
                    events = [
                        {"type": "response.output_text.delta", "delta": "done"},
                        {"type": "response.output_item.done", "item": item},
                        {"type": "response.completed", "response": {"status": "completed"}},
                    ]
                payload = "".join(f"data: {json.dumps(event)}\n\n" for event in events) + "data: [DONE]\n\n"
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(payload.encode())))
                self.end_headers()
                self.wfile.write(payload.encode())

            def log_message(self, _format: str, *_args: object) -> None:
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self) -> "FakeResponsesServer":
        self.thread.start()
        return self

    def __exit__(self, *_args: object) -> None:
        self.server.shutdown()
        self.thread.join(timeout=2)
        self.server.server_close()

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.server.server_port}"


class StaticSseServer:
    def __init__(self, payload: str) -> None:
        self.payload = payload.encode()
        self.requests: list[dict] = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                owner.requests.append(json.loads(self.rfile.read(length)))
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(owner.payload)))
                self.end_headers()
                self.wfile.write(owner.payload)

            def log_message(self, _format: str, *_args: object) -> None:
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self) -> "StaticSseServer":
        self.thread.start()
        return self

    def __exit__(self, *_args: object) -> None:
        self.server.shutdown()
        self.thread.join(timeout=2)
        self.server.server_close()

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.server.server_port}"


class ConfigAndSafetyTests(unittest.TestCase):
    def test_environment_precedence_defaults_and_flavor(self) -> None:
        config = config_for(OPENAI_AUTH_TOKEN="first", OPENAI_API_KEY="second")
        self.assertEqual(config.auth_token, "first")
        self.assertEqual(config.base, tui.CODEX_BASE)
        self.assertEqual(config.model, "gpt-5.6-terra")
        self.assertEqual(config.api_flavor, "responses")
        custom = config_for(OPENAI_BASE_URL="http://localhost:9000/v1", OPENAI_API_KEY="key")
        self.assertEqual(custom.api_flavor, "chat")
        self.assertEqual(custom.max_tool_rounds, 12)

    def test_command_classifier_matches_guard_policy(self) -> None:
        self.assertEqual(tui.classify_command("grep shutdown src/"), "normal")
        self.assertEqual(tui.classify_command("git reset --hard HEAD"), "destructive")
        self.assertEqual(tui.classify_command("rm -rf build/cache"), "destructive")
        self.assertEqual(tui.classify_command("rm -rf /"), "catastrophic")
        self.assertEqual(tui.classify_command("echo ok && shutdown now"), "catastrophic")
        self.assertEqual(tui.classify_command("DELETE FROM users"), "destructive")
        self.assertEqual(tui.classify_command("DELETE FROM users WHERE id=1"), "normal")

    def test_realpath_confinement_rejects_escape_and_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as outside:
            session = tui.Session(config_for(), root)
            self.assertEqual(session.safe_path("inside.txt"), (Path(root) / "inside.txt").resolve())
            with self.assertRaises(ValueError):
                session.safe_path("../outside.txt")
            with self.assertRaises(ValueError):
                session.safe_path(str(Path(outside) / "outside.txt"))
            link = Path(root) / "link"
            try:
                link.symlink_to(outside, target_is_directory=True)
            except OSError:
                self.skipTest("symlinks unavailable")
            with self.assertRaises(ValueError):
                session.safe_path("link/outside.txt")

    def test_redactor_prefers_longest_secret_and_redacts_keys_and_values(self) -> None:
        redactor = tui.Redactor(["token", "token-long"])
        safe = redactor.any({"token-long-key": {"value": "token-long token"}})
        rendered = json.dumps(safe)
        self.assertNotIn("token-long", rendered)
        self.assertNotIn('"token"', rendered)
        self.assertIn("auth-***REDACTED***-key", rendered)


class ToolsAndStateTests(unittest.TestCase):
    def test_tool_schema_validation_and_offline_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            session = tui.Session(config_for(), root)
            read = session.tools["read_file"]
            self.assertEqual(read.schema()["parameters"]["required"], ["path"])
            self.assertIn("path", read.validate({}))
            rendered: list[str] = []
            agent = tui.Agent(session, tui.DemoTransport())
            result = agent.submit("list files", rendered.append, rendered.append)
            self.assertTrue(any(item.get("type") == "function_call_output" for item in result))
            self.assertIn("tool_call", [event["type"] for event in session.events])
            self.assertIn("tool_result", [event["type"] for event in session.events])
            self.assertEqual([e for e in session.events if e["type"] == "turn_done"].__len__(), 1)

    def test_write_edit_diff_and_targeted_undo_preserve_later_change(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            session = tui.Session(config_for(), root)
            agent = tui.Agent(session, tui.DemoTransport())
            write = agent.run_tool_call({"name": "write_file", "call_id": "w1",
                                         "arguments": '{"path":"note.txt","content":"one\\n"}'})
            self.assertIn("wrote note.txt", write["output"])
            edit = agent.run_tool_call({"name": "edit_file", "call_id": "e1",
                                        "arguments": '{"path":"note.txt","old_text":"one","new_text":"two"}'})
            self.assertIn("edited note.txt", edit["output"])
            self.assertIn("change #2", session.diff())
            (Path(root) / "note.txt").write_text("user change\n", encoding="utf-8")
            self.assertIn("refused", session.undo(2))
            self.assertEqual((Path(root) / "note.txt").read_text(), "user change\n")

    def test_nested_secrets_are_redacted_from_events_and_state(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            state = Path(root) / "state"
            config = tui.Config.from_env({"OPENAI_AUTH_TOKEN": "top-secret",
                                          "GENE_AGENT_STATE": str(state)})
            session = tui.Session(config, root)
            session.emit("error", text="top-secret", nested={"value": ["top-secret"]})
            session.save()
            persisted = "\n".join(path.read_text() for path in state.glob("*.json"))
            self.assertNotIn("top-secret", persisted)
            self.assertIn("auth-***REDACTED***", persisted)

    def test_trace_filters_and_context_compaction_keep_tool_pair(self) -> None:
        config = dataclasses.replace(config_for(), context_max_items=6, context_keep_turns=1,
                                     context_max_bytes=100_000)
        events = tui.EventLog(tui.Redactor())
        events.begin_turn()
        events.emit("tool_call", name="read_file", args={"path": "src/a.gene"})
        self.assertIn("read_file", events.report("type=tool_call path=src/"))
        items = [tui.system_item("system")]
        for index in range(3):
            items.extend([tui.user_item(f"turn {index}"),
                          {"type": "function_call", "call_id": f"c{index}"},
                          {"type": "function_call_output", "call_id": f"c{index}", "output": "ok"}])
        compacted = tui.compact_context(items, [], config, events.emit)
        retained = [item.get("call_id") for item in compacted if item.get("type", "").startswith("function_call")]
        self.assertEqual(retained, ["c2", "c2"])
        self.assertTrue(events.trace("context_compacted"))

    def test_tool_registration_rejects_bad_declarations_but_accepts_extra_args(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            session = tui.Session(config_for(), root)
            handler = lambda _args, _session: "ok"
            with self.assertRaises(ValueError):
                session.add_tool(tui.Tool("Bad-Name", "", "read", [], handler))
            with self.assertRaises(ValueError):
                session.add_tool(tui.Tool("duplicate", "", "read",
                                          [tui.Param("x", "string"), tui.Param("x", "string")], handler))
            with self.assertRaises(ValueError):
                session.add_tool(tui.Tool("unsupported", "", "read", [tui.Param("x", "number")], handler))
            with self.assertRaises(ValueError):
                session.add_tool(tui.Tool("bad_risk", "", "admin", [], handler))
            with self.assertRaises(ValueError):
                session.add_tool(tui.Tool("bad_param", "", "read", [tui.Param("Bad-Param", "string")], handler))
            with self.assertRaises(ValueError):
                session.add_tool(tui.Tool("bad_handler", "", "read", [], None))
            tool = tui.Tool("extra_args", "", "read", [tui.Param("x", "string", True)], handler)
            session.add_tool(tool)
            self.assertIsNone(tool.validate({"x": "yes", "model_supplied_extra": 1}))

    def test_cancelled_parallel_batch_stops_before_second_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            session = tui.Session(config_for(), root)
            mutated: list[bool] = []
            session.add_tool(tui.Tool("cancel_now", "", "read", [],
                                      lambda _args, active: active.cancel()))
            session.add_tool(tui.Tool("mutate_later", "", "write", [],
                                      lambda _args, _active: mutated.append(True) or "mutated"))

            def transport(_body: object, _on_text: object) -> dict:
                return {"output": [
                    {"type": "function_call", "name": "cancel_now", "call_id": "c1", "arguments": "{}"},
                    {"type": "function_call", "name": "mutate_later", "call_id": "c2", "arguments": "{}"},
                ]}

            tui.Agent(session, transport).submit("cancel", lambda _text: None, lambda _text: None)
            self.assertEqual(mutated, [])
            cancelled = [event for event in session.events
                         if event["type"] == "error" and event.get("kind") == "cancelled"]
            self.assertEqual(len(cancelled), 1)
            self.assertEqual(len([event for event in session.events if event["type"] == "turn_done"]), 1)

    def test_tool_call_batch_limit_rejects_all_excess_calls(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            session = tui.Session(config_for(), root)
            executed: list[str] = []
            session.add_tool(tui.Tool("count_call", "", "write", [],
                                      lambda _args, _session: executed.append("called") or "ok"))
            calls = [{"type": "function_call", "name": "count_call", "call_id": f"c{index}",
                      "arguments": "{}"} for index in range(tui.MAX_TOOL_CALLS_PER_RESPONSE + 1)]
            transport = lambda _body, _on_text: {"output": calls}
            rendered: list[str] = []
            tui.Agent(session, transport).submit("too many", rendered.append, rendered.append)
            self.assertEqual(executed, [])
            self.assertTrue(any("tool-call limits" in text for text in rendered))

    def test_bounded_process_caps_output_and_times_out(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            started = time.monotonic()
            result = tui.run_bounded_process(
                [sys.executable, "-c",
                 "import sys,time; sys.stdout.write('x'*200000); sys.stdout.flush(); time.sleep(5)"],
                Path(root), 100, 1024)
            self.assertTrue(result.timed_out)
            self.assertTrue(result.truncated)
            self.assertLessEqual(len(result.stdout.encode()) + len(result.stderr.encode()), 1024)
            self.assertLess(time.monotonic() - started, 3)

    @unittest.skipUnless(os.name == "posix", "process-group behavior is POSIX-specific")
    def test_bounded_process_reaps_background_descendants(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            child_code = "import time; time.sleep(30)"
            for redirected in (False, True):
                redirection = ", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL" if redirected else ""
                parent_code = ("import subprocess,sys; "
                               f"p=subprocess.Popen([sys.executable,'-c',{child_code!r}]{redirection}); "
                               "print(p.pid, flush=True)")
                started = time.monotonic()
                result = tui.run_bounded_process([sys.executable, "-c", parent_code], Path(root), 5_000, 1024)
                self.assertFalse(result.timed_out)
                self.assertLess(time.monotonic() - started, 2)
                child_pid = int(result.stdout.strip())
                alive = True
                for _ in range(20):
                    try:
                        os.kill(child_pid, 0)
                    except ProcessLookupError:
                        alive = False
                        break
                    time.sleep(0.025)
                self.assertFalse(alive, f"background child {child_pid} survived")

    def test_nested_instructions_survive_compaction_and_restore(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            state = Path(root) / ".state"
            nested = Path(root) / "pkg"
            nested.mkdir()
            (nested / "AGENTS.md").write_text("Never discard this nested rule.\n", encoding="utf-8")
            (nested / "file.txt").write_text("content\n", encoding="utf-8")
            config = tui.Config.from_env({"GENE_AGENT_STATE": str(state)})
            session = tui.Session(config, root)
            tui.Agent(session, tui.DemoTransport()).run_tool_call(
                {"name": "read_file", "call_id": "r1", "arguments": '{"path":"pkg/file.txt"}'})
            items = list(session.items)
            for index in range(3):
                items.extend([tui.user_item(f"old turn {index}"),
                              {"role": "assistant", "content": f"answer {index}"}])
            compacted = tui.compact_context(
                items, [], dataclasses.replace(config, context_max_items=4, context_keep_turns=1), session.emit)
            instruction_items = [item for item in compacted if item.get("workspace_instructions")]
            self.assertEqual(len(instruction_items), 1)
            self.assertIn("Never discard this nested rule", instruction_items[0]["content"])
            session.items = compacted
            session.save()
            restored = tui.Session(config, root)
            restored_items = [item for item in restored.items if item.get("workspace_instructions")]
            self.assertEqual(len(restored_items), 1)
            self.assertIn("Never discard this nested rule", restored_items[0]["content"])

    def test_restored_instructions_revalidate_changed_deleted_and_new_files(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            state = Path(root) / ".state"
            nested = Path(root) / "pkg"
            nested.mkdir()
            policy = nested / "AGENTS.md"
            target = nested / "file.txt"
            policy.write_text("old rule\n", encoding="utf-8")
            target.write_text("content\n", encoding="utf-8")
            config = tui.Config.from_env({"GENE_AGENT_STATE": str(state)})
            first = tui.Session(config, root)
            first.instructions_loader.ensure("pkg/file.txt", False)
            first.refresh_workspace_instructions()
            first.save()
            policy.write_text("new rule\n", encoding="utf-8")
            changed = tui.Session(config, root)
            self.assertIn("new rule", changed._nested_instruction_text())
            self.assertNotIn("old rule", changed._nested_instruction_text())
            policy.unlink()
            deleted = tui.Session(config, root)
            self.assertNotIn("new rule", deleted._nested_instruction_text())
            policy.write_text("created later\n", encoding="utf-8")
            self.assertIn("created later", deleted.instructions_loader.newly_loaded_text("pkg/file.txt"))

    def test_event_identity_is_reserved_and_event_view_is_live_read_only(self) -> None:
        events = tui.EventLog(tui.Redactor())
        view = events.events
        emitted = events.emit("actual", v=999, turn=999, type="spoofed")
        self.assertEqual((emitted["v"], emitted["turn"], emitted["type"]), (1, 0, "actual"))
        snapshot = view[0]
        snapshot["type"] = "changed"
        self.assertEqual(view[0]["type"], "actual")
        self.assertFalse(hasattr(view, "append"))
        events.emit("later")
        self.assertEqual(len(view), 2)

    def test_undo_and_new_change_use_non_repeating_file_change_ids(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            session = tui.Session(config_for(), root)
            agent = tui.Agent(session, tui.DemoTransport())
            call = lambda call_id, content: agent.run_tool_call({
                "name": "write_file", "call_id": call_id,
                "arguments": json.dumps({"path": "note.txt", "content": content})})
            call("w1", "one\n")
            self.assertIn("undid", session.undo())
            call("w2", "two\n")
            ids = [event["id"] for event in session.events if event["type"] == "file_change"]
            self.assertEqual(ids, [1, 2, 3])
            self.assertEqual([change.id for change in session.changes], [1, 3])

    def test_file_change_ids_continue_after_restore(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            state = Path(root) / ".state"
            config = tui.Config.from_env({"GENE_AGENT_STATE": str(state)})
            first = tui.Session(config, root)
            first.record_change("write", "a.txt", False, "", True, "a")
            first.save()
            restored = tui.Session(config, root)
            change = restored.record_change("write", "b.txt", False, "", True, "b")
            self.assertEqual(change.id, 2)

    def test_diff_includes_change_after_line_forty(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            session = tui.Session(config_for(), root)
            before = "\n".join(f"line {index}" for index in range(100)) + "\n"
            after = before.replace("line 90", "late changed line")
            session.record_change("edit", "late.txt", True, before, True, after)
            report = session.diff()
            self.assertIn("late changed line", report)
            self.assertIn("line 90", report)

    def test_diff_is_byte_bounded_for_huge_lines(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            session = tui.Session(config_for(), root)
            session.record_change("edit", "huge.txt", True, "a" * 2_000_000, True, "b" * 2_000_000)
            report = session.diff()
            self.assertLessEqual(len(report.encode("utf-8")), tui.MAX_DIFF_REPORT_BYTES)
            self.assertIn("diff omitted", report)

    def test_corrupt_and_oversized_state_records_fall_back_safely(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            state = Path(root) / "state"
            state.mkdir()
            (state / "session.json").write_text(
                '{"items":"bad","transcript":3,"instructions":"bad"}', encoding="utf-8")
            (state / "memory.json").write_text('{"not":"a list"}', encoding="utf-8")
            (state / "events.json").write_text('{"events":"bad"}', encoding="utf-8")
            config = tui.Config.from_env({"GENE_AGENT_STATE": str(state)})
            session = tui.Session(config, root)
            self.assertEqual(session.memory, [])
            (state / "oversized.json").write_bytes(b" " * (tui.MAX_STATE_BYTES + 1))
            self.assertEqual(session.store.get("oversized", "fallback"), "fallback")
            session.save()
            if os.name == "posix":
                self.assertEqual(state.stat().st_mode & 0o777, 0o700)
                self.assertEqual((state / "session.json").stat().st_mode & 0o777, 0o600)

    def test_oversized_state_write_preserves_previous_record(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            store = tui.StateStore(str(Path(root) / "state"), tui.Redactor())
            self.assertTrue(store.put("record", {"value": "valid"}))
            self.assertFalse(store.put("record", {"value": "x" * (tui.MAX_STATE_BYTES + 1)}))
            self.assertEqual(store.get("record", None), {"value": "valid"})


class TransportTests(unittest.TestCase):
    def test_chat_message_order_and_fragmented_tool_calls(self) -> None:
        items = [tui.system_item("s"), tui.user_item("u"),
                 {"type": "message", "content": [{"type": "output_text", "text": "thinking"}]},
                 {"type": "function_call", "call_id": "c1", "name": "grep", "arguments": "{\"pat"},
                 {"type": "function_call_output", "call_id": "c1", "output": "ok"}]
        messages = tui.items_to_chat_messages(items)
        self.assertEqual([message["role"] for message in messages], ["system", "user", "assistant", "tool"])
        assembler = tui.ChatStreamAssembler(lambda _text: None)
        assembler.feed({"choices": [{"delta": {"tool_calls": [
            {"index": 0, "id": "c1", "function": {"name": "gr", "arguments": "{\"p"}}]}}]})
        assembler.feed({"choices": [{"delta": {"tool_calls": [
            {"index": 0, "function": {"name": "ep", "arguments": "\":\"x\"}"}}]}}]})
        call = assembler.response()["output"][0]
        self.assertEqual((call["name"], call["arguments"]), ("grep", '{"p":"x"}'))

    def test_wire_serialization_strips_internal_top_level_fields(self) -> None:
        internal = {"context_summary": True, "context_limit_warning": True,
                    "workspace_instructions": True}
        item = {"role": "system", "content": "keep", **internal}
        with tempfile.TemporaryDirectory() as root:
            responses = tui.Session(config_for(OPENAI_API="responses"), root)
            response_body = tui.Agent(responses, tui.DemoTransport()).request_body([item])
            self.assertEqual(response_body["input"], [{"role": "system", "content": "keep"}])
            chat_config = dataclasses.replace(config_for(), api_flavor="chat")
            chat = tui.Session(chat_config, root)
            chat_body = tui.Agent(chat, tui.DemoTransport()).request_body([item])
            self.assertEqual(chat_body["messages"], [{"role": "system", "content": "keep"}])

    def test_request_body_and_rendered_tool_arguments_are_redacted(self) -> None:
        completed = ("data: {\"type\":\"response.completed\","
                     "\"response\":{\"status\":\"completed\"}}\n\ndata: [DONE]\n\n")
        with tempfile.TemporaryDirectory() as root, StaticSseServer(completed) as server:
            config = config_for(OPENAI_AUTH_TOKEN="top-secret", OPENAI_BASE_URL=server.base,
                                OPENAI_API="responses")
            session = tui.Session(config, root)
            result = tui.HttpTransport(session)({"input": [{"top-secret-key": "top-secret"}]}, lambda _text: None)
            self.assertNotIn("agent_error", result)
            serialized = json.dumps(server.requests[0])
            self.assertNotIn("top-secret", serialized)
            self.assertIn("auth-***REDACTED***", serialized)

            calls = [0]

            def transport(_body: object, _on_text: object) -> dict:
                calls[0] += 1
                if calls[0] == 1:
                    return {"output": [{"type": "function_call", "name": "missing_tool",
                                        "call_id": "c1", "arguments": '{"value":"top-secret"}'}]}
                return {"output": [{"type": "message", "role": "assistant", "content": []}]}

            rendered: list[str] = []
            tui.Agent(session, transport).submit("render", rendered.append, rendered.append)
            self.assertNotIn("top-secret", "\n".join(rendered))

    def test_authenticated_post_redirect_is_rejected_without_forwarding_authorization(self) -> None:
        received: list[str | None] = []

        class TargetHandler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                received.append(self.headers.get("Authorization"))
                self.send_response(200)
                self.end_headers()

            def log_message(self, _format: str, *_args: object) -> None:
                pass

        target = ThreadingHTTPServer(("127.0.0.1", 0), TargetHandler)
        target_thread = threading.Thread(target=target.serve_forever, daemon=True)
        target_thread.start()
        location = f"http://127.0.0.1:{target.server_port}/capture"

        class RedirectHandler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                self.send_response(307)
                self.send_header("Location", location)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, _format: str, *_args: object) -> None:
                pass

        redirect = ThreadingHTTPServer(("127.0.0.1", 0), RedirectHandler)
        redirect_thread = threading.Thread(target=redirect.serve_forever, daemon=True)
        redirect_thread.start()
        try:
            with tempfile.TemporaryDirectory() as root:
                base = f"http://127.0.0.1:{redirect.server_port}"
                session = tui.Session(config_for(OPENAI_AUTH_TOKEN="token", OPENAI_BASE_URL=base,
                                                 OPENAI_API="responses"), root)
                result = tui.HttpTransport(session)({"input": []}, lambda _text: None)
                self.assertIn("redirect rejected", result["agent_error"])
                self.assertEqual(received, [])
        finally:
            redirect.shutdown()
            redirect_thread.join(timeout=2)
            redirect.server_close()
            target.shutdown()
            target_thread.join(timeout=2)
            target.server_close()

    def test_credentialed_plaintext_http_requires_loopback(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            session = tui.Session(config_for(OPENAI_AUTH_TOKEN="token", OPENAI_BASE_URL="http://example.com",
                                             OPENAI_API="responses"), root)
            with mock.patch.object(tui.urllib.request, "build_opener") as opener:
                result = tui.HttpTransport(session)({"input": []}, lambda _text: None)
            self.assertIn("loopback", result["agent_error"])
            opener.assert_not_called()

    def test_sse_multiline_payload_and_strict_terminal_validation(self) -> None:
        source = io.BytesIO(b'data: {"type":\ndata: "response.completed"}\n\ndata: [DONE]\n\n')
        payloads = list(tui.sse_payloads(source))
        self.assertEqual(json.loads(payloads[0]), {"type": "response.completed"})
        self.assertEqual(payloads[1], "[DONE]")
        cases = {
            "data: []\n\ndata: [DONE]\n\n": "must decode to an object",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"x\"}\n\n":
                "before response.completed",
            "data: not-json\n\n": "malformed SSE JSON",
            ("data: {\"type\":\"response.failed\","
             "\"response\":{\"status\":\"failed\"}}\n\n"): "OpenAI API error failed",
            ("data: {\"type\":\"response.incomplete\","
             "\"response\":{\"status\":\"incomplete\"}}\n\n"): "OpenAI API error incomplete",
        }
        for payload, message in cases.items():
            with self.subTest(message=message), tempfile.TemporaryDirectory() as root, StaticSseServer(payload) as server:
                session = tui.Session(config_for(OPENAI_AUTH_TOKEN="token", OPENAI_BASE_URL=server.base,
                                                 OPENAI_API="responses"), root)
                result = tui.HttpTransport(session)({"input": []}, lambda _text: None)
                self.assertIn(message, result["agent_error"])
        with self.assertRaisesRegex(ValueError, "pending-event byte cap"):
            list(tui.sse_payloads(io.BytesIO(b"data: " + b"x" * 64), pending_cap=32))

    def test_chat_sse_requires_done_and_mapping_chunks(self) -> None:
        cases = {
            'data: {"choices":[]}\n\n': "before [DONE]",
            'data: []\n\ndata: [DONE]\n\n': "must decode to an object",
        }
        for payload, message in cases.items():
            with self.subTest(message=message), tempfile.TemporaryDirectory() as root, StaticSseServer(payload) as server:
                session = tui.Session(config_for(OPENAI_AUTH_TOKEN="token", OPENAI_BASE_URL=server.base,
                                                 OPENAI_API="chat"), root)
                result = tui.HttpTransport(session)({"messages": []}, lambda _text: None)
                self.assertIn(message, result["agent_error"])

    def test_streaming_responses_transport_executes_tool_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as root, FakeResponsesServer() as fake:
            config = config_for(OPENAI_AUTH_TOKEN="token", OPENAI_BASE_URL=fake.base,
                                OPENAI_API="responses")
            session = tui.Session(config, root)
            rendered: list[str] = []
            tui.Agent(session).submit("inspect", rendered.append, rendered.append)
            self.assertEqual(len(fake.requests), 2)
            second_input = fake.requests[1]["input"]
            self.assertTrue(any(item.get("type") == "function_call_output" for item in second_input))
            self.assertIn("done", rendered)


class InteractiveShellTests(unittest.TestCase):
    def test_keyboard_interrupt_returns_from_shell(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            cli = tui.Cli(tui.Session(config_for(), root))
            terminal = mock.Mock()
            cli.terminal = terminal
            replacement = mock.Mock()
            fake_stdin = mock.Mock()
            fake_stdin.isatty.return_value = True
            with mock.patch.object(tui.sys, "stdin", fake_stdin), \
                    mock.patch.object(tui.subprocess, "run", side_effect=KeyboardInterrupt), \
                    mock.patch.object(cli, "_open_terminal", return_value=replacement):
                cli.shell()
            terminal.close.assert_called_once()
            self.assertIs(cli.terminal, replacement)


if __name__ == "__main__":
    unittest.main()