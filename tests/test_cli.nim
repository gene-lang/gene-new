import std/[json, monotimes, net, os, osproc, streams, strutils, times, unittest]
when defined(posix):
  import std/posix
when defined(macosx):
  const SigWinch = 28
import gene/[repl, vm]

let cliDir = getTempDir() / "gene_cli_tests"
let geneExe = cliDir / "gene-test-bin"
var cliBuilt = false

proc buildGeneCli() =
  if cliBuilt:
    return
  createDir(cliDir)
  let build = execCmdEx("nim c --path:src --hints:off -o:" & geneExe & " src/gene.nim")
  if build.exitCode != 0:
    checkpoint build.output
  check build.exitCode == 0
  cliBuilt = true

proc writeCliProgram(name, src: string): string =
  createDir(cliDir)
  result = cliDir / name
  writeFile(result, src)

proc shellQuote(arg: string): string =
  if arg.len == 0:
    return "''"
  result = "'"
  for ch in arg:
    if ch == chr(39):
      result.add "'\\''"
    else:
      result.add ch
  result.add "'"

proc geneQuote(arg: string): string =
  result = "\""
  for ch in arg:
    case ch
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    else: result.add ch
  result.add '"'

proc execCmdOnce(cmd: string): tuple[output: string, exitCode: int] =
  ## Keep process execution behind one helper so command-heavy CLI tests use
  ## the same capture behavior without masking crashes through retries.
  execCmdEx(cmd)

proc runGene(args: openArray[string]): tuple[output: string, exitCode: int] =
  buildGeneCli()
  var command = shellQuote(geneExe)
  for arg in args:
    command.add " " & shellQuote(arg)
  execCmdEx(command)

proc runGeneInput(args: openArray[string],
                  input: string): tuple[output: string, exitCode: int] =
  buildGeneCli()
  var command = shellQuote(geneExe)
  for arg in args:
    command.add " " & shellQuote(arg)
  execCmdEx(command, input = input)

suite "cli — gene run":
  setup:
    createDir(cliDir)

  test "main return convention controls process exit":
    let nilMain = writeCliProgram("nil_main.gene", "(fn main [] nil)")
    var ran = runGene(["run", nilMain])
    check ran.exitCode == 0

    let intMain = writeCliProgram("int_main.gene", "(fn main [] 7)")
    ran = runGene(["run", intMain])
    check ran.exitCode == 7

  test "main receives command-line arguments":
    let argMain = writeCliProgram("arg_main.gene",
      "(fn main [args] (if (== args/0 \"ok\") 0 4))")
    let ran = runGene(["run", argMain, "ok"])
    check ran.exitCode == 0

  test "main receives raw command-line argument tail":
    let rawMain = writeCliProgram("raw_arg_main.gene",
      "(fn main [args] (if (== args/raw \"a b, c\") 0 4))")
    let ran = runGene(["run", rawMain, "a", "b,", "c"])
    check ran.exitCode == 0

  test "main receives only explicitly granted named capabilities":
    let grantedMain = writeCliProgram("granted_main.gene",
      "(fn main [args, ^config : Capability] " &
      "  (if (same? config Fs/ReadDir) 0 4))")
    var ran = runGene(["run", grantedMain, "--grant", "config=Fs/ReadDir",
                       "--", "arg"])
    check ran.exitCode == 0

    let missingMain = writeCliProgram("missing_grant_main.gene",
      "(fn main [args, ^config : Capability] " &
      "  (do (println \"BODY-RAN\") 0))")
    ran = runGene(["run", missingMain])
    check ran.exitCode == 1
    check "missing named argument: config" in ran.output
    check ("at " & normalizedPath(absolutePath(missingMain)) & ":1:1") in
      ran.output
    check not ran.output.startsWith("BODY-RAN\n")

  test "run loads explicit structured logging config before the entry module":
    let logDir = cliDir / "configured_logs"
    createDir(logDir)
    let logPath = logDir / "events.jsonl"
    removeFile(logPath)
    let configPath = cliDir / "logging_config.gene"
    writeFile(configPath, """
{^level "warn"
 ^sinks {^main {^type "file" ^path "configured_logs/events.jsonl"
                 ^format "jsonl" ^flush "close"}}
 ^targets []
 ^loggers {{"app" : {^level "info" ^targets ["main"]}}}}
""")
    let fixture = writeCliProgram("logging_configured.gene", """
(import log [new_logger])
(var logger (new_logger "app/cli" ^payload {^service "test"}))
(logger ~ info "started" ^payload {^token "secret" ^count 2})
""")
    let ran = runGene(["run", "--log-config", configPath, fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check fileExists(logPath)
    let logged = readFile(logPath)
    check "\"logger\":\"app/cli\"" in logged
    check "\"message\":\"started\"" in logged
    check "\"service\":\"test\"" in logged
    check "\"token\":\"[redacted]\"" in logged

  test "invalid logging config fails before entry-module execution":
    let marker = cliDir / "bad_logging_marker"
    removeFile(marker)
    let configPath = cliDir / "bad_logging_config.gene"
    writeFile(configPath,
      "{^sinks {^console {^type \"console\"}} ^targets [\"missing\"]}")
    let fixture = writeCliProgram("bad_logging_entry.gene",
      "(import Fs [write_text WriteDir]) " &
      "(write_text WriteDir " & geneQuote(marker) & " \"ran\")")
    let ran = runGene(["run", "--log-config", configPath, fixture])
    check ran.exitCode == 1
    check "unknown sink 'missing'" in ran.output
    check not fileExists(marker)

  test "main parameter boundary errors include source location":
    let typedMain = writeCliProgram("typed_arg_main.gene",
      "(fn main [args : (List Str)] nil)")
    let ran = runGene(["run", typedMain, "x"])
    check ran.exitCode == 1
    check "parameter 'args' expected (List Str), got vkNode" in ran.output
    check ("at " & normalizedPath(absolutePath(typedMain)) & ":1:1") in ran.output

  test "ai agent example runs offline demo without an auth token":
    buildGeneCli()
    let ran = execCmdOnce("env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
                        "-u CODEX_ACCESS_TOKEN " &
                        shellQuote(geneExe) & " run examples/ai_agent/tui.gene")
    check ran.exitCode == 0
    check "No OPENAI_AUTH_TOKEN, OPENAI_API_KEY, or CODEX_ACCESS_TOKEN set" in
      ran.output
    check "agent>   · tool list_dir" in ran.output
    check "Demo complete" in ran.output

  test "ai agent writes detailed content-safe structured diagnostics":
    buildGeneCli()
    let logPath = cliDir / "agent_diagnostics.jsonl"
    removeFile(logPath)
    let configPath = cliDir / "agent_logging_config.gene"
    writeFile(configPath, """
{^level "warn"
 ^sinks {^agent {^type "file" ^path "agent_diagnostics.jsonl"
                  ^format "jsonl" ^flush "close"}}
 ^targets []
 ^loggers {{"app/ai_agent" : {^level "trace" ^targets ["agent"]}}}}
""")
    let command = "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
                  "-u CODEX_ACCESS_TOKEN -u GENE_AGENT_STATE " &
                  shellQuote(geneExe) & " run --log-config " &
                  shellQuote(configPath) &
                  " examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check fileExists(logPath)
    let logged = readFile(logPath)
    check "\"logger\":\"app/ai_agent\"" in logged
    check "\"message\":\"agent starting\"" in logged
    check "\"message\":\"event appended\"" in logged
    check "\"message\":\"turn started\"" in logged
    check "\"message\":\"model request started\"" in logged
    check "\"message\":\"tool call started\"" in logged
    check "\"message\":\"tool call completed\"" in logged
    check "\"message\":\"turn completed\"" in logged
    check "\"message\":\"agent stopped\"" in logged
    check "\"level\":\"trace\"" in logged
    check "\"level\":\"debug\"" in logged
    check "\"level\":\"info\"" in logged
    check "what's in this directory?" notin logged

  test "ai agent slash sh opens a cancellable shell pane":
    buildGeneCli()
    let command = "printf '/sh\\n/1 printf hi\\n/1 close\\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    check "shell pane 1" in ran.output
    check "hi" in ran.output
    check "closed pane 1" in ran.output

  test "ai agent mediated shell panes deny detached workspace writers":
    buildGeneCli()
    let marker = "tmp/agent-detached-writer-must-not-run"
    removeFile(marker)
    defer: removeFile(marker)
    let command =
      "printf '/sh\\n" &
      "/1 (sleep 0.1; touch " & marker & ") &\\n" &
      "/1 sleep 0.2; if [ ! -e " & marker & " ]; then echo lease-preserved; fi\\n" &
      "/1 close\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "must stay in the foreground; use /tty" in ran.output
    check "lease-preserved" in ran.output
    check not fileExists(marker)

  test "ai agent routes bare input to the focused worker and close detaches":
    buildGeneCli()
    let command =
      "printf '/sh\\necho routed-to-shell\\n/workers\\n/1 close\\n/workers\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "routed-to-shell" in ran.output
    check "w1 shell idle pane=1 shell" in ran.output
    check "closed pane 1" in ran.output
    check "w1 shell idle headless shell" in ran.output

  test "ai agent worker input addresses headless shell and REPL controllers":
    buildGeneCli()
    let fixture = "examples/ai_agent/headless_process_input_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [active_application make_application_with_task open_shell_pane
         open_repl_pane application_close_pane application_send_worker_input
         user_item]
  from "./tui.gene")
(var items (cell []))
(var transcript (cell ""))
(var memory (cell []))
(var app
  (make_application_with_task items transcript memory
    (fn [_type, _props] nil) (cell nil)))
(active_application ~ Cell/set app)
(var shell_pane (open_shell_pane))
(var shell shell_pane/worker)
(application_close_pane app shell_pane/id)
(var shell_result
  (application_send_worker_input app shell
    "printf top-secret-agent-token" "http"))
(while (!= (shell/current_task ~ Cell/get) nil) (sleep 10))
(var shell_history (shell/history ~ Cell/get))
(println $"shell=${shell_result} panes=${((app/local_surface/panes ~ Cell/get) ~ size)} adapter=${shell_history/0/adapter} output=${(shell/output ~ Cell/get)}")
(var denied
  (application_send_worker_input app shell "rm -rf tmp/gene-agent-remote-missing" "http"))
(println $"denied=${denied} task=${(shell/current_task ~ Cell/get)}")
(var repl_pane (open_repl_pane items transcript memory))
(var repl repl_pane/worker)
(application_close_pane app repl_pane/id)
(var repl_result (application_send_worker_input app repl "(+ 1 2)" "http"))
(while (!= (repl/current_task ~ Cell/get) nil) (sleep 10))
(var repl_history (repl/history ~ Cell/get))
(println $"repl=${repl_result} panes=${((app/local_surface/panes ~ Cell/get) ~ size)} adapter=${repl_history/0/adapter} output=${(repl/output ~ Cell/get)}")
(var model_input (user_item "top-secret-agent-token"))
(println $"model_input=${model_input/content}")
""")
    let ran = execCmdEx(
      "OPENAI_AUTH_TOKEN=top-secret-agent-token " & shellQuote(geneExe) &
      " run " & shellQuote(fixture))
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "shell=accepted panes=0 adapter=http" in ran.output
    check "auth-***REDACTED***" in ran.output
    check "top-secret-agent-token" notin ran.output
    check "denied=error: denied: destructive command was not confirmed task=nil" in ran.output
    check "repl=accepted panes=0 adapter=http" in ran.output
    check "3" in ran.output

  test "ai agent model supervision tools use the application registries":
    buildGeneCli()
    let fixture = "examples/ai_agent/application_tools_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [make_application_with_task make_headless_application_with_task
         run_tool_call_in] from "./tui.gene")
(import json [stringify])
(var events (cell []))
(fn emit [type props]
  ((events ~ Cell/get) ~ List/push! {^type type ^props props}))
(var app (make_application_with_task (cell []) (cell "") (cell []) emit
                                      (cell nil)))
(var context {^app app ^agent app/main_agent ^pane nil})
(var spawned
  (run_tool_call_in
    {^name "spawn_agent" ^call_id "s1"
     ^arguments (stringify {^assignment "review parser" ^title "reader"})}
    emit context))
(println $"spawn=${spawned/output} agents=${((app/agents ~ Cell/get) ~ size)}")
(var registered_agents (app/agents ~ Cell/get))
(var child_context {^app app ^agent registered_agents/1 ^pane nil})
(var recursive
  (run_tool_call_in
    {^name "spawn_agent" ^call_id "s2"
     ^arguments (stringify {^assignment "spawn recursively"})}
    emit child_context))
(println $"recursive=${recursive/output} agents=${((app/agents ~ Cell/get) ~ size)}")
(var opened
  (run_tool_call_in
    {^name "open_pane" ^call_id "p1"
     ^arguments (stringify {^kind "output" ^title "checks" ^text "ready\n"})}
    emit context))
(println $"worker=${opened/output} panes=${((app/local_surface/panes ~ Cell/get) ~ size)}")
(var appended
  (run_tool_call_in
    {^name "append_pane" ^call_id "p2"
     ^arguments (stringify {^pane_id 1 ^text "passed\n"})}
    emit context))
(println appended/output)
(var pane_list (app/local_surface/panes ~ Cell/get))
(var output_pane pane_list/0)
(println (output_pane/output ~ Cell/get))
(var closed
  (run_tool_call_in
    {^name "close_pane" ^call_id "p3"
     ^arguments (stringify {^pane_id 1})}
    emit context))
(println $"${closed/output} panes=${((app/local_surface/panes ~ Cell/get) ~ size)}")
(fn headless_emit [type, _props]
  (println $"headless-event=${type}"))
(var headless
  (make_headless_application_with_task
    (cell []) (cell "") (cell []) headless_emit (cell nil)))
(var headless_opened
  (run_tool_call_in
    {^name "open_pane" ^call_id "hp1"
     ^arguments (stringify {^kind "output" ^title "headless checks"
                            ^text "ready\n"})}
    headless_emit {^app headless ^agent headless/main_agent ^pane nil}))
(println $"headless=${headless_opened/output} workers=${((headless/workers ~ Cell/get) ~ size)} surface=${headless/local_surface}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "spawn=a1 agents=2" in ran.output
    check "recursive=error: main supervisor authority is required agents=2" in ran.output
    check "worker=w1 panes=1" in ran.output
    check "appended to pane 1" in ran.output
    check "ready\npassed" in ran.output
    check "closed pane 1 panes=0" in ran.output
    check "headless=w1 workers=2 surface=nil" in ran.output
    check "headless-event=worker_attention_requested" in ran.output
    check "headless-event=pane_opened" notin ran.output

  test "ai agent opens stats event-tail and file-view workers":
    buildGeneCli()
    let command =
      "printf '/stats\\n/1 max\\n/tail worker_started\\n/view examples/ai_agent/design.md\\n/view /etc/passwd\\n/workers\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "maximized pane 1" in ran.output
    check "w1 stats idle pane=1 stats" in ran.output
    check "w2 log_tail idle pane=2 event tail" in ran.output
    check "w3 file_view idle pane=3 view examples/ai_agent/design.md" in ran.output
    check "cannot open /etc/passwd" in ran.output
    check "w4 file_view" notin ran.output

  test "ai agent persists and delivers bounded supervisor results":
    buildGeneCli()
    let fixture = "examples/ai_agent/supervisor_inbox_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import json [stringify])
(import [make_application_with_task application_spawn_agent
         application_enqueue_supervisor_result! application_snapshot
         restore_application_snapshot! application_drain_supervisor_inbox
         worker_history_push!]
  from "./tui.gene")
(var restored_events (cell []))
(fn sink [type, props]
  ((restored_events ~ Cell/get) ~ List/push! type)
  {^type type ^^props})
(var first
  (make_application_with_task (cell []) (cell "") (cell []) sink (cell nil)))
(var agent
  (application_spawn_agent first "reviewer" "review reader" (cell [])
                           (cell "")))
(application_enqueue_supervisor_result! first agent "reader is sound")
(worker_history_push! first/main_agent "remote prompt" "http" nil)
(first/main_agent/current_operation ~ Cell/set
  {^task_id "t-before-restart" ^kind "agent_turn"})
(first/main_agent/input_reserved ~ Cell/set true)
(first/main_agent/status ~ Cell/set "working")
(var saved (application_snapshot first))
(var restored
  (make_application_with_task (cell []) (cell "") (cell []) sink (cell nil)))
(restore_application_snapshot! restored saved)
(var queued ((restored/supervisor_inbox ~ Cell/get) ~ size))
(application_drain_supervisor_inbox restored)
(println $"queued=${queued} empty=${((restored/supervisor_inbox ~ Cell/get) ~ size)} status=${(restored/main_agent/status ~ Cell/get)} reserved=${(restored/main_agent/input_reserved ~ Cell/get)} operation=${(restored/main_agent/current_operation ~ Cell/get)} events=${(stringify (restored_events ~ Cell/get))} history=${(stringify (restored/main_agent/history ~ Cell/get))} items=${(stringify (restored/main_agent/items ~ Cell/get))}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "queued=1 empty=0" in ran.output
    check "status=idle reserved=false operation=nil" in ran.output
    check "worker_operation_finished" in ran.output
    check "t-before-restart" notin ran.output # event type list is content-safe
    check "\"adapter\":\"http\"" in ran.output
    check "\"text\":\"remote prompt\"" in ran.output
    check "Sub-agent a1 completed assignment: review reader" in ran.output
    check "reader is sound" in ran.output

  test "ai agent shell remains usable while a sub-agent operation runs":
    buildGeneCli()
    let fixture = "examples/ai_agent/concurrent_shell_agent_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [active_application make_application_with_task application_spawn_agent
         application_begin_worker_operation! application_cancel_worker
         application_finish_worker_operation! open_shell_pane
         run_shell_pane_command_unchecked] from "./tui.gene")
(var app
  (make_application_with_task (cell []) (cell "") (cell [])
    (fn [_type, _props] nil) (cell nil)))
(active_application ~ Cell/set app)
(var agent
  (application_spawn_agent app "reviewer" "review" (cell []) (cell "")))
(var agent_task (spawn (sleep 500)))
(application_begin_worker_operation! app agent agent_task "agent_turn")
(var shell (open_shell_pane))
(var result (run_shell_pane_command_unchecked shell "printf shell-ready"))
(println $"agent_busy=${(!= (agent/current_task ~ Cell/get) nil)} result=${result}")
(application_cancel_worker app agent)
(sleep 25)
(application_finish_worker_operation! app agent "cancelled")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "agent_busy=true" in ran.output
    check "shell-ready" in ran.output

  test "ai agent maximized log tail follows checks and restores":
    buildGeneCli()
    let fixture = "examples/ai_agent/maximized_log_tail_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import str [contains?])
(import [active_application make_application_with_task open_log_tail_pane
         application_emit handle_surface_escape!] from "./tui.gene")
(var app
  (make_application_with_task (cell []) (cell "") (cell [])
    (fn [type, props]
      (var event {^type type ^v 1 ^turn 1})
      (for [key value] in props (event ~ Map/put! key value))
      event)
    (cell nil)))
(active_application ~ Cell/set app)
(var pane (open_log_tail_pane "check"))
(app/local_surface/maximized_pane ~ Cell/set pane/id)
(application_emit app "check"
  {^command "nimble test" ^status 0 ^verified true})
(var editor {^values (cell [])})
(var restored (handle_surface_escape! editor))
(println $"followed=${(contains? (pane/output ~ Cell/get) \"nimble test\")} restored=${restored} max=${(app/local_surface/maximized_pane ~ Cell/get)}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "followed=true restored=true max=nil" in ran.output

  test "ai agent keeps independent focused-pane scroll state":
    buildGeneCli()
    let fixture = "examples/ai_agent/pane_scroll_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [make_application_with_task application_open_pane
         application_pane_views application_scroll_target!
         application_pane_page_rows] from "./tui.gene")
(var app
  (make_application_with_task (cell []) (cell "") (cell [])
    (fn [_type, _props] nil) (cell nil)))
(var pane
  (application_open_pane app "output" nil "checks" (cell "ready\n") nil
                         "detach"))
(var main_scroll (cell 0))
(application_scroll_target! app main_scroll 1 3)
(var views (application_pane_views app))
(println $"focused=${(app/local_surface/focused_pane ~ Cell/get)} pane=${views/0/scroll} main=${(main_scroll ~ Cell/get)} title=${views/0/title}")
(println $"page=${(application_pane_page_rows app 18)}")
(application_scroll_target! app main_scroll -1 3)
(app/local_surface/focused_pane ~ Cell/set nil)
(application_scroll_target! app main_scroll 1 4)
(println $"pane=${(pane/scroll ~ Cell/get)} main=${(main_scroll ~ Cell/get)}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "focused=1 pane=3 main=0 title=[1]* checks (idle)" in ran.output
    check "page=12" in ran.output
    check "pane=0 main=4" in ran.output

  test "ai agent shares one cancellable workspace lease across sessions":
    buildGeneCli()
    let fixture = "examples/ai_agent/workspace_coordinator_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [make_application_with_task application_acquire_workspace
         application_release_workspace application_shutdown] from "./tui.gene")
(fn sink [_type, _props] nil)
(var a (make_application_with_task (cell []) (cell "") (cell []) sink
                                   (cell nil)))
(var b (make_application_with_task (cell []) (cell "") (cell []) sink
                                   (cell nil)))
(println $"shared=${(== a/workspace_coordinator/owner b/workspace_coordinator/owner)}")
(application_acquire_workspace a "main" "edit")
# Session-local worker ids deliberately collide. Neither an unrelated release
# nor an unrelated application shutdown may clear A's process-wide lease.
(var foreign_release (application_release_workspace b "main" "edit"))
(var c (make_application_with_task (cell []) (cell "") (cell []) sink
                                   (cell nil)))
(application_shutdown c)
(var owner_after_foreign (a/workspace_coordinator/owner ~ Cell/get))
(var waiting (spawn (application_acquire_workspace b "main" "edit")))
(sleep 25)
(waiting ~ Task/cancel)
# Cancellation is a control signal and deliberately bypasses `catch _`.
# Give the task's `ensure` cleanup a scheduler turn instead of awaiting it.
(sleep 25)
(println $"owner=${(a/workspace_coordinator/owner ~ Cell/get)} foreign=${foreign_release} preserved=${(== owner_after_foreign (a/workspace_coordinator/owner ~ Cell/get))} waiters=${((a/workspace_coordinator/waiters ~ Cell/get) ~ size)}")
(application_release_workspace a "main" "edit")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "shared=true" in ran.output
    check "owner=app1/main foreign=false preserved=true waiters=0" in ran.output

  test "ai agent confirms destructive work before taking the workspace lease":
    buildGeneCli()
    let fixture = "examples/ai_agent/workspace_confirmation_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [make_application_with_task run_tool_call_in
         application_acquire_workspace application_release_workspace
         preflight_tool_mutation mutation_preflight_valid?]
  from "./tui.gene")
(fn sink [_type, _props] nil)
(var a (make_application_with_task (cell []) (cell "") (cell []) sink
                                   (cell nil)))
(var b (make_application_with_task (cell []) (cell "") (cell []) sink
                                   (cell nil)))
(var confirming (cell false))
(var result (cell nil))
(var task
  (spawn
    (result ~ Cell/set
      (run_tool_call_in
        {^name "run_shell" ^call_id "guard-order"
         ^arguments "{\"command\":\"rm -rf tmp/guard-order-target\"}"}
        sink
        {^app a ^agent a/main_agent
         ^guard_confirm (fn [_command]
           (confirming ~ Cell/set true)
           (sleep 100)
           false)}))))
(while (! (confirming ~ Cell/get)) (sleep 1))
(application_acquire_workspace b "worker-b" "edit")
(println $"owner=${(a/workspace_coordinator/owner ~ Cell/get)}")
(application_release_workspace b "worker-b" "edit")
(await task)
(println (result ~ Cell/get)/output)
(var checked {^command "echo stable" ^timeout_ms 1000 ^_emit sink})
(preflight_tool_mutation "run_shell" checked nil)
(var preflight_valid (mutation_preflight_valid? "run_shell" checked))
(println $"preflight=${preflight_valid}")
(checked ~ Map/put! "command" "echo changed")
(var changed_valid (mutation_preflight_valid? "run_shell" checked))
(println $"changed=${changed_valid}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "owner=app2/worker-b" in ran.output
    check "denied: destructive command was not confirmed" in ran.output
    check "preflight=true" in ran.output
    check "changed=false" in ran.output

  test "ai agent foreground contract survives guard bypass and covers model tools":
    buildGeneCli()
    let marker = "tmp/model-detached-writer-must-not-run"
    removeFile(marker)
    let fixture = "examples/ai_agent/foreground_contract_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
      removeFile(marker)
    writeFile(fixture, """
(import [make_application_with_task run_tool_call_in guard_shell_in]
  from "./tui.gene")
(import json [stringify])
(fn sink [type, props]
  (if (== type "confirmation")
    (println $"event=${props/risk}:${props/decision}:${props/reason}") nil))
(var app
  (make_application_with_task (cell []) (cell "") (cell []) sink (cell nil)))
(var result
  (run_tool_call_in
    {^name "run_shell" ^call_id "detach-1"
     ^arguments
       (stringify
         {^command "(sleep 0.1; touch tmp/model-detached-writer-must-not-run) &"})}
    sink {^app app ^agent app/main_agent ^pane nil}))
(println result/output)
(var quoted (guard_shell_in "printf '&'" nil sink))
(var escaped (guard_shell_in "printf \\&" nil sink))
(var redirected (guard_shell_in "printf ok 2>&1" nil sink))
(var chained (guard_shell_in "printf a && printf b" nil sink))
(var launcher (guard_shell_in "setsid -f writer" nil sink))
(println $"normal=${(== quoted nil)}:${(== escaped nil)}:${(== redirected nil)}:${(== chained nil)} launcher=${(!= launcher nil)}")
(sleep 250)
""")
    let ran = execCmdEx(
      "GENE_AGENT_GUARD=0 " & shellQuote(geneExe) &
      " run " & shellQuote(fixture))
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "event=detached_process:deny:background operator '&'" in ran.output
    check "must stay in the foreground; use /tty" in ran.output
    check "normal=true:true:true:true launcher=true" in ran.output
    check not fileExists(marker)

  test "ai agent cancellation revokes destructive preflight admission":
    buildGeneCli()
    let marker = "tmp/preflight-cancel-must-not-run"
    removeFile(marker)
    let fixture = "examples/ai_agent/preflight_cancel_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
      removeFile(marker)
    writeFile(fixture, """
(import [active_application make_application_with_task open_shell_pane
         run_shell_pane_command set_guard_confirm application_cancel_worker
         application_shutdown] from "./tui.gene")
(fn sink [_type, _props] nil)
(var app
  (make_application_with_task (cell []) (cell "") (cell []) sink (cell nil)))
(active_application ~ Cell/set app)
(var pane (open_shell_pane))
(set_guard_confirm
  (fn [_command]
    (println $"cancelled=${(application_cancel_worker app pane/worker)}")
    true))
(var result
  (run_shell_pane_command pane
    "rm -rf tmp/preflight-cancel-target; touch tmp/preflight-cancel-must-not-run"))
(println result)
(app/main_agent/input_reserved ~ Cell/set true)
(application_shutdown app)
(println $"shutdown_reserved=${(app/main_agent/input_reserved ~ Cell/get)}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "cancelled=true" in ran.output
    check "shell command cancelled before start" in ran.output
    check "shutdown_reserved=false" in ran.output
    check not fileExists(marker)

  test "ai agent coalesces legacy approval with destructive confirmation":
    buildGeneCli()
    let fixture = "examples/ai_agent/single_confirmation_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [preflight_tool_mutation] from "./tui.gene")
(fn sink [_type, _props] nil)
(var confirmations (cell 0))
(var args
  {^command "rm -rf tmp/single-confirmation-target"
   ^timeout_ms 1000 ^_emit sink})
(var denial
  (preflight_tool_mutation "run_shell" args
    {^guard_confirm (fn [_command]
      (confirmations ~ Cell/set (+ (confirmations ~ Cell/get) 1))
      true)}))
(println $"confirmations=${(confirmations ~ Cell/get)} allowed=${(== denial nil)}")
""")
    let ran = execCmdEx(
      "GENE_AGENT_APPROVE_ALL=0 " & shellQuote(geneExe) &
      " run " & shellQuote(fixture) & " </dev/null")
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "confirmations=1 allowed=true" in ran.output

  test "ai agent Escape restores max then preserves a composed routed draft":
    buildGeneCli()
    let fixture = "examples/ai_agent/escape_priority_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [active_application make_application_with_task application_open_pane
         handle_surface_escape!] from "./tui.gene")
(var app
  (make_application_with_task (cell []) (cell "") (cell [])
    (fn [_type, _props] nil) (cell nil)))
(active_application ~ Cell/set app)
(application_open_pane app "output" nil "checks" (cell "") nil "detach")
(app/local_surface/maximized_pane ~ Cell/set 1)
(var editor {^values (cell ["x"])})
(println $"max=${(handle_surface_escape! editor)} focus=${(app/local_surface/focused_pane ~ Cell/get)} zoom=${(app/local_surface/maximized_pane ~ Cell/get)}")
(println $"draft=${(handle_surface_escape! editor)} focus=${(app/local_surface/focused_pane ~ Cell/get)}")
(editor/values ~ Cell/set [])
(println $"empty=${(handle_surface_escape! editor)} focus=${(app/local_surface/focused_pane ~ Cell/get)}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "max=true focus=1 zoom=nil" in ran.output
    check "draft=false focus=1" in ran.output
    check "empty=true focus=nil" in ran.output

  test "ai agent TUI routes focused input and layers maximize Escape reset":
    when defined(macosx):
      buildGeneCli()
      let outputFile = cliDir / "agent_focus_escape_pty.out"
      let focusedProof = cliDir / "agent_focus_escape_focused"
      removeFile(outputFile)
      removeFile(focusedProof)
      let inner =
        "stty rows 18 cols 80; exec /usr/bin/env " &
        "-u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
        "CODEX_ACCESS_TOKEN=dummy TERM=xterm-256color " &
        shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
      let expectScript =
        "set timeout 15\n" &
        "log_file -noappend " & outputFile & "\n" &
        "spawn /bin/sh -c {" & inner & "}\n" &
        "after 500\n" &
        "send -- \"/sh\\r\"\n" &
        "after 350\n" &
        "send -- \"touch " & focusedProof & "\\r\"\n" &
        "expect -re {\\[exit 0}\n" &
        # Shell-pane input is classified even on a live TTY. The destructive
        # confirmation itself uses the async curses editor, then the accepted
        # command runs without a second legacy prompt.
        "send -- \"rm -rf tmp/gene-agent-pty-confirm-missing\\r\"\n" &
        "expect -re {run it once\\? \\[y/N\\]}\n" &
        "send -- \"y\\r\"\n" &
        "expect -re {\\[exit 0}\n" &
        "send -- \"/1 max\\r\"\n" &
        "after 700\n" &
        # First Escape restores the split while keeping shell focus.
        "send -- \"\\033\"\n" &
        "after 350\n" &
        # With a composed draft Escape is a no-op; Enter must still route
        # this bare command to the shell rather than switching to main.
        "send -- \"printf DRAFT_RESULT_\\$((40+2))\"\n" &
        "after 1000\n" &
        "send -- \"\\033\"\n" &
        "after 350\n" &
        "send -- \"\\r\"\n" &
        "expect -re {DRAFT_RESULT_42}\n" &
        # Empty-draft Escape resets to pane 0; /quit remains global.
        "send -- \"\\033\"\n" &
        "after 500\n" &
        "send -- \"/quit\\r\"\n" &
        "expect eof\n"
      let command = "/usr/bin/expect -c " & shellQuote(expectScript) &
                    " >/dev/null 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      let exitCode = terminal.waitForExit(20000)
      sleep(100)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check fileExists(focusedProof)
      check "DRAFT_RESULT_42" in output
      check "[0 main]" in output
      check "\e[?1049l" in output
      removeFile(focusedProof)

  test "ai agent worker output drops oldest bytes with explicit loss metadata":
    buildGeneCli()
    let fixture = "examples/ai_agent/worker_output_bound_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [make_application_with_task application_new_worker
         application_append_worker_output! application_set_projection_output!]
  from "./tui.gene")
(import str [byte_size])
(var app
  (make_application_with_task (cell []) (cell "") (cell [])
    (fn [_type, _props] nil) (cell nil)))
(var worker
  (application_new_worker app "output" "bounded" (cell "") nil))
(application_append_worker_output! app worker
  "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" "test")
(application_append_worker_output! app worker
  "more-output-abcdefghijklmnopqrstuvwxyz" "test")
(println (worker/output ~ Cell/get))
(println $"bytes=${(byte_size (worker/output ~ Cell/get))} dropped=${(worker/dropped_bytes ~ Cell/get)} before=${(worker/dropped_before ~ Cell/get)}")
(application_set_projection_output! app worker "fresh" "stats")
(println $"replacement=${(worker/output ~ Cell/get)} dropped=${(worker/dropped_bytes ~ Cell/get)} before=${(worker/dropped_before ~ Cell/get)}")
""")
    let ran = execCmdEx(
      "GENE_AGENT_WORKER_OUTPUT_MAX_BYTES=48 " & shellQuote(geneExe) &
      " run " & shellQuote(fixture))
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "[older output dropped:" in ran.output
    check ran.output.count("[older output dropped:") == 1
    check "bytes=48 dropped=85 before=2" in ran.output
    check "replacement=fresh dropped=0 before=nil" in ran.output

  test "ai agent main transcript reports exact bounded loss metadata":
    buildGeneCli()
    let fixture = "examples/ai_agent/transcript_overflow_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import str [byte_size])
(import [active_application make_application_with_task append_transcript
         application_workers_snapshot] from "./tui.gene")
(var app
  (make_application_with_task (cell []) (cell "") (cell [])
    (fn [_type, _props] nil) (cell nil)))
(active_application ~ Cell/set app)
(append_transcript app/main_agent/transcript
  "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-more")
(append_transcript app/main_agent/transcript
  "-second-abcdefghijklmnopqrstuvwxyz")
(var snapshots (application_workers_snapshot app))
(var snapshot snapshots/0)
(println (app/main_agent/transcript ~ Cell/get))
(println $"bytes=${(byte_size (app/main_agent/transcript ~ Cell/get))} dropped=${snapshot/transcript_dropped_bytes} before=${snapshot/transcript_dropped_before} seq=${snapshot/transcript_seq}")
""")
    let ran = execCmdEx(
      "GENE_AGENT_TRANSCRIPT_MAX_BYTES=64 " & shellQuote(geneExe) &
      " run " & shellQuote(fixture))
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check ran.output.count("[older transcript dropped:") == 1
    check "bytes=64" in ran.output
    check "before=2 seq=2" in ran.output
    check "dropped=0" notin ran.output

  test "ai agent projection workers do not amplify the event journal":
    buildGeneCli()
    let fixture = "examples/ai_agent/projection_amplification_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [active_application make_application_with_task open_stats_pane
         open_log_tail_pane application_emit] from "./tui.gene")
(var emitted (cell []))
(fn sink [type, props]
  (var event {^v (+ ((emitted ~ Cell/get) ~ size) 1) ^type type})
  (for [key value] in props (event ~ Map/put! key value))
  ((emitted ~ Cell/get) ~ List/push! event)
  event)
(var app
  (make_application_with_task (cell []) (cell "") (cell []) sink (cell nil)))
(active_application ~ Cell/set app)
(open_stats_pane)
(open_log_tail_pane "")
(application_emit app "check" {^command "nimble test" ^status 0})
(application_emit app "text_delta"
  {^worker_id app/main_agent/id ^agent_id app/main_agent/id ^text "ok"})
(application_emit app "agent_text"
  {^worker_id app/main_agent/id ^agent_id app/main_agent/id ^text "ok"})
(var projected 0)
(var source_checks 0)
(var aliased false)
(var worker_chunks 0)
(for event in (emitted ~ Cell/get)
  (if (== event/projection true) (set projected (+ projected 1)) nil)
  (if (== event/type "check") (set source_checks (+ source_checks 1)) nil)
  (if (&& (== event/type "worker_output") (!= event/source_v nil))
    (set aliased true) nil)
  (if (== event/type "worker_output")
    (set worker_chunks (+ worker_chunks 1)) nil))
(println $"projected=${projected} checks=${source_checks} aliased=${aliased} chunks=${worker_chunks} events=${((emitted ~ Cell/get) ~ size)}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "projected=0 checks=1" in ran.output
    check "aliased=true" in ran.output
    check "chunks=1" in ran.output

  test "ai agent shared worker snapshots exclude local surface state":
    buildGeneCli()
    let fixture = "examples/ai_agent/surface_independent_snapshot_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import str [contains?])
(import [make_application_with_task application_open_pane
         application_spawn_agent application_attach_worker_pane
         application_close_pane application_pane_ids_for_worker
         application_pane_views application_workers_snapshot
         main_presented_output] from "./tui.gene")
(import json [stringify])
(var app
  (make_application_with_task (cell []) (cell "") (cell [])
    (fn [_type, _props] nil) (cell nil)))
(var pane
  (application_open_pane app "output" nil "checks" (cell "ready") nil
                         "detach"))
(var before (stringify (application_workers_snapshot app)))
(app/local_surface/focused_pane ~ Cell/set pane/id)
(app/local_surface/maximized_pane ~ Cell/set pane/id)
(pane/scroll ~ Cell/set 99)
(var after (stringify (application_workers_snapshot app)))
(println $"same=${(== before after)} local_field=${(contains? after \"attached_local_pane\")}")
(var agent
  (application_spawn_agent app "review" "task" (cell []) (cell "ready")))
(var agent_pane
  (application_attach_worker_pane app agent agent/id "detach"))
(println $"agent_field=${(== agent/pane_ids void)} local_ids=${(application_pane_ids_for_worker app agent/id)}")
(agent/output ~ Cell/set "assistant|steered")
(agent_pane/pending_visible ~ Cell/set true)
(var presented (application_pane_views app))
(app/main_agent/transcript ~ Cell/set "agent> steered")
(app/local_surface/main_pending_visible ~ Cell/set true)
(var pane_overlay
  (contains? presented/1/output "assistant|steered\nassistant|..."))
(var main_overlay
  (contains? (main_presented_output app app/main_agent/transcript)
             "agent> steered\nagent> ..."))
(println $"pane_overlay=${pane_overlay} canonical=${(agent/output ~ Cell/get)} main_overlay=${main_overlay} main_canonical=${(app/main_agent/transcript ~ Cell/get)}")
(agent_pane/pending_visible ~ Cell/set false)
(app/local_surface/main_pending_visible ~ Cell/set false)
(var final_pane (application_pane_views app))
(println $"pane_final=${final_pane/1/output} main_final=${(main_presented_output app app/main_agent/transcript)}")
(app/local_surface/maximized_pane ~ Cell/set agent_pane/id)
(application_close_pane app agent_pane/id)
(println $"detached_ids=${(application_pane_ids_for_worker app agent/id)} max=${(app/local_surface/maximized_pane ~ Cell/get)}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "same=true local_field=false" in ran.output
    check "agent_field=true local_ids=[2]" in ran.output
    check "pane_overlay=true canonical=assistant|steered main_overlay=true main_canonical=agent> steered" in ran.output
    check "pane_final=assistant|steered main_final=agent> steered" in ran.output
    check "detached_ids=[] max=nil" in ran.output

  test "ai agent live worker and agent bounds are configurable":
    buildGeneCli()
    let fixture = "examples/ai_agent/live_worker_bound_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [make_application_with_task application_new_worker
         application_spawn_agent] from "./tui.gene")
(var app
  (make_application_with_task (cell []) (cell "") (cell [])
    (fn [_type, _props] nil) (cell nil)))
(var worker (application_new_worker app "output" "extra" (cell "") nil))
(var agent
  (application_spawn_agent app "extra" "task" (cell []) (cell "")))
(println $"worker=${(== worker nil)} agent=${(== agent nil)} max_workers=${app/max_workers} max_agents=${app/max_agents}")
""")
    let ran = execCmdEx(
      "GENE_AGENT_LIVE_WORKER_MAX_COUNT=1 " &
      "GENE_AGENT_LIVE_AGENT_MAX_COUNT=1 " & shellQuote(geneExe) &
      " run " & shellQuote(fixture))
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "worker=true agent=true max_workers=1 max_agents=1" in ran.output

  test "ai agent restarts stopped process workers with a successor id":
    buildGeneCli()
    let fixture = "examples/ai_agent/worker_restart_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [active_application make_application_with_task open_shell_pane
         application_stop_worker] from "./tui.gene")
(fn emit [type, props]
  (if (== type "worker_started")
    (println $"started=${props/worker_id} from=${props/restarted_from}") nil))
(var app
  (make_application_with_task (cell []) (cell "") (cell []) emit (cell nil)))
(active_application ~ Cell/set app)
(var first (open_shell_pane))
(first/worker/output ~ Cell/set "captured history\n")
(application_stop_worker app first/worker)
(var second (open_shell_pane))
(println $"old=${first/worker_id}:${(first/worker/lifecycle ~ Cell/get)}:${(first/output ~ Cell/get)} new=${second/worker_id}:${(second/worker/lifecycle ~ Cell/get)}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "started=w1 from=nil" in ran.output
    check "started=w2 from=w1" in ran.output
    check "old=w1:stopped:captured history" in ran.output
    check "new=w2:running" in ran.output

  test "ai agent bounds retained stopped worker snapshots":
    buildGeneCli()
    let fixture = "examples/ai_agent/stopped_worker_bound_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [make_headless_application_with_task application_new_worker
         application_stop_worker application_find_worker] from "./tui.gene")
(var dropped (cell []))
(fn emit [type, props]
  (if (== type "worker_retention_dropped")
    ((dropped ~ Cell/get) ~ List/push! props/worker_id) nil))
(var app
  (make_headless_application_with_task
    (cell []) (cell "") (cell []) emit (cell nil)))
(var worker nil)
(repeat i in 4
  (do
    (set worker
      (application_new_worker app "output" $"output ${i}" (cell $"${i}") nil))
    (application_stop_worker app worker)))
(var w1 (application_find_worker app "w1"))
(var w4 (application_find_worker app "w4"))
(println $"workers=${((app/workers ~ Cell/get) ~ size)} dropped=${(dropped ~ Cell/get)} w1=${w1} w4=${w4/id}")
""")
    let ran = execCmdEx(
      "GENE_AGENT_STOPPED_WORKER_MAX_COUNT=2 " & shellQuote(geneExe) &
      " run " & shellQuote(fixture))
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "workers=3" in ran.output
    check "dropped=[\"w1\" \"w2\"]" in ran.output
    check "w1=nil w4=w4" in ran.output

  test "ai agent summarizes oversized event records atomically":
    buildGeneCli()
    let fixture = "examples/ai_agent/oversized_event_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [bounded_event_record] from "./tui.gene")
(import json [stringify])
(import str [byte_size join])
(var pieces [])
(repeat i in 2400 (pieces ~ List/push! "x"))
(var event
  {^v 7 ^turn 2 ^type "worker_output" ^worker_id "w9" ^task_id "t3"
   ^text (join pieces "")})
(var bounded (bounded_event_record event 1024))
(println $"type=${bounded/type} worker=${bounded/worker_id} task=${bounded/task_id} truncated=${bounded/truncated} original=${bounded/original_bytes} bytes=${(byte_size (stringify bounded))}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "type=worker_output worker=w9 task=t3 truncated=true" in ran.output
    let bytesPos = ran.output.rfind("bytes=")
    check bytesPos >= 0
    if bytesPos >= 0:
      check parseInt(ran.output[bytesPos + 6 .. ^1].strip()) <= 1024

  test "ai agent external editor composition returns the saved draft":
    buildGeneCli()
    let editor = cliDir / "fake-agent-editor.sh"
    writeFile(editor,
      "#!/bin/sh\nsleep 0.2\nprintf 'composed\\nsecond line' > \"$1\"\n")
    setFilePermissions(editor, {fpUserRead, fpUserWrite, fpUserExec})
    let fixture = "examples/ai_agent/external_editor_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
      if fileExists(editor): removeFile(editor)
    writeFile(fixture, """
(import [external_editor_draft] from "./tui.gene")
(var ticks (cell 0))
(var composed (cell ""))
(scope
  (spawn (repeat 5 (do (sleep 20)
    (ticks ~ Cell/set (+ (ticks ~ Cell/get) 1)))))
  (composed ~ Cell/set (external_editor_draft "seed")))
(println (composed ~ Cell/get))
(println $"ticks=${(ticks ~ Cell/get)}")
""")
    let ran = execCmdEx(
      "EDITOR=" & shellQuote(editor) & " " & shellQuote(geneExe) &
      " run " & shellQuote(fixture))
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "composed\nsecond line" in ran.output
    check "ticks=5" in ran.output

  test "ai agent external editor suspension does not pause a remote turn":
    when defined(macosx):
      buildGeneCli()
      let editor = cliDir / "slow-agent-editor.sh"
      let editorStarted = cliDir / "slow-agent-editor.started"
      let editorFinished = cliDir / "slow-agent-editor.finished"
      let outputFile = cliDir / "agent-editor-gateway-pty.out"
      for path in [editorStarted, editorFinished, outputFile]:
        removeFile(path)
      writeFile(editor,
        "#!/bin/sh\n" &
        "touch " & shellQuote(editorStarted) & "\n" &
        "sleep 2\n" &
        "printf 'draft from editor' > \"$1\"\n" &
        "touch " & shellQuote(editorFinished) & "\n")
      setFilePermissions(editor, {fpUserRead, fpUserWrite, fpUserExec})
      defer:
        for path in [editor, editorStarted, editorFinished, outputFile]:
          removeFile(path)
      let inner =
        "stty rows 18 cols 80; exec /usr/bin/env " &
        "-u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY -u CODEX_ACCESS_TOKEN " &
        "TERM=xterm-256color GENE_GATEWAY_TOKEN=editor-gateway " &
        "EDITOR=" & shellQuote(editor) & " " &
        shellQuote(geneExe) &
        " run examples/ai_agent/tui.gene -- --gateway=8996"
      let expectScript =
        "set timeout 15\n" &
        "log_file -noappend " & outputFile & "\n" &
        "spawn /bin/sh -c {" & inner & "}\n" &
        # Tcl's regexp matcher can reject the UTF-8 screen buffer containing
        # arrow glyphs on older macOS Expect builds; the glob matcher handles
        # the same ASCII readiness marker reliably.
        "expect {Enter sends}\n" &
        # The status row is painted immediately before the first asynchronous
        # input poll is installed. Do not race that tiny setup window.
        "after 200\n" &
        "send -- \"/edit\\r\"\n" &
        "expect -re {external editor draft loaded}\n" &
        # `/edit` composes rather than submits. Clear its returned draft before
        # issuing the global shutdown command.
        "send -- [string repeat \"\\177\" 64]\n" &
        "after 100\n" &
        "send -- \"/quit\\r\"\n" &
        "expect eof\n"
      let terminal = startProcess(
        "/bin/sh",
        args = ["-c", "/usr/bin/expect -c " & shellQuote(expectScript) &
                      " >/dev/null 2>&1"],
        options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      let startedDeadline = getMonoTime() + initDuration(seconds = 10)
      while not fileExists(editorStarted):
        if getMonoTime() > startedDeadline:
          checkpoint "external editor did not start; terminal output: " &
                     (if fileExists(outputFile): readFile(outputFile) else: "")
          break
        sleep(25)
      require fileExists(editorStarted)
      proc editorGatewayCurl(call: string): string =
        let ran = execCmdEx(
          "curl -sS -H 'Authorization: Bearer editor-gateway' " & call)
        if ran.exitCode != 0: checkpoint ran.output
        check ran.exitCode == 0
        ran.output
      let posted = editorGatewayCurl(
        "-X POST -H 'content-type: application/json' " &
        "-d '{\"text\":\"remote while editing\"}' " &
        "http://127.0.0.1:8996/api/sessions/local/messages")
      check "\"ok\":true" in posted
      var remoteEvents = ""
      let eventDeadline = getMonoTime() + initDuration(seconds = 5)
      while "turn_done" notin remoteEvents and getMonoTime() < eventDeadline:
        remoteEvents.add editorGatewayCurl(
          "'http://127.0.0.1:8996/api/sessions/local/events?cursor=0'")
      check "turn_done" in remoteEvents
      check not fileExists(editorFinished)
      let exitCode = terminal.waitForExit(15000)
      if exitCode != 0 and fileExists(outputFile):
        checkpoint readFile(outputFile)
      check exitCode == 0
      check fileExists(editorFinished)

  test "ai agent ignores blank input":
    buildGeneCli()
    let command = "printf '   \\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    check "agent>" notin ran.output

  test "ai agent opens routes and closes extension conversations":
    buildGeneCli()
    let fixture = writeCliProgram("fake_extension_endpoint.gene", """
(import net/http [Server serve Response])
(import json [stringify])

(var chunk
  {^choices [{^index 0
              ^delta {^role "assistant" ^content "extension-ok"}
              ^finish_reason "stop"}]})

(fn handle [req]
  (Response ^status 200
            ^headers {^content-type "text/event-stream"}
            ^body $"data: ${(stringify chunk)}\n\ndata: [DONE]\n\n"))

(serve (Server ^host "127.0.0.1" ^port 8958) handle ^max_requests 1)
""")
    let server = startProcess(geneExe, args = ["run", fixture],
                              options = {poUsePath, poStdErrToStdOut})
    defer:
      if server.running: server.terminate()
      server.close()
    block waitForServer:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var socket = newSocket()
        try:
          socket.connect("127.0.0.1", Port(8958), timeout = 500)
          socket.close()
          break waitForServer
        except OSError, TimeoutError:
          socket.close()
          if getMonoTime() > deadline:
            raise
          sleep(50)
    let command = "(printf '/ext\\n/1 inspect this\\n'; sleep 1; " &
                  "printf '/1 close\\n/quit\\n') | " &
                  "env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
                  "OPENAI_AUTH_TOKEN=dummy OPENAI_API=chat " &
                  "OPENAI_BASE_URL=http://127.0.0.1:8958/v1 " &
                  "OPENAI_MODEL=fake-chat " & shellQuote(geneExe) &
                  " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "opened agent a1 in pane 1" in ran.output
    check "extension 1 completed" in ran.output
    check "closed pane 1" in ran.output
    check server.waitForExit(3000) == 0

  test "ai agent can delegate through the open_extension tool":
    buildGeneCli()
    let fixture = writeCliProgram("fake_extension_tool_endpoint.gene", """
(import net/http [Server serve Response])
(import json [parse stringify])
(import str [contains?])

(var hits (cell 0))

(fn sse [chunks]
  (var body (cell ""))
  (for chunk in chunks
    (body ~ Cell/set $"${(body ~ Cell/get)}data: ${(stringify chunk)}\n\n"))
  $"${(body ~ Cell/get)}data: [DONE]\n\n")

(var delegate
  [{^choices [{^index 0
               ^delta {^role "assistant"
                       ^tool_calls [{^index 0 ^id "call_ext" ^type "function"
                                     ^function {^name "open_extension"
                                                ^arguments "{\"title\":\"review\",\"prompt\":\"inspect\"}"}}]}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "tool_calls"}]}])

(fn answer [text]
  [{^choices [{^index 0 ^delta {^role "assistant" ^content text}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "stop"}]}])

(fn handle [req]
  (Cell/set hits (+ (Cell/get hits) 1))
  (var chunks
    (if (== (Cell/get hits) 1)
      delegate
      (if (== (Cell/get hits) 2)
        (answer "extension-findings")
        (answer
          (if (contains? req/body "extension-findings")
            "delegation-ok"
            "delegation-missing-result")))))
  (Response ^status 200
            ^headers {^content-type "text/event-stream"}
            ^body (sse chunks)))

(serve (Server ^host "127.0.0.1" ^port 8957) handle ^max_requests 3)
""")
    let server = startProcess(geneExe, args = ["run", fixture],
                              options = {poUsePath, poStdErrToStdOut})
    defer:
      if server.running: server.terminate()
      server.close()
    block waitForServer:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var socket = newSocket()
        try:
          socket.connect("127.0.0.1", Port(8957), timeout = 500)
          socket.close()
          break waitForServer
        except OSError, TimeoutError:
          socket.close()
          if getMonoTime() > deadline:
            raise
          sleep(50)
    let command = "printf 'delegate\\n/quit\\n' | " &
                  "env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
                  "OPENAI_AUTH_TOKEN=dummy OPENAI_API=chat " &
                  "OPENAI_BASE_URL=http://127.0.0.1:8957/v1 " &
                  "OPENAI_MODEL=fake-chat " & shellQuote(geneExe) &
                  " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "tool open_extension" in ran.output
    check "delegation-ok" in ran.output
    check "delegation-missing-result" notin ran.output
    check server.waitForExit(3000) == 0

  test "ai agent slash repl exposes session binding":
    buildGeneCli()
    let command = "printf '/repl\\n/1 session/config/model\\n/1 (var x 41)\\n/1 (+ x 1)\\n/1 close\\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    check "REPL pane 1" in ran.output
    # session/config/model is a real projection (model lives under config,
    # §9.1); the quoted form is the REPL value, distinct from the banner text.
    check "\"gpt-5.6-terra\"" in ran.output
    check "41" in ran.output
    check "42" in ran.output

  test "ai agent repl pane closes back to the agent prompt":
    buildGeneCli()
    let command = "printf '/repl\\n/1 session/main_agent/id\\n/1 close\\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    check "\"main\"" in ran.output
    check "closed pane 1" in ran.output

  test "ai agent persists config session and memory":
    buildGeneCli()
    let stateDir = cliDir / "ai_agent_state"
    if dirExists(stateDir):
      removeDir(stateDir)

    let first = execCmdOnce(
      "printf '/remember project uses Gene\\n/status\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
      "CODEX_ACCESS_TOKEN=dummy GENE_AGENT_STATE=" & shellQuote(stateDir) &
      " " & shellQuote(geneExe) & " run examples/ai_agent/tui.gene")
    check first.exitCode == 0
    check "remembered: project uses Gene" in first.output
    check "state: " & stateDir in first.output
    check "memory: 1" in first.output
    let configText = readFile(stateDir / "config.gene")
    check "dummy" notin configText
    check "OPENAI_AUTH_TOKEN" notin configText
    check "CODEX_ACCESS_TOKEN" notin configText

    let second = execCmdOnce(
      "printf '/memory\\n/status\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
      "CODEX_ACCESS_TOKEN=dummy GENE_AGENT_STATE=" & shellQuote(stateDir) &
      " " & shellQuote(geneExe) & " run examples/ai_agent/tui.gene")
    check second.exitCode == 0
    check "memory:\nproject uses Gene" in second.output
    check "state: " & stateDir in second.output
    check "model: gpt-5.6-terra" in second.output
    check "api: responses" in second.output
    check "memory: 1" in second.output
    let sessionText = readFile(stateDir / "session.gene")
    check "/remember project uses Gene\\n" in sessionText
    check "/memory\\n" in sessionText
    check "agent> remembered: project uses Gene" in sessionText
    check "agent> memory:\\nproject uses Gene" in sessionText

  test "ai agent talks to an openai-compatible chat endpoint":
    ## End-to-end over loopback: a fake /chat/completions endpoint streams a
    ## tool_call in SSE fragments, then validates that the agent's second
    ## request carries the round trip in chat shape (assistant tool_calls +
    ## role:"tool" reply) before answering.
    buildGeneCli()
    let fixture = writeCliProgram("fake_chat_endpoint.gene", """
(import net/http [Server serve Response])
(import json [parse stringify])
(import str [join])
(import std/stream [to_stream map each into])

(var hits (cell 0))

(fn sse-body [chunks]
  (var lines
    ((to_stream chunks)
      ~ map (fn [c] $"data: ${(stringify c)}")
      ; ~ into []))
  (var sep "\n\n")
  (var joined (join lines sep))
  $"${joined}${sep}data: [DONE]${sep}")

(var turn1
  [{^choices [{^index 0
               ^delta {^role "assistant"
                       ^tool_calls [{^index 0 ^id "call_fake_1" ^type "function"
                                     ^function {^name "list_dir" ^arguments ""}}]}}]}
   {^choices [{^index 0
               ^delta {^tool_calls [{^index 0
                                     ^function {^arguments "{\"path\":\".\"}"}}]}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "tool_calls"}]}])

(fn turn2-verdict [body-text]
  (var req (parse body-text))
  (var saw-assistant-call (cell false))
  (var saw-tool-reply (cell false))
  ((to_stream req/messages)
    ~ each (fn [m]
        (if (&& (== m/role "assistant")
                (== m/tool_calls/0/id "call_fake_1")
                (== m/tool_calls/0/function/name "list_dir"))
          (Cell/set saw-assistant-call true)
          nil)
        (if (&& (== m/role "tool")
                (== m/tool_call_id "call_fake_1"))
          (Cell/set saw-tool-reply true)
          nil)))
  (if (!= req/model "fake-chat")
    "roundtrip-bad: model"
    (if (!= req/tools/0/function/name "read_file")
      "roundtrip-bad: tools"
      (if (! (Cell/get saw-assistant-call))
        "roundtrip-bad: assistant tool_calls"
        (if (! (Cell/get saw-tool-reply))
          "roundtrip-bad: tool reply"
          "roundtrip-ok")))))

(fn turn2-chunks [body-text]
  [{^choices [{^index 0 ^delta {^content "verdict: "}}]}
   {^choices [{^index 0 ^delta {^content (turn2-verdict body-text)}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "stop"}]}])

(fn handle [req]
  (Cell/set hits (+ (Cell/get hits) 1))
  (var chunks (if (== (Cell/get hits) 1) turn1 (turn2-chunks req/body)))
  (Response ^status 200
            ^headers {^content-type "text/event-stream"}
            ^body (sse-body chunks)))

(serve (Server ^host "127.0.0.1" ^port 8987) handle ^max_requests 2)
""")
    let server = startProcess(geneExe, args = ["run", fixture],
                              options = {poUsePath, poStdErrToStdOut})
    defer:
      if server.running:
        server.terminate()
      server.close()
    block waitForServer:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(8987), timeout = 500)
          s.close()
          break waitForServer
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline:
            raise
          sleep(50)
    let ran = execCmdOnce("env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
                        "-u OPENAI_API OPENAI_AUTH_TOKEN=dummy " &
                        "OPENAI_BASE_URL=http://127.0.0.1:8987/v1 " &
                        "OPENAI_MODEL=fake-chat " &
                        shellQuote(geneExe) &
                        " run examples/ai_agent/tui.gene 'what is here?'")
    check ran.exitCode == 0
    check "tool list_dir" in ran.output
    check "verdict: roundtrip-ok" in ran.output

  test "ai agent surfaces non-success HTTP responses":
    ## A completed native HTTP transfer has process status 0 even for a 401.
    ## The agent must report the HTTP error instead of accepting its JSON body
    ## as an empty model response and appearing to hang at a blank prompt.
    buildGeneCli()
    let fixture = writeCliProgram("fake_agent_unauthorized.gene", """
(import net/http [Server serve Response])

(fn handle [req]
  (Response ^status 401
            ^headers {^content-type "application/json"}
            ^body "{\"detail\":\"Unauthorized\"}"))

(serve (Server ^host "127.0.0.1" ^port 8996) handle ^max_requests 1)
""")
    let server = startProcess(geneExe, args = ["run", fixture],
                              options = {poUsePath, poStdErrToStdOut})
    defer:
      if server.running:
        server.terminate()
      server.close()
    block waitForServer:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(8996), timeout = 500)
          s.close()
          break waitForServer
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline:
            raise
          sleep(50)
    let ran = execCmdOnce("env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
                        "OPENAI_AUTH_TOKEN=dummy OPENAI_API=responses " &
                        "OPENAI_BASE_URL=http://127.0.0.1:8996 " &
                        "OPENAI_MODEL=fake-responses " &
                        shellQuote(geneExe) &
                        " run examples/ai_agent/tui.gene 'say hi'")
    check ran.exitCode == 0
    check "OpenAI API error 401: Unauthorized" in ran.output

  test "ai agent redacts the api token out of tool output before the model sees it":
    ## §8.5 secret-redaction: a run_shell tool whose OUTPUT contains the token
    ## must not leak it into the next model request. Turn 1 runs
    ## `printenv OPENAI_AUTH_TOKEN` (token is in the child env, not the command
    ## text); turn 2 inspects the request body — the tool output must be
    ## redacted. The command itself carries no token, so a LEAKED verdict can
    ## only come from unredacted tool output.
    buildGeneCli()
    let fixture = writeCliProgram("fake_redact_endpoint.gene", """
(import net/http [Server serve Response])
(import json [parse stringify])
(import str [join contains?])
(import std/stream [to_stream map into])

(var hits (cell 0))

(fn sse-body [chunks]
  (var lines
    ((to_stream chunks)
      ~ map (fn [c] $"data: ${(stringify c)}")
      ; ~ into []))
  (var sep "\n\n")
  (var joined (join lines sep))
  $"${joined}${sep}data: [DONE]${sep}")

(var turn1
  [{^choices [{^index 0
               ^delta {^role "assistant"
                       ^tool_calls [{^index 0 ^id "call_r1" ^type "function"
                                     ^function {^name "run_shell" ^arguments ""}}]}}]}
   {^choices [{^index 0
               ^delta {^tool_calls [{^index 0
                 ^function {^arguments "{\"command\":\"printenv OPENAI_AUTH_TOKEN\"}"}}]}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "tool_calls"}]}])

(fn turn2-verdict [body]
  (if (contains? body "sk-secret-tok-9Z")
    "LEAKED"
    (if (contains? body "REDACTED")
      "redacted-ok"
      "no-tool-output")))

(fn turn2-chunks [body]
  [{^choices [{^index 0 ^delta {^content "verdict: "}}]}
   {^choices [{^index 0 ^delta {^content (turn2-verdict body)}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "stop"}]}])

(fn handle [req]
  (Cell/set hits (+ (Cell/get hits) 1))
  (var chunks (if (== (Cell/get hits) 1) turn1 (turn2-chunks req/body)))
  (Response ^status 200
            ^headers {^content-type "text/event-stream"}
            ^body (sse-body chunks)))

(serve (Server ^host "127.0.0.1" ^port 8991) handle ^max_requests 2)
""")
    let server = startProcess(geneExe, args = ["run", fixture],
                              options = {poUsePath, poStdErrToStdOut})
    defer:
      if server.running:
        server.terminate()
      server.close()
    block waitForServer:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(8991), timeout = 500)
          s.close()
          break waitForServer
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline:
            raise
          sleep(50)
    let ran = execCmdOnce("env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
                        "-u OPENAI_API OPENAI_AUTH_TOKEN=sk-secret-tok-9Z " &
                        "GENE_AGENT_APPROVE_ALL=1 " &
                        "OPENAI_BASE_URL=http://127.0.0.1:8991/v1 " &
                        "OPENAI_MODEL=fake-chat " &
                        shellQuote(geneExe) &
                        " run examples/ai_agent/tui.gene 'print the token'")
    check ran.exitCode == 0
    check "verdict: redacted-ok" in ran.output
    check "LEAKED" notin ran.output

  test "ai agent derives the tool json schema from the typed declaration":
    ## Slice A (§6): the model-facing tool schema is DERIVED from one typed
    ## Tool value, not a hand-written list. The fake endpoint answers on the
    ## first request and reports what the derived read_file schema looked like
    ## on the wire — object type, required[path], and a param description that
    ## only the declaration carries.
    buildGeneCli()
    let fixture = writeCliProgram("fake_schema_endpoint.gene", """
(import net/http [Server serve Response])
(import json [parse stringify])
(import str [join contains?])
(import std/stream [to_stream map filter into])

(fn sse-body [chunks]
  (var lines
    ((to_stream chunks)
      ~ map (fn [c] $"data: ${(stringify c)}")
      ; ~ into []))
  (var sep "\n\n")
  (var joined (join lines sep))
  $"${joined}${sep}data: [DONE]${sep}")

(fn read-file-schema [req]
  (var hit
    ((to_stream req/tools)
      ~ filter (fn [t] (== t/function/name "read_file"))
      ; ~ into []))
  hit/0/function)

(fn verdict [body-text]
  (var req (parse body-text))
  (var f (read-file-schema req))
  (if (!= f/parameters/type "object")
    "schema-bad: type"
    (if (!= f/parameters/required/0 "path")
      "schema-bad: required"
      (if (! (contains? (stringify f/parameters/properties/path) "workspace"))
        "schema-bad: param-doc"
        "schema-ok"))))

(fn chunks [body-text]
  [{^choices [{^index 0 ^delta {^content "verdict: "}}]}
   {^choices [{^index 0 ^delta {^content (verdict body-text)}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "stop"}]}])

(fn handle [req]
  (Response ^status 200
            ^headers {^content-type "text/event-stream"}
            ^body (sse-body (chunks req/body))))

(serve (Server ^host "127.0.0.1" ^port 8993) handle ^max_requests 1)
""")
    let server = startProcess(geneExe, args = ["run", fixture],
                              options = {poUsePath, poStdErrToStdOut})
    defer:
      if server.running:
        server.terminate()
      server.close()
    block waitForServer:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(8993), timeout = 500)
          s.close()
          break waitForServer
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline:
            raise
          sleep(50)
    let ran = execCmdOnce("env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
                        "-u OPENAI_API OPENAI_AUTH_TOKEN=dummy " &
                        "OPENAI_BASE_URL=http://127.0.0.1:8993/v1 " &
                        "OPENAI_MODEL=fake-chat " &
                        shellQuote(geneExe) &
                        " run examples/ai_agent/tui.gene 'read something'")
    check ran.exitCode == 0
    check "verdict: schema-ok" in ran.output

  test "ai agent scripted /sh denies a catastrophic line but runs normal ones":
    ## Review #3: the piped /sh loop reads lines in Gene, so each runs through
    ## the same §8.5 classifier as model-issued run_shell. A catastrophic line
    ## is denied; a normal line still executes. (Interactive TTY /sh is a
    ## documented escape hatch and is not covered here.) The command targets a
    ## nonexistent root-level path: it classifies catastrophic via the
    ## leading-/ rule but deletes nothing if the guard ever regresses.
    buildGeneCli()
    let command = "printf '/sh\\n/1 rm -rf /nonexistent-gene-guard-root\\n/1 echo ran-normal\\n/1 close\\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    check "denied by catastrophe guard" in ran.output
    check "ran-normal" in ran.output

  test "ai agent classifier flags the real worst-case strings without executing them":
    ## Review #1: exercise classify_command on the REAL catastrophic spellings
    ## through /repl (pure classification — nothing is executed), so the
    ## dangerous strings never sit in an executable path.
    buildGeneCli()
    let command = "printf '/repl\\n" &
      "/1 (classify_command \"rm -rf /\")\\n" &
      "/1 (classify_command \"rm -rf $HOME\")\\n" &
      "/1 (classify_command \"shutdown -h now\")\\n" &
      "/1 (classify_command \"git reset --hard HEAD~1\")\\n" &
      "/1 (classify_command \"npm test\")\\n" &
      "/1 close\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    check ran.output.count("\"catastrophic\"") == 3
    check "\"destructive\"" in ran.output
    check "\"normal\"" in ran.output

  test "ai agent survives non-object tool arguments and logs turn_done":
    ## Review #5/#6: valid JSON that is not an object ([]) must become a tool
    ## error, not a crashed turn; and the CLI must log exactly the turn_done
    ## boundary event the vocabulary declares. A fake endpoint sends list_dir
    ## with arguments "[]" on turn 1, then a plain answer on turn 2.
    buildGeneCli()
    let fixture = writeCliProgram("fake_badargs_endpoint.gene", """
(import net/http [Server serve Response])
(import json [parse stringify])
(import str [join])
(import std/stream [to_stream map into])

(var hits (cell 0))

(fn sse-body [chunks]
  (var lines
    ((to_stream chunks)
      ~ map (fn [c] $"data: ${(stringify c)}")
      ; ~ into []))
  (var sep "\n\n")
  (var joined (join lines sep))
  $"${joined}${sep}data: [DONE]${sep}")

(var turn1
  [{^choices [{^index 0
               ^delta {^role "assistant"
                       ^tool_calls [{^index 0 ^id "call_b1" ^type "function"
                                     ^function {^name "list_dir" ^arguments ""}}]}}]}
   {^choices [{^index 0
               ^delta {^tool_calls [{^index 0 ^function {^arguments "[]"}}]}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "tool_calls"}]}])

(var turn2
  [{^choices [{^index 0 ^delta {^content "done"}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "stop"}]}])

(fn handle [req]
  (Cell/set hits (+ (Cell/get hits) 1))
  (Response ^status 200
            ^headers {^content-type "text/event-stream"}
            ^body (sse-body (if (== (Cell/get hits) 1) turn1 turn2))))

(serve (Server ^host "127.0.0.1" ^port 8971) handle ^max_requests 2)
""")
    let server = startProcess(geneExe, args = ["run", fixture],
                              options = {poUsePath, poStdErrToStdOut})
    defer:
      if server.running:
        server.terminate()
      server.close()
    block waitForServer:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(8971), timeout = 500)
          s.close()
          break waitForServer
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline:
            raise
          sleep(50)
    let command = "printf 'go\\n/trace type=turn_done\\n/trace type=tool_result\\n/quit\\n' | " &
                  "env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY -u OPENAI_API " &
                  "OPENAI_AUTH_TOKEN=dummy " &
                  "OPENAI_BASE_URL=http://127.0.0.1:8971/v1 OPENAI_MODEL=fake-chat " &
                  shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    # #5: no crash — the turn completed with the model's final answer.
    check "agent> done" in ran.output
    # #5: the non-object args produced a tool error, not an exception.
    check "tool arguments must be a JSON object" in ran.output
    # #6: the CLI logged the turn_done boundary event.
    check "turn_done" in ran.output

  test "ai agent converts an invalid tool result shape into a tool error":
    ## Review #6: a /repl-registered handler returning nil (or any non-Str,
    ## non-{^text Str} shape) must become a tool error the model sees — not a
    ## boundary error that aborts the turn. The fake endpoint asks for the
    ## bad tool on the resumed turn, then reports what the tool reply said.
    buildGeneCli()
    let fixture = writeCliProgram("fake_badshape_endpoint.gene", """
(import net/http [Server serve Response])
(import json [parse stringify])
(import str [join contains?])
(import std/stream [to_stream map each into])

(var hits (cell 0))

(fn sse-body [chunks]
  (var lines
    ((to_stream chunks)
      ~ map (fn [c] $"data: ${(stringify c)}")
      ; ~ into []))
  (var sep "\n\n")
  (var joined (join lines sep))
  $"${joined}${sep}data: [DONE]${sep}")

(var call-badres
  [{^choices [{^index 0
               ^delta {^role "assistant"
                       ^tool_calls [{^index 0 ^id "call_s1" ^type "function"
                                     ^function {^name "badres" ^arguments "{}"}}]}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "tool_calls"}]}])

(fn verdict-chunks [body]
  (var req (parse body))
  (var tool-text (cell "no-tool-msg"))
  ((to_stream req/messages)
    ~ each (fn [m]
        (if (== m/role "tool")
          (Cell/set tool-text m/content)
          nil)))
  (var v (if (contains? (Cell/get tool-text) "invalid result shape")
           "shape-error-ok"
           "shape-unhandled"))
  [{^choices [{^index 0 ^delta {^content $"verdict: ${v}"}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "stop"}]}])

(fn handle [req]
  (Cell/set hits (+ (Cell/get hits) 1))
  (var chunks (if (== (Cell/get hits) 1) call-badres (verdict-chunks req/body)))
  (Response ^status 200
            ^headers {^content-type "text/event-stream"}
            ^body (sse-body chunks)))

(serve (Server ^host "127.0.0.1" ^port 8969) handle ^max_requests 2)
""")
    let server = startProcess(geneExe, args = ["run", fixture],
                              options = {poUsePath, poStdErrToStdOut})
    defer:
      if server.running:
        server.terminate()
      server.close()
    block waitForServer:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(8969), timeout = 500)
          s.close()
          break waitForServer
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline:
            raise
          sleep(50)
    let script = "printf '/repl\\n" &
      "/1 (session ~ add_tool (Tool ^name \"badres\" ^description \"demo\" " &
      "^risk \"read\" ^params [] ^handler (fn [a] nil)))\\n" &
      "/1 (session ~ resume)\\n/1 close\\n/quit\\n' | " &
      "env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY -u OPENAI_API " &
      "OPENAI_AUTH_TOKEN=dummy " &
      "OPENAI_BASE_URL=http://127.0.0.1:8969/v1 OPENAI_MODEL=fake-chat " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(script)
    check ran.exitCode == 0
    check "verdict: shape-error-ok" in ran.output

  test "ai agent catastrophe guard denies a host-destroying run_shell command":
    ## §8.5: a run_shell tool call whose command is catastrophic (recursive rm
    ## of a root-level path — harmless here: the target does not exist)
    ## must be denied by the guard BEFORE the subprocess runs, and the denial
    ## must be the tool output the model sees on the next turn. Auto-approve is
    ## on, so only the guard can stop it — proving classification, not a prompt.
    buildGeneCli()
    let fixture = writeCliProgram("fake_guard_endpoint.gene", """
(import net/http [Server serve Response])
(import json [parse stringify])
(import str [join contains?])
(import std/stream [to_stream each into map])

(var hits (cell 0))

(fn sse-body [chunks]
  (var lines
    ((to_stream chunks)
      ~ map (fn [c] $"data: ${(stringify c)}")
      ; ~ into []))
  (var sep "\n\n")
  (var joined (join lines sep))
  $"${joined}${sep}data: [DONE]${sep}")

(var turn1
  [{^choices [{^index 0
               ^delta {^role "assistant"
                       ^tool_calls [{^index 0 ^id "call_g1" ^type "function"
                                     ^function {^name "run_shell" ^arguments ""}}]}}]}
   {^choices [{^index 0
               ^delta {^tool_calls [{^index 0
                 ^function {^arguments "{\"command\":\"rm -rf /nonexistent-gene-guard-root\"}"}}]}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "tool_calls"}]}])

(fn turn2-verdict [body]
  (var req (parse body))
  (var tool-text (cell "no-tool-msg"))
  ((to_stream req/messages)
    ~ each (fn [m]
        (if (== m/role "tool")
          (Cell/set tool-text m/content)
          nil)))
  (if (contains? (Cell/get tool-text) "catastrophe guard")
    "guard-blocked"
    "guard-bypassed"))

(fn turn2-chunks [body]
  [{^choices [{^index 0 ^delta {^content "verdict: "}}]}
   {^choices [{^index 0 ^delta {^content (turn2-verdict body)}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "stop"}]}])

(fn handle [req]
  (Cell/set hits (+ (Cell/get hits) 1))
  (var chunks (if (== (Cell/get hits) 1) turn1 (turn2-chunks req/body)))
  (Response ^status 200
            ^headers {^content-type "text/event-stream"}
            ^body (sse-body chunks)))

(serve (Server ^host "127.0.0.1" ^port 8994) handle ^max_requests 2)
""")
    let server = startProcess(geneExe, args = ["run", fixture],
                              options = {poUsePath, poStdErrToStdOut})
    defer:
      if server.running:
        server.terminate()
      server.close()
    block waitForServer:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(8994), timeout = 500)
          s.close()
          break waitForServer
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline:
            raise
          sleep(50)
    let ran = execCmdOnce("env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
                        "-u OPENAI_API OPENAI_AUTH_TOKEN=dummy " &
                        "GENE_AGENT_APPROVE_ALL=1 " &
                        "OPENAI_BASE_URL=http://127.0.0.1:8994/v1 " &
                        "OPENAI_MODEL=fake-chat " &
                        shellQuote(geneExe) &
                        " run examples/ai_agent/tui.gene 'clean up the disk'")
    check ran.exitCode == 0
    check "verdict: guard-blocked" in ran.output

  test "ai agent trace lists tool registration and turn events":
    ## Slice A (§9.2/§10.2): every tool registers as a tool_registered event
    ## and /trace filters the versioned log. /status surfaces the guard state
    ## and event count.
    buildGeneCli()
    let command = "printf '/trace type=tool_registered\\n/status\\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
                  "CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    check "tool_registered read_file (read)" in ran.output
    check "tool_registered run_shell (execute)" in ran.output
    check "guard: on" in ran.output

  test "ai agent diff and targeted undo preserve unowned edits":
    buildGeneCli()
    let workspace = cliDir / "agent-attribution-workspace"
    if dirExists(workspace):
      removeDir(workspace)
    createDir(workspace)
    writeFile(workspace / "dirty.txt", "user-before\n")
    writeFile(workspace / "safe.txt", "safe-before\n")
    writeFile(workspace / "untouched.txt", "keep-me\n")

    let fixture = writeCliProgram("file_change_endpoint.gene", """
(import net/http [Server serve Response])
(import json [stringify])
(import str [join])
(import std/stream [to_stream map into])
(var hits (cell 0))
(fn sse_body [chunks]
  (var lines ((to_stream chunks)
    ~ map (fn [c] $"data: ${(stringify c)}") ; ~ into []))
  (var joined (join lines "\n\n"))
  $"${joined}\n\ndata: [DONE]\n\n")
(var tool_turn
  [{^choices [{^index 0 ^delta {^role "assistant" ^tool_calls
    [{^index 0 ^id "fc1" ^type "function"
      ^function {^name "edit_file"
                 ^arguments "{\"path\":\"dirty.txt\",\"old_text\":\"user-before\\n\",\"new_text\":\"agent-owned\\n\"}"}}
     {^index 1 ^id "fc2" ^type "function"
      ^function {^name "write_file"
                 ^arguments "{\"path\":\"new.txt\",\"content\":\"new-content\\n\"}"}}
     {^index 2 ^id "fc3" ^type "function"
      ^function {^name "edit_file"
                 ^arguments "{\"path\":\"safe.txt\",\"old_text\":\"safe-before\\n\",\"new_text\":\"safe-agent\\n\"}"}}]}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "tool_calls"}]}])
(var done_turn
  [{^choices [{^index 0 ^delta {^content "files changed"}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "stop"}]}])
(fn handle [req]
  (hits ~ Cell/set (+ (hits ~ Cell/get) 1))
  (Response ^status 200 ^headers {^content-type "text/event-stream"}
            ^body (sse_body (if (== (hits ~ Cell/get) 1)
                              tool_turn done_turn))))
(serve (Server ^host "127.0.0.1" ^port 8966) handle ^max_requests 2)
""")
    let server = startProcess(geneExe, args = ["run", fixture],
                              options = {poUsePath, poStdErrToStdOut})
    defer:
      if server.running:
        server.terminate()
      server.close()
    block waitForServer:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(8966), timeout = 500)
          s.close()
          break waitForServer
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline:
            raise
          sleep(50)

    let tui = normalizedPath(absolutePath("examples/ai_agent/tui.gene"))
    let input = "go\n/diff\n/sh\n/1 printf external > dirty.txt\n/1 close\n" &
                "/undo 1\n/undo 3\n/undo 2\n/diff\n" &
                "/trace type=file_change\n/quit\n"
    let command = "cd " & shellQuote(workspace) & " && printf " &
      shellQuote(input) & " | env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
      "OPENAI_AUTH_TOKEN=dummy OPENAI_API=chat " &
      "OPENAI_BASE_URL=http://127.0.0.1:8966/v1 OPENAI_MODEL=fake-chat " &
      shellQuote(geneExe) & " run " & shellQuote(tui)
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    check "change #1 edit dirty.txt (pre-existing file)" in ran.output
    check "change #2 write new.txt (new file)" in ran.output
    check "refused: dirty.txt changed after agent change #1" in ran.output
    check "undid change #3 (safe.txt)" in ran.output
    check "undid change #2 (new.txt)" in ran.output
    check "file_change #1 edit: dirty.txt" in ran.output
    check "file_change undo #3: safe.txt" in ran.output
    check readFile(workspace / "dirty.txt") == "external"
    check readFile(workspace / "safe.txt") == "safe-before\n"
    check readFile(workspace / "untouched.txt") == "keep-me\n"
    check not fileExists(workspace / "new.txt")

  test "ai agent records structured command evidence and restores it":
    buildGeneCli()
    let stateDir = cliDir / "agent-evidence-state"
    if dirExists(stateDir): removeDir(stateDir)
    let fixture = writeCliProgram("evidence_endpoint.gene", """
(import net/http [Server serve Response])
(import json [stringify])
(import str [join])
(import std/stream [to_stream map into])
(var hits (cell 0))
(fn sse_body [chunks]
  (var lines ((to_stream chunks)
    ~ map (fn [c] $"data: ${(stringify c)}") ; ~ into []))
  (var joined (join lines "\n\n"))
  $"${joined}\n\ndata: [DONE]\n\n")
(var calls
  [{^choices [{^index 0 ^delta {^role "assistant" ^tool_calls
    [{^index 0 ^id "ev1" ^type "function"
      ^function {^name "run_shell" ^arguments "{\"command\":\"printf checked\"}"}}
     {^index 1 ^id "ev2" ^type "function"
      ^function {^name "run_shell" ^arguments "{\"command\":\"exit 7\"}"}}
     {^index 2 ^id "ev3" ^type "function"
      ^function {^name "run_shell" ^arguments "{\"command\":\"yes x | head -c 70000\"}"}}]}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "tool_calls"}]}])
(var done
  [{^choices [{^index 0 ^delta {^content "checks complete"}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "stop"}]}])
(fn handle [req]
  (hits ~ Cell/set (+ (hits ~ Cell/get) 1))
  (Response ^status 200 ^headers {^content-type "text/event-stream"}
            ^body (sse_body (if (== (hits ~ Cell/get) 1) calls done))))
(serve (Server ^host "127.0.0.1" ^port 8965) handle ^max_requests 2)
""")
    let server = startProcess(geneExe, args = ["run", fixture],
                              options = {poUsePath, poStdErrToStdOut})
    defer:
      if server.running: server.terminate()
      server.close()
    block waitForServer:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(8965), timeout = 500)
          s.close()
          break waitForServer
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline: raise
          sleep(50)
    let command = "printf '/repl\n/1 (session/evidence ~ Cell/get)\n/1 close\n" &
      "go\n/trace type=check\n/repl\n/2 (session/evidence ~ Cell/get)\n" &
      "/2 close\n/quit\n' | env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
      "OPENAI_AUTH_TOKEN=dummy OPENAI_API=chat " &
      "GENE_AGENT_STATE=" & shellQuote(stateDir) & " " &
      "OPENAI_BASE_URL=http://127.0.0.1:8965/v1 OPENAI_MODEL=fake-chat " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    check "REPL pane 1: []" in ran.output
    check "check command status=0" in ran.output
    check "check command status=7" in ran.output
    check "^^truncated" in ran.output
    check "^^verified" in ran.output
    check "^verified false" in ran.output
    let stored = readFile(stateDir / "events.gene")
    check stored.count("^type \"check\"") == 3
    check "^duration_ms" in stored

    let restored = execCmdOnce(
      "printf '/trace type=check\n/quit\n' | " &
      "env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
      "OPENAI_AUTH_TOKEN=dummy GENE_AGENT_STATE=" & shellQuote(stateDir) & " " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene")
    check restored.exitCode == 0
    check restored.output.count("check command status=") == 3

  test "ai agent compacts context without splitting tool pairs and persists it":
    buildGeneCli()
    let stateDir = cliDir / "agent-context-state"
    if dirExists(stateDir): removeDir(stateDir)
    let tui = "./tui.gene"
    let writer = "examples/ai_agent/context_compact_writer_test.gene"
    let reader = "examples/ai_agent/context_compact_reader_test.gene"
    defer:
      for path in [writer, reader]:
        if fileExists(path): removeFile(path)
    writeFile(writer, """
(import [compact_context init_agent_state save_agent_state emit_event!]
        from "TUI_PATH")
(var items
  [{^role "system" ^content "instructions + remembered decision: keep API v2"}
   {^role "user" ^content "old-intent"}
   {^type "function_call" ^name "read_file" ^call_id "old-call" ^arguments "{}"}
   {^type "function_call_output" ^call_id "old-call" ^output "old-out"}
   {^type "message" ^role "assistant"
    ^content [{^type "output_text" ^text "old-answer"}]}
   {^role "user" ^content "recent-intent"}
   {^type "function_call" ^name "read_file" ^call_id "new-call" ^arguments "{}"}
   {^type "function_call_output" ^call_id "new-call" ^output "new-out"}
   {^type "message" ^role "assistant"
    ^content [{^type "output_text" ^text "recent-answer"}]}])
(init_agent_state)
(var compacted (compact_context items emit_event!))
(save_agent_state compacted "saved" ["keep API v2"])
(println "wrote")
""".replace("TUI_PATH", tui))
    writeFile(reader, """
(import [init_agent_state load_session restore_events agent_events context_stats
         config_snapshot]
        from "TUI_PATH")
(import json [stringify])
(init_agent_state)
(var saved (load_session))
(restore_events)
(println (stringify {^items saved/items
                     ^events (agent_events ~ Cell/get)
                     ^config (config_snapshot)
                     ^stats (context_stats saved/items ["keep API v2"])}))
""".replace("TUI_PATH", tui))
    let contextEnv = "GENE_AGENT_STATE=" & shellQuote(stateDir) &
      " GENE_AGENT_CONTEXT_MAX_BYTES=1 GENE_AGENT_CONTEXT_MAX_ITEMS=3 " &
      "GENE_AGENT_CONTEXT_KEEP_TURNS=1 "
    let wrote = execCmdOnce(contextEnv & shellQuote(geneExe) & " run " &
                            shellQuote(writer))
    if wrote.exitCode != 0:
      checkpoint wrote.output
    check wrote.exitCode == 0
    let restoredContext = execCmdOnce(
      "GENE_AGENT_STATE=" & shellQuote(stateDir) & " " &
      shellQuote(geneExe) & " run " & shellQuote(reader))
    if restoredContext.exitCode != 0:
      checkpoint restoredContext.output
    check restoredContext.exitCode == 0
    check "instructions + remembered decision: keep API v2" in restoredContext.output
    check "recent-intent" in restoredContext.output
    check "new-call" in restoredContext.output
    check "new-out" in restoredContext.output
    check "old-intent" notin restoredContext.output
    check "old-call" notin restoredContext.output
    check "old-out" notin restoredContext.output
    check "\"type\":\"context_compacted\"" in restoredContext.output
    check "\"removed_turns\":1" in restoredContext.output
    check "\"retained_turns\":1" in restoredContext.output
    check "\"bytes\":" in restoredContext.output
    check "\"context_max_bytes\":750000" in restoredContext.output
    check "\"context_max_items\":200" in restoredContext.output
    check "\"context_keep_turns\":8" in restoredContext.output
    let status = execCmdOnce(
      "printf '/status\n/repl\n/1 session/config\n/1 close\n/quit\n' | " &
      "env OPENAI_AUTH_TOKEN=dummy " &
      "GENE_AGENT_STATE=" & shellQuote(stateDir) & " " &
      "GENE_AGENT_CONTEXT_MAX_BYTES=1234 GENE_AGENT_CONTEXT_MAX_ITEMS=12 " &
      "GENE_AGENT_CONTEXT_KEEP_TURNS=2 " & shellQuote(geneExe) &
      " run examples/ai_agent/tui.gene")
    check status.exitCode == 0
    check "context:" in status.output
    check "tool rounds: max 12" in status.output
    check "context limits: 1234 bytes, 12 items, keep 2 turns" in status.output
    check "memory: 1 items" in status.output
    check "^context {^bytes" in status.output
    check "^context_max_bytes 1234" in status.output

  test "ai agent improvement tools return structural, bounded guidance":
    buildGeneCli()
    let fixture = "examples/ai_agent/improvements_test.gene"
    let target = "tmp/agent-improvements-target.gene"
    let largeTarget = "tmp/agent-improvements-large.txt"
    defer:
      if fileExists(fixture): removeFile(fixture)
      if fileExists(target): removeFile(target)
      if fileExists(largeTarget): removeFile(largeTarget)
    writeFile(fixture, """
(import [find_tool compact_context run_turn_ready config_snapshot append
         edit_mismatch_hint]
        from "./tui.gene")
(import json [stringify])
(import str [contains? split])

(fn sink [type, props] nil)

(var write_tool (find_tool "write_file"))
(var write_handler write_tool/handler)
(var wrote
  (write_handler {^path "tmp/agent-improvements-target.gene"
                  ^content "(fn broken []\n  [1 2)\n"
                  ^_emit sink}))
(var read_tool (find_tool "read_file"))
(var read_handler read_tool/handler)
(var ranged
  (read_handler {^path "tmp/agent-improvements-target.gene"
                 ^start_line 2 ^max_lines 1 ^_emit sink}))

(var edit_tool (find_tool "edit_file"))
(var edit_handler edit_tool/handler)
(var mismatch
  (edit_handler {^path "tmp/agent-improvements-target.gene"
                 ^old_text "(fn broken []\n  [9 9)"
                 ^new_text "unused"
                 ^_emit sink}))
(var edited_warning
  (edit_handler {^path "tmp/agent-improvements-target.gene"
                 ^old_text "(fn broken []\n  [1 2)\n"
                 ^new_text "(fn broken []\n  [1 2]\n"
                 ^_emit sink}))
(var candidates
  (edit_mismatch_hint "anchor\nLONG_CONTEXT\nanchor\nanchor\nanchor\n"
                      "anchor\nmissing"))

(var large_wrote
  (write_handler {^path "tmp/agent-improvements-large.txt"
                  ^content "LARGE_LINE"
                  ^_emit sink}))
(var byte_range_1
  (read_handler {^path "tmp/agent-improvements-large.txt"
                 ^start_line 1 ^max_lines 1 ^start_byte 0 ^max_bytes 128
                 ^_emit sink}))
(var byte_range_2
  (read_handler {^path "tmp/agent-improvements-large.txt"
                 ^start_line 1 ^max_lines 1 ^start_byte 128 ^max_bytes 128
                 ^_emit sink}))

(var shell_tool (find_tool "run_shell"))
(var shell_handler shell_tool/handler)
(var timeout_range
  (shell_handler {^command "true" ^timeout_ms 120001 ^_emit sink}))
(var timeout
  (shell_handler {^command "sleep 1" ^timeout_ms 10 ^_emit sink}))
(var completed
  (shell_handler {^command "true" ^timeout_ms 1000 ^_emit sink}))

(var list_tool (find_tool "list_dir"))
(var list_handler list_tool/handler)
(var unsafe
  (try
    (list_handler {^path "../outside" ^_emit sink})
  catch {^message message} message))

(var compact_events (cell []))
(fn compact_emit [type, props]
  (compact_events ~ Cell/set
    (append (compact_events ~ Cell/get) {^type type ^props props})))
(var compacted
  (compact_context
    [{^role "user" ^content "inspect"}
     {^type "function_call" ^name "read_file" ^call_id "large-call"
      ^arguments "{}"}
     {^type "function_call_output" ^call_id "large-call"
      ^output "LARGE_OUTPUT"}]
    compact_emit))
(var irreducible_events (cell []))
(fn irreducible_emit [type, props]
  (irreducible_events ~ Cell/set
    (append (irreducible_events ~ Cell/get) {^type type ^props props})))
(var irreducible
  (compact_context [{^role "user" ^content "LARGE_USER"}]
                   irreducible_emit))
(var irreducible_again
  (compact_context irreducible irreducible_emit))

(var seen_body (cell ""))
(fn transport [body, render]
  (seen_body ~ Cell/set body)
  {^output [] ^output_text "done"})
(var retained
  (run_turn_ready transport [{^role "user" ^content "finish"}]
                  (fn [text] nil) (fn [text] nil) 2 sink))

(var round_calls (cell 0))
(var round_first_body (cell ""))
(fn round_transport [body, render]
  (round_calls ~ Cell/set (+ (round_calls ~ Cell/get) 1))
  (if (== (round_calls ~ Cell/get) 1)
    (do
      (round_first_body ~ Cell/set body)
      {^output
        [{^type "function_call" ^name "missing_one" ^call_id "round-1"
          ^arguments "{}"}
         {^type "function_call" ^name "missing_two" ^call_id "round-2"
          ^arguments "{}"}]})
    {^output [] ^output_text "landed"}))
(var parallel_round
  (run_turn_ready round_transport [{^role "user" ^content "parallel"}]
                  (fn [text] nil) (fn [text] nil) 1 sink))

(println (stringify
  {^wrote wrote
   ^ranged ranged
   ^mismatch mismatch
   ^edited_warning edited_warning
   ^candidate_count (- ((split candidates "candidate near line") ~ size) 1)
   ^candidate_elided (contains? candidates "[line omitted:")
   ^large_wrote large_wrote
   ^byte_range_1 byte_range_1
   ^byte_range_2 byte_range_2
   ^timeout_range timeout_range
   ^timeout timeout/text
   ^completed completed/text
   ^unsafe unsafe
   ^compacted compacted
   ^compact_events (compact_events ~ Cell/get)
   ^irreducible irreducible
   ^irreducible_again irreducible_again
   ^irreducible_events (irreducible_events ~ Cell/get)
   ^budget_body (seen_body ~ Cell/get)
   ^retained retained
   ^round_calls (round_calls ~ Cell/get)
   ^round_first_body (round_first_body ~ Cell/get)
   ^parallel_round parallel_round
   ^config (config_snapshot)}))
""".replace("LARGE_OUTPUT", repeat('x', 4000)).replace(
      "LARGE_USER", repeat('u', 2000)).replace(
      "LONG_CONTEXT", repeat('z', 1200)).replace(
      "LARGE_LINE", repeat('q', 2000)))
    let ran = execCmdOnce(
      "GENE_AGENT_CONTEXT_MAX_BYTES=500 " &
      "GENE_AGENT_CONTEXT_KEEP_TURNS=8 " &
      "GENE_AGENT_MAX_TOOL_ROUNDS=17 " &
      shellQuote(geneExe) & " run " & shellQuote(fixture))
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "warning: file does not parse at" in ran.output
    check "while reading '[' opened at" in ran.output
    check "[lines 2-2 of 3; request start_line/max_lines" in ran.output
    check "candidate near line 1" in ran.output
    check "\"edited_warning\":\"edited tmp/agent-improvements-target.gene" in
      ran.output
    check "\"candidate_count\":3" in ran.output
    check "\"candidate_elided\":true" in ran.output
    check "\"byte_range_1\":\"[bytes 0-128 of 2000" in ran.output
    check "\"byte_range_2\":\"[bytes 128-256 of 2000" in ran.output
    check "timeout_ms must be between 1 and 120000" in ran.output
    check "timed out after" in ran.output
    check "requested cap 10 ms" in ran.output
    check "timeout_ms=1000 timed_out=false" in ran.output
    check "unsafe path rejected (escapes workspace): ../outside" in ran.output
    check "../outside/AGENTS.md" notin ran.output
    check "tool output omitted during context compaction" in ran.output
    check "\"call_id\":\"large-call\"" in ran.output
    check "\"elided_tool_outputs\":1" in ran.output
    check "\"removed_items\":0" in ran.output
    check "\"removed_items\":-" notin ran.output
    check "\"irreducible_over_limit\":true" in ran.output
    check ran.output.count("\"type\":\"context_limit_warning\"") == 1
    check "\"irreducible_events\":[{\"type\":\"context_limit_warning\"" in
      ran.output
    check "Two executable tool rounds remain" in ran.output
    check ran.output.count("Two executable tool rounds remain") == 1
    check "\"round_calls\":2" in ran.output
    check "One executable tool round remains" in ran.output
    check ran.output.count("One executable tool round remains") == 1
    check "\"call_id\":\"round-1\"" in ran.output
    check "\"call_id\":\"round-2\"" in ran.output
    check "\"max_tool_rounds\":17" in ran.output

  test "ai agent loads hierarchical AGENTS instructions safely":
    buildGeneCli()
    let workspace = cliDir / "agents-workspace"
    let outside = cliDir / "agents-outside"
    for dir in [workspace, outside]:
      if dirExists(dir): removeDir(dir)
      createDir(dir)
    createDir(workspace / "sub")
    createDir(workspace / "sibling")
    createDir(workspace / "huge")
    writeFile(workspace / "AGENTS.md", "ROOT_INSTRUCTION\n")
    writeFile(workspace / "sub" / "AGENTS.md", "CHILD_INSTRUCTION\n")
    writeFile(workspace / "sibling" / "AGENTS.md", "SIBLING_INSTRUCTION\n")
    writeFile(workspace / "huge" / "AGENTS.md",
              "HUGE_INSTRUCTION\n" & repeat('x', 33000))
    writeFile(workspace / "huge" / "target.txt", "huge-content\n")
    var deep = workspace
    for i in 1..9:
      deep = deep / ("d" & $i)
      createDir(deep)
      if i == 8: writeFile(deep / "AGENTS.md", "DEPTH8_INSTRUCTION\n")
      if i == 9: writeFile(deep / "AGENTS.md", "DEPTH9_INSTRUCTION\n")
    writeFile(deep / "target.txt", "deep-content\n")
    writeFile(outside / "AGENTS.md", "OUTSIDE_INSTRUCTION\n")
    writeFile(outside / "secret.txt", "outside-secret\n")
    createSymlink(outside, workspace / "escape")
    for i in 1..6: removeFile("tmp/agents-req-" & $i & ".json")

    let fixture = writeCliProgram("agents_endpoint.gene", """
(import net/http [Server serve Response])
(import Fs [write_text WriteDir])
(import json [stringify])
(import str [join])
(import std/stream [to_stream map into])
(var hits (cell 0))
(fn sse_body [chunks]
  (var lines ((to_stream chunks)
    ~ map (fn [c] $"data: ${(stringify c)}") ; ~ into []))
  (var joined (join lines "\n\n"))
  $"${joined}\n\ndata: [DONE]\n\n")
(fn tool_turn [id : Str, name : Str, arguments : Str]
  [{^choices [{^index 0 ^delta {^role "assistant" ^tool_calls
      [{^index 0 ^id id ^type "function"
        ^function {^name name ^arguments arguments}}]}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "tool_calls"}]}])
(var final_turn
  [{^choices [{^index 0 ^delta {^content "instructions verified"}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "stop"}]}])
(fn handle [req]
  (hits ~ Cell/set (+ (hits ~ Cell/get) 1))
  (var n (hits ~ Cell/get))
  (write_text WriteDir $"tmp/agents-req-${n}.json" req/body)
  (var chunks
    (match n
      (when 1 (tool_turn "a1" "write_file"
        "{\"path\":\"sub/target.txt\",\"content\":\"created\\n\"}"))
      (when 2 (tool_turn "a2" "write_file"
        "{\"path\":\"sub/target.txt\",\"content\":\"created\\n\"}"))
      (when 3 (tool_turn "a3" "read_file"
        "{\"path\":\"huge/target.txt\"}"))
      (when 4 (tool_turn "a4" "read_file"
        "{\"path\":\"d1/d2/d3/d4/d5/d6/d7/d8/d9/target.txt\"}"))
      (when 5 (tool_turn "a5" "read_file"
        "{\"path\":\"escape/secret.txt\"}"))
      (else final_turn)))
  (Response ^status 200 ^headers {^content-type "text/event-stream"}
            ^body (sse_body chunks)))
(serve (Server ^host "127.0.0.1" ^port 8964) handle ^max_requests 6)
""")
    let server = startProcess(geneExe, args = ["run", fixture],
                              options = {poUsePath, poStdErrToStdOut})
    defer:
      if server.running: server.terminate()
      server.close()
    block waitForServer:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(8964), timeout = 500)
          s.close()
          break waitForServer
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline: raise
          sleep(50)
    let tui = normalizedPath(absolutePath("examples/ai_agent/tui.gene"))
    let command = "cd " & shellQuote(workspace) &
      " && printf 'go\n/status\n/repl\n/1 (session/instructions ~ Cell/get)\n" &
      "/1 close\n/quit\n' | env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
      "OPENAI_AUTH_TOKEN=dummy OPENAI_API=chat " &
      "OPENAI_BASE_URL=http://127.0.0.1:8964/v1 OPENAI_MODEL=fake-chat " &
      shellQuote(geneExe) & " run " & shellQuote(tui)
    let ran = execCmdOnce(command)
    if ran.exitCode != 0 or not fileExists(workspace / "sub" / "target.txt"):
      checkpoint ran.output
    check ran.exitCode == 0
    check fileExists(workspace / "sub" / "target.txt")
    if fileExists(workspace / "sub" / "target.txt"):
      check readFile(workspace / "sub" / "target.txt") == "created\n"
    let req1 = readFile("tmp/agents-req-1.json")
    let req2 = readFile("tmp/agents-req-2.json")
    let req3 = readFile("tmp/agents-req-3.json")
    let req4 = readFile("tmp/agents-req-4.json")
    let req5 = readFile("tmp/agents-req-5.json")
    let req6 = readFile("tmp/agents-req-6.json")
    check "ROOT_INSTRUCTION" in req1
    check "CHILD_INSTRUCTION" notin req1
    check req2.find("ROOT_INSTRUCTION") < req2.find("CHILD_INSTRUCTION")
    check "SIBLING_INSTRUCTION" notin req2
    check "write deferred" in req2
    check "wrote sub/target.txt" in req3
    check "HUGE_INSTRUCTION" notin req4
    check "huge-content" in req4
    check "DEPTH8_INSTRUCTION" in req5
    check "DEPTH9_INSTRUCTION" notin req5
    check "OUTSIDE_INSTRUCTION" notin req6
    check "unsafe path rejected" in req6
    check "instructions: 3" in ran.output
    check "AGENTS.md" in ran.output
    check "sub/AGENTS.md" in ran.output

  test "ai agent repl add_tool plus resume exposes the new tool to the model":
    ## Slice A signature demo (§9.1/§10.2): a typed tool registered live in
    ## /repl reaches the model on the resumed turn. The fake endpoint answers
    ## the first turn as plain text, then on the resume turn reports whether a
    ## tool named `ping` — added only from /repl — is present in the wire tools.
    buildGeneCli()
    let fixture = writeCliProgram("fake_resume_endpoint.gene", """
(import net/http [Server serve Response])
(import json [parse stringify])
(import str [join])
(import std/stream [to_stream map filter into])

(var hits (cell 0))

(fn sse-body [chunks]
  (var lines
    ((to_stream chunks)
      ~ map (fn [c] $"data: ${(stringify c)}")
      ; ~ into []))
  (var sep "\n\n")
  (var joined (join lines sep))
  $"${joined}${sep}data: [DONE]${sep}")

(fn plain [text]
  [{^choices [{^index 0 ^delta {^content text}}]}
   {^choices [{^index 0 ^delta {} ^finish_reason "stop"}]}])

(fn has-ping [body]
  (var req (parse body))
  (var hit
    ((to_stream req/tools)
      ~ filter (fn [t] (== t/function/name "ping"))
      ; ~ into []))
  (> hit/~size 0))

(fn handle [req]
  (Cell/set hits (+ (Cell/get hits) 1))
  (var chunks
    (if (== (Cell/get hits) 1)
      (plain "started")
      (plain (if (has-ping req/body) "verdict: ping-visible" "verdict: ping-missing"))))
  (Response ^status 200
            ^headers {^content-type "text/event-stream"}
            ^body (sse-body chunks)))

(serve (Server ^host "127.0.0.1" ^port 8992) handle ^max_requests 2)
""")
    let server = startProcess(geneExe, args = ["run", fixture],
                              options = {poUsePath, poStdErrToStdOut})
    defer:
      if server.running:
        server.terminate()
      server.close()
    block waitForServer:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(8992), timeout = 500)
          s.close()
          break waitForServer
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline:
            raise
          sleep(50)
    let script = "printf 'go\\n/repl\\n" &
      "/1 (session ~ add_tool (Tool ^name \"ping\" ^description \"demo\" " &
      "^risk \"read\" ^params [] ^handler (fn [a] \"pong\")))\\n" &
      "/1 (session ~ resume)\\n/1 close\\n/quit\\n' | " &
      "env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY -u OPENAI_API " &
      "OPENAI_AUTH_TOKEN=dummy " &
      "OPENAI_BASE_URL=http://127.0.0.1:8992/v1 OPENAI_MODEL=fake-chat " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(script)
    check ran.exitCode == 0
    check "verdict: ping-visible" in ran.output

  test "ai agent SIGINT cancels a model turn and accepts a continuation":
    when defined(posix):
      buildGeneCli()
      let commandStarted = "tmp/interrupt-command-started"
      removeFile(commandStarted)
      let endpoint = writeCliProgram("interrupt_chat_endpoint.gene", """
(import net/http [Server serve Response])
(var hits (cell 0))
(fn handle [req]
  (hits ~ Cell/set (+ (hits ~ Cell/get) 1))
  (var n (hits ~ Cell/get))
  (var body
    (if (== n 1)
      "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"tool_calls\":[{\"index\":0,\"id\":\"call_cancel_1\",\"type\":\"function\",\"function\":{\"name\":\"run_shell\",\"arguments\":\"{\\\"command\\\":\\\"touch tmp/interrupt-command-started; sleep 5\\\"}\"}}]}}]}\n\ndata: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n"
      "data: {\"choices\":[{\"delta\":{\"content\":\"steered\"}}]}\n\ndata: [DONE]\n\n"))
  (Response ^status 200 ^headers {^content-type "text/event-stream"} ^body body))
(serve (Server ^host "127.0.0.1" ^port 8968) handle ^max_requests 2)
""")
      let endpointProc = startProcess(geneExe, args = ["run", endpoint],
                                      options = {poUsePath, poStdErrToStdOut})
      defer:
        if endpointProc.running:
          endpointProc.terminate()
        endpointProc.close()
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(8968), timeout = 500)
          s.close()
          break
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline:
            raise
          sleep(50)

      let stateDir = cliDir / "interrupt-state"
      if dirExists(stateDir): removeDir(stateDir)
      let agentArgs = ["-u", "CODEX_ACCESS_TOKEN", "-u", "OPENAI_API_KEY",
                       "OPENAI_AUTH_TOKEN=dummy",
                       "OPENAI_BASE_URL=http://127.0.0.1:8968/v1",
                       "OPENAI_API=chat", "OPENAI_MODEL=fake-chat",
                       "GENE_AGENT_STATE=" & stateDir,
                       geneExe, "run", "examples/ai_agent/tui.gene"]
      let pidFile = cliDir / "interrupt_agent.pid"
      let outputFile = cliDir / "interrupt_agent.out"
      removeFile(pidFile)
      removeFile(outputFile)
      let agentProc =
        when defined(macosx):
          var inner = "echo $$ > " & shellQuote(pidFile) & "; exec /usr/bin/env"
          for arg in agentArgs: inner.add " " & shellQuote(arg)
          let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                        shellQuote(inner) & " > " & shellQuote(outputFile) &
                        " 2>&1"
          startProcess("/bin/sh", args = ["-c", command],
                       options = {poUsePath, poStdErrToStdOut})
        else:
          startProcess("/usr/bin/env", args = agentArgs,
                       options = {poUsePath, poStdErrToStdOut})
      defer:
        if agentProc.running: agentProc.terminate()
        agentProc.close()
      let inputStream = agentProc.inputStream
      inputStream.write("wait\n")
      inputStream.flush()
      let hitDeadline = getMonoTime() + initDuration(seconds = 5)
      while not fileExists(commandStarted) and getMonoTime() < hitDeadline: sleep(10)
      check fileExists(commandStarted)
      let interruptedAt = getMonoTime()
      when defined(macosx):
        let pidDeadline = getMonoTime() + initDuration(seconds = 3)
        while not fileExists(pidFile) and getMonoTime() < pidDeadline: sleep(10)
        check fileExists(pidFile)
        check kill(Pid(parseInt(readFile(pidFile).strip())), SIGINT) == 0
      else:
        check kill(Pid(agentProc.processID), SIGINT) == 0
      let eventsFile = stateDir / "events.gene"
      let cancelDeadline = getMonoTime() + initDuration(seconds = 2)
      var cancellationPersisted = false
      while getMonoTime() < cancelDeadline and not cancellationPersisted:
        if fileExists(eventsFile):
          cancellationPersisted = "cancelled" in readFile(eventsFile)
        if not cancellationPersisted: sleep(10)
      check cancellationPersisted
      check (getMonoTime() - interruptedAt).inMilliseconds < 2000
      inputStream.write("steer now\n/trace tool=run_shell\n/trace type=check\n/trace type=turn_done\n/quit\n")
      inputStream.flush()
      inputStream.close()
      let exitCode = agentProc.waitForExit(8000)
      let output =
        when defined(macosx): readFile(outputFile)
        else: agentProc.outputStream.readAll()
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "turn cancelled; enter steering to continue" in output
      # A curses capture is a stream of differential screen updates, not a
      # linear transcript: the prefix may have been painted by an earlier
      # frame. The trace row is a stable assertion that the continuation text
      # reached the presented turn.
      check "turn_done steered" in output
      check "tool_call run_shell" in output
      check "check command status=nil" in output
      let events = readFile(eventsFile)
      check "^type \"check\"" in events
      check "^cancelled true" in events
      check events.count("^kind \"cancelled\"") == 1

  test "gene view rejects non-TTY use before changing terminal mode":
    buildGeneCli()
    let fixture = writeCliProgram("view_non_tty.gene", "(server ^port 8080)\n")
    let ran = execCmdOnce(shellQuote(geneExe) & " view --readonly " &
                          shellQuote(fixture))
    check ran.exitCode == 1
    check "interactive terminal required" in ran.output

  test "gene view navigates in a pseudo-terminal and restores it":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("view_tui.gene",
        "(server ^host \"127.0.0.1\" ^port 8080 ^routes [[GET] [POST]])\n")
      let outputFile = cliDir / "view_tui.out"
      removeFile(outputFile)
      let inner = "exec /usr/bin/env TERM=xterm-256color " &
                  shellQuote(geneExe) & " view --readonly " & shellQuote(fixture)
      let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                    shellQuote(inner) & " > " & shellQuote(outputFile) & " 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      sleep(250)
      terminal.inputStream.write("jjjl\e[Bq")
      terminal.inputStream.flush()
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(5000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "Path: routes" in output
      check "GET" in output
      check "POST" in output

  test "gene view suspends and resumes around an external editor":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("view_editor.gene", "(server ^port 8080)\n")
      let outputFile = cliDir / "view_editor.out"
      removeFile(outputFile)
      let inner = "exec /usr/bin/env TERM=xterm-256color " &
                  shellQuote(geneExe) & " view --editor /usr/bin/true " &
                  shellQuote(fixture)
      let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                    shellQuote(inner) & " > " & shellQuote(outputFile) & " 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      sleep(250)
      terminal.inputStream.write("e")
      terminal.inputStream.flush()
      sleep(250)
      terminal.inputStream.write("q")
      terminal.inputStream.flush()
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(5000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "reloaded" in output
      check "\e[?1049l" in output

  test "public curses events are cancellable, Unicode-safe, and resize-aware":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("curses_events.gene", """
(import curses [open close dimensions next_event])
(import json [stringify])
(var screen (open))
(try
  (do
    (var dims (dimensions screen))
    (var abandoned (next_event screen))
    (abandoned ~ Task/cancel)
    (sleep 50)
    (var text_event (await (next_event screen)))
    (var resize_event (await (next_event screen)))
    (close screen)
    (println $"CURSES-EVENTS:${(stringify {^dims dims
                                           ^text text_event
                                           ^resize resize_event})}"))
  ensure
    (close screen))
""")
      let pidFile = cliDir / "curses_events.pid"
      let outputFile = cliDir / "curses_events.out"
      removeFile(pidFile)
      removeFile(outputFile)
      let inner = "echo $$ > " & shellQuote(pidFile) &
                  "; exec /usr/bin/env TERM=xterm-256color " &
                  shellQuote(geneExe) & " run " & shellQuote(fixture)
      let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                    shellQuote(inner) & " > " & shellQuote(outputFile) &
                    " 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      let pidDeadline = getMonoTime() + initDuration(seconds = 3)
      while not fileExists(pidFile) and getMonoTime() < pidDeadline: sleep(10)
      check fileExists(pidFile)
      sleep(200)
      terminal.inputStream.write("é")
      terminal.inputStream.flush()
      sleep(200)
      check kill(Pid(parseInt(readFile(pidFile).strip())), SigWinch) == 0
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(5000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "CURSES-EVENTS:" in output
      check "\"type\":\"text\"" in output
      check "\"text\":\"é\"" in output
      check "\"type\":\"resize\"" in output
      check "\"rows\":" in output
      check "\"cols\":" in output
      check "\e[?1049l" in output

  test "public curses events decode editor control sequences":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("curses_control_events.gene", """
(import curses [open close next_event])
(import json [stringify])
(var screen (open))
(try
  (do
    (var paste_start (await (next_event screen)))
    (var text_event (await (next_event screen)))
    (var pasted_enter (await (next_event screen)))
    (var paste_end (await (next_event screen)))
    (var newline (await (next_event screen)))
    (var page_up (await (next_event screen)))
    (var escape (await (next_event screen)))
    (var queued_text (await (next_event screen)))
    (close screen)
    (println $"CURSES-CONTROLS:${(stringify [paste_start text_event
                                             pasted_enter paste_end newline
                                             page_up escape queued_text])}"))
  ensure
    (close screen))
""")
      let outputFile = cliDir / "curses_control_events.out"
      removeFile(outputFile)
      let inner = "exec /usr/bin/env TERM=xterm-256color " &
                  shellQuote(geneExe) & " run " & shellQuote(fixture)
      let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                    shellQuote(inner) & " > " & shellQuote(outputFile) &
                    " 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      sleep(300)
      terminal.inputStream.write("\e[200~x\n\e[201~\e[13;2u\e[5~")
      terminal.inputStream.flush()
      sleep(100)
      # A printable byte already queued behind standalone Escape must be
      # pushed back rather than consumed as an unsupported Alt sequence.
      terminal.inputStream.write("\ep")
      terminal.inputStream.flush()
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(5000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "CURSES-CONTROLS:" in output
      check "\"type\":\"paste_start\"" in output
      check "\"text\":\"x\"" in output
      check "\"type\":\"enter\"" in output
      check "\"type\":\"paste_end\"" in output
      check "\"type\":\"newline\"" in output
      check "\"type\":\"page_up\"" in output
      check "\"type\":\"escape\"" in output
      check "\"text\":\"p\"" in output

  test "public curses ownership suppresses only diagnostic console output":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("curses_log_suppression.gene", """
(import curses [open close draw])
(import log [new_logger warn!])
(var logger (new_logger "app/curses_test"))
(var screen (open))
(try
  (do
    (draw screen ^output "screen active" ^output_scroll 0)
    (warn! logger "hidden while screen owns terminal")
    (close screen)
    (println "CURSES-LOG-SUPPRESSION:ok"))
  ensure
    (close screen))
""")
      let outputFile = cliDir / "curses_log_suppression.out"
      removeFile(outputFile)
      let inner = "exec /usr/bin/env TERM=xterm-256color " &
                  shellQuote(geneExe) & " run " & shellQuote(fixture)
      let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                    shellQuote(inner) & " > " & shellQuote(outputFile) &
                    " 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(5000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "CURSES-LOG-SUPPRESSION:ok" in output
      check "hidden while screen owns terminal" notin output
      check "\e[?1049l" in output

  test "public curses editor handles resize and bracketed Unicode paste":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("curses_paste.gene", """
(import curses [open close read_input])
(var screen (open))
(try
  (do
    (var input (read_input screen ^prompt "" ^multiline true))
    (close screen)
    (println $"CURSES-PASTE:${input}"))
  ensure
    (close screen))
""")
      let pidFile = cliDir / "curses_paste.pid"
      let outputFile = cliDir / "curses_paste.out"
      removeFile(pidFile)
      removeFile(outputFile)
      let inner = "echo $$ > " & shellQuote(pidFile) &
                  "; exec /usr/bin/env TERM=xterm-256color " &
                  shellQuote(geneExe) & " run " & shellQuote(fixture)
      let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                    shellQuote(inner) & " > " & shellQuote(outputFile) &
                    " 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      let pidDeadline = getMonoTime() + initDuration(seconds = 3)
      while not fileExists(pidFile) and getMonoTime() < pidDeadline: sleep(10)
      check fileExists(pidFile)
      sleep(200)
      check kill(Pid(parseInt(readFile(pidFile).strip())), SigWinch) == 0
      sleep(100)
      terminal.inputStream.write("\e[200~hello\né\e[201~\n")
      terminal.inputStream.flush()
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(5000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "CURSES-PASTE:hello\né" in output.replace("\r\n", "\n")
      check "\e[?1049l" in output

  test "public curses editor browses submitted input history":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("curses_history.gene", """
(import curses [open close read_input])
(var screen (open))
(try
  (do
    (var input
      (read_input screen ^prompt "" ^multiline true
                  ^history ["first command" "second command"]))
    (close screen)
    (println $"CURSES-HISTORY:${input}"))
  ensure
    (close screen))
""")
      let outputFile = cliDir / "curses_history.out"
      removeFile(outputFile)
      let inner = "exec /usr/bin/env TERM=xterm-256color " &
                  shellQuote(geneExe) & " run " & shellQuote(fixture)
      let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                    shellQuote(inner) & " > " & shellQuote(outputFile) &
                    " 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      sleep(300)
      # Type once, then browse newest -> oldest -> newest and submit. Each
      # event redraws the editor, but only initial ncurses setup may clear the
      # physical screen.
      terminal.inputStream.write("x\e[A\e[A\e[B\n")
      terminal.inputStream.flush()
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(5000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "CURSES-HISTORY:second command" in output
      check "[SCROLL +" notin output
      check output.count("\e[H\e[2J") <= 1
      check "\e[?1049l" in output

  test "public curses editor renders extension panes beside the transcript":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("curses_panes.gene", """
(import curses [open close read_input])
(var screen (open))
(try
  (do
    (var input
      (read_input screen ^prompt "" ^multiline true
        ^output "MAIN-TRANSCRIPT"
        ^panes [{^title "ext 1" ^output "EXTENSION-ONE\nready"}
                {^title "ext 2" ^output "EXTENSION-TWO\ndone"}]))
    (close screen)
    (println $"CURSES-PANES:${input}"))
  ensure
    (close screen))
""")
      let outputFile = cliDir / "curses_panes.out"
      removeFile(outputFile)
      let inner = "stty rows 18 cols 80; exec /usr/bin/env TERM=xterm-256color " &
                  shellQuote(geneExe) & " run " & shellQuote(fixture)
      let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                    shellQuote(inner) & " > " & shellQuote(outputFile) &
                    " 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      sleep(300)
      terminal.inputStream.write("pane input\n")
      terminal.inputStream.flush()
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(5000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "MAIN-TRANSCRIPT" in output
      check "ext 1" in output
      check "EXTENSION-ONE" in output
      check "ext 2" in output
      check "EXTENSION-TWO" in output
      check "CURSES-PANES:pane input" in output
      check "\e[?1049l" in output

  test "public curses editor renders scrolled extension panes":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("curses_pane_scroll.gene", """
(import curses [open close read_input])
(var screen (open))
(try
  (do
    (var input
      (read_input screen ^prompt "" ^multiline true
        ^output "MAIN-TRANSCRIPT"
        ^panes [{^title "ext"
                 ^output "PANE-SCROLL-TOP\nline-01\nline-02\nline-03\nline-04\nline-05\nline-06\nline-07\nline-08\nline-09\nline-10\nline-11\nline-12\nline-13\nline-14\nline-15\nline-16\nline-17\nline-18\nline-19\nline-20\nline-21\nline-22\nline-23\nline-24\nline-25\nline-26\nline-27\nline-28\nPANE-SCROLL-BOTTOM"
                 ^scroll 20}]))
    (close screen)
    (println $"CURSES-PANE-SCROLL:${input}"))
  ensure
    (close screen))
""")
      let outputFile = cliDir / "curses_pane_scroll.out"
      removeFile(outputFile)
      let inner = "stty rows 18 cols 80; exec /usr/bin/env TERM=xterm-256color " &
                  shellQuote(geneExe) & " run " & shellQuote(fixture)
      let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                    shellQuote(inner) & " > " & shellQuote(outputFile) &
                    " 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      sleep(300)
      terminal.inputStream.write("\n")
      terminal.inputStream.flush()
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(5000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "PANE-SCROLL-TOP" in output
      check "[SCROLL +" in output
      check "CURSES-PANE-SCROLL:" in output
      check "\e[?1049l" in output

  test "public curses renders the focused pane full-width on narrow terminals":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("curses_focused_narrow.gene", """
(import curses [open close read_input])
(var screen (open))
(try
  (do
    (var input
      (read_input screen ^prompt "" ^multiline true
        ^output "MAIN-HIDDEN"
        ^panes [{^title "shell" ^output "FOCUSED-NARROW"
                 ^focused true}]))
    (close screen)
    (println $"CURSES-FOCUSED:${input}"))
  ensure
    (close screen))
""")
      let outputFile = cliDir / "curses_focused_narrow.out"
      removeFile(outputFile)
      let inner = "stty rows 12 cols 40; exec /usr/bin/env TERM=xterm-256color " &
                  shellQuote(geneExe) & " run " & shellQuote(fixture)
      let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                    shellQuote(inner) & " > " & shellQuote(outputFile) &
                    " 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      sleep(300)
      terminal.inputStream.write("\n")
      terminal.inputStream.flush()
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(5000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "FOCUSED-NARROW" in output
      check "CURSES-FOCUSED:" in output
      check "\e[?1049l" in output

  test "curses standalone Escape detection preserves queued typing":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("curses_escape.gene", """
(import curses [open close read_input escape_pressed?])
(var screen (open))
(var found false)
(try
  (do
    (while (! found)
      (sleep 25)
      (set found (escape_pressed? screen)))
    (var input (read_input screen ^prompt "" ^multiline true
                           ^history ["old "]))
    (close screen)
    (println $"CURSES-ESCAPE:${found}:${input}"))
  ensure
    (close screen))
""")
      let outputFile = cliDir / "curses_escape.out"
      removeFile(outputFile)
      let inner = "exec /usr/bin/env TERM=xterm-256color " &
                  shellQuote(geneExe) & " run " & shellQuote(fixture)
      let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                    shellQuote(inner) & " > " & shellQuote(outputFile) &
                    " 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      sleep(300)
      terminal.inputStream.write("\e[Aabc\e")
      terminal.inputStream.flush()
      sleep(300)
      terminal.inputStream.write("\n")
      terminal.inputStream.flush()
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(5000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "CURSES-ESCAPE:true:old abc" in output
      check "\e[?1049l" in output

  test "Escape cancels a tracked active task":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("agent_escape_cancel.gene", """
(import os [begin_interrupt take_interrupt end_interrupt])
(import curses [open close escape_pressed?])
(var screen (open))
(var running (cell true))
(var cancelled (cell false))
(var done (channel ^capacity 1))
(var task
  (spawn
    (try
      (do
        (sleep 5000)
        (println "too late"))
    ensure
      (done ~ Channel/close))))
(var armed (begin_interrupt))
(var watcher
  (spawn
    (while (running ~ Cell/get)
      (sleep 25)
      (if (|| (take_interrupt) (escape_pressed? screen))
        (do
          (cancelled ~ Cell/set true)
          (task ~ Task/cancel))
        nil))))
(try (done ~ Channel/recv) catch (ChannelClosed) nil)
(running ~ Cell/set false)
(watcher ~ Task/cancel)
(if armed (end_interrupt) nil)
(close screen)
(if (cancelled ~ Cell/get)
  (println "turn cancelled; enter steering to continue")
  nil)
(println "AGENT-ESCAPE-DONE")
""")
      let outputFile = cliDir / "agent_escape_cancel.out"
      removeFile(outputFile)
      let inner = "exec /usr/bin/env TERM=xterm-256color " &
                  shellQuote(geneExe) & " run " & shellQuote(fixture)
      let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                    shellQuote(inner) & " > " & shellQuote(outputFile) &
                    " 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      sleep(400)
      let cancelledAt = getMonoTime()
      terminal.inputStream.write("\e")
      terminal.inputStream.flush()
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(3000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check (getMonoTime() - cancelledAt).inMilliseconds < 2000
      check "turn cancelled; enter steering to continue" in output
      check "AGENT-ESCAPE-DONE" in output
      check "too late" notin output
      check "\e[?1049l" in output

  test "public curses editor scrolls transcript with page keys":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("curses_scroll.gene", """
(import curses [open close read_input])
(var screen (open))
(try
  (do
    (var input
      (read_input screen ^prompt "" ^multiline true
        ^output "SCROLL-TOP\nline-01\nline-02\nline-03\nline-04\nline-05\nline-06\nline-07\nline-08\nline-09\nline-10\nline-11\nline-12\nline-13\nline-14\nline-15\nline-16\nline-17\nline-18\nline-19\nline-20\nline-21\nline-22\nline-23\nline-24\nline-25\nline-26\nline-27\nline-28\nSCROLL-BOTTOM"))
    (close screen)
    (println $"CURSES-SCROLL:${input}"))
  ensure
    (close screen))
""")
      let outputFile = cliDir / "curses_scroll.out"
      removeFile(outputFile)
      let inner = "exec /usr/bin/env TERM=xterm-256color " &
                  shellQuote(geneExe) & " run " & shellQuote(fixture)
      let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                    shellQuote(inner) & " > " & shellQuote(outputFile) &
                    " 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      sleep(300)
      terminal.inputStream.write("\e[5~\n")
      terminal.inputStream.flush()
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(5000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "SCROLL-TOP" in output
      check "[SCROLL +" in output
      check "CURSES-SCROLL:" in output
      check "\e[?1049l" in output

  test "public curses editor captures mouse wheel transcript scrolling":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("curses_mouse_scroll.gene", """
(import curses [open close read_input])
(var screen (open))
(try
  (do
    (var input
      (read_input screen ^prompt "" ^multiline true
        ^output "MOUSE-SCROLL-TOP\nline-01\nline-02\nline-03\nline-04\nline-05\nline-06\nline-07\nline-08\nline-09\nline-10\nline-11\nline-12\nline-13\nline-14\nline-15\nline-16\nline-17\nline-18\nline-19\nline-20\nline-21\nline-22\nline-23\nline-24\nline-25\nline-26\nline-27\nline-28\nMOUSE-SCROLL-BOTTOM"))
    (close screen)
    (println $"CURSES-MOUSE-SCROLL:${input}"))
  ensure
    (close screen))
""")
      let outputFile = cliDir / "curses_mouse_scroll.out"
      removeFile(outputFile)
      let inner = "exec /usr/bin/env TERM=xterm-256color " &
                  shellQuote(geneExe) & " run " & shellQuote(fixture)
      let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                    shellQuote(inner) & " > " & shellQuote(outputFile) &
                    " 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      sleep(300)
      # SGR mouse protocol: wheel up/down at column 1, row 1. Scrolling down
      # must return to the live tail even on macOS' ncurses mouse protocol v1.
      terminal.inputStream.write(
        repeat("\e[<64;1;1M", 5) & repeat("\e[<65;1;1M", 5) & "\n")
      terminal.inputStream.flush()
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(5000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "\e[?1000h" in output
      check "\e[?1006h" in output
      check "MOUSE-SCROLL-TOP" in output
      check "[SCROLL +" in output
      check output.rfind("MOUSE-SCROLL-BOTTOM") > output.rfind("[SCROLL +")
      check "CURSES-MOUSE-SCROLL:" in output
      check "\e[?1000l" in output

  test "public curses editor word-wraps transcript visual rows":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("curses_word_wrap.gene", """
(import curses [open close read_input])
(var screen (open))
(try
  (do
    (var input
      (read_input screen ^prompt "" ^multiline true
        ^output "assistant|WRAP-BEGIN alpha beta gamma delta epsilon zeta eta theta WRAP-END"))
    (close screen)
    (println $"CURSES-WRAP:${input}"))
  ensure
    (close screen))
""")
      let outputFile = cliDir / "curses_word_wrap.out"
      removeFile(outputFile)
      let inner = "stty rows 12 cols 32; exec /usr/bin/env TERM=xterm-256color " &
                  shellQuote(geneExe) & " run " & shellQuote(fixture)
      let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                    shellQuote(inner) & " > " & shellQuote(outputFile) &
                    " 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      sleep(300)
      terminal.inputStream.write("\n")
      terminal.inputStream.flush()
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(5000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "WRAP-BEGIN" in output
      check "WRAP-END" in output
      check "CURSES-WRAP:" in output
      check "\e[?1049l" in output

  test "agent gateway runs concurrent sessions over the async transport":
    ## Milestone 8 e2e (examples/ai_agent/design.md §12): a slow fake chat endpoint
    ## (900ms per response) serves two gateway sessions. Both turns must
    ## complete in well under 2x the endpoint latency — proof that model
    ## calls ride dedicated threads and sessions do not block each other.
    ## Also covers bearer auth and the versioned-event long-poll contract.
    buildGeneCli()
    let endpoint = writeCliProgram("slow_chat_endpoint.gene", """
(import net/http [Server serve Response])
(import json [stringify])
(import str [join])
(import std/stream [to_stream map into])

(fn sse-body [chunks]
  (var lines
    ((to_stream chunks)
      ~ map (fn [c] $"data: ${(stringify c)}")
      ; ~ into []))
  (var sep "\n\n")
  (var joined (join lines sep))
  $"${joined}${sep}data: [DONE]${sep}")

(fn handle [req]
  (sleep 900)
  (Response ^status 200
            ^headers {^content-type "text/event-stream"}
            ^body (sse-body
              [{^choices [{^index 0 ^delta {^content "slow "}}]}
               {^choices [{^index 0 ^delta {^content "answer"}}]}
               {^choices [{^index 0 ^delta {} ^finish_reason "stop"}]}])))

(serve (Server ^host "127.0.0.1" ^port 8988) handle ^max_requests 2)
""")
    let endpointProc = startProcess(geneExe, args = ["run", endpoint],
                                    options = {poUsePath, poStdErrToStdOut})
    defer:
      if endpointProc.running:
        endpointProc.terminate()
      endpointProc.close()
    let gatewayProc = startProcess(
      "/usr/bin/env",
      args = ["-u", "CODEX_ACCESS_TOKEN", "-u", "OPENAI_API_KEY",
              "-u", "OPENAI_API",
              "OPENAI_AUTH_TOKEN=dummy",
              "OPENAI_BASE_URL=http://127.0.0.1:8988/v1",
              "OPENAI_MODEL=fake-chat",
              "GENE_GATEWAY_PORT=8989",
              "GENE_GATEWAY_TOKEN=gw-secret",
              geneExe, "run", "examples/ai_agent/gateway.gene"],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if gatewayProc.running:
        gatewayProc.terminate()
      gatewayProc.close()
    for port in [8988, 8989]:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(port), timeout = 500)
          s.close()
          break
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline:
            raise
          sleep(50)

    proc gwCurl(call: string): string =
      let ran = execCmdEx("curl -sS -H 'Authorization: Bearer gw-secret' " &
                          call)
      check ran.exitCode == 0
      ran.output

    # Auth is enforced.
    let denied = execCmdEx(
      "curl -s -o /dev/null -w '%{http_code}' " &
      "-X POST http://127.0.0.1:8989/api/sessions")
    check denied.output.strip() == "401"

    # Two sessions, one message each, posted back to back.
    check "\"id\":\"s1\"" in gwCurl("-X POST http://127.0.0.1:8989/api/sessions")
    check "\"id\":\"s2\"" in gwCurl("-X POST http://127.0.0.1:8989/api/sessions")
    let t0 = getMonoTime()
    check "\"ok\":true" in gwCurl(
      "-X POST -H 'content-type: application/json' -d '{\"text\":\"go\"}' " &
      "http://127.0.0.1:8989/api/sessions/s1/messages")
    let duplicate = execCmdEx(
      "curl -sS -w '\n%{http_code}' " &
      "-H 'Authorization: Bearer gw-secret' " &
      "-H 'content-type: application/json' " &
      "-d '{\"text\":\"must-not-queue\"}' " &
      "http://127.0.0.1:8989/api/sessions/s1/messages")
    check duplicate.exitCode == 0
    check duplicate.output.strip().endsWith("409")
    check "worker_busy" in duplicate.output
    check "turn already in flight" in duplicate.output
    check "\"ok\":true" in gwCurl(
      "-X POST -H 'content-type: application/json' -d '{\"text\":\"go\"}' " &
      "http://127.0.0.1:8989/api/sessions/s2/messages")

    # Long-poll each session until its turn completes.
    proc waitTurnDone(sid: string): string =
      var cursor = 0
      let deadline = getMonoTime() + initDuration(seconds = 15)
      while getMonoTime() < deadline:
        let body = gwCurl("'http://127.0.0.1:8989/api/sessions/" & sid &
                          "/events?cursor=" & $cursor & "'")
        result.add body
        if "turn_done" in result:
          return
        for piece in body.split("\"v\":"):
          let numEnd = piece.find(',')
          if numEnd > 0:
            try:
              cursor = max(cursor, parseInt(piece[0 ..< numEnd]))
            except ValueError:
              discard
      checkpoint "timed out waiting for turn_done: " & result
      check false

    let s1Events = waitTurnDone("s1")
    let s2Events = waitTurnDone("s2")
    let elapsedMs = (getMonoTime() - t0).inMilliseconds

    # Streaming deltas arrived as events for both sessions.
    check "text_delta" in s1Events
    check "slow " in s1Events
    check "answer" in s2Events
    check "changed_worker_ids" in s1Events
    # Concurrency: serial turns would take >= 1800ms against a 900ms
    # endpoint; parallel sessions finish in roughly one latency. The margin
    # is generous (vs. the 1800ms serial floor) because a full `nimble verify`
    # run contends for cores and can stretch the two concurrent turns.
    check elapsedMs < 1750

  test "agent gateway exposes headless worker lifecycle without pane state":
    buildGeneCli()
    let gatewayProc = startProcess(
      "/usr/bin/env",
      args = ["-u", "OPENAI_AUTH_TOKEN", "-u", "CODEX_ACCESS_TOKEN",
              "-u", "OPENAI_API_KEY", "GENE_GATEWAY_PORT=8993",
              "GENE_GATEWAY_TOKEN=gw-workers",
              "GENE_GATEWAY_EVENT_MAX_COUNT=5",
              geneExe, "run", "examples/ai_agent/gateway.gene"],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if gatewayProc.running: gatewayProc.terminate()
      gatewayProc.close()
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while true:
      var s = newSocket()
      try:
        s.connect("127.0.0.1", Port(8993), timeout = 500)
        s.close()
        break
      except OSError, TimeoutError:
        s.close()
        if getMonoTime() > deadline: raise
        sleep(50)

    proc workerCurl(call: string): string =
      let ran = execCmdEx(
        "curl -sS -H 'Authorization: Bearer gw-workers' " & call)
      check ran.exitCode == 0
      ran.output

    check "\"id\":\"s1\"" in workerCurl(
      "-X POST http://127.0.0.1:8993/api/sessions")
    let mainStop = workerCurl(
      "-w '\n%{http_code}' -X DELETE " &
      "http://127.0.0.1:8993/api/sessions/s1/workers/main")
    check "main_worker_cannot_stop" in mainStop
    check mainStop.strip().endsWith("409")
    check "\"ok\":true" in workerCurl(
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"text\":\"main snapshot recovery\"}' " &
      "http://127.0.0.1:8993/api/sessions/s1/messages")
    let mainDeadline = getMonoTime() + initDuration(seconds = 5)
    while "\"busy\":true" in workerCurl(
        "http://127.0.0.1:8993/api/sessions"):
      if getMonoTime() > mainDeadline:
        checkpoint "main gateway turn did not finish"
        break
      sleep(25)
    let mainSnapshotText = workerCurl(
      "http://127.0.0.1:8993/api/sessions/s1/snapshot")
    let mainSnapshot = parseJson(mainSnapshotText)
    check mainSnapshotText.contains("main snapshot recovery")
    check mainSnapshotText.contains("I listed the workspace")
    check mainSnapshotText.count("I listed the workspace") == 1
    let mainSnapshotCursor = mainSnapshot["cursor"].getInt()
    let created = workerCurl(
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"kind\":\"output\",\"config\":{\"title\":\"checks\",\"text\":\"ready\"}}' " &
      "http://127.0.0.1:8993/api/sessions/s1/workers")
    check "\"worker_id\":\"w1\"" in created
    let workers = workerCurl(
      "http://127.0.0.1:8993/api/sessions/s1/workers")
    check "\"kind\":\"output\"" in workers
    check "attached_local_pane" notin workers
    check "\"output\":\"ready\"" in workers
    let events = workerCurl(
      "'http://127.0.0.1:8993/api/sessions/s1/events?cursor=" &
      $mainSnapshotCursor & "'")
    check "worker_started" in events
    check "worker_output" in events
    let outputCursor = parseJson(events)["cursor"].getInt()
    let agentCreated = workerCurl(
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"assignment\":\"review worker events\",\"title\":\"reviewer\",\"context\":[{\"kind\":\"summary\",\"text\":\"bounded snapshot\"}]}' " &
      "http://127.0.0.1:8993/api/sessions/s1/agents")
    check "\"agent_id\":\"a1\"" in agentCreated
    check "\"worker_id\":\"a1\"" in agentCreated
    let agentEvents = workerCurl(
      "'http://127.0.0.1:8993/api/sessions/s1/events?cursor=" &
      $outputCursor & "'")
    check "agent_spawned" in agentEvents
    check "summary" in agentEvents
    let prompted = workerCurl(
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"text\":\"report briefly\"}' " &
      "http://127.0.0.1:8993/api/sessions/s1/agents/a1/messages")
    check "\"ok\":true" in prompted
    let agentStopped = workerCurl(
      "-X DELETE http://127.0.0.1:8993/api/sessions/s1/agents/a1")
    check "\"ok\":true" in agentStopped
    let gapResponse = workerCurl(
      "'http://127.0.0.1:8993/api/sessions/s1/events?cursor=0'")
    check "cursor_gap" in gapResponse
    check "/api/sessions/s1/snapshot" in gapResponse
    let snapshotText = workerCurl(
      "http://127.0.0.1:8993/api/sessions/s1/snapshot")
    let snapshot = parseJson(snapshotText)
    check snapshot["session_id"].getStr() == "s1"
    check snapshot["main_worker_id"].getStr() == "main"
    check snapshotText.contains("\"output\":\"ready\"")
    check snapshotText.contains("main snapshot recovery")
    check snapshotText.contains("I listed the workspace")
    let snapshotCursor = snapshot["cursor"].getInt()
    let afterSnapshot = workerCurl(
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"kind\":\"output\",\"config\":{\"title\":\"after snapshot\"}}' " &
      "http://127.0.0.1:8993/api/sessions/s1/workers")
    check "worker_id" in afterSnapshot
    let resumed = workerCurl(
      "'http://127.0.0.1:8993/api/sessions/s1/events?cursor=" &
      $snapshotCursor & "'")
    check "worker_started" in resumed
    check parseJson(resumed)["cursor"].getInt() > snapshotCursor
    let stopped = workerCurl(
      "-X DELETE http://127.0.0.1:8993/api/sessions/s1/workers/w1")
    check "\"ok\":true" in stopped
    let afterStop = workerCurl(
      "http://127.0.0.1:8993/api/sessions/s1/workers")
    check "\"lifecycle\":\"stopped\"" in afterStop
    let stoppedInput = workerCurl(
      "-w '\n%{http_code}' -X POST -H 'content-type: application/json' " &
      "-d '{\"text\":\"late\"}' " &
      "http://127.0.0.1:8993/api/sessions/s1/workers/w1/input")
    check "worker_stopped" in stoppedInput
    check stoppedInput.strip().endsWith("409")
    let gap = workerCurl(
      "-w '\\n%{http_code}' " &
      "'http://127.0.0.1:8993/api/sessions/s1/events?cursor=0'")
    check "cursor_gap" in gap
    check gap.strip().endsWith("409")

  test "agent gateway cancellation stops an in-flight model turn":
    buildGeneCli()
    let commandStarted = "tmp/gateway-cancel-command-started"
    removeFile(commandStarted)
    let endpoint = writeCliProgram("cancel_chat_endpoint.gene", """
(import net/http [Server serve Response])
(fn handle [req]
  (Response ^status 200
            ^headers {^content-type "text/event-stream"}
            ^body "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"tool_calls\":[{\"index\":0,\"id\":\"gw_cancel\",\"type\":\"function\",\"function\":{\"name\":\"run_shell\",\"arguments\":\"{\\\"command\\\":\\\"touch tmp/gateway-cancel-command-started; sleep 5\\\"}\"}}]}}]}\n\ndata: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n"))
(serve (Server ^host "127.0.0.1" ^port 8972) handle ^max_requests 1)
""")
    let endpointProc = startProcess(geneExe, args = ["run", endpoint],
                                    options = {poUsePath, poStdErrToStdOut})
    defer:
      if endpointProc.running:
        endpointProc.terminate()
      endpointProc.close()
    let gatewayProc = startProcess(
      "/usr/bin/env",
      args = ["-u", "CODEX_ACCESS_TOKEN", "-u", "OPENAI_API_KEY",
              "-u", "OPENAI_API", "OPENAI_AUTH_TOKEN=dummy",
              "OPENAI_BASE_URL=http://127.0.0.1:8972/v1",
              "OPENAI_MODEL=fake-chat", "GENE_GATEWAY_PORT=8973",
              geneExe, "run", "examples/ai_agent/gateway.gene"],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if gatewayProc.running:
        gatewayProc.terminate()
      gatewayProc.close()

    for port in [8972, 8973]:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(port), timeout = 500)
          s.close()
          break
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline:
            raise
          sleep(50)

    proc curl(call: string): tuple[output: string, exitCode: int] =
      execCmdEx("curl -sS --max-time 5 " & call)

    check "\"id\":\"s1\"" in
      curl("-X POST http://127.0.0.1:8973/api/sessions").output
    let started = getMonoTime()
    check "\"ok\":true" in curl(
      "-X POST -H 'content-type: application/json' -d '{\"text\":\"wait\"}' " &
      "http://127.0.0.1:8973/api/sessions/s1/messages").output

    # Wait until the actor has published its tracked Task, then cancel it.
    let busyDeadline = getMonoTime() + initDuration(seconds = 5)
    var busy = false
    while getMonoTime() < busyDeadline and not busy:
      busy = "\"busy\":true" in
        curl("http://127.0.0.1:8973/api/sessions").output
      if not busy:
        sleep(20)
    check busy
    let commandDeadline = getMonoTime() + initDuration(seconds = 5)
    while not fileExists(commandStarted) and getMonoTime() < commandDeadline:
      sleep(10)
    check fileExists(commandStarted)
    check "\"ok\":true" in curl(
      "-X POST http://127.0.0.1:8973/api/sessions/s1/cancel").output

    let doneDeadline = getMonoTime() + initDuration(seconds = 5)
    var events = ""
    while getMonoTime() < doneDeadline:
      events = curl(
        "'http://127.0.0.1:8973/api/sessions/s1/events?cursor=0'").output
      if "turn_done" in events:
        break
      sleep(20)
    check "turn cancelled" in events
    check "\"cancelled\":true" in events
    check "\"type\":\"check\"" in events
    check "\"tool\":\"run_shell\"" in events
    check "turn_done" in events
    check (getMonoTime() - started).inMilliseconds < 2000

  test "agent gateway persists sessions across restarts":
    ## Milestone 11 e2e: run a turn with GENE_GATEWAY_DB set, kill the
    ## gateway, restart on the same db — the event history must be intact,
    ## the restored session must accept another turn (versions continue),
    ## and new session ids must not collide with restored ones.
    buildGeneCli()
    let dbPath = cliDir / "gateway_persist.sqlite"
    removeFile(dbPath)

    proc startGw(): Process =
      startProcess(
        "/usr/bin/env",
        args = ["-u", "OPENAI_AUTH_TOKEN", "-u", "CODEX_ACCESS_TOKEN",
                "-u", "OPENAI_API_KEY", "-u", "OPENAI_BASE_URL",
                "-u", "TELEGRAM_BOT_TOKEN",
                "GENE_GATEWAY_PORT=8997",
                "GENE_GATEWAY_DB=" & dbPath,
                geneExe, "run", "examples/ai_agent/gateway.gene"],
        options = {poUsePath, poStdErrToStdOut})

    proc waitPort() =
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(8997), timeout = 500)
          s.close()
          break
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline:
            raise
          sleep(50)

    proc waitTurn(cursor: int): string =
      let deadline = getMonoTime() + initDuration(seconds = 15)
      while getMonoTime() < deadline:
        let ran = execCmdEx(
          "curl -sS --max-time 5 " &
          "'http://127.0.0.1:8997/api/sessions/s1/events?cursor=" &
          $cursor & "'")
        if ran.exitCode == 0:
          result = ran.output
          if "turn_done" in result:
            return
        sleep(200)
      checkpoint "turn never completed: " & result
      check false

    var gw = startGw()
    waitPort()
    let created = execCmdEx(
      "curl -sS -X POST http://127.0.0.1:8997/api/sessions")
    check "\"id\":\"s1\"" in created.output
    discard execCmdEx(
      "curl -sS -X POST -H 'content-type: application/json' " &
      "-d '{\"text\":\"list it\"}' " &
      "http://127.0.0.1:8997/api/sessions/s1/messages")
    let firstTurn = waitTurn(0)
    check "list_dir tool" in firstTurn
    # Slice A / review #2: the per-session log carries the full tool trail, not
    # just streamed text — the demo transport invokes list_dir.
    check "tool_call" in firstTurn
    check "tool_result" in firstTurn
    let durableWorker = execCmdEx(
      "curl -sS -X POST -H 'content-type: application/json' " &
      "-d '{\"kind\":\"output\",\"config\":{\"title\":\"durable-checks\",\"text\":\"saved\"}}' " &
      "http://127.0.0.1:8997/api/sessions/s1/workers")
    check "\"worker_id\":\"w1\"" in durableWorker.output
    gw.terminate()
    discard gw.waitForExit()
    gw.close()

    gw = startGw()
    defer:
      if gw.running:
        gw.terminate()
      gw.close()
    waitPort()
    # History restored verbatim, including the structured tool events.
    let restored = execCmdEx(
      "curl -sS --max-time 5 " &
      "'http://127.0.0.1:8997/api/sessions/s1/events?cursor=0'")
    check "\"v\":1" in restored.output
    check "list it" in restored.output
    check "list_dir tool" in restored.output
    check "tool_call" in restored.output
    check "tool_result" in restored.output
    let restoredWorkers = execCmdEx(
      "curl -sS http://127.0.0.1:8997/api/sessions/s1/workers")
    check "\"worker_id\":\"w1\"" in restoredWorkers.output
    check "\"title\":\"durable-checks\"" in restoredWorkers.output
    let restoredSnapshot = execCmdEx(
      "curl -sS http://127.0.0.1:8997/api/sessions/s1/snapshot")
    check "list it" in restoredSnapshot.output
    check "I listed the workspace" in restoredSnapshot.output
    # Highest version in the restored log (robust to per-turn event count).
    var maxV = 0
    for piece in restored.output.split("\"v\":"):
      let numEnd = piece.find(',')
      if numEnd > 0:
        try:
          maxV = max(maxV, parseInt(piece[0 ..< numEnd]))
        except ValueError:
          discard
    check maxV >= 1
    # New ids continue past restored ones.
    let second = execCmdEx(
      "curl -sS -X POST http://127.0.0.1:8997/api/sessions")
    check "\"id\":\"s2\"" in second.output
    # The restored session keeps working, with versions continuing past maxV.
    discard execCmdEx(
      "curl -sS -X POST -H 'content-type: application/json' " &
      "-d '{\"text\":\"again\"}' " &
      "http://127.0.0.1:8997/api/sessions/s1/messages")
    let contTurn = waitTurn(maxV)
    check ("\"v\":" & $(maxV + 1)) in contTurn

  test "agent gateway bridges telegram chats through the bot api":
    ## Milestone 9 e2e (examples/ai_agent/design.md §12.6) over loopback: a fake Telegram
    ## Bot API serves one canned getUpdates batch — a message from allowed
    ## chat 42 and one from unlisted chat 99 — and records sendMessage /
    ## editMessageText calls. The gateway (offline demo transport) must route
    ## chat 42 into a session, run the turn, and mirror the tool trace and
    ## final answer back via sendMessage; chat 99 must produce nothing.
    buildGeneCli()
    let botApi = writeCliProgram("fake_telegram_api.gene", """
(import net/http [Server serve Response])
(import json [parse stringify])
(import str [contains?])
(import std/stream [to_stream into])

(var served-updates (cell false))
(var outbox (cell []))
(var next-mid (cell 100))

(fn append-out [entry]
  (outbox ~ Cell/set ((to_stream [entry]) ~ into (outbox ~ Cell/get))))

(fn json_response [value]
  (Response ^status 200
            ^headers {^content-type "application/json"}
            ^body (stringify value)))

(fn handle [req]
  (if (contains? req/path "/getUpdates")
    (if (served-updates ~ Cell/get)
      (do
        (sleep 400)
        (json_response {^ok true ^result []}))
      (do
        (served-updates ~ Cell/set true)
        (json_response
          {^ok true
           ^result [{^update_id 1
                     ^message {^message_id 10
                               ^chat {^id 42}
                               ^text "what is in this directory?"}}
                    {^update_id 2
                     ^message {^message_id 11
                               ^chat {^id 99}
                               ^text "let me in"}}]})))
    (if (contains? req/path "/sendMessage")
      (do
        (var payload (parse req/body))
        (next-mid ~ Cell/set (+ (next-mid ~ Cell/get) 1))
        (append-out {^method "sendMessage" ^chat_id payload/chat_id
                     ^text payload/text ^message_id (next-mid ~ Cell/get)})
        (json_response {^ok true
                        ^result {^message_id (next-mid ~ Cell/get)}}))
      (if (contains? req/path "/editMessageText")
        (do
          (var payload (parse req/body))
          (append-out {^method "editMessageText" ^chat_id payload/chat_id
                       ^message_id payload/message_id ^text payload/text})
          (json_response {^ok true ^result true}))
        (if (== req/path "/outbox")
          (json_response {^outbox (outbox ~ Cell/get)})
          (json_response {^ok false ^description "unknown method"}))))))

(serve (Server ^host "127.0.0.1" ^port 8994) handle)
""")
    let botProc = startProcess(geneExe, args = ["run", botApi],
                               options = {poUsePath, poStdErrToStdOut})
    defer:
      if botProc.running:
        botProc.terminate()
      botProc.close()
    let gatewayProc = startProcess(
      "/usr/bin/env",
      args = ["-u", "OPENAI_AUTH_TOKEN", "-u", "CODEX_ACCESS_TOKEN",
              "-u", "OPENAI_API_KEY", "-u", "OPENAI_BASE_URL",
              "GENE_GATEWAY_PORT=8995",
              "TELEGRAM_BOT_TOKEN=test-token",
              "TELEGRAM_API_BASE=http://127.0.0.1:8994",
              "TELEGRAM_ALLOWED_CHAT_IDS=42",
              geneExe, "run", "examples/ai_agent/gateway.gene"],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if gatewayProc.running:
        gatewayProc.terminate()
      gatewayProc.close()
    for port in [8994, 8995]:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(port), timeout = 500)
          s.close()
          break
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline:
            raise
          sleep(50)

    # Poll the recorded outbox until the final answer lands.
    var outbox = ""
    block waitOutbox:
      let deadline = getMonoTime() + initDuration(seconds = 20)
      while getMonoTime() < deadline:
        let ran = execCmdEx("curl -sS --max-time 5 http://127.0.0.1:8994/outbox")
        if ran.exitCode == 0:
          outbox = ran.output
          if "list_dir tool" in outbox:
            break waitOutbox
        sleep(250)
      checkpoint "telegram outbox never received the answer: " & outbox
      check false

    check "\"chat_id\":42" in outbox
    check "tool list_dir" in outbox
    check "I listed the workspace via the list_dir tool." in outbox
    check outbox.count("I listed the workspace via the list_dir tool.") == 1
    # The unlisted chat never got a message.
    check "\"chat_id\":99" notin outbox
    # The turn also shows up in the gateway session log under tg-42.
    let events = execCmdEx(
      "curl -sS --max-time 5 " &
      "'http://127.0.0.1:8995/api/sessions/tg-42/events?cursor=0'")
    check events.exitCode == 0
    check "turn_done" in events.output

  test "invalid main return is a boundary TypeError":
    let badMain = writeCliProgram("bad_main.gene", "(fn main [] \"bad\")")
    let ran = runGene(["run", badMain])
    check ran.exitCode == 1
    check "TypeError" in ran.output
    check "main return expected Nil or Int" in ran.output

  test "oversized main return is a boundary TypeError":
    let bigMain = writeCliProgram("big_main.gene",
      "(fn main [] 9223372036854775808)")
    let ran = runGene(["run", bigMain])
    check ran.exitCode == 1
    check "TypeError" in ran.output
    check "main return Int must fit in int64" in ran.output

suite "cli — gene eval":
  setup:
    createDir(cliDir)

  test "evaluates source strings and prints the final value":
    let ran = runGene(["eval", "(var x 2) (+ x 3)"])
    check ran.exitCode == 0
    check ran.output.strip == "5"

  test "uses eval authority rules instead of ambient imports":
    let ran = runGene(["eval", "(import [x] from \"./missing\") x"])
    check ran.exitCode == 1
    check "eval cannot use import; add imports to Env" in ran.output

  test "eval errors include source location":
    let ran = runGene(["eval", "(missing)"])
    check ran.exitCode == 1
    check "undefined symbol: missing" in ran.output
    check "at <eval>:1:1" in ran.output

suite "cli — gene repl":
  setup:
    createDir(cliDir)

  test "runReplSession can be driven programmatically":
    let app = initModuleContext(cliDir)
    let scope = newGlobalScope(app)
    var inputs = @["(var x 2)", "(+ x 4)", ":quit"]
    var index = 0
    var outText = ""
    var errText = ""
    let reader = proc(line: var string): bool =
      if index >= inputs.len:
        return false
      line = inputs[index]
      inc index
      true
    let writeOut = proc(text: string) =
      outText.add text
    let writeErr = proc(text: string) =
      errText.add text

    let code = runReplSession(scope, reader, writeOut, writeErr)

    check code == 0
    check outText.strip.splitLines == @["2", "6"]
    check errText == ""

  test "runReplSession writes newline on interactive eof":
    let app = initModuleContext(cliDir)
    let scope = newGlobalScope(app)
    var outText = ""
    var errText = ""
    let reader = proc(line: var string): bool =
      false
    let writeOut = proc(text: string) =
      outText.add text
    let writeErr = proc(text: string) =
      errText.add text

    let code = runReplSession(scope, reader, writeOut, writeErr,
                              ReplOptions(interactive: true, prompt: "gene> "))

    check code == 0
    check outText == "gene> \n"
    check errText == ""

  test "retains declarations across input lines":
    let ran = runGeneInput(["repl"], "(var x 2)\n(+ x 3)\n")
    check ran.exitCode == 0
    check ran.output.strip.splitLines == @["2", "5"]

  test "continues reading after incomplete input":
    let ran = runGeneInput(["repl"], "(+ 1\n2)\n")
    check ran.exitCode == 0
    check ran.output.strip == "3"

  test "reports incomplete input on eof":
    let ran = runGeneInput(["repl"], "(+ 1\n")
    check ran.exitCode == 0
    check "Read error: unexpected EOF: unclosed '('" in ran.output

  test "interactive incomplete input uses continuation prompt":
    let app = initModuleContext(cliDir)
    let scope = newGlobalScope(app)
    var inputs = @["(+ 1", "2)", ":quit"]
    var index = 0
    var outText = ""
    var errText = ""
    let reader = proc(line: var string): bool =
      if index >= inputs.len:
        return false
      line = inputs[index]
      inc index
      true
    let writeOut = proc(text: string) =
      outText.add text
    let writeErr = proc(text: string) =
      errText.add text

    let code = runReplSession(scope, reader, writeOut, writeErr,
                              ReplOptions(interactive: true, prompt: "gene> "))

    check code == 0
    check outText == "gene> ....> 3\ngene> "
    check errText == ""

  test "rejects unknown repl options":
    let ran = runGene(["repl", "--bogus"])
    check ran.exitCode == 1
    check "unknown repl option: --bogus" in ran.output

  test "uses eval authority rules for each input line":
    let ran = runGeneInput(["repl"], "(import [x] from \"./missing\")\n(+ 1 2)\n")
    check ran.exitCode == 0
    check "eval cannot use import; add imports to Env" in ran.output
    check ran.output.strip.splitLines[^1] == "3"

  test "REPL_ON_ERROR enters repl after eval errors":
    buildGeneCli()
    let command = "env REPL_ON_ERROR=1 " & shellQuote(geneExe) &
                  " eval " & shellQuote("(var x 2) missing")
    let ran = execCmdEx(command, input = "x\n:quit\n")
    check ran.exitCode == 1
    check "Error: undefined symbol: missing" in ran.output
    check "REPL_ON_ERROR=1: entering Gene REPL" in ran.output
    check "\n2\n" in ran.output

  test "REPL_ON_ERROR enters module repl after run errors":
    let path = writeCliProgram("run_error_repl.gene",
      "(var x 41) (fn main [] missing)")
    buildGeneCli()
    let command = "env REPL_ON_ERROR=1 " & shellQuote(geneExe) &
                  " run " & shellQuote(path)
    let ran = execCmdEx(command, input = "x\n:quit\n")
    check ran.exitCode == 1
    check "Error: undefined symbol: missing" in ran.output
    check "REPL_ON_ERROR=1: entering Gene REPL" in ran.output
    check "\n41\n" in ran.output

suite "cli — gene parse/fmt/compile":
  setup:
    createDir(cliDir)

  test "parse prints canonical multi-form source":
    let path = writeCliProgram("parse_subject.gene",
      "(var x   1)\n" &
      "[x   2]\n")
    let ran = runGene(["parse", path])
    check ran.exitCode == 0
    check ran.output.strip.splitLines == @[
      "(var x 1)",
      "[x 2]"
    ]

  test "fmt is human-friendly: sugar restored, comments kept, forms wrapped":
    let path = writeCliProgram("fmt_subject.gene",
      "# header comment\n" &
      "\n" &
      "(var x (path a b))\n" &
      "(fn f [t] (if (== (path t done) 0) (quasiquote (li (unquote t))) " &
      "\"a really really really really really long string to force a wrap\"))\n")
    let ran = runGene(["fmt", path])
    check ran.exitCode == 0
    let outText = ran.output
    check "# header comment" in outText          # comments preserved
    check "(var x a/b)" in outText               # slash-path resugared
    check "`(li %t)" in outText                  # quasiquote/unquote resugared
    check "\n  (if (== t/done 0)" in outText     # fn body wrapped + indented

    let lexical = writeCliProgram("fmt_lexical_dispatch.gene",
      "#\"a#b\"im # after regex\n" &
      "$\"\"\"hello ${name}\"\"\" # after interpolation\n" &
      "'a' # after char\n" &
      "0#SGk= # after bytes\n" &
      "2026-07-04T09:30Z # after datetime\n")
    let lexicalFmt = runGene(["fmt", lexical])
    check lexicalFmt.exitCode == 0
    check lexicalFmt.output.count("# after ") == 5
    check "#\"a#b\"im" in lexicalFmt.output

  test "fmt output is parse-equivalent and idempotent on the todo app":
    buildGeneCli()
    let f1 = execCmdEx(shellQuote(geneExe) & " fmt examples/todo_app.gene")
    check f1.exitCode == 0
    let fmtPath = writeCliProgram("todo_fmt.gene", f1.output)
    # Same canonical forms as the original source.
    let p0 = execCmdEx(shellQuote(geneExe) & " parse examples/todo_app.gene")
    let p1 = execCmdEx(shellQuote(geneExe) & " parse " & shellQuote(fmtPath))
    check p0.exitCode == 0
    check p1.exitCode == 0
    check p0.output == p1.output
    # Formatting a second time changes nothing.
    let f2 = execCmdEx(shellQuote(geneExe) & " fmt " & shellQuote(fmtPath))
    check f2.exitCode == 0
    check f2.output == f1.output
    # Interior comments survive verbatim (the reader drops them; fmt keeps
    # the original span for forms that contain them).
    let commented = writeCliProgram("fmt_interior.gene",
      "(fn g [x]\n  # interior comment\n  x)\n")
    let f3 = runGene(["fmt", commented])
    check f3.exitCode == 0
    check "# interior comment" in f3.output

  test "compile prints bytecode without executing forms":
    let path = writeCliProgram("compile_subject.gene",
      "(panic \"compile should not run\")")
    let ran = runGene(["compile", path])
    check ran.exitCode == 0
    check "opPanic" in ran.output
    check "Panic:" notin ran.output

  test "compile loads macro artifacts without running dependency top levels":
    discard writeCliProgram("compile_macro_dep.gene",
      "(macro twice! [x] `(+ %x %x))\n" &
      "(panic \"dependency runtime should not run\")\n")
    let path = writeCliProgram("compile_macro_user.gene",
      "(import [twice!] from \"./compile_macro_dep\")\n" &
      "(var answer (twice! 21))\n")
    let ran = runGene(["compile", path])
    check ran.exitCode == 0
    check "twice!" notin ran.output
    check "Panic:" notin ran.output

  test "compile target c prints experimental typed_native C":
    let path = writeCliProgram("compile_c_subject.gene",
      "(fn add64 [x : I64 y : I64] : I64 (+ x y)) " &
      "(ffi/fn strlen ^library libc ^symbol \"strlen\" [s : C/CStr] : C/Size) " &
      "(fn main [] (panic \"compile c should not run\"))")
    let ran = runGene(["compile", "--target", "c", path])
    check ran.exitCode == 0
    check "#include <stdint.h>" in ran.output
    check "int64_t gene_native_add64(int64_t x, int64_t y)" in ran.output
    check "static const GeneAotModuleFunction gene_aot_module[] GENE_MAYBE_UNUSED = {" in ran.output
    check "{\"add64\", \"gene_native_add64\", \"I64\", 2, &gene_frame_add64}," in ran.output
    check "extern size_t GENE_FFI_CDECL strlen(const char * s);" in ran.output
    check "GeneStatus gene_ffi_strlen" in ran.output
    check "Panic:" notin ran.output

  test "compile rejects reserved native targets explicitly":
    let path = writeCliProgram("compile_reserved_target.gene",
      "(fn main [] nil)")
    let ran = runGene(["compile", "--target", "llvm", path])
    check ran.exitCode == 1
    check "unsupported compile target: llvm" in ran.output

  test "file runtime errors include source location and snippet":
    let path = writeCliProgram("located_runtime_error.gene",
      "(var x 1)\n(+ x missing)\n")
    let ran = runGene(["run", path])
    check ran.exitCode == 1
    check "undefined symbol: missing" in ran.output
    check ("at " & normalizedPath(absolutePath(path)) & ":2:1") in ran.output
    check "2 | (+ x missing)" in ran.output

  test "serde references, instances, hooks, and value-refs round-trip across modules":
    ## Stages 3-4 (docs/proposals/serialization.md §5-§7): type/enum/variant/
    ## protocol/fn refs to an imported module round-trip by identity; typed
    ## instances round-trip via direct construction (ctor never runs on
    ## read-back); serde/read resolves against loaded modules WITHOUT executing
    ## a module that only appears in a reference (no-code-execution property).
    discard writeCliProgram("serde_geometry.gene", """
(mod serde-geometry)
(type Point ^props {^x Int ^y Int})
(type Line ^props {^a Point ^b Point})
(enum Shape circle square triangle)
(enum Result (ok Any) (err Str))
(protocol Drawable (message draw [self : Self] : Str))
(fn area [p : Point] : Int (* p/x p/y))
(type Counter ^props {^n Int}
  (ctor [start] (println "COUNTER-CTOR-RAN") (self ~ Node/set_prop! `n start)))
(type Conn ^props {^host Str ^live Bool}
  (message serde_state [self] {^host self/host})
  (message serde_restore [state] (Conn ^host state/host ^live true)))
(type Registry ^props {^label Str})
(impl SerdeRef for Registry)
(var REGISTRY (Registry ^label "the-one"))
""")
    discard writeCliProgram("serde_sidefx.gene", """
(mod serde-sidefx)
(println "SIDEFX-RAN")
(type Widget ^props {^n Int})
""")
    let prog = writeCliProgram("serde_refs.gene", """
(import serde [write read write_data SerdePolicy SerdeError])
(import str [contains? join])
(import [Point Line Shape Result Drawable area Counter Conn REGISTRY] from "./serde_geometry")
(fn check [label ok] (println (join [label (if ok "ok" "FAIL")] " ")))
# stage 3: references
(check "type" (== Point (read (write Point))))
(check "enum" (== Shape (read (write Shape))))
(check "variant" (== Shape/circle (read (write Shape/circle))))
(check "protocol" (== Drawable (read (write Drawable))))
(var a2 (read (write area)))
(check "fn" (== 12 (a2 (Point ^x 3 ^y 4))))
(var imported-area area)
(var a3 (read (write imported-area)))
(check "fn-alias" (== 30 (a3 (Point ^x 5 ^y 6))))
(var t (write Point))
(check "ref-shape" (&& (contains? t "serde_type_ref") (contains? t "Point")))
(check "no-exec"
  (try (do (read "(serde_v1 (serde_type_ref ^module \"serde-sidefx\" ^path \"Widget\"))") false)
       catch (SerdeError ^message m) (contains? m "not loaded")))
# stage 4: typed instances via direct construction
(var p (Point ^x 3 ^y 4))
(check "inst" (== p (read (write p))))
(check "inst-nested"
  (== (Line ^a (Point ^x 1 ^y 2) ^b (Point ^x 5 ^y 6))
     (read (write (Line ^a (Point ^x 1 ^y 2) ^b (Point ^x 5 ^y 6))))))
(check "inst-variant-payload" (== (Result/ok 42) (read (write (Result/ok 42)))))
(check "inst-wd-reject"
  (try (do (write_data p) false) catch (SerdeError ^message m) (contains? m "not data")))
(check "inst-unknown-field"
  (try (do (read "(serde_v1 (serde_inst (serde_type_ref ^module \"serde_geometry\" ^path \"Point\") (serde_map false [\"x\" 1 \"y\" 2 \"z\" 9]) []))") false)
       catch (SerdeError ^message m) (contains? m "no field")))
# ctor must NOT run on read-back (new runs it once, printing the marker)
(var c (new Counter 7))
(var c2 (read (write c)))
(check "inst-no-ctor" (&& (== c c2) (== 7 c2/n)))
# stage 5: Serde hooks behind ^allow_restore
(var conn (Conn ^host "db" ^live false))
(var ht (write conn))
(check "hooked-form" (&& (contains? ht "serde_hooked") (! (contains? ht "live"))))
(check "hooked-no-allow"
  (try (do (read ht) false) catch (SerdeError ^message m) (contains? m "allow_restore")))
(var conn2 (read ht ^policy (SerdePolicy ^allow_restore true)))
(check "hooked-restore" (&& (== "db" conn2/host) (== true conn2/live)))
# stage 6: SerdeRef module singleton -> identity value_ref
(check "value-ref-form" (contains? (write REGISTRY) "serde_value_ref"))
(var reg2 (read (write REGISTRY)))
(reg2 ~ Node/set_prop! `marker 99)
(check "value-ref-identity" (== 99 REGISTRY/marker))
# a non-SerdeRef module instance serializes by value, not as a value_ref
(check "plain-by-value" (! (contains? (write (Point ^x 1 ^y 2)) "value_ref")))
""")
    let ran = runGene(["run", prog])
    check ran.exitCode == 0
    check "type ok" in ran.output
    check "enum ok" in ran.output
    check "variant ok" in ran.output
    check "protocol ok" in ran.output
    check "fn ok" in ran.output
    check "fn-alias ok" in ran.output
    check "ref-shape ok" in ran.output
    check "no-exec ok" in ran.output
    check "inst ok" in ran.output
    check "inst-nested ok" in ran.output
    check "inst-variant-payload ok" in ran.output
    check "inst-wd-reject ok" in ran.output
    check "inst-unknown-field ok" in ran.output
    check "inst-no-ctor ok" in ran.output
    check "hooked-form ok" in ran.output
    check "hooked-no-allow ok" in ran.output
    check "hooked-restore ok" in ran.output
    check "value-ref-form ok" in ran.output
    check "value-ref-identity ok" in ran.output
    check "plain-by-value ok" in ran.output
    check "FAIL" notin ran.output
    check "SIDEFX-RAN" notin ran.output
    # The ctor ran exactly once (from `new`), never during read-back.
    check ran.output.count("COUNTER-CTOR-RAN") == 1

suite "cli — gene doc":
  setup:
    createDir(cliDir)

  test "prints module metadata and declarations without calling main":
    let path = writeCliProgram("doc_subject.gene",
      "(mod docs @doc \"module docs\") " &
      "(var answer 42) " &
      "(fn helper [] answer) " &
      "(fn main [] (panic \"doc should not call main\"))")
    let ran = runGene(["doc", path])
    check ran.exitCode == 0
    let lines = ran.output.strip.splitLines
    check lines[0] == "Module: docs"
    check lines[1] == "Path: " & normalizedPath(absolutePath(path))
    check lines[2] == "Doc: module docs"
    check lines[3] == "Declarations:"
    check lines[4 .. ^1] == @[
      "- answer : Int",
      "- helper : Fn",
      "- main : Fn"
    ]
    check "this_mod" notin ran.output

  test "prints namespace declarations recursively":
    let path = writeCliProgram("doc_namespaces.gene",
      "(mod docs) " &
      "(ns util " &
      "  (var answer 42) " &
      "  (fn double [x] (+ x x)) " &
      "  (ns nested (var flag true)))")
    let ran = runGene(["doc", path])
    check ran.exitCode == 0
    let lines = ran.output.strip.splitLines
    check lines == @[
      "Module: docs",
      "Path: " & normalizedPath(absolutePath(path)),
      "Declarations:",
      "- util : Namespace",
      "Namespaces:",
      "Namespace util:",
      "- answer : Int",
      "- double : Fn",
      "- nested : Namespace",
      "Namespace util/nested:",
      "- flag : Bool"
    ]

  test "prints normalized import targets":
    let depPath = writeCliProgram("dep_for_doc.gene",
      "(var dep 1)")
    let path = writeCliProgram("doc_imports.gene",
      "(mod docs) " &
      "(import [dep : local-dep] from \"./dep_for_doc\") " &
      "(ns source (var item 2)) " &
      "(import source [item : local-item]) " &
      "(var done true)")
    let ran = runGene(["doc", path])
    check ran.exitCode == 0
    let lines = ran.output.strip.splitLines
    check lines == @[
      "Module: docs",
      "Path: " & normalizedPath(absolutePath(path)),
      "Imports:",
      "- from \"./dep_for_doc\" -> " & normalizedPath(absolutePath(depPath)) &
        " [dep : local-dep]",
      "- source [item : local-item]",
      "Declarations:",
      "- done : Bool",
      "- local-dep : Int",
      "- local-item : Int",
      "- source : Namespace",
      "Namespaces:",
      "Namespace source:",
      "- item : Int"
    ]
