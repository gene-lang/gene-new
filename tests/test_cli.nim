import std/[algorithm, json, monotimes, net, os, osproc, sequtils, streams,
            strutils, times, unittest]
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

proc agentStateRecordPath(root, key: string): string =
  ## Agent checkpoints publish a generation atomically. Tests inspect the
  ## authoritative generation selected by CURRENT, never loose legacy keys.
  let current = root / "CURRENT"
  if not fileExists(current):
    return root / "generations" / "missing" / (key & ".gene")
  root / "generations" / readFile(current).strip() / (key & ".gene")

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

  test "runurl runs a remote module graph with URL-relative imports":
    # design §15.9 (experimental): the entry URL redirects, so the relative
    # import must resolve against the final URL after redirects.
    buildGeneCli()
    let serverScript = cliDir / "urlmod_server.py"
    writeFile(serverScript, """
import http.server
import socketserver

ROUTES = {
    "/real/entry.gene":
        b'(import [util_fn] from "./util") (println (+ (util_fn) 1))',
    "/real/util.gene": b'(fn util_fn [] 41)',
}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/entry.gene":
            self.send_response(302)
            self.send_header("Location", "/real/entry.gene")
            self.end_headers()
            return
        body = ROUTES.get(self.path)
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


with socketserver.TCPServer(("127.0.0.1", 0), Handler) as srv:
    print(f"PORT {srv.server_address[1]}", flush=True)
    srv.serve_forever()
""")
    let server = startProcess("python3", args = [serverScript],
                              options = {poUsePath, poStdErrToStdOut})
    try:
      let portLine = server.outputStream.readLine()
      check portLine.startsWith("PORT ")
      let port = portLine.split(' ')[1]
      let ran = runGene(["runurl",
                         "http://127.0.0.1:" & port & "/entry.gene"])
      checkpoint ran.output
      check ran.exitCode == 0
      check "42" in ran.output
    finally:
      server.terminate()
      server.close()

  test "runurl rejects non-localhost http before any fetch":
    let ran = runGene(["runurl", "http://example.invalid/x.gene"])
    check ran.exitCode == 1
    check "module URLs require https" in ran.output

  test "gene run cannot import URL modules":
    let fixture = writeCliProgram("url_import.gene",
      "(import [x] from \"https://127.0.0.1:1/x.gene\")")
    let ran = runGene(["run", fixture])
    check ran.exitCode == 1
    check "URL module imports require a 'gene runurl' entry" in ran.output

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
    let paneCommand =
      "printf '/pane new output diagnostics\\n/pane 1 max\\n/close\\n/quit\\n' | " &
      "env -u OPENAI_API_KEY -u CODEX_ACCESS_TOKEN " &
      "-u GENE_AGENT_STATE -u GENE_AGENT_HOME OPENAI_AUTH_TOKEN=dummy " &
      shellQuote(geneExe) & " run --log-config " & shellQuote(configPath) &
      " examples/ai_agent/tui.gene"
    let paneRan = execCmdOnce(paneCommand)
    if paneRan.exitCode != 0: checkpoint paneRan.output
    check paneRan.exitCode == 0
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
    check "\"worker_id\":\"w1\"" in logged
    check "\"pane_id\":1" in logged
    check "\"surface_id\":\"local_tui:" in logged
    check "what's in this directory?" notin logged

  test "ai agent pane new shell opens a cancellable structured shell":
    buildGeneCli()
    let command =
      "printf '/pane new shell\\n/1 cd tests\\n/1 pwd\\n" &
      "/1 cd ..\\n/1 pwd\\n" &
      "/1 printf \"shell-line-one\\\\nshell-line-two\\\\n\"\\n" &
      "/close\\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    check "shell pane 1" in ran.output
    check ("shell pane 1: " & getCurrentDir() / "tests" & "\n[exit") in
      ran.output
    check ("shell pane 1: " & getCurrentDir() & "\n[exit") in ran.output
    check "shell-line-one\nshell-line-two\n" in ran.output
    check "closed pane 1" in ran.output

  test "ai agent comprehensive help is global and presentation-only":
    buildGeneCli()
    let fixture = "examples/ai_agent/help_surface_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [active_application make_application application_spawn_agent
         application_attach_worker_pane
         application_begin_worker_operation!
         application_finish_agent_operation!]
  from "./core.gene")
(import [show_surface_help! open_shell_pane open_repl_pane
         open_output_pane open_log_tail_pane open_stats_pane
         open_file_view_pane]
  from "./tui.gene")
(import str [starts_with?])
(var items (cell []))
(var transcript (cell "base transcript\n"))
(var memory (cell []))
(var events (cell []))
(fn sink [type, props]
  (var event {^v (+ ((events ~ get) ~ size) 1) ^type type})
  (for [key value] in props (event ~ put! key value))
  ((events ~ get) ~ push! event)
  event)
(var app (make_application items transcript memory sink))
(active_application ~ set app)
(var child
  (application_spawn_agent app "reviewer" "review" (cell []) (cell "ready\n")))
(application_attach_worker_pane app child child/id "detach")
(application_begin_worker_operation! app child nil "agent_turn")
(application_finish_agent_operation!
  app child "completed" "ready" "" "" nil)
(open_shell_pane)
(open_repl_pane items transcript memory)
(open_output_pane "notes")
(open_log_tail_pane "")
(open_stats_pane)
(open_file_view_pane "examples/ai_agent/design.md")
(var before_text (transcript ~ get))
(var before_items (items ~ get))
(var before_events ((events ~ get) ~ size))
(var full_help (show_surface_help! app transcript "/help"))
(var alias_help (show_surface_help! app transcript "/?"))
(var all_routes true)
(for pane in (app/local_surface/panes ~ get)
  (app/local_surface/focused_pane ~ set pane/id)
  (app/local_surface/maximized_pane ~ set pane/id)
  (show_surface_help! app transcript "/? input")
  (if (|| (!= (app/local_surface/focused_pane ~ get) nil)
          (!= (app/local_surface/maximized_pane ~ get) nil))
    (set all_routes false)))
(var result (child/result ~ get))
(var unchanged
  (&& (== (transcript ~ get) before_text)
      (== (items ~ get) before_items)
      (== ((events ~ get) ~ size) before_events)
      (== result/read false)))
(var comprehensive (starts_with? full_help "Gene agent help"))
(println $"unchanged=${unchanged} focus=${(app/local_surface/focused_pane ~ get)} max=${(app/local_surface/maximized_pane ~ get)} comprehensive=${comprehensive} alias=${(== full_help alias_help)} routes=${all_routes} panes=${((app/local_surface/panes ~ get) ~ size)}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "unchanged=true focus=nil max=nil comprehensive=true alias=true routes=true panes=7" in ran.output

  test "ai agent help supports all command pages search and suggestions":
    buildGeneCli()
    let command =
      "printf '/help all\n/help /worker\n/help search durable\n/pan\n/quit\n' | " &
      "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "Gene agent help" in ran.output
    check "/worker\nusage: /worker list" in ran.output
    check "help search: durable" in ran.output
    check "/artifacts" in ran.output
    check "unknown command: /pan; did you mean '/pane'?" in ran.output

  test "ai agent canonical pane commands and unknown-slash safety work":
    buildGeneCli()
    let stateDir = cliDir / "agent_c3_command_state"
    if dirExists(stateDir): removeDir(stateDir)
    defer:
      if dirExists(stateDir): removeDir(stateDir)
    let command =
      "printf '/pane new output notes\\n/pane 1 max\\n/pane max 1\\n/1 append first\\n" &
      "/worker w1 append second\\n/pane open w1 mirror\\n" &
      "/pane hide 1\\n/pane hide 2\\n/worker w1 open\\n" &
      "/pane new shell\\n/pane hide 3\\n/pane new shell\\n" &
      "/stats\\n/pane hide 4\\n/stats\\n" &
      "/repl\\n/pane hide 5\\n/repl\\n" &
      "/pane list\\n/worker list\\n/focus 1\\n/pane list\\n" &
      "/unknown-command\\n/close 1\\n/pane close 0\\n/? pane\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
      "GENE_AGENT_STATE=" & shellQuote("fs:" & stateDir) & " " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "opened output pane 1" in ran.output
    check "maximized pane 1" in ran.output
    check "restored split layout" in ran.output
    check "appended to pane 1" in ran.output
    check "appended to worker w1" in ran.output
    check "opened worker w1 in pane 2" in ran.output
    check "2 w1 output hidden lifecycle=running" in ran.output
    check "mirror" in ran.output
    check "3 w2 shell visible lifecycle=running" in ran.output
    check "4 w3 stats visible lifecycle=running" in ran.output
    check "5 w4 repl visible lifecycle=running" in ran.output
    check "panes=" in ran.output
    check "2:hidden" in ran.output
    check "focused pane 1" in ran.output
    check "1 w1 output visible lifecycle=running" in ran.output
    check "closed pane 1" in ran.output
    check "pane 0 cannot be closed" in ran.output
    check "unknown command: /unknown-command" in ran.output
    check "use /help or /?" in ran.output
    check "unknown command: /unknown-command\nuse /help or /?;" notin ran.output
    check "/pane new <agent|shell|terminal|repl|tail|output|view|stats>" in ran.output
    check "/close [N]" in ran.output
    check "/ext" notin ran.output

  test "ai agent max toggles the focused pane and focus switch restores split":
    buildGeneCli()
    let command =
      "printf '/max\\n/pane new output notes\\n/max\\n/pane list\\n" &
      "/pane new output extra\\n/pane list\\n/max\\n/1\\n/pane list\\n" &
      "/max 2\\n/max\\n/max 0\\n/max abc\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY -u GENE_AGENT_STATE " &
      "-u GENE_AGENT_HOME CODEX_ACCESS_TOKEN=dummy " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    # Bare /max needs a focused pane; pane 0 never maximizes.
    check "no pane is focused; use /max <N> or /N max" in ran.output
    check "maximized pane 1" in ran.output
    # A maximized pane reports maximized visibility in /pane list.
    check "1 w1 output maximized lifecycle=running" in ran.output
    # Opening pane 2 claims focus and restores the split; focusing pane 1
    # away from maximized pane 2 restores it again, so pane 2 reads visible
    # in both subsequent listings.
    check ran.output.count("1 w1 output visible lifecycle=running") == 2
    check ran.output.count("2 w2 output visible lifecycle=running") == 2
    check ran.output.count("maximized pane 2") == 2
    check "restored split layout" in ran.output
    check "pane 0 cannot be maximized" in ran.output
    check "usage: /max [N]" in ran.output

  test "ai agent memory commands repeat within one session":
    buildGeneCli()
    let command =
      "printf '/remember one\\n/remember two\\n/memory\\n/forget\\n" &
      "/memory\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY -u GENE_AGENT_STATE " &
      "-u GENE_AGENT_HOME CODEX_ACCESS_TOKEN=dummy " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    # Both branch-local bindings used to be `var`s in the interactive while
    # body, so the second /remember or /memory crashed with a duplicate
    # binding error.
    check "remembered: one" in ran.output
    check "remembered: two" in ran.output
    check "memory:\none\ntwo" in ran.output
    check "memory cleared" in ran.output
    check "memory is empty" in ran.output
    check "duplicate binding" notin ran.output

  test "ai agent output follow rejects cycles and process restart mints identity":
    buildGeneCli()
    let fixture = "examples/ai_agent/output_follow_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [make_application application_create_worker_from_config
         application_follow_output!
         application_append_worker_output!]
  from "./core.gene")
(import str [contains?])
(var app
  (make_application (cell []) (cell "") (cell [])
    (fn [_type, _props] nil)))
(var one (application_create_worker_from_config app "output" {^title "one"}))
(var two (application_create_worker_from_config app "output" {^title "two"}))
(var linked (application_follow_output! app two one))
(application_append_worker_output! app one "evidence\n" "test")
(var cycle (application_follow_output! app one two))
(var self (application_follow_output! app two two))
(println $"linked=${linked/ok} copied=${(contains? (two/output ~ get) \"evidence\")} cycle=${cycle/error} self=${self/error}")
""")
    let followed = runGene(["run", fixture])
    if followed.exitCode != 0: checkpoint followed.output
    check followed.exitCode == 0
    check "linked=true copied=true cycle=worker_follow_cycle self=worker_follow_cycle" in followed.output

    let stateDir = cliDir / "agent_c3_restart_state"
    if dirExists(stateDir): removeDir(stateDir)
    defer:
      if dirExists(stateDir): removeDir(stateDir)
    let command =
      "printf '/pane new shell\n/worker w1 stop\n/worker w1 restart\n" &
      "/worker list\n/trace type=worker_started worker=w2 --detail\n/quit\n' | " &
      "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
      "GENE_AGENT_STATE=" & shellQuote("fs:" & stateDir) & " " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let restarted = execCmdOnce(command)
    if restarted.exitCode != 0: checkpoint restarted.output
    check restarted.exitCode == 0
    check "restarted worker w1 as w2" in restarted.output
    check "w1 shell stopped" in restarted.output
    check "w2 shell idle" in restarted.output
    check "\"worker_id\":\"w2\"" in restarted.output
    check "\"restarted_from\":\"w1\"" in restarted.output

  test "ai agent worker operations are typed attributed delegated and stateful":
    buildGeneCli()
    let fixture = "examples/ai_agent/worker_operations_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [active_application make_application
         application_create_worker_from_config
         application_call_worker application_find_worker
         application_spawn_agent_with_attachments]
  from "./core.gene")
(import [open_repl_pane]
  from "./tui.gene")
(import str [contains?])
(var events (cell []))
(var sink
  (fn [type, props]
    (var event {^type type})
    (for [key value] in props (event ~ put! key value))
    ((events ~ get) ~ push! event)
    event))
(var items (cell []))
(var transcript (cell ""))
(var memory (cell []))
(var app (make_application items transcript memory sink))
(active_application ~ set app)
(var shell
  (application_create_worker_from_config app "shell"
    {^title "build" ^name "build-shell"}))
(var addressed (application_find_worker app "build-shell"))
(var invocation {^origin "worker" ^caller_worker_id "main"
                 ^adapter "model" ^detached false})
(var changed
  (application_call_worker app "build-shell" "chdir" {^path "tests"}
    invocation))
(var escaped
  (application_call_worker app "build-shell" "chdir" {^path "../.."}
    invocation))
(var env_set
  (application_call_worker app "build-shell" "set_env"
    {^name "C4_MARKER" ^value "stateful"} invocation))
(var ran
  (application_call_worker app "build-shell" "run"
    {^command "printf $C4_MARKER; pwd"} invocation))
(var before_observe ((events ~ get) ~ size))
(var status
  (application_call_worker app "build-shell" "status" {}
    {^origin "user" ^caller_worker_id "main"}))
(var tail
  (application_call_worker app "build-shell" "tail" {^n 5}
    {^origin "worker" ^caller_worker_id "main"}))
(var observe_events (- ((events ~ get) ~ size) before_observe))
(var child
  (application_spawn_agent_with_attachments app "child" "test" (cell [])
    (cell "") []))
(var denied
  (application_call_worker app shell/id "status" {}
    {^origin "model" ^caller_worker_id child/id}))
(var delegated
  (application_spawn_agent_with_attachments app "delegated" "test" (cell [])
    (cell "") [{^kind "worker" ^worker_id shell/id}]))
(var allowed
  (application_call_worker app shell/id "tail" {^n 2}
    {^origin "model" ^caller_worker_id delegated/id}))
(var repl_pane (open_repl_pane items transcript memory))
(var repl_denied
  (application_call_worker app repl_pane/worker/id "eval" {^form "(+ 1 2)"}
    {^origin "model" ^caller_worker_id "main"}))
(var busy
  (application_call_worker app shell/id "run" {^command "sleep 5"}
    {^origin "worker" ^caller_worker_id "main" ^adapter "model"
     ^detached true}))
# Let the detached task enter its guarded body before testing cancellation;
# otherwise this fixture can cancel it before its `ensure` is installed.
(sleep 25)
(var busy_status
  (application_call_worker app shell/id "status" {}
    {^origin "worker" ^caller_worker_id "main"}))
(var cancelled
  (application_call_worker app shell/id "cancel" {}
    {^origin "worker" ^caller_worker_id "main"}))
(while (!= (shell/current_task ~ get) nil) (sleep 10))
(var attributed false)
(for event in (events ~ get)
  (if (&& (== event/type "worker_operation_started")
          (== event/operation_kind "run") (== event/origin "worker")
          (== event/caller_worker_id "main"))
    (set attributed true)))
(var duplicate "")
(try
  (application_create_worker_from_config app "output" {^name "build-shell"})
catch {^message message} (set duplicate message))
(println "named" (== addressed/id shell/id)
  "changed" changed/ok "env" env_set/ok "run" ran/ok
  "escape" escaped/error/kind
  "stateful" (contains? (shell/output ~ get) "stateful")
  "cwd" (contains? (shell/output ~ get) "/tests")
  "observe_events" observe_events "status" status/result/status "tail" tail/ok
  "denied" denied/error/kind "delegated" allowed/ok
  "repl" repl_denied/error/kind "busy" busy/ok busy_status/result/busy
  "cancel" cancelled/ok "attributed" attributed
  "duplicate" (contains? duplicate "worker_name_taken"))
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "named true changed true env true run true escape operation_failed" in ran.output
    check "stateful true cwd true" in ran.output
    check "observe_events 0 status idle tail true" in ran.output
    check "denied worker_access_denied delegated true repl worker_access_denied" in ran.output
    check "busy true true cancel true attributed true duplicate true" in ran.output

  test "interactive terminal control stays on its one local surface":
    when defined(posix):
      buildGeneCli()
      let fixture = "examples/ai_agent/terminal_authority_test.gene"
      defer:
        if fileExists(fixture): removeFile(fixture)
      writeFile(fixture, """
(import [active_application make_application application_call_worker
         application_create_worker_from_config
         application_worker_snapshot application_shutdown]
  from "./core.gene")
(import [open_terminal_pane]
  from "./tui.gene")
(var app
  (make_application (cell []) (cell "") (cell [])
    (fn [_type, _props] nil)))
(active_application ~ set app)
(var pane (open_terminal_pane "/bin/sh" ["-c" "sleep 30"]))
(var worker pane/worker)
(var surface_id (app/local_surface/instance_id ~ get))
(var wrong_surface
  (application_call_worker app worker/id "write" {^bytes "forbidden"}
    {^origin "user" ^surface_id "local_tui:other"
     ^caller_worker_id "main"}))
(var wrong_signal
  (application_call_worker app worker/id "signal" {^name "INT"}
    {^origin "user" ^surface_id "local_tui:other"
     ^caller_worker_id "main"}))
(var wrong_stop
  (application_call_worker app worker/id "stop" {}
    {^origin "user" ^surface_id "local_tui:other"
     ^caller_worker_id "main"}))
(var remote
  (application_call_worker app worker/id "snapshot" {}
    {^origin "remote" ^caller_worker_id "main"}))
(var model
  (application_call_worker app worker/id "snapshot" {}
    {^origin "model" ^caller_worker_id "main"}))
(var local
  (application_call_worker app worker/id "resize" {^rows 10 ^cols 40}
    {^origin "user" ^surface_id surface_id ^caller_worker_id "main"}))
(var metadata (application_worker_snapshot app worker))
(var created
  (application_create_worker_from_config app "terminal" {^title "denied"}))
(var stopped
  (application_call_worker app worker/id "stop" {}
    {^origin "user" ^surface_id surface_id ^caller_worker_id "main"}))
(while (!= (worker/lifecycle ~ get) "stopped") (sleep 5))
(println "wrong" wrong_surface/error/kind
  wrong_signal/error/kind wrong_stop/error/kind
  "remote" remote/error/kind "model" model/error/kind
  "local" local/ok "hidden" (== metadata/output "")
  "created" (== created nil) "stop" stopped/ok)
(application_shutdown app)
""")
      let ran = runGene(["run", fixture])
      if ran.exitCode != 0: checkpoint ran.output
      check ran.exitCode == 0
      # Slice C9: a remote caller denied a local-surface-bound terminal
      # operation gets the typed local_only error; same-process wrong-surface
      # and model callers keep the generic access denial.
      check "wrong worker_access_denied worker_access_denied worker_access_denied remote local_only" in ran.output
      check "model worker_access_denied local true hidden true created true stop true" in ran.output

  # test "ai agent slash sh is a contained interactive terminal":
  #   when defined(macosx):
  #     buildGeneCli()
  #     let outputFile = cliDir / "agent_terminal_c8.out"
  #     let viProof = "tmp/agent_terminal_c8_vi.txt"
  #     let foregroundPid = "tmp/agent_terminal_c8_foreground.pid"
  #     removeFile(outputFile)
  #     removeFile(viProof)
  #     removeFile(foregroundPid)
  #     defer:
  #       removeFile(viProof)
  #       removeFile(foregroundPid)
  #     let inner =
  #       # SHELL pinned to /bin/sh (and ENV cleared): /sh spawns $SHELL, and a
  #       # user zsh with prompt themes/autosuggestions makes every expect
  #       # pattern race against dotfile output.
  #       "stty rows 24 cols 100; exec /usr/bin/env " &
  #       "-u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY -u GENE_AGENT_HOME " &
  #       "-u ENV SHELL=/bin/sh " &
  #       "CODEX_ACCESS_TOKEN=dummy GENE_AGENT_STATE= GENE_AGENT_RESUME=0 " &
  #       "TERM=xterm-256color " & shellQuote(geneExe) &
  #       " run examples/ai_agent/tui.gene"
  #     let expectScript =
  #       "set timeout 20\n" &
  #       "log_file -noappend " & outputFile & "\n" &
  #       "spawn /bin/sh -c {" & inner & "}\n" &
  #       "expect -re {\\[0 main\\]}\n" &
  #       "send -- \"/sh\\r\"\n" &
  #       "expect -re {terminal w1: direct/unmediated}\n" &
  #       # Tcl: inside a double-quoted word `\\[` is backslash + live command
  #       # substitution ("missing close-bracket"); `\[` is a literal bracket.
  #       "send -- \"printf 'C8_COLOR_\\\\033\\[31m_界\\\\033\\[0m\\\\n'\\r\"\n" &
  #       "expect -re {C8_COLOR_.*界}\n" &
  #       "send -- \"cd tests\\r\"\n" &
  #       "send -- \"pwd\\r\"\n" &
  #       "expect -re {" & (getCurrentDir() / "tests") & "}\n" &
  #       "send -- \"python3 -q\\r\"\n" &
  #       "expect -re {>>>}\n" &
  #       "send -- \"print('C8_REPL_42')\\r\"\n" &
  #       "expect -re {C8_REPL_42}\n" &
  #       "send -- \"exit()\\r\"\n" &
  #       "after 250\n" &
  #       "send -- \"cd ..\\r\"\n" &
  #       "send -- \"vi " & viProof & "\\r\"\n" &
  #       "after 500\n" &
  #       "send -- \"iC8_VI_ALT_SCREEN\"\n" &
  #       "send -- \"\\033:wq\\r\"\n" &
  #       "after 500\n" &
  #       # The child may request arbitrary OSC controls, but those bytes must
  #       # terminate at libvterm rather than reach the outer terminal.
  #       "send -- \"printf '\\\\033]52;c;C8_CLIPBOARD\\\\007'\\r\"\n" &
  #       "after 250\n" &
  #       # Leader enters the application editor; focus can leave and return to
  #       # the same live PTY without creating a second input surface.
  #       "send -- \"\\035\"\n" &
  #       "expect -re {terminal w1: app commands}\n" &
  #       "send -- \"0\\r\"\n" &
  #       "expect -re {\\[0 main\\]}\n" &
  #       "send -- \"/1\\r\"\n" &
  #       "expect -re {terminal w1: direct/unmediated}\n" &
  #       # Repeating the leader sends one literal byte to the child.
  #       "send -- \"od -An -tu1 -N1\\r\"\n" &
  #       "after 200\n" &
  #       "send -- \"\\035\\035\\r\"\n" &
  #       "expect -re {[[:space:]]29}\n" &
  #       # Stop while a job owns a separate foreground process group.
  #       # Tcl `\$` sends a literal dollar; the inner sh must see `echo $$`.
  #       "send -- \"sh -c 'echo \\$\\$ > " & foregroundPid &
  #       "; exec sleep 30'\\r\"\n" &
  #       "after 300\n" &
  #       "send -- \"\\035\"\n" &
  #       "send -- \"worker w1 stop\\r\"\n" &
  #       "expect -re {stopping worker w1}\n" &
  #       "expect -re {terminal w1: stopped}\n" &
  #       "send -- \"\\003/quit\\r\"\n" &
  #       "expect eof\n"
  #     let ran = execCmdOnce(
  #       "/usr/bin/expect -c " & shellQuote(expectScript) &
  #       " >/dev/null 2>&1")
  #     let output = readFile(outputFile)
  #     if ran.exitCode != 0: checkpoint output
  #     check ran.exitCode == 0
  #     check fileExists(viProof)
  #     # vi terminates the last line with the standard trailing newline.
  #     check readFile(viProof).strip() == "C8_VI_ALT_SCREEN"
  #     check "\e]52;c;C8_CLIPBOARD" notin output
  #     check fileExists(foregroundPid)
  #     let childPid = Pid(parseInt(readFile(foregroundPid).strip()))
  #     var alive = kill(childPid, 0) == 0
  #     let deadline = getMonoTime() + initDuration(seconds = 2)
  #     while alive and getMonoTime() < deadline:
  #       sleep(10)
  #       alive = kill(childPid, 0) == 0
  #     check not alive

  test "ai agent mediated shell panes deny detached workspace writers":
    buildGeneCli()
    let marker = "tmp/agent-detached-writer-must-not-run"
    removeFile(marker)
    defer: removeFile(marker)
    let command =
      "printf '/pane new shell\\n" &
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
      "printf '/pane new shell\\necho routed-to-shell\\n/workers\\n/1 close\\n/workers\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "routed-to-shell" in ran.output
    check "w1 shell idle pane=1 shell" in ran.output
    check "closed pane 1" in ran.output
    check "w1 shell idle headless shell" in ran.output

  test "ai agent worker input addresses shell and rejects remote REPL eval":
    buildGeneCli()
    let fixture = "examples/ai_agent/headless_process_input_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [active_application make_application_with_task
         application_close_pane application_send_worker_input
         user_item]
  from "./core.gene")
(import [open_shell_pane open_repl_pane]
  from "./tui.gene")
(var items (cell []))
(var transcript (cell ""))
(var memory (cell []))
(var app
  (make_application_with_task items transcript memory
    (fn [_type, _props] nil) (cell nil)))
(active_application ~ set app)
(var shell_pane (open_shell_pane))
(var shell shell_pane/worker)
(application_close_pane app shell_pane/id)
(var shell_result
  (application_send_worker_input app shell
    "printf top-secret-agent-token" "http"))
(while (!= (shell/current_task ~ get) nil) (sleep 10))
(var shell_history (shell/history ~ get))
(println $"shell=${shell_result} panes=${((app/local_surface/panes ~ get) ~ size)} adapter=${shell_history/0/adapter} output=${(shell/output ~ get)}")
(var denied
  (application_send_worker_input app shell "rm -rf tmp/gene-agent-remote-missing" "http"))
(println $"denied=${denied} task=${(shell/current_task ~ get)}")
(var repl_pane (open_repl_pane items transcript memory))
(var repl repl_pane/worker)
(application_close_pane app repl_pane/id)
(var repl_result (application_send_worker_input app repl "(+ 1 2)" "http"))
(while (!= (repl/current_task ~ get) nil) (sleep 10))
(var repl_history (repl/history ~ get))
(println $"repl=${repl_result} panes=${((app/local_surface/panes ~ get) ~ size)} adapter=${repl_history/0/adapter} output=${(repl/output ~ get)}")
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
    check "denied=error: operation_rejected: denied: destructive command was not confirmed task=nil" in ran.output
    # Slice C9: repl eval is in-process-only; remote callers get local_only.
    check "repl=error: local_only" in ran.output
    check "adapter=void" in ran.output

  test "ai agent model supervision tools use the application registries":
    buildGeneCli()
    let fixture = "examples/ai_agent/application_tools_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [make_application_with_task
         make_headless_application_with_task run_tool_call_in]
  from "./core.gene")
(import json [stringify])
(var events (cell []))
(fn emit [type props]
  ((events ~ get) ~ push! {^type type ^props props}))
(var app (make_application_with_task (cell []) (cell "") (cell []) emit
                                      (cell nil)))
(var context {^app app ^agent app/main_agent ^pane nil})
(var spawned
  (run_tool_call_in
    {^name "spawn_agent" ^call_id "s1"
     ^arguments (stringify {^assignment "review parser" ^title "reader"})}
    emit context))
(println $"spawn=${spawned/output} agents=${((app/agents ~ get) ~ size)}")
(var registered_agents (app/agents ~ get))
(var child_context {^app app ^agent registered_agents/1 ^pane nil})
(var recursive
  (run_tool_call_in
    {^name "spawn_agent" ^call_id "s2"
     ^arguments (stringify {^assignment "spawn recursively"})}
    emit child_context))
(println $"recursive=${recursive/output} agents=${((app/agents ~ get) ~ size)}")
(var opened
  (run_tool_call_in
    {^name "open_pane" ^call_id "p1"
     ^arguments (stringify {^kind "output" ^title "checks" ^text "ready\n"})}
    emit context))
(println $"worker=${opened/output} panes=${((app/local_surface/panes ~ get) ~ size)}")
(var appended
  (run_tool_call_in
    {^name "append_pane" ^call_id "p2"
     ^arguments (stringify {^pane_id 1 ^text "passed\n"})}
    emit context))
(println appended/output)
(var pane_list (app/local_surface/panes ~ get))
(var output_pane pane_list/0)
(println (output_pane/output ~ get))
(var closed
  (run_tool_call_in
    {^name "close_pane" ^call_id "p3"
     ^arguments (stringify {^pane_id 1})}
    emit context))
(println $"${closed/output} panes=${((app/local_surface/panes ~ get) ~ size)}")
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
(println $"headless=${headless_opened/output} workers=${((headless/workers ~ get) ~ size)} surface=${headless/local_surface}")
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

  test "ai agent opens stats event-tail and shared file-view workers":
    buildGeneCli()
    let command =
      "printf '/stats\\n/1 max\\n/tail worker_started\\n/pane new view examples/ai_agent/design.md\\n/pane new view /etc/passwd\\n/workers\\n/quit\\n' | " &
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
         restore_application_snapshot!
         application_drain_supervisor_inbox worker_history_push!]
  from "./core.gene")
(var restored_events (cell []))
(fn sink [type, props]
  ((restored_events ~ get) ~ push! type)
  {^type type ^^props})
(var first
  (make_application_with_task (cell []) (cell "") (cell []) sink (cell nil)))
(var agent
  (application_spawn_agent first "reviewer" "review reader" (cell [])
                           (cell "")))
(application_enqueue_supervisor_result! first agent "reader is sound")
(worker_history_push! first/main_agent "remote prompt" "http" nil)
(first/main_agent/current_operation ~ set
  {^task_id "t-before-restart" ^kind "agent_turn"})
(first/main_agent/input_reserved ~ set true)
(first/main_agent/status ~ set "working")
(var saved (application_snapshot first))
(var restored
  (make_application_with_task (cell []) (cell "") (cell []) sink (cell nil)))
(restore_application_snapshot! restored saved)
(var queued ((restored/supervisor_inbox ~ get) ~ size))
(application_drain_supervisor_inbox restored)
(println $"queued=${queued} empty=${((restored/supervisor_inbox ~ get) ~ size)} status=${(restored/main_agent/status ~ get)} reserved=${(restored/main_agent/input_reserved ~ get)} operation=${(restored/main_agent/current_operation ~ get)} events=${(stringify (restored_events ~ get))} history=${(stringify (restored/main_agent/history ~ get))} items=${(stringify (restored/main_agent/items ~ get))}")
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

  test "ai agent terminal results are structured linked unread and explicit":
    buildGeneCli()
    let fixture = "examples/ai_agent/structured_agent_result_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [active_application make_application application_spawn_agent
         application_begin_worker_operation!
         application_finish_agent_operation!
         application_inspect_agent_result!
         application_incorporate_agent_result!
         application_update_progress! application_snapshot
         restore_application_snapshot! application_find_agent
         application_stop_agent agent_result_report
         project_progress_report event_dropped_before]
  from "./core.gene")
(import str [contains?])
(var events (cell []))
(var next_v (cell 1))
(fn sink [type, props]
  (var event {^v (next_v ~ get) ^type type})
  (next_v ~ set (+ (next_v ~ get) 1))
  (for [key value] in props (event ~ put! key value))
  ((events ~ get) ~ push! event)
  event)
(var main_items (cell []))
(var main_transcript (cell ""))
(var app (make_application main_items main_transcript (cell []) sink))
(active_application ~ set app)
(var agent
  (application_spawn_agent app "reviewer" "review reader"
    (cell []) (cell "ready\n")))
(application_begin_worker_operation! app agent nil "agent_turn")
(var completed
  (application_finish_agent_operation!
    app agent "completed" "reader is sound" "" "" nil))
(var linked false)
(for event in (events ~ get)
  (if (== event/type "agent_finished")
    (for source in (events ~ get)
      (if (&& (== source/v event/source_v)
              (== source/type "worker_operation_finished"))
        (set linked true)))))
(application_inspect_agent_result! app agent)
(var inspected (agent/result ~ get))
(var before ((app/main_agent/items ~ get) ~ size))
(application_incorporate_agent_result! app agent)
(var once ((app/main_agent/items ~ get) ~ size))
(application_incorporate_agent_result! app agent)
(var twice ((app/main_agent/items ~ get) ~ size))
(application_begin_worker_operation! app agent nil "agent_turn")
(var failed
  (application_finish_agent_operation!
    app agent "failed" "" "TypeError" "bad tool value" nil))
(var stopped_agent
  (application_spawn_agent app "stop-test" "stop active agent"
    (cell []) (cell "ready\n")))
(application_begin_worker_operation! app stopped_agent nil "agent_turn")
(var stopped (application_stop_agent app stopped_agent))
(var stopped_result (stopped_agent/result ~ get))
# A cancelled Task's later ensure must reuse the terminal result rather than
# emitting a second agent boundary.
(application_finish_agent_operation!
  app stopped_agent "cancelled" "" "cancelled" "late cleanup" nil)
(var finished_count 0)
(var stopped_linked false)
(for event in (events ~ get)
  (if (== event/type "agent_finished")
    (set finished_count (+ finished_count 1)))
  (if (&& (== event/type "agent_finished")
          (== event/agent_id stopped_agent/id))
    (for source in (events ~ get)
      (if (&& (== source/v event/source_v)
              (== source/task_id event/task_id)
              (== source/type "worker_operation_finished"))
        (set stopped_linked true)))))
(application_update_progress! app "ship C3" "verifying" "active"
  "checking results" nil nil [agent/id] [] [failed/finished_v])
(var saved (application_snapshot app))
(var restored
  (make_application (cell []) (cell "") (cell []) sink))
(restore_application_snapshot! restored saved)
(event_dropped_before ~ set 1000)
(var restored_agent (application_find_agent restored agent/id))
(var restored_result (restored_agent/result ~ get))
(var result_expired (contains? (agent_result_report restored_agent)
                               "evidence expired"))
(var progress_expired (contains? (project_progress_report restored)
                                 "evidence expired"))
(var unread (== completed/read false))
(var once_added (- once before))
(var twice_added (- twice once))
(var notice (contains? (main_transcript ~ get) "/agent a1 result"))
(println $"completed=${completed/outcome} unread=${unread} linked=${linked} inspected=${inspected/read} once=${once_added} twice=${twice_added} failed=${failed/outcome} error=${failed/error/kind} notice=${notice} stopped=${stopped} stopped_outcome=${stopped_result/outcome} stopped_linked=${stopped_linked} finishes=${finished_count} restored=${restored_result/outcome} result_expired=${result_expired} progress_expired=${progress_expired}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "completed=completed unread=true linked=true inspected=true" in ran.output
    check "once=1 twice=0 failed=failed error=TypeError notice=true" in ran.output
    check "stopped=true stopped_outcome=cancelled stopped_linked=true finishes=3" in ran.output
    check "restored=failed result_expired=true progress_expired=true" in ran.output

  test "ai agent restore isolates malformed records across every saved section":
    buildGeneCli()
    let fixture = "examples/ai_agent/restore_isolation_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [active_application make_application application_spawn_agent
         application_attach_worker_pane
         application_attach_worker_pane_as application_snapshot
         surface_snapshot restore_application_snapshot!
         restore_surface_snapshot!]
  from "./core.gene")
(import [open_shell_pane open_repl_pane open_output_pane
         open_log_tail_pane open_stats_pane open_file_view_pane]
  from "./tui.gene")
(import json [parse stringify])
(var first
  (make_application (cell []) (cell "main survives\n") (cell [])
    (fn [_type, _props] nil)))
(active_application ~ set first)
(var child
  (application_spawn_agent first "reviewer" "review" (cell [])
    (cell "ready\n")))
(application_attach_worker_pane first child child/id "detach")
(application_attach_worker_pane_as first child child/id "detach" "review mirror")
(open_shell_pane)
(open_repl_pane first/main_agent/items first/main_agent/transcript (cell []))
(open_output_pane "notes")
(open_log_tail_pane "worker_started")
(open_stats_pane)
(open_file_view_pane "examples/ai_agent/design.md")
(var saved (application_snapshot first))
(var saved_surface (surface_snapshot first))
(saved/main_worker ~ put! "result" {^outcome 7})
(saved/agents ~ push! {^id "bad-agent" ^title 7})
(saved/workers ~ push!
  {^id "bad-worker" ^kind "unknown" ^title "bad"})
(var bad_output_worker (parse (stringify saved/workers/0)))
(bad_output_worker ~ put! "id" "bad-output")
(bad_output_worker ~ put! "output" 7)
(saved/workers ~ push! bad_output_worker)
(saved_surface/panes ~ push!
  {^id 99 ^worker_id "missing" ^kind "output"})
(var bad_scroll_pane (parse (stringify saved_surface/panes/0)))
(bad_scroll_pane ~ put! "id" 98)
(bad_scroll_pane ~ put! "scroll" "bad")
(saved_surface/panes ~ push! bad_scroll_pane)
(saved ~ put! "progress" {^objective 7})
(saved_surface/surface ~ put! "next_pane_id" "bad-counter")
(var rejected (cell []))
(var next_v (cell 1))
(fn sink [type, props]
  (var event {^v (next_v ~ get) ^type type})
  (next_v ~ set (+ (next_v ~ get) 1))
  (for [key value] in props (event ~ put! key value))
  (if (== type "restore_record_rejected")
    ((rejected ~ get) ~ push!
      $"${props/record_kind}:${props/record_id}:${props/error_text}"))
  event)
(var restored
  (make_application (cell []) (cell "") (cell []) sink))
(restore_application_snapshot! restored saved)
(restore_surface_snapshot! restored saved_surface)
(var kinds [])
(var titles [])
(for worker in (restored/workers ~ get)
  (if (!= worker/id "main") (kinds ~ push! worker/kind)))
(for pane in (restored/local_surface/panes ~ get)
  (titles ~ push! pane/title))
(println $"main=${(restored/main_agent/transcript ~ get)} agents=${((restored/agents ~ get) ~ size)} panes=${((restored/local_surface/panes ~ get) ~ size)} kinds=${(stringify kinds)} titles=${(stringify titles)} rejected=${(stringify (rejected ~ get))}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "main=main survives" in ran.output
    check "agents=2 panes=8" in ran.output
    check "review mirror" in ran.output
    for kind in ["agent", "shell", "repl", "output", "log_tail",
                 "stats", "file_view"]:
      check "\"" & kind & "\"" in ran.output
    for rejected in ["agent:bad-agent", "worker:bad-worker", "pane:99",
                     "result:main", "worker:bad-output", "pane:98",
                     "progress:main", "surface:local_tui"]:
      check rejected in ran.output

  test "ai agent shell remains usable while a sub-agent operation runs":
    buildGeneCli()
    let fixture = "examples/ai_agent/concurrent_shell_agent_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [active_application make_application_with_task
         application_spawn_agent application_begin_worker_operation!
         application_cancel_worker
         application_finish_worker_operation!]
  from "./core.gene")
(import [open_shell_pane run_shell_pane_command_unchecked]
  from "./tui.gene")
(var app
  (make_application_with_task (cell []) (cell "") (cell [])
    (fn [_type, _props] nil) (cell nil)))
(active_application ~ set app)
(var agent
  (application_spawn_agent app "reviewer" "review" (cell []) (cell "")))
(var agent_task (spawn (sleep 500)))
(application_begin_worker_operation! app agent agent_task "agent_turn")
(var shell (open_shell_pane))
(var result (run_shell_pane_command_unchecked shell "printf shell-ready"))
(println $"agent_busy=${(!= (agent/current_task ~ get) nil)} result=${result}")
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
(import [active_application make_application_with_task
         application_emit]
  from "./core.gene")
(import [open_log_tail_pane handle_surface_escape!]
  from "./tui.gene")
(var app
  (make_application_with_task (cell []) (cell "") (cell [])
    (fn [type, props]
      (var event {^type type ^v 1 ^turn 1})
      (for [key value] in props (event ~ put! key value))
      event)
    (cell nil)))
(active_application ~ set app)
(var pane (open_log_tail_pane "check"))
(app/local_surface/maximized_pane ~ set pane/id)
(application_emit app "check"
  {^command "nimble test" ^status 0 ^verified true})
(var editor {^values (cell [])})
(var restored (handle_surface_escape! editor))
(println $"followed=${(contains? (pane/output ~ get) \"nimble test\")} restored=${restored} max=${(app/local_surface/maximized_pane ~ get)}")
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
(import [make_application_with_task application_open_pane]
  from "./core.gene")
(import [application_pane_views application_scroll_target!
         application_pane_page_rows]
  from "./tui.gene")
(var app
  (make_application_with_task (cell []) (cell "") (cell [])
    (fn [_type, _props] nil) (cell nil)))
(var pane
  (application_open_pane app "output" nil "checks" (cell "ready\n") nil
                         "detach"))
(var main_scroll (cell 0))
(application_scroll_target! app main_scroll 1 3)
(var views (application_pane_views app))
(println $"focused=${(app/local_surface/focused_pane ~ get)} pane=${views/0/scroll} main=${(main_scroll ~ get)} title=${views/0/title}")
(println $"page=${(application_pane_page_rows app 18)}")
(application_scroll_target! app main_scroll -1 3)
(app/local_surface/focused_pane ~ set nil)
(application_scroll_target! app main_scroll 1 4)
(println $"pane=${(pane/scroll ~ get)} main=${(main_scroll ~ get)}")
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
         application_release_workspace application_shutdown]
  from "./core.gene")
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
(var owner_after_foreign (a/workspace_coordinator/owner ~ get))
(var waiting (spawn (application_acquire_workspace b "main" "edit")))
(sleep 25)
(waiting ~ cancel)
# Cancellation is a control signal and deliberately bypasses `catch _`.
# Give the task's `ensure` cleanup a scheduler turn instead of awaiting it.
(sleep 25)
(println $"owner=${(a/workspace_coordinator/owner ~ get)} foreign=${foreign_release} preserved=${(== owner_after_foreign (a/workspace_coordinator/owner ~ get))} waiters=${((a/workspace_coordinator/waiters ~ get) ~ size)}")
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
  from "./core.gene")
(fn sink [_type, _props] nil)
(var a (make_application_with_task (cell []) (cell "") (cell []) sink
                                   (cell nil)))
(var b (make_application_with_task (cell []) (cell "") (cell []) sink
                                   (cell nil)))
(var confirming (cell false))
(var result (cell nil))
(var task
  (spawn
    (result ~ set
      (run_tool_call_in
        {^name "run_shell" ^call_id "guard-order"
         ^arguments "{\"command\":\"rm -rf tmp/guard-order-target\"}"}
        sink
        {^app a ^agent a/main_agent
         ^guard_confirm (fn [_command]
           (confirming ~ set true)
           (sleep 100)
           false)}))))
(while (! (confirming ~ get)) (sleep 1))
(application_acquire_workspace b "worker-b" "edit")
(println $"owner=${(a/workspace_coordinator/owner ~ get)}")
(application_release_workspace b "worker-b" "edit")
(await task)
(println (result ~ get)/output)
(var checked {^command "echo stable" ^timeout_ms 1000 ^_emit sink})
(preflight_tool_mutation "run_shell" checked nil)
(var preflight_valid (mutation_preflight_valid? "run_shell" checked))
(println $"preflight=${preflight_valid}")
(checked ~ put! "command" "echo changed")
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
  from "./core.gene")
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
(import [active_application make_application_with_task
         set_guard_confirm application_cancel_worker
         application_shutdown]
  from "./core.gene")
(import [open_shell_pane run_shell_pane_command]
  from "./tui.gene")
(fn sink [_type, _props] nil)
(var app
  (make_application_with_task (cell []) (cell "") (cell []) sink (cell nil)))
(active_application ~ set app)
(var pane (open_shell_pane))
(set_guard_confirm
  (fn [_command]
    (println $"cancelled=${(application_cancel_worker app pane/worker)}")
    true))
(var result
  (run_shell_pane_command pane
    "rm -rf tmp/preflight-cancel-target; touch tmp/preflight-cancel-must-not-run"))
(println result)
(app/main_agent/input_reserved ~ set true)
(application_shutdown app)
(println $"shutdown_reserved=${(app/main_agent/input_reserved ~ get)}")
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
(import [preflight_tool_mutation]
  from "./core.gene")
(fn sink [_type, _props] nil)
(var confirmations (cell 0))
(var args
  {^command "rm -rf tmp/single-confirmation-target"
   ^timeout_ms 1000 ^_emit sink})
(var denial
  (preflight_tool_mutation "run_shell" args
    {^guard_confirm (fn [_command]
      (confirmations ~ set (+ (confirmations ~ get) 1))
      true)}))
(println $"confirmations=${(confirmations ~ get)} allowed=${(== denial nil)}")
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
(import [active_application make_application_with_task
         application_open_pane]
  from "./core.gene")
(import [handle_surface_escape!]
  from "./tui.gene")
(var app
  (make_application_with_task (cell []) (cell "") (cell [])
    (fn [_type, _props] nil) (cell nil)))
(active_application ~ set app)
(application_open_pane app "output" nil "checks" (cell "") nil "detach")
(app/local_surface/maximized_pane ~ set 1)
(var editor {^values (cell ["x"])})
(println $"max=${(handle_surface_escape! editor)} focus=${(app/local_surface/focused_pane ~ get)} zoom=${(app/local_surface/maximized_pane ~ get)}")
(println $"draft=${(handle_surface_escape! editor)} focus=${(app/local_surface/focused_pane ~ get)}")
(editor/values ~ set [])
(println $"empty=${(handle_surface_escape! editor)} focus=${(app/local_surface/focused_pane ~ get)}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "max=true focus=1 zoom=nil" in ran.output
    check "draft=false focus=1" in ran.output
    check "empty=true focus=nil" in ran.output

  test "ai agent pane cycling retargets the live editor without losing drafts":
    buildGeneCli()
    let fixture = "examples/ai_agent/editor_route_cycle_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [active_application make_application_with_task
         application_open_pane application_shutdown]
  from "./core.gene")
(import [application_cycle_visible_pane! surface_route_draft
         surface_route_history editor_sync_focused_route!
         editor_set_text! editor_text]
  from "./tui.gene")
(var app
  (make_application_with_task (cell []) (cell "") (cell [])
    (fn [_type, _props] nil) (cell nil)))
(active_application ~ set app)
(application_open_pane app "output" nil "one" (cell "") nil "detach")
(application_open_pane app "output" nil "two" (cell "") nil "detach")
(app/local_surface/focused_pane ~ set 1)
(var first_draft (surface_route_draft app))
(var first_history (surface_route_history app))
(var editor
  {^values (cell ["edited" "-" "one"]) ^cursor (cell 3)
   ^history (first_history ~ get)
   ^history_index (cell ((first_history ~ get) ~ size))
   ^draft first_draft ^paste (cell false) ^terminal_pane nil
   ^terminal_direct (cell false) ^overlay (cell nil)})
(application_cycle_visible_pane! app 1)
(editor_sync_focused_route! editor)
(println $"to_two focus=${(app/local_surface/focused_pane ~ get)} first=${(first_draft ~ get)} current=${(editor_text (editor/values ~ get))}")
(editor_set_text! editor "edited-two")
(var second_draft editor/draft)
(application_cycle_visible_pane! app 1)
(editor_sync_focused_route! editor)
(println $"to_main focus=${(app/local_surface/focused_pane ~ get)} second=${(second_draft ~ get)} current=${(editor_text (editor/values ~ get))}")
(editor_set_text! editor "edited-main")
(var main_draft editor/draft)
(application_cycle_visible_pane! app -1)
(editor_sync_focused_route! editor)
(println $"back_two focus=${(app/local_surface/focused_pane ~ get)} main=${(main_draft ~ get)} current=${(editor_text (editor/values ~ get))}")
(application_shutdown app)
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "to_two focus=2 first=edited-one current=" in ran.output
    check "to_main focus=nil second=edited-two current=" in ran.output
    check "back_two focus=2 main=edited-main current=edited-two" in ran.output

  test "ai agent TUI routes focused input and layers maximize Escape reset":
    when defined(macosx):
      buildGeneCli()
      let outputFile = cliDir / "agent_focus_escape_pty.out"
      let focusedProof = cliDir / "agent_focus_escape_focused"
      let historyProof = "tmp/agent_focus_escape_history"
      removeFile(outputFile)
      removeFile(focusedProof)
      removeFile(historyProof)
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
        "send -- \"/pane new shell\\r\"\n" &
        "after 350\n" &
        "send -- \"/0\\r\"\n" &
        "expect -re {focused main agent}\n" &
        "send -- \"/pane new shell\\r\"\n" &
        "expect -re {shell pane 1}\n" &
        # A literal leading slash reaches the shell only through `//`. The
        # accepted command must remain the shell's latest recall entry even
        # after presentation commands and an invalid command-shaped typo.
        "send -- \"//usr/bin/printf H >> " & historyProof & "\\r\"\n" &
        "expect -re {\\[exit 0;}\n" &
        "expect -re {idle\\] Enter run}\n" &
        "send -- \"/pane list\\r\"\n" &
        "expect -re {lifecycle=running}\n" &
        "send -- \"/focus typo\\r\"\n" &
        "expect -re {literal leading-slash input}\n" &
        "send -- \"\\033\\[A\\r\"\n" &
        "expect -re {\\[exit 0;}\n" &
        "expect -re {idle\\] Enter run}\n" &
        "send -- \"touch " & focusedProof & "\\r\"\n" &
        "expect -re {\\[exit 0}\n" &
        "expect -re {idle\\] Enter run}\n" &
        # Shell-pane input is classified even on a live TTY. The destructive
        # confirmation itself uses the async curses editor, then the accepted
        # command runs without a second legacy prompt.
        "send -- \"rm -rf tmp/gene-agent-pty-confirm-missing && echo CONFIRM_DONE\\r\"\n" &
        "expect -re {run it once\\? \\[y/N\\]}\n" &
        "send -- \"y\\r\"\n" &
        # Repaints can repeat an earlier `[exit 0]`; wait for output unique to
        # this accepted command, then for its terminal operation boundary,
        # before manipulating the pane.
        "expect -re {idle\\] Enter run}\n" &
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
        "expect -re {42\\[exit 0;}\n" &
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
      # The Expect script retains its 15-second per-step timeout. Allow extra
      # time here for application shutdown when the full suite leaves the host
      # under load; this outer bound must not kill an already-closing session.
      let exitCode = terminal.waitForExit(30000)
      sleep(100)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check fileExists(focusedProof)
      check readFile(historyProof) == "HH"
      check "DRAFT_RESULT_" in output
      # Curses differential captures can begin after the opening bracket was
      # painted; the stable route/status payload still proves the focused
      # worker is named in the input row.
      check "1 shell w1:" in output
      check "//literal slash" in output
      check "[0 main]" in output
      check "\e[?1049l" in output
      removeFile(focusedProof)
      removeFile(historyProof)

  test "ai agent Ctrl-C clears drafts and Ctrl-D exits":
    when defined(macosx):
      buildGeneCli()
      let outputFile = cliDir / "agent_ctrl_c_d_pty.out"
      removeFile(outputFile)
      let inner =
        "stty rows 18 cols 100; exec /usr/bin/env " &
        "-u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
        "CODEX_ACCESS_TOKEN=dummy TERM=xterm-256color " &
        shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
      let expectScript =
        "set timeout 15\n" &
        "log_file -noappend " & outputFile & "\n" &
        "spawn /bin/sh -c {" & inner & "}\n" &
        "after 500\n" &
        "send -- \"/pane output clear-test\\r\"\n" &
        "expect -re {opened output pane 1}\n" &
        "send -- \"discard-this-draft\"\n" &
        "after 150\n" &
        "send -- \"\\003\"\n" &
        "after 250\n" &
        "send -- \"/1 close\\r\"\n" &
        "expect -re {closed pane 1}\n" &
        # Ctrl-C on an empty draft is a no-op, not process termination.
        "send -- \"\\003\"\n" &
        "after 250\n" &
        "send -- \"\\004\"\n" &
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
      check "opened output pane 1" in output
      check "closed pane 1" in output
      check "\e[?1049l" in output

  test "ai agent coalesces rapid child events without losing routed input":
    when defined(macosx):
      buildGeneCli()
      let fixture = "examples/ai_agent/repaint_stress_test.gene"
      let outputFile = cliDir / "agent_repaint_stress_pty.out"
      defer:
        if fileExists(fixture): removeFile(fixture)
      removeFile(outputFile)
      writeFile(fixture, """
(import [active_application application_emit
         application_find_worker_kind]
  from "./core.gene")
(import [refresh_active_input run_repl]
  from "./tui.gene")

(fn main [_args]
  (var burst
    (spawn
      (do
        (while (== (active_application ~ get) nil) (sleep 5))
        (var app (active_application ~ get))
        (while (== (application_find_worker_kind app "shell") nil) (sleep 5))
        (sleep 50)
        (repeat i in 300
          (application_emit app "tool_call"
            {^worker_id "a-stress" ^agent_id "a-stress"
             ^tool_call_id $"rapid-${i}" ^name "grep"})
          (refresh_active_input)
          (sleep 1)))))
  (burst ~ detach)
  (run_repl))
""")
      let inner =
        "stty rows 18 cols 90; exec /usr/bin/env " &
        "-u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY -u GENE_AGENT_HOME " &
        "CODEX_ACCESS_TOKEN=dummy GENE_AGENT_STATE= TERM=xterm-256color " &
        shellQuote(geneExe) & " run " & shellQuote(fixture)
      let expectScript =
        "set timeout 15\n" &
        "set send_slow {1 0.004}\n" &
        "log_file -noappend " & outputFile & "\n" &
        "spawn /bin/sh -c {" & inner & "}\n" &
        "after 500\n" &
        "send -- \"/tail tool_call\\r\"\n" &
        "expect -re {opened event tail pane 1}\n" &
        "send -- \"/pane new shell\\r\"\n" &
        "expect -re {shell pane 2}\n" &
        "send -s -- \"printf RAPID_INPUT_OK\"\n" &
        "send -- \"\\r\"\n" &
        "expect -re {idle\\] Enter run}\n" &
        "send -- \"/quit\\r\"\n" &
        "expect eof\n"
      let command = "/usr/bin/expect -c " & shellQuote(expectScript) &
                    " >/dev/null 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      let started = getMonoTime()
      let exitCode = terminal.waitForExit(20000)
      let elapsedMs = (getMonoTime() - started).inMilliseconds
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check elapsedMs < 10000
      check "RAPID_INPUT_OK" in output
      check "tool_call grep" in output
      check "2 shell w2:" in output
      check "\e[?1049l" in output

  test "ai agent worker output drops oldest bytes with explicit loss metadata":
    buildGeneCli()
    let fixture = "examples/ai_agent/worker_output_bound_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [make_application_with_task application_new_worker
         application_append_worker_output!
         application_set_projection_output!]
  from "./core.gene")
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
(println (worker/output ~ get))
(println $"bytes=${(byte_size (worker/output ~ get))} dropped=${(worker/dropped_bytes ~ get)} before=${(worker/dropped_before ~ get)}")
(application_set_projection_output! app worker "fresh" "stats")
(println $"replacement=${(worker/output ~ get)} dropped=${(worker/dropped_bytes ~ get)} before=${(worker/dropped_before ~ get)}")
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
(import [active_application make_application_with_task
         application_workers_snapshot]
  from "./core.gene")
(import [append_transcript]
  from "./tui.gene")
(var app
  (make_application_with_task (cell []) (cell "") (cell [])
    (fn [_type, _props] nil) (cell nil)))
(active_application ~ set app)
(append_transcript app/main_agent/transcript
  "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-more")
(append_transcript app/main_agent/transcript
  "-second-abcdefghijklmnopqrstuvwxyz")
(var snapshots (application_workers_snapshot app))
(var snapshot snapshots/0)
(println (app/main_agent/transcript ~ get))
(println $"bytes=${(byte_size (app/main_agent/transcript ~ get))} dropped=${snapshot/transcript_dropped_bytes} before=${snapshot/transcript_dropped_before} seq=${snapshot/transcript_seq}")
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
(import [active_application make_application_with_task
         application_emit]
  from "./core.gene")
(import [open_stats_pane open_log_tail_pane]
  from "./tui.gene")
(var emitted (cell []))
(fn sink [type, props]
  (var event {^v (+ ((emitted ~ get) ~ size) 1) ^type type})
  (for [key value] in props (event ~ put! key value))
  ((emitted ~ get) ~ push! event)
  event)
(var app
  (make_application_with_task (cell []) (cell "") (cell []) sink (cell nil)))
(active_application ~ set app)
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
(for event in (emitted ~ get)
  (if (== event/projection true) (set projected (+ projected 1)) nil)
  (if (== event/type "check") (set source_checks (+ source_checks 1)) nil)
  (if (&& (== event/type "worker_output") (!= event/source_v nil))
    (set aliased true) nil)
  (if (== event/type "worker_output")
    (set worker_chunks (+ worker_chunks 1)) nil))
(println $"projected=${projected} checks=${source_checks} aliased=${aliased} chunks=${worker_chunks} events=${((emitted ~ get) ~ size)}")
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
         application_workers_snapshot]
  from "./core.gene")
(import [application_pane_views main_presented_output]
  from "./tui.gene")
(import json [stringify])
(var app
  (make_application_with_task (cell []) (cell "") (cell [])
    (fn [_type, _props] nil) (cell nil)))
(var pane
  (application_open_pane app "output" nil "checks" (cell "ready") nil
                         "detach"))
(var before (stringify (application_workers_snapshot app)))
(app/local_surface/focused_pane ~ set pane/id)
(app/local_surface/maximized_pane ~ set pane/id)
(pane/scroll ~ set 99)
(var after (stringify (application_workers_snapshot app)))
(println $"same=${(== before after)} local_field=${(contains? after \"attached_local_pane\")}")
(var agent
  (application_spawn_agent app "review" "task" (cell []) (cell "ready")))
(var agent_pane
  (application_attach_worker_pane app agent agent/id "detach"))
(println $"agent_field=${(== agent/pane_ids void)} local_ids=${(application_pane_ids_for_worker app agent/id)}")
(agent/output ~ set "agent> steered")
(agent_pane/pending_visible ~ set true)
(var presented (application_pane_views app))
(app/main_agent/transcript ~ set "agent> steered")
(app/local_surface/main_pending_visible ~ set true)
(var pane_overlay
  (contains? presented/1/output "agent> steered\nagent> ..."))
(var main_overlay
  (contains? (main_presented_output app app/main_agent/transcript)
             "agent> steered\nagent> ..."))
(println $"pane_overlay=${pane_overlay} canonical=${(agent/output ~ get)} main_overlay=${main_overlay} main_canonical=${(app/main_agent/transcript ~ get)}")
(agent_pane/pending_visible ~ set false)
(app/local_surface/main_pending_visible ~ set false)
(var final_pane (application_pane_views app))
(println $"pane_final=${final_pane/1/output} main_final=${(main_presented_output app app/main_agent/transcript)}")
(app/local_surface/maximized_pane ~ set agent_pane/id)
(application_close_pane app agent_pane/id)
(println $"detached_ids=${(application_pane_ids_for_worker app agent/id)} max=${(app/local_surface/maximized_pane ~ get)}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "same=true local_field=false" in ran.output
    check "agent_field=true local_ids=[2]" in ran.output
    check "pane_overlay=true canonical=agent> steered main_overlay=true main_canonical=agent> steered" in ran.output
    check "pane_final=agent> steered main_final=agent> steered" in ran.output
    check "detached_ids=[] max=nil" in ran.output

  test "ai agent live worker and agent bounds are configurable":
    buildGeneCli()
    let fixture = "examples/ai_agent/live_worker_bound_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [make_application_with_task application_new_worker
         application_spawn_agent]
  from "./core.gene")
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
(import [active_application make_application_with_task
         application_stop_worker]
  from "./core.gene")
(import [open_shell_pane]
  from "./tui.gene")
(fn emit [type, props]
  (if (== type "worker_started")
    (println $"started=${props/worker_id} from=${props/restarted_from}") nil))
(var app
  (make_application_with_task (cell []) (cell "") (cell []) emit (cell nil)))
(active_application ~ set app)
(var first (open_shell_pane))
(first/worker/output ~ set "captured history\n")
(application_stop_worker app first/worker)
(var second (open_shell_pane))
(println $"old=${first/worker_id}:${(first/worker/lifecycle ~ get)}:${(first/output ~ get)} new=${second/worker_id}:${(second/worker/lifecycle ~ get)}")
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
         application_stop_worker application_find_worker]
  from "./core.gene")
(var dropped (cell []))
(fn emit [type, props]
  (if (== type "worker_retention_dropped")
    ((dropped ~ get) ~ push! props/worker_id) nil))
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
(println $"workers=${((app/workers ~ get) ~ size)} dropped=${(dropped ~ get)} w1=${w1} w4=${w4/id}")
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
(import [bounded_event_record]
  from "./core.gene")
(import json [stringify])
(import str [byte_size join])
(var pieces [])
(repeat i in 2400 (pieces ~ push! "x"))
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
(import [external_editor_draft]
  from "./tui.gene")
(var ticks (cell 0))
(var composed (cell ""))
(scope
  (spawn (repeat 5 (do (sleep 20)
    (ticks ~ set (+ (ticks ~ get) 1)))))
  (composed ~ set (external_editor_draft "seed")))
(println (composed ~ get))
(println $"ticks=${(ticks ~ get)}")
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
        "expect {Enter send}\n" &
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
      let editorAtt = execCmdEx(
        "curl -sS -H 'Authorization: Bearer editor-gateway' -X POST " &
        "http://127.0.0.1:8996/api/sessions/local/attachments")
      check editorAtt.exitCode == 0
      let editorAttId = parseJson(editorAtt.output)["attachment_id"].getStr()
      proc editorGatewayCurl(call: string): string =
        let ran = execCmdEx(
          "curl -sS -H 'Authorization: Bearer editor-gateway' " &
          "-H 'X-Gene-Attachment: " & editorAttId & "' " & call)
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

  test "ai agent accepts exit as a quit alias":
    buildGeneCli()
    let command = "printf '/exit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0

  test "ai agent opens, focuses, and closes secondary-agent panes":
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
    let command = "(printf '/agent new\\n/0   \\n/1\\n/1 inspect this\\n'; sleep 1; " &
                  "printf '/worker a1 tail\\n/close\\n/close 0\\n/quit\\n') | " &
                  "env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
                  "OPENAI_AUTH_TOKEN=dummy OPENAI_API=chat " &
                  "OPENAI_BASE_URL=http://127.0.0.1:8958/v1 " &
                  "OPENAI_MODEL=fake-chat " & shellQuote(geneExe) &
                  " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "opened agent a1 in pane 1" in ran.output
    check "focused main agent" in ran.output
    check "focused pane 1" in ran.output
    check "extension 1 completed" in ran.output
    # The agent pane transcript follows pane 0's turn pattern: ──────
    # separator, verbatim input, then agent>-prefixed response text.
    check "──────\ninspect this" in ran.output
    check "agent> extension-ok" in ran.output
    check "user|" notin ran.output
    check "closed pane 1" in ran.output
    check "pane 0 cannot be closed" in ran.output
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
    (body ~ set $"${(body ~ get)}data: ${(stringify chunk)}\n\n"))
  $"${(body ~ get)}data: [DONE]\n\n")

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

  test "ai agent pane export writes pane and transcript content":
    buildGeneCli()
    let replOut = "tmp/agent-export-repl.txt"
    let mainOut = "tmp/agent-export-main.txt"
    defer:
      if fileExists(replOut): removeFile(replOut)
      if fileExists(mainOut): removeFile(mainOut)
    if fileExists(replOut): removeFile(replOut)
    if fileExists(mainOut): removeFile(mainOut)
    let command = "printf '/repl\\n/1 (+ 40 2)\\n/0\\n/1 export " & replOut &
                  "\\n/export " & mainOut & "\\n/1 export " & replOut &
                  "\\n/1 export /etc/evil.txt\\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    check "exported pane 1 repl" in ran.output
    check "exported main transcript" in ran.output
    # Second export to the same path refuses to overwrite; absolute paths
    # stay workspace-confined like every other surface file path.
    check "already exists" in ran.output
    check "unsafe path rejected (absolute)" in ran.output
    check fileExists(replOut)
    check "42" in readFile(replOut)
    check "REPL pane 1" in readFile(mainOut)

  test "ai agent persists config session and memory":
    buildGeneCli()
    let stateDir = cliDir / "ai_agent_state"
    if dirExists(stateDir):
      removeDir(stateDir)

    let first = execCmdOnce(
      "printf '/remember project uses Gene\\n/model persisted-main\\n/effort xhigh\\n/status\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
      "-u OPENAI_REASONING_EFFORT " &
      "CODEX_ACCESS_TOKEN=dummy GENE_AGENT_STATE=" & shellQuote("fs:" & stateDir) &
      " " & shellQuote(geneExe) & " run examples/ai_agent/tui.gene")
    check first.exitCode == 0
    check "remembered: project uses Gene" in first.output
    check "state: " & stateDir in first.output
    check "memory: 1" in first.output
    check "main agent model set to persisted-main" in first.output
    check "reasoning effort set to xhigh" in first.output
    check "effort: xhigh" in first.output
    let configText = readFile(agentStateRecordPath(stateDir, "config"))
    check "^model \"persisted-main\"" in configText
    check "^reasoning_effort \"xhigh\"" in configText
    check "dummy" notin configText
    check "OPENAI_AUTH_TOKEN" notin configText
    check "CODEX_ACCESS_TOKEN" notin configText

    let second = execCmdOnce(
      "printf '/memory\\n/effort\\n/status\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
      "-u OPENAI_REASONING_EFFORT " &
      "CODEX_ACCESS_TOKEN=dummy GENE_AGENT_STATE=" & shellQuote("fs:" & stateDir) &
      " " & shellQuote(geneExe) & " run examples/ai_agent/tui.gene")
    check second.exitCode == 0
    check "memory:\nproject uses Gene" in second.output
    check "state: " & stateDir in second.output
    check "model: persisted-main" in second.output
    check "api: responses" in second.output
    check "current effort: xhigh" in second.output
    check "effort: xhigh" in second.output
    check "memory: 1" in second.output
    let sessionText = readFile(agentStateRecordPath(stateDir, "session"))
    check "/remember project uses Gene\\n" in sessionText
    check "/memory\\n" in sessionText
    check "agent> remembered: project uses Gene" in sessionText
    check "agent> memory:\\nproject uses Gene" in sessionText

    let overridden = execCmdOnce(
      "printf '/effort\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
      "OPENAI_REASONING_EFFORT=low CODEX_ACCESS_TOKEN=dummy " &
      "GENE_AGENT_STATE=" & shellQuote("fs:" & stateDir) & " " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene")
    check overridden.exitCode == 0
    check "current effort: low" in overridden.output

  test "ai agent serializes reasoning effort for both OpenAI wire shapes":
    buildGeneCli()
    let fixture = "examples/ai_agent/reasoning_effort_request_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [call_model]
  from "./core.gene")
(import json [parse stringify])
(var captured (cell nil))
(fn transport [body, render_stream]
  (captured ~ set (parse body))
  {^output []})
(call_model transport [] (fn [text] nil))
(println (stringify (captured ~ get)))
""")

    let responses = execCmdOnce(
      "env OPENAI_API=responses OPENAI_REASONING_EFFORT=high " &
      shellQuote(geneExe) & " run " & shellQuote(fixture))
    if responses.exitCode != 0:
      checkpoint responses.output
    check responses.exitCode == 0
    check "\"reasoning\":{\"effort\":\"high\"}" in responses.output
    check "reasoning_effort" notin responses.output

    let chat = execCmdOnce(
      "env OPENAI_API=chat OPENAI_REASONING_EFFORT=low " &
      shellQuote(geneExe) & " run " & shellQuote(fixture))
    if chat.exitCode != 0:
      checkpoint chat.output
    check chat.exitCode == 0
    check "\"reasoning_effort\":\"low\"" in chat.output
    check "\"reasoning\":" notin chat.output

    let defaultEffort = execCmdOnce(
      "env -u OPENAI_REASONING_EFFORT OPENAI_API=responses " &
      shellQuote(geneExe) & " run " & shellQuote(fixture))
    if defaultEffort.exitCode != 0:
      checkpoint defaultEffort.output
    check defaultEffort.exitCode == 0
    check "\"reasoning\":" notin defaultEffort.output
    check "reasoning_effort" notin defaultEffort.output

  test "ai agent switches models independently for main and pane agents":
    buildGeneCli()
    let command =
      "printf '/model\\n/model main-one\\n/model 0\\n/agent new\\n" &
      "/model 1\\n/model 1 child-two\\n/model 1\\n/agents\\n/status\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY -u GENE_AGENT_STATE " &
      "-u GENE_AGENT_HOME CODEX_ACCESS_TOKEN=dummy " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "main agent model: gpt-5.6-terra" in ran.output
    check "main agent model set to main-one" in ran.output
    check "pane 1 agent a1 model: main-one" in ran.output
    check "pane 1 agent a1 model set to child-two" in ran.output
    check "a1 model=child-two" in ran.output
    check "model: main-one" in ran.output

  test "ai agent persists and sends each agent model":
    buildGeneCli()
    let fixture = "examples/ai_agent/per_agent_model_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import json [parse stringify])
(import [application_call_worker application_find_agent application_snapshot
         call_model make_application_with_task application_spawn_agent
         restore_application_snapshot!]
  from "./core.gene")
(fn sink [_type, _props] nil)
(var first
  (make_application_with_task (cell []) (cell "") (cell []) sink (cell nil)))
(var main_changed
  (application_call_worker first "main" "set_model" {^model "main-one"}
    {^origin "user" ^caller_worker_id "main"}))
(var child
  (application_spawn_agent first "child" "review" (cell []) (cell "")))
(var inherited (child/model ~ get))
(var child_changed
  (application_call_worker first child/id "set_model" {^model "child-two"}
    {^origin "user" ^caller_worker_id "main"}))
(child/current_task ~ set "busy")
(var busy_change
  (application_call_worker first child/id "set_model" {^model "too-late"}
    {^origin "user" ^caller_worker_id "main"}))
(child/current_task ~ set nil)
(var saved (application_snapshot first))
(var restored
  (make_application_with_task (cell []) (cell "") (cell []) sink (cell nil)))
(restore_application_snapshot! restored saved)
(var restored_child (application_find_agent restored child/id))
(var requested [])
(fn transport [body, _render_stream]
  (var request (parse body))
  (requested ~ push! request/model)
  {^output []})
(call_model transport [] (fn [_text] nil)
  {^app restored ^agent restored/main_agent})
(call_model transport [] (fn [_text] nil)
  {^app restored ^agent restored_child})
(println
  $"changed=${main_changed/ok}/${child_changed/ok} busy=${busy_change/error/kind} inherited=${inherited} restored=${(restored/main_agent/model ~ get)}/${(restored_child/model ~ get)} requested=${(stringify requested)}")
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "changed=true/true busy=worker_busy inherited=main-one" in ran.output
    check "restored=main-one/child-two" in ran.output
    check "requested=[\"main-one\",\"child-two\"]" in ran.output

  test "ai agent checkpoints application state before graceful exit":
    buildGeneCli()
    let stateDir = cliDir / "ai-agent-checkpoint-state"
    if dirExists(stateDir):
      removeDir(stateDir)
    let agentArgs = ["-u", "OPENAI_AUTH_TOKEN", "-u", "OPENAI_API_KEY",
                     "-u", "GENE_AGENT_HOME", "CODEX_ACCESS_TOKEN=dummy",
                     "GENE_AGENT_STATE=fs:" & stateDir, geneExe, "run",
                     "examples/ai_agent/tui.gene"]
    let agentProc = startProcess("/usr/bin/env", args = agentArgs,
                                 options = {poUsePath, poStdErrToStdOut})
    defer:
      if agentProc.running: agentProc.terminate()
      agentProc.close()
    agentProc.inputStream.write("/pane output crash-safe\n")
    agentProc.inputStream.flush()

    # Worker lifecycle checkpoints the session store; the pane record lands in
    # the TUI's own client store (slice C9, invariant §0.13), never in session
    # checkpoints.
    let deadline = getMonoTime() + initDuration(seconds = 10)
    var checkpointReady = false
    let surfacePath = stateDir / "surface_local_tui" / "surface.gene"
    while getMonoTime() < deadline:
      let applicationPath = agentStateRecordPath(stateDir, "application")
      if fileExists(applicationPath) and fileExists(surfacePath):
        if "crash-safe" in readFile(applicationPath) and
            "crash-safe" in readFile(surfacePath):
          checkpointReady = true
          break
      sleep(25)
    check checkpointReady
    check "surface" notin readFile(agentStateRecordPath(stateDir, "checkpoint"))

    # Simulate a crash: no /quit, EOF, or application shutdown may perform the
    # ordinary final save.
    when defined(posix):
      discard kill(Pid(agentProc.processID), SIGKILL)
    else:
      agentProc.terminate()
    discard agentProc.waitForExit(5000)
    check "crash-safe" in
      readFile(agentStateRecordPath(stateDir, "application"))
    check "crash-safe" in readFile(surfacePath)

    let restored = execCmdOnce(
      "printf '/status\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY -u GENE_AGENT_HOME " &
      "CODEX_ACCESS_TOKEN=dummy GENE_AGENT_STATE=" &
      shellQuote("fs:" & stateDir) & " " & shellQuote(geneExe) &
      " run examples/ai_agent/tui.gene")
    if restored.exitCode != 0:
      checkpoint restored.output
    check restored.exitCode == 0
    check "panes: 1" in restored.output

  test "ai agent tool calls create durable checkpoints":
    buildGeneCli()
    let stateDir = cliDir / "ai-agent-tool-checkpoint"
    if dirExists(stateDir):
      removeDir(stateDir)
    let fixture = "examples/ai_agent/agent_tool_checkpoint_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [init_agent_state make_application active_application
         application_emit emit_event!]
  from "./core.gene")
(init_agent_state)
(var app (make_application (cell []) (cell "tool checkpoint\n")
                           (cell []) emit_event!))
(active_application ~ set app)
(application_emit app "tool_call"
  {^worker_id "main" ^agent_id "main" ^id "call-1"
   ^name "read_file" ^args {^path "README.md"}})
""")
    let ran = execCmdOnce(
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY -u GENE_AGENT_HOME " &
      "GENE_AGENT_STATE=" & shellQuote("fs:" & stateDir) & " " &
      shellQuote(geneExe) & " run " & shellQuote(fixture))
    if ran.exitCode != 0:
      checkpoint ran.output
    check ran.exitCode == 0
    check "^reason \"tool_call\"" in
      readFile(agentStateRecordPath(stateDir, "checkpoint"))
    check "^type \"tool_call\"" in
      readFile(agentStateRecordPath(stateDir, "events"))

  test "ai agent home restores application state only for the same home":
    buildGeneCli()
    let homeDir = cliDir / "ai-agent-home-state"
    let otherHome = cliDir / "ai-agent-other-home"
    for path in [homeDir, otherHome]:
      if dirExists(path):
        removeDir(path)

    let first = execCmdOnce(
      "printf '/pane output durable\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
      "-u GENE_AGENT_RESUME GENE_AGENT_STATE= " &
      "CODEX_ACCESS_TOKEN=dummy GENE_AGENT_HOME=" & shellQuote(homeDir) &
      " " & shellQuote(geneExe) & " run examples/ai_agent/tui.gene")
    if first.exitCode != 0:
      checkpoint first.output
    check first.exitCode == 0
    check "opened output pane 1" in first.output
    check fileExists(agentStateRecordPath(homeDir, "application"))
    let applicationText = readFile(agentStateRecordPath(homeDir, "application"))
    check "^kind \"output\"" in applicationText
    check "durable" in applicationText

    let restored = execCmdOnce(
      "printf '/status\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
      "-u GENE_AGENT_STATE -u GENE_AGENT_RESUME " &
      "CODEX_ACCESS_TOKEN=dummy GENE_AGENT_HOME=" & shellQuote(homeDir) &
      " " & shellQuote(geneExe) & " run examples/ai_agent/tui.gene")
    if restored.exitCode != 0:
      checkpoint restored.output
    check restored.exitCode == 0
    check "state: " & homeDir in restored.output
    check "panes: 1" in restored.output

    let isolated = execCmdOnce(
      "printf '/status\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
      "-u GENE_AGENT_STATE -u GENE_AGENT_RESUME " &
      "CODEX_ACCESS_TOKEN=dummy GENE_AGENT_HOME=" & shellQuote(otherHome) &
      " " & shellQuote(geneExe) & " run examples/ai_agent/tui.gene")
    if isolated.exitCode != 0:
      checkpoint isolated.output
    check isolated.exitCode == 0
    check "state: " & otherHome in isolated.output
    check "panes: 0" in isolated.output

  test "ai agent restores application state from sqlite":
    buildGeneCli()
    let dbPath = cliDir / "ai-agent-state.sqlite"
    if fileExists(dbPath):
      removeFile(dbPath)
    let stateSpec = "db:sqlite:" & dbPath

    let first = execCmdOnce(
      "printf '/pane output database\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
      "-u GENE_AGENT_HOME -u GENE_AGENT_RESUME " &
      "CODEX_ACCESS_TOKEN=dummy GENE_AGENT_STATE=" & shellQuote(stateSpec) &
      " " & shellQuote(geneExe) & " run examples/ai_agent/tui.gene")
    if first.exitCode != 0:
      checkpoint first.output
    check first.exitCode == 0
    check "opened output pane 1" in first.output
    check fileExists(dbPath)

    let restored = execCmdOnce(
      "printf '/status\\n/quit\\n' | " &
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
      "-u GENE_AGENT_HOME -u GENE_AGENT_RESUME " &
      "CODEX_ACCESS_TOKEN=dummy GENE_AGENT_STATE=" & shellQuote(stateSpec) &
      " " & shellQuote(geneExe) & " run examples/ai_agent/tui.gene")
    if restored.exitCode != 0:
      checkpoint restored.output
    check restored.exitCode == 0
    check "state: " & stateSpec in restored.output
    check "panes: 1" in restored.output

  test "ai agent pins deduplicated redacted artifacts and deletes explicitly":
    buildGeneCli()
    let stateDir = cliDir / "ai-agent-artifacts"
    if dirExists(stateDir):
      removeDir(stateDir)
    let first = execCmdOnce(
      "printf '/pane output evidence\n/1 append pin-secret\n" &
      "/pin worker w1 tail\n/pin worker w1 tail\n/artifacts\n/quit\n' | " &
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
      "CODEX_ACCESS_TOKEN=pin-secret GENE_AGENT_STATE=" &
      shellQuote("fs:" & stateDir) & " " & shellQuote(geneExe) &
      " run examples/ai_agent/tui.gene")
    if first.exitCode != 0: checkpoint first.output
    check first.exitCode == 0
    check "pinned artifact:1 sha256:" in first.output
    check "pinned artifact:2 sha256:" in first.output
    let pinnedLines = first.output.splitLines().filterIt(
      it.contains("pinned artifact:"))
    check pinnedLines.len == 2
    if pinnedLines.len == 2:
      check strutils.splitWhitespace(pinnedLines[0])[^1] ==
            strutils.splitWhitespace(pinnedLines[1])[^1]
    var blobCount = 0
    for path in walkFiles(stateDir / "blob*.gene"):
      inc blobCount
      check "pin-secret" notin readFile(path)
    check blobCount == 1

    let restored = execCmdOnce(
      "printf '/artifacts\n/artifact artifact:1\n" &
      "/artifact delete artifact:1\n/artifact artifact:2\n" &
      "/artifact delete artifact:2\n/artifacts\n/quit\n' | " &
      "env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
      "CODEX_ACCESS_TOKEN=pin-secret GENE_AGENT_STATE=" &
      shellQuote("fs:" & stateDir) & " " & shellQuote(geneExe) &
      " run examples/ai_agent/tui.gene")
    if restored.exitCode != 0: checkpoint restored.output
    check restored.exitCode == 0
    check "auth-***REDACTED***" in restored.output
    check "deleted artifact:1" in restored.output
    check "deleted artifact:2" in restored.output
    check "no artifacts" in restored.output

  test "ai agent restores ephemeral handlers disabled and exact refs enabled":
    buildGeneCli()
    let stateDir = cliDir / "ai-agent-handler-refs"
    if dirExists(stateDir):
      removeDir(stateDir)
    let fixture = "examples/ai_agent/handler_ref_restore_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import os [get_env Env])
(import [Tool HandlerRef Operation EmptyArgs OperationAck
         register_tool! register_worker_operation!
         worker_operation_for init_agent_state
         restore_dynamic_registrations! save_agent_state
         close_agent_state find_tool agent_events]
  from "./core.gene")
(var mode (get_env Env "HANDLER_MODE"))
(var exact (HandlerRef ^module "test/workflows" ^path "run"
                       ^version "sha256:exact"))
(register_tool! (Tool ^name "durable_check" ^description "durable"
  ^risk "read" ^params [] ^handler (fn [_args] "ok") ^handler_ref exact))
(register_worker_operation! "output"
  (Operation ^name "durable_op" ^summary "durable" ^usage "durable_op"
    ^args EmptyArgs ^result OperationAck ^errors [] ^effects ["observe"]
    ^audience ["local_user"] ^admission "none" ^audit "none"
    ^cancellable false ^idempotent true ^task_managed false
    ^primary_input false
    ^handler (fn [_a, _w, _o, _x, _i]
      (OperationAck ^accepted true ^text "ok"))
    ^parse_cli (fn [_text] {}) ^handler_ref exact))
(if (== mode "write")
  (do
    (register_tool! (Tool ^name "ephemeral_check" ^description "ephemeral"
      ^risk "read" ^params [] ^handler (fn [_args] "live")))
    (register_worker_operation! "output"
      (Operation ^name "ephemeral_op" ^summary "ephemeral"
        ^usage "ephemeral_op" ^args EmptyArgs ^result OperationAck ^errors []
        ^effects ["observe"] ^audience ["local_user"]
        ^admission "none" ^audit "none" ^cancellable false
        ^idempotent true ^task_managed false ^primary_input false
        ^handler (fn [_a, _w, _o, _x, _i]
          (OperationAck ^accepted true ^text "live"))
        ^parse_cli (fn [_text] {})))
    (init_agent_state)
    (save_agent_state [] "" [])
    (close_agent_state))
  (do
    (init_agent_state)
    (restore_dynamic_registrations! nil)
    (var ephemeral_tool (find_tool "ephemeral_check"))
    (var durable_tool (find_tool "durable_check"))
    (var ephemeral_op (worker_operation_for "output" "ephemeral_op"))
    (var durable_op (worker_operation_for "output" "durable_op"))
    (println "handlers" ephemeral_tool/enabled durable_tool/enabled
      ephemeral_op/enabled durable_op/enabled)
    (var rejections 0)
    (for event in (agent_events ~ get)
      (if (== event/type "restore_record_rejected")
        (set rejections (+ rejections 1))))
    (println "rejections" rejections)
    (close_agent_state)))
""")
    let common = " GENE_AGENT_STATE=" & shellQuote("fs:" & stateDir) &
                 " " & shellQuote(geneExe) & " run " & shellQuote(fixture)
    let wrote = execCmdOnce("env HANDLER_MODE=write" & common)
    if wrote.exitCode != 0: checkpoint wrote.output
    check wrote.exitCode == 0
    let restored = execCmdOnce("env HANDLER_MODE=read" & common)
    if restored.exitCode != 0: checkpoint restored.output
    check restored.exitCode == 0
    check "handlers false true false true" in restored.output
    check "rejections 2" in restored.output

  test "ai agent warns when another process owns the workspace advisory":
    buildGeneCli()
    let stateDir = cliDir / "ai-agent-workspace-owner"
    if dirExists(stateDir):
      removeDir(stateDir)
    let fixture = "examples/ai_agent/workspace_owner_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import os [get_env Env])
(import [init_agent_state start_workspace_heartbeat!
         close_agent_state]
  from "./core.gene")
(init_agent_state)
(start_workspace_heartbeat!)
(if (== (get_env Env "OWNER_MODE") "hold") (sleep 10000))
(close_agent_state)
""")
    let common = ["GENE_AGENT_STATE=fs:" & stateDir,
                  "OWNER_MODE=hold", geneExe, "run", fixture]
    let owner = startProcess("/usr/bin/env", args = common,
                             options = {poUsePath, poStdErrToStdOut})
    defer:
      if owner.running: owner.terminate()
      owner.close()
    let deadline = getMonoTime() + initDuration(seconds = 5)
    while getMonoTime() < deadline:
      var found = false
      for path in walkFiles(stateDir / "workspace*.gene"):
        found = fileExists(path)
      if found: break
      sleep(20)
    let second = execCmdOnce(
      "env OWNER_MODE=check GENE_AGENT_STATE=" &
      shellQuote("fs:" & stateDir) & " " & shellQuote(geneExe) &
      " run " & shellQuote(fixture))
    if second.exitCode != 0: checkpoint second.output
    check second.exitCode == 0
    check "WARNING: another Gene agent owns this workspace (pid " in
      second.output

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
(import gene/stream [to_stream map each into])

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

(serve (Server ^host "127.0.0.1" ^port 8996) handle ^max_requests 2)
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
    let ran = execCmdOnce(
                        "printf 'say hi\\n/agent new fail too\\n/agents\\n/agent a1 result\\n/trace type=agent_finished --detail\\n/quit\\n' | " &
                        "env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
                        "OPENAI_AUTH_TOKEN=dummy OPENAI_API=responses " &
                        "OPENAI_BASE_URL=http://127.0.0.1:8996 " &
                        "OPENAI_MODEL=fake-responses " &
                        shellQuote(geneExe) &
                        " run examples/ai_agent/tui.gene")
    check ran.exitCode == 0
    check "OpenAI API error 401: Unauthorized" in ran.output
    check ran.output.count("\"type\":\"agent_finished\"") == 2
    check "\"outcome\":\"failed\"" in ran.output
    check "\"error_kind\":\"AgentError\"" in ran.output
    check "\"source_v\":" in ran.output
    check "a1 model=fake-responses lifecycle=running availability=idle last=failed unread=true" in ran.output
    check "agent a1 failed task=" in ran.output

  test "ai agent research results survive multi-tool success failure and restore":
    buildGeneCli()
    let stateDir = cliDir / "agent-c3-research-state"
    if dirExists(stateDir): removeDir(stateDir)
    defer:
      if dirExists(stateDir): removeDir(stateDir)
    let fixture = writeCliProgram("fake_agent_research.gene", """
(import net/http [Server serve Response])
(import json [stringify])
(import str [join])
(import gene/stream [to_stream map into])

(var hits (cell 0))

(fn sse-body [chunks]
  (var lines
    ((to_stream chunks)
      ~ map (fn [chunk] $"data: ${(stringify chunk)}")
      ; ~ into []))
  (var separator "\n\n")
  $"${(join lines separator)}${separator}data: [DONE]${separator}")

(fn tool-turn [name, args, id]
  (sse-body
    [{^choices [{^index 0
                 ^delta {^role "assistant"
                         ^tool_calls
                           [{^index 0 ^id id ^type "function"
                             ^function {^name name
                                        ^arguments (stringify args)}}]}}]}
     {^choices [{^index 0 ^delta {} ^finish_reason "tool_calls"}]}]))

(fn answer [text]
  (sse-body
    [{^choices [{^index 0 ^delta {^content text}}]}
     {^choices [{^index 0 ^delta {} ^finish_reason "stop"}]}]))

(fn handle [_req]
  (hits ~ set (+ (hits ~ get) 1))
  (var n (hits ~ get))
  (if (== n 5)
    (Response ^status 500
              ^headers {^content-type "application/json"}
              ^body "{\"detail\":\"research failed\"}")
    (Response
      ^status 200 ^headers {^content-type "text/event-stream"}
      ^body
        (match n
          (when 1 (tool-turn "list_dir" {^path "."} "call-list"))
          (when 2
            (tool-turn "grep"
              {^pattern "fn" ^path "examples/ai_agent/tui.gene"
               ^max_results 2}
              "call-grep"))
          (when 3
            (tool-turn "read_file"
              {^path "examples/ai_agent/design.md"
               ^start_line 1 ^max_lines 2}
              "call-read"))
          (else (answer "research succeeded"))))))

(serve (Server ^host "127.0.0.1" ^port 8970) handle ^max_requests 5)
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
          socket.connect("127.0.0.1", Port(8970), timeout = 500)
          socket.close()
          break waitForServer
        except OSError, TimeoutError:
          socket.close()
          if getMonoTime() > deadline: raise
          sleep(50)
    let first = execCmdOnce(
      "printf '/agent new inspect the project\\n" &
      "/agent new demonstrate failure\\n/agents\\n" &
      "/trace type=agent_finished --detail\\n" &
      "/agent a1 result\\n/agent a2 result\\n/quit\\n' | " &
      "env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
      "OPENAI_AUTH_TOKEN=dummy OPENAI_API=chat " &
      "OPENAI_BASE_URL=http://127.0.0.1:8970/v1 " &
      "OPENAI_MODEL=fake-research GENE_AGENT_STATE=" &
      shellQuote("fs:" & stateDir) & " " & shellQuote(geneExe) &
      " run examples/ai_agent/tui.gene")
    if first.exitCode != 0: checkpoint first.output
    check first.exitCode == 0
    check "extension 1 completed: research succeeded" in first.output
    check "OpenAI API error 500: research failed" in first.output
    check first.output.count("\"type\":\"agent_finished\"") == 2
    check "\"outcome\":\"completed\"" in first.output
    check "\"outcome\":\"failed\"" in first.output
    check "\"source_v\":" in first.output
    check "a1 model=fake-research lifecycle=running availability=idle last=completed unread=true" in first.output
    check "a2 model=fake-research lifecycle=running availability=idle last=failed unread=true" in first.output
    check "agent a1 completed task=" in first.output
    check "agent a2 failed task=" in first.output
    let persistedEvents = readFile(agentStateRecordPath(stateDir, "events"))
    check persistedEvents.count("^type \"agent_finished\"") == 2
    check "^name \"list_dir\"" in persistedEvents
    check "^name \"grep\"" in persistedEvents
    check "^name \"read_file\"" in persistedEvents
    check "research succeeded" in
      readFile(agentStateRecordPath(stateDir, "application"))

    let restored = execCmdOnce(
      "printf '/agents\\n/agent a1 result\\n/agent a2 result\\n/quit\\n' | " &
      "env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
      "OPENAI_AUTH_TOKEN=dummy OPENAI_API=chat " &
      "OPENAI_BASE_URL=http://127.0.0.1:8970/v1 " &
      "OPENAI_MODEL=fake-research GENE_AGENT_STATE=" &
      shellQuote("fs:" & stateDir) & " " & shellQuote(geneExe) &
      " run examples/ai_agent/tui.gene")
    if restored.exitCode != 0: checkpoint restored.output
    check restored.exitCode == 0
    check "research succeeded" in restored.output
    check "agent a2 failed task=" in restored.output

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
(import gene/stream [to_stream map into])

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
(import gene/stream [to_stream map filter into])

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

  test "ai agent path guard rejects traversal segments not safe dotdot names":
    buildGeneCli()
    let target = "tmp/agent-v1..v2.txt"
    let fixture = "examples/ai_agent/path_segment_guard_test.gene"
    defer:
      if fileExists(target): removeFile(target)
      if fileExists(fixture): removeFile(fixture)
    writeFile(target, "safe\n")
    writeFile(fixture, """
(import [safe_path]
  from "./core.gene")
(println (safe_path "tmp/agent-v1..v2.txt"))
(try
  (println (safe_path "tmp/../outside"))
catch {^message message}
  (println message))
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "tmp/agent-v1..v2.txt" in ran.output
    check "unsafe path rejected (escapes workspace): tmp/../outside" in
      ran.output

  test "ai agent structured shell denies a catastrophic line but runs normal ones":
    ## The structured shell route reads lines in Gene, so each runs through
    ## the same §8.5 classifier as model-issued run_shell. A catastrophic line
    ## is denied; a normal line still executes. /sh is the interactive PTY
    ## escape hatch and is intentionally not covered here. The command targets a
    ## nonexistent root-level path: it classifies catastrophic via the
    ## leading-/ rule but deletes nothing if the guard ever regresses.
    buildGeneCli()
    let command = "printf '/pane new shell\\n/1 rm -rf /nonexistent-gene-guard-root\\n/1 echo ran-normal\\n/1 close\\n/quit\\n' | " &
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
(import gene/stream [to_stream map into])

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
    let command = "printf 'go\\n/trace type=turn_done\\n/trace type=tool_result\\n/trace type=agent_finished --detail\\n/quit\\n' | " &
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
    # C3: the main agent also has one linked structured terminal boundary.
    check ran.output.count("\"type\":\"agent_finished\"") == 1
    check "\"worker_id\":\"main\"" in ran.output
    check "\"outcome\":\"completed\"" in ran.output
    check "\"source_v\":" in ran.output

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
(import gene/stream [to_stream map each into])

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
(import gene/stream [to_stream each into map])

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
(import gene/stream [to_stream map into])
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
  (hits ~ set (+ (hits ~ get) 1))
  (Response ^status 200 ^headers {^content-type "text/event-stream"}
            ^body (sse_body (if (== (hits ~ get) 1)
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
    let input = "go\n/diff\n/pane new shell\n/1 printf external > dirty.txt\n/1 close\n" &
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
(import gene/stream [to_stream map into])
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
  (hits ~ set (+ (hits ~ get) 1))
  (Response ^status 200 ^headers {^content-type "text/event-stream"}
            ^body (sse_body (if (== (hits ~ get) 1) calls done))))
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
    let command = "printf '/repl\n/1 (session/evidence ~ get)\n/1 close\n" &
      "go\n/trace type=check\n/repl\n/2 (session/evidence ~ get)\n" &
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
    let stored = readFile(agentStateRecordPath(stateDir, "events"))
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
    let tui = "./core.gene"
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
                     ^events (agent_events ~ get)
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
    # The REPL result is rendered through the canonical formatter, which may
    # wrap the nested context map — assert the pieces, not the line shape.
    check "^context {" in status.output
    check "^bytes " in status.output
    check "^context_max_bytes 1234" in status.output

  test "ai agent keeps compaction markers off both model wire shapes":
    buildGeneCli()
    let fixture = "examples/ai_agent/wire_marker_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import str [contains?])
(import [call_model compact_context] from "./core.gene")
(fn sink [_type, _props] nil)
(var items
  [{^role "system" ^content "sys"}
   {^role "user" ^content "old-intent"}
   {^type "message" ^role "assistant"
    ^content [{^type "output_text" ^text "old-answer"}]}
   {^role "user" ^content "recent-intent"}
   {^type "message" ^role "assistant"
    ^content [{^type "output_text" ^text "recent-answer"}]}])
(var compacted (compact_context items sink))
(var markers 0)
(for item in compacted
  (if (|| (== item/context_summary true) (== item/context_limit_warning true))
    (set markers (+ markers 1))))
(var bodies [])
(fn transport [body, _render_stream]
  (bodies ~ push! body)
  {^output []})
(call_model transport compacted (fn [_text] nil))
(var body bodies/0)
(var summary_sent (contains? body "Context compacted"))
(var warning_sent (contains? body "configured floor"))
(var leak (|| (contains? body "context_summary")
              (contains? body "context_limit_warning")))
(println $"markers=${markers} summary_sent=${summary_sent} warning_sent=${warning_sent} leak=${leak}")
""")
    let compactEnv =
      "GENE_AGENT_CONTEXT_MAX_BYTES=1 GENE_AGENT_CONTEXT_MAX_ITEMS=3 " &
      "GENE_AGENT_CONTEXT_KEEP_TURNS=1 "
    for flavorEnv in ["env -u OPENAI_BASE_URL -u OPENAI_API ",
                      "env -u OPENAI_BASE_URL OPENAI_API=chat "]:
      # OpenAI's strict backends reject unknown item fields such as
      # input[N].context_summary, so the markers must stay agent-local
      # while the summary text itself still reaches the model.
      let ran = execCmdOnce(flavorEnv & compactEnv & shellQuote(geneExe) &
                            " run " & shellQuote(fixture))
      if ran.exitCode != 0: checkpoint ran.output
      check ran.exitCode == 0
      check "markers=2 summary_sent=true warning_sent=true leak=false" in
        ran.output

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
(import [find_tool compact_context run_turn_ready config_snapshot
         append edit_mismatch_hint]
  from "./core.gene")
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
  (compact_events ~ set
    (append (compact_events ~ get) {^type type ^props props})))
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
  (irreducible_events ~ set
    (append (irreducible_events ~ get) {^type type ^props props})))
(var irreducible
  (compact_context [{^role "user" ^content "LARGE_USER"}]
                   irreducible_emit))
(var irreducible_again
  (compact_context irreducible irreducible_emit))

(var seen_body (cell ""))
(fn transport [body, render]
  (seen_body ~ set body)
  {^output [] ^output_text "done"})
(var retained
  (run_turn_ready transport [{^role "user" ^content "finish"}]
                  (fn [text] nil) (fn [text] nil) 2 sink))

(var round_calls (cell 0))
(var round_first_body (cell ""))
(fn round_transport [body, render]
  (round_calls ~ set (+ (round_calls ~ get) 1))
  (if (== (round_calls ~ get) 1)
    (do
      (round_first_body ~ set body)
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
   ^compact_events (compact_events ~ get)
   ^irreducible irreducible
   ^irreducible_again irreducible_again
   ^irreducible_events (irreducible_events ~ get)
   ^budget_body (seen_body ~ get)
   ^retained retained
   ^round_calls (round_calls ~ get)
   ^round_first_body (round_first_body ~ get)
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
(import gene/stream [to_stream map into])
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
  (hits ~ set (+ (hits ~ get) 1))
  (var n (hits ~ get))
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
      " && printf 'go\n/status\n/repl\n/1 (session/instructions ~ get)\n" &
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
(import gene/stream [to_stream map filter into])

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
  (hits ~ set (+ (hits ~ get) 1))
  (var n (hits ~ get))
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
      let cancelDeadline = getMonoTime() + initDuration(seconds = 2)
      var cancellationPersisted = false
      while getMonoTime() < cancelDeadline and not cancellationPersisted:
        let eventsFile = agentStateRecordPath(stateDir, "events")
        if fileExists(eventsFile):
          cancellationPersisted = "cancelled" in readFile(eventsFile)
        if not cancellationPersisted: sleep(10)
      check cancellationPersisted
      check (getMonoTime() - interruptedAt).inMilliseconds < 2000
      inputStream.write("steer now\n/trace tool=run_shell\n/trace type=check\n/trace type=turn_done\n/trace type=agent_finished --detail\n/quit\n")
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
      check "agent_finished" in output
      let events = readFile(agentStateRecordPath(stateDir, "events"))
      check "^type \"check\"" in events
      check "^cancelled true" in events
      check events.count("^kind \"cancelled\"") == 1
      check events.count("^type \"agent_finished\"") == 2
      check events.count("^type \"worker_operation_finished\"") == 2
      check "^outcome \"cancelled\"" in events
      check "^source_v" in events

  test "ai agent /view hands the terminal to gene view and resumes":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("agent_view_handoff.gene",
        "(server ^port 8080 ^routes [[GET] [POST]])\n")
      let stateDir = cliDir / "agent_view_handoff_state"
      let outputFile = cliDir / "agent_view_handoff.out"
      if dirExists(stateDir): removeDir(stateDir)
      removeFile(outputFile)
      defer:
        if dirExists(stateDir): removeDir(stateDir)
      let inner = "stty rows 24 cols 100; exec /usr/bin/env " &
                  "TERM=xterm-256color OPENAI_AUTH_TOKEN=dummy " &
                  "GENE_AGENT_STATE=" & shellQuote("fs:" & stateDir) & " " &
                  shellQuote(geneExe) &
                  " run examples/ai_agent/tui.gene"
      let expectScript =
        "set timeout 20\n" &
        "log_file -noappend " & outputFile & "\n" &
        "spawn /bin/sh -c {" & inner & "}\n" &
        "expect -re {\\[0 main\\]}\n" &
        "send -- \"/view " & fixture & "\\r\"\n" &
        "expect -re {Path:}\n" &
        "send -- \"q\"\n" &
        "expect -re {returned from gene view}\n" &
        "send -- \"/status\\r\"\n" &
        "expect -re {agent> state:}\n" &
        "send -- \"/quit\\r\"\n" &
        "expect eof\n"
      let terminal = execCmdOnce(
        "/usr/bin/expect -c " & shellQuote(expectScript) &
        " >/dev/null 2>&1")
      let exitCode = terminal.exitCode
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "Path:" in output
      check "returned from gene view" in output
      check "state:" in output
      check output.count("\e[?1049l") >= 2

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
    (abandoned ~ cancel)
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
    (var pane_previous (await (next_event screen)))
    (var pane_next (await (next_event screen)))
    (var complete (await (next_event screen)))
    (var reverse_search (await (next_event screen)))
    (var edit (await (next_event screen)))
    (var interrupt (await (next_event screen)))
    (var escape (await (next_event screen)))
    (var queued_text (await (next_event screen)))
    (close screen)
    (println $"CURSES-CONTROLS:${(stringify [paste_start text_event
                                             pasted_enter paste_end newline
                                             page_up pane_previous pane_next
                                             complete reverse_search edit
                                             interrupt escape
                                             queued_text])}"))
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
      terminal.inputStream.write(
        "\e[200~x\n\e[201~\e[13;2u\e[5~\e[5;5~\e[6;5~\t\x12\x05\x03")
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
      check "\"type\":\"pane_previous\"" in output
      check "\"type\":\"pane_next\"" in output
      check "\"type\":\"complete\"" in output
      check "\"type\":\"reverse_search\"" in output
      check "\"type\":\"edit\"" in output
      check "\"type\":\"interrupt\"" in output
      check "\"type\":\"escape\"" in output
      check "\"text\":\"p\"" in output

  test "ai agent palette completion reverse search and Ctrl-E share the overlay editor":
    when defined(macosx):
      buildGeneCli()
      let editor = cliDir / "agent_c6_editor.sh"
      writeFile(editor, "#!/bin/sh\nprintf '/status' > \"$1\"\n")
      setFilePermissions(editor,
        {fpUserRead, fpUserWrite, fpUserExec,
         fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
      let outputFile = cliDir / "agent_c6_overlay.out"
      removeFile(outputFile)
      let inner = "exec /usr/bin/env TERM=xterm-256color " &
                  "EDITOR=" & shellQuote(editor) &
                  " CODEX_ACCESS_TOKEN=dummy GENE_AGENT_STATE= " &
                  shellQuote(geneExe) &
                  " run examples/ai_agent/tui.gene"
      let command = "/usr/bin/script -q /dev/null /bin/sh -c " &
                    shellQuote(inner) & " > " & shellQuote(outputFile) &
                    " 2>&1"
      let terminal = startProcess("/bin/sh", args = ["-c", command],
                                  options = {poUsePath, poStdErrToStdOut})
      defer:
        if terminal.running: terminal.terminate()
        terminal.close()
      sleep(500)
      # Escape dismisses the palette without touching /wor; Tab reopens the
      # same overlay and completes it to /worker. Enter accepts without
      # submitting, then " list" submits the completed command.
      terminal.inputStream.write("/wor\x1b\t\n list\n")
      terminal.inputStream.flush()
      sleep(400)
      # Global control commands are presentation history, not accepted worker
      # input. Open a shell route and execute one admitted command instead.
      # Escape dismisses the automatic slash-command palette before submit.
      terminal.inputStream.write("/pane new shell\x1b\nprintf history-marker\n")
      terminal.inputStream.flush()
      sleep(600)
      # Route-local reverse search restores the prior shell command into the
      # draft. First Enter accepts; second submits it again.
      terminal.inputStream.write("\x12history\n\n")
      terminal.inputStream.flush()
      sleep(600)
      # Ctrl-E loads /status through the configured editor, then Enter runs it.
      terminal.inputStream.write("\x05")
      terminal.inputStream.flush()
      sleep(500)
      terminal.inputStream.write("\n")
      terminal.inputStream.flush()
      sleep(600)
      terminal.inputStream.write("/quit\x1b\n")
      terminal.inputStream.flush()
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(8000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "main agent idle pane=0" in output
      check output.count("history-marker") >= 2
      check "state:" in output
      check "context limits:" in output

  test "ai agent typed tools and shell completion use one closed schema and lexer":
    buildGeneCli()
    let candidate = "tmp/agent-c6-completion space.txt"
    let fixture = "examples/ai_agent/c6_completion_contract_test.gene"
    defer:
      if fileExists(candidate): removeFile(candidate)
      if fileExists(fixture): removeFile(fixture)
    writeFile(candidate, "completion\n")
    writeFile(fixture, """
(import [Tool]
  from "./core.gene")
(import [workspace_path_completion_items
         shell_route_completion_items]
  from "./tui.gene")
(type Args ^props {^name Str ^count Int?})
(var tool
  (Tool ^name "typed" ^description "typed" ^risk "read" ^args Args
        ^handler (fn [_args] "ok")))
(var schema (tool ~ schema))
(println [(tool ~ validate_args {^name "ok"})
          (tool ~ validate_args {^name 7})
          (tool ~ validate_args {^name "ok" ^surprise 1})
          schema/parameters/additionalProperties])
(println (workspace_path_completion_items "cat tmp/agent-c6-com"))
(println (workspace_path_completion_items "cat \"tmp/agent-c6-com"))
(println (workspace_path_completion_items "cat $(echo nope"))
(println
  (shell_route_completion_items
    {^history (cell [{^text "echo history-token"}])} "hist"))
""")
    let ran = runGene(["run", fixture])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "[nil \"field 'name' for Args expected Str, got vkInt\"" in ran.output
    check "Args has no field 'surprise'" in ran.output
    check ran.output.contains("false]")
    check "cat 'tmp/agent-c6-completion space.txt'" in ran.output
    check "cat \\\"tmp/agent-c6-completion space.txt\\\"" in ran.output
    check "[]\n" in ran.output
    check "history-token" in ran.output
    check "shell history" in ran.output

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
      (done ~ close))))
(var armed (begin_interrupt))
(var watcher
  (spawn
    (while (running ~ get)
      (sleep 25)
      (if (|| (take_interrupt) (escape_pressed? screen))
        (do
          (cancelled ~ set true)
          (task ~ cancel))
        nil))))
(try (done ~ recv) catch (ChannelClosed) nil)
(running ~ set false)
(watcher ~ cancel)
(if armed (end_interrupt) nil)
(close screen)
(if (cancelled ~ get)
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
(import gene/stream [to_stream map into])

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

    proc gwAttach(sid: string): string =
      let body = gwCurl(
        "-X POST -H 'content-type: application/json' " &
        "-d '{\"display_label\":\"test\"}' " &
        "http://127.0.0.1:8989/api/sessions/" & sid & "/attachments")
      parseJson(body)["attachment_id"].getStr()

    proc gwCurlAs(attachmentId, call: string): string =
      gwCurl("-H 'X-Gene-Attachment: " & attachmentId & "' " & call)

    # Auth is enforced.
    let denied = execCmdEx(
      "curl -s -o /dev/null -w '%{http_code}' " &
      "-X POST http://127.0.0.1:8989/api/sessions")
    check denied.output.strip() == "401"

    # Two sessions, one message each, posted back to back.
    check "\"id\":\"s1\"" in gwCurl("-X POST http://127.0.0.1:8989/api/sessions")
    check "\"id\":\"s2\"" in gwCurl("-X POST http://127.0.0.1:8989/api/sessions")
    let s1Attachment = gwAttach("s1")
    let s2Attachment = gwAttach("s2")
    let t0 = getMonoTime()
    check "\"ok\":true" in gwCurlAs(s1Attachment,
      "-X POST -H 'content-type: application/json' -d '{\"text\":\"go\"}' " &
      "http://127.0.0.1:8989/api/sessions/s1/messages")
    let duplicate = execCmdEx(
      "curl -sS -w '\n%{http_code}' " &
      "-H 'Authorization: Bearer gw-secret' " &
      "-H 'X-Gene-Attachment: " & s1Attachment & "' " &
      "-H 'content-type: application/json' " &
      "-d '{\"text\":\"must-not-queue\"}' " &
      "http://127.0.0.1:8989/api/sessions/s1/messages")
    check duplicate.exitCode == 0
    check duplicate.output.strip().endsWith("409")
    check "worker_busy" in duplicate.output
    check "turn already in flight" in duplicate.output
    check "\"ok\":true" in gwCurlAs(s2Attachment,
      "-X POST -H 'content-type: application/json' -d '{\"text\":\"go\"}' " &
      "http://127.0.0.1:8989/api/sessions/s2/messages")

    # Long-poll each session until its turn completes.
    proc waitTurnDone(sid, attachmentId: string): string =
      var cursor = 0
      let deadline = getMonoTime() + initDuration(seconds = 15)
      while getMonoTime() < deadline:
        let body = gwCurlAs(attachmentId,
          "'http://127.0.0.1:8989/api/sessions/" & sid &
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

    let s1Events = waitTurnDone("s1", s1Attachment)
    let s2Events = waitTurnDone("s2", s2Attachment)
    var s1Terminal = s1Events
    let terminalDeadline = getMonoTime() + initDuration(seconds = 3)
    while "agent_finished" notin s1Terminal and
          getMonoTime() < terminalDeadline:
      sleep(10)
      s1Terminal = gwCurlAs(s1Attachment,
        "'http://127.0.0.1:8989/api/sessions/s1/events?cursor=0'")
    let elapsedMs = (getMonoTime() - t0).inMilliseconds

    # Streaming deltas arrived as events for both sessions.
    check "text_delta" in s1Events
    check "slow " in s1Events
    check "answer" in s2Events
    check "changed_worker_ids" in s1Events
    check s1Terminal.count("agent_finished") == 1
    check "worker_operation_finished" in s1Terminal
    check "\"source_v\":" in s1Terminal
    check "\"result_unread\":false" in s1Terminal
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

    var workerAttachment = ""
    proc workerCurl(call: string): string =
      let attachmentHeader =
        if workerAttachment.len > 0:
          "-H 'X-Gene-Attachment: " & workerAttachment & "' "
        else:
          ""
      let ran = execCmdEx(
        "curl -sS -H 'Authorization: Bearer gw-workers' " &
        attachmentHeader & call)
      check ran.exitCode == 0
      ran.output

    let operations = workerCurl(
      "http://127.0.0.1:8993/api/operations")
    check "\"worker_kind\":\"agent\"" in operations
    check "\"name\":\"send\"" in operations
    check "\"effects\":[\"session_write\",\"model_call\"]" in operations
    check "\"worker_kind\":\"terminal\"" in operations
    check "\"id\":\"s1\"" in workerCurl(
      "-X POST http://127.0.0.1:8993/api/sessions")
    let missingAttachment = workerCurl(
      "-w '\n%{http_code}' " &
      "http://127.0.0.1:8993/api/sessions/s1/snapshot")
    check "attachment_required" in missingAttachment
    check missingAttachment.strip().endsWith("428")
    let attachedText = workerCurl(
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"display_label\":\"test\",\"tier\":\"channel\",\"capabilities\":[]}' " &
      "http://127.0.0.1:8993/api/sessions/s1/attachments")
    let attached = parseJson(attachedText)
    workerAttachment = attached["attachment_id"].getStr()
    let resumeCredential = attached["resume_credential"].getStr()
    check workerAttachment.startsWith("att_")
    check resumeCredential.startsWith("resume_")
    check attached["principal"].getStr() == "bearer"
    check attached["tier"].getStr() == "full"
    check attached["capabilities"].len == 5
    check "session_write" in attachedText
    let acked = workerCurl(
      "-X POST -H 'content-type: application/json' -d '{\"cursor\":0}' " &
      "http://127.0.0.1:8993/api/sessions/s1/attachments/" &
      workerAttachment & "/ack")
    check "\"acknowledged_cursor\":0" in acked
    let resumedAttachment = workerCurl(
      "-X POST -H 'content-type: application/json' -d '{\"resume_credential\":\"" &
      resumeCredential & "\"}' " &
      "http://127.0.0.1:8993/api/sessions/s1/attachments/" &
      workerAttachment & "/resume")
    check "\"attachment_id\":\"" & workerAttachment & "\"" in
      resumedAttachment
    let transportRun = execCmdEx(
      "/usr/bin/env GENE_AGENT_CONNECT=http://127.0.0.1:8993 " &
      "GENE_GATEWAY_TOKEN=gw-workers GENE_AGENT_SESSION=s1 " &
      shellQuote(geneExe) & " run examples/ai_agent/remote_client_smoke.gene")
    if transportRun.exitCode != 0: checkpoint transportRun.output
    check transportRun.exitCode == 0
    check transportRun.output.strip() == "[\"full\" \"s1\" true]"
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
    let createOutputCall =
      "-X POST -H 'Idempotency-Key: create-output' " &
      "-H 'content-type: application/json' " &
      "-d '{\"kind\":\"output\",\"config\":{\"title\":\"checks\",\"text\":\"ready\"}}' " &
      "http://127.0.0.1:8993/api/sessions/s1/workers"
    let created = workerCurl(createOutputCall)
    check "\"worker_id\":\"w1\"" in created
    check workerCurl(createOutputCall) == created
    let reusedKey = workerCurl(
      "-w '\n%{http_code}' -X POST " &
      "-H 'Idempotency-Key: create-output' " &
      "-H 'content-type: application/json' " &
      "-d '{\"kind\":\"output\",\"config\":{\"title\":\"different\"}}' " &
      "http://127.0.0.1:8993/api/sessions/s1/workers")
    check "idempotency_key_reused" in reusedKey
    check reusedKey.strip().endsWith("409")
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
    let statusAlias = workerCurl(
      "http://127.0.0.1:8993/api/sessions/s1/workers/w1/status")
    check "\"ok\":true" in statusAlias
    check "\"kind\":\"output\"" in statusAlias
    let tailAlias = workerCurl(
      "'http://127.0.0.1:8993/api/sessions/s1/workers/w1/tail?n=1'")
    check "\"ok\":true" in tailAlias
    check "\"requested\":1" in tailAlias
    check "\"text\":\"ready\"" in tailAlias
    let observed = workerCurl(
      "-X POST -H 'content-type: application/json' -d '{\"args\":{}}' " &
      "http://127.0.0.1:8993/api/sessions/s1/workers/w1/ops/status")
    check "\"ok\":true" in observed
    check "\"kind\":\"output\"" in observed
    check "\"status\":\"idle\"" in observed
    let observeEvents = workerCurl(
      "'http://127.0.0.1:8993/api/sessions/s1/events?cursor=" &
      $outputCursor & "'")
    check "\"events\":[]" in observeEvents
    check parseJson(observeEvents)["cursor"].getInt() == outputCursor
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
    var agentResult = workerCurl(
      "http://127.0.0.1:8993/api/sessions/s1/agents/a1/result")
    let resultDeadline = getMonoTime() + initDuration(seconds = 5)
    while "no agent result" in agentResult:
      if getMonoTime() > resultDeadline:
        checkpoint "sub-agent result did not finish: " & agentResult
        break
      sleep(25)
      agentResult = workerCurl(
        "http://127.0.0.1:8993/api/sessions/s1/agents/a1/result")
    check "\"read\":false" in agentResult
    check "\"incorporated\":false" in agentResult
    let agentResultAgain = workerCurl(
      "http://127.0.0.1:8993/api/sessions/s1/agents/a1/result")
    check "\"read\":false" in agentResultAgain
    check "\"result_unread\":true" in workerCurl(
      "http://127.0.0.1:8993/api/sessions/s1/agents")
    for _ in 0 .. 1:
      let markedRead = workerCurl(
        "-X POST http://127.0.0.1:8993/api/sessions/s1/agents/a1/result/read")
      check "\"read\":true" in markedRead
      check "\"incorporated\":false" in markedRead
    for _ in 0 .. 1:
      let incorporated = workerCurl(
        "-X POST http://127.0.0.1:8993/api/sessions/s1/agents/a1/incorporate")
      check "\"read\":true" in incorporated
      check "\"incorporated\":true" in incorporated
    let progressUpdated = workerCurl(
      "-X PUT -H 'content-type: application/json' " &
      "-d '{\"objective\":\"ship C3\",\"phase\":\"verifying\",\"status\":\"blocked\",\"summary\":\"waiting for review\",\"blocked_reason\":\"review pending\",\"required_action\":\"approve\"}' " &
      "http://127.0.0.1:8993/api/sessions/s1/progress")
    check "\"objective\":\"ship C3\"" in progressUpdated
    check "\"blocked_reason\":\"review pending\"" in progressUpdated
    let progressRead = workerCurl(
      "http://127.0.0.1:8993/api/sessions/s1/progress")
    check "\"required_action\":\"approve\"" in progressRead
    check "\"objective\":\"ship C3\"" in workerCurl(
      "http://127.0.0.1:8993/api/sessions/s1/snapshot")
    let beforeAgentStop = parseJson(workerCurl(
      "http://127.0.0.1:8993/api/sessions/s1/snapshot"))["cursor"].getInt()
    let agentStopped = workerCurl(
      "-X DELETE http://127.0.0.1:8993/api/sessions/s1/agents/a1")
    check "\"ok\":true" in agentStopped
    let agentStopEvents = workerCurl(
      "'http://127.0.0.1:8993/api/sessions/s1/events?cursor=" &
      $beforeAgentStop & "'")
    check "\"operation_kind\":\"stop\"" in agentStopEvents
    check "\"origin\":\"remote\"" in agentStopEvents
    check "\"type\":\"agent_status\"" in agentStopEvents
    check "\"status\":\"stopped\"" in agentStopEvents
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
    check "\"ok\":true" in workerCurl(
      "-X DELETE http://127.0.0.1:8993/api/sessions/s1/attachments/" &
      workerAttachment)
    let detached = workerCurl(
      "-w '\n%{http_code}' " &
      "http://127.0.0.1:8993/api/sessions/s1/snapshot")
    check "attachment_invalid" in detached
    check detached.strip().endsWith("401")

  test "agent gateway remote parity spans two attachments with local_only":
    ## Slice C9 stage 3 (design.md §10.12): the remote client surface reaches
    ## worker operations, artifacts, and snapshots over the long-poll routes;
    ## two attachments on one session hold independent acknowledgement
    ## cursors; in-process-only operations answer the typed local_only error.
    buildGeneCli()
    let stateDir = cliDir / "gateway_remote_parity_state"
    if dirExists(stateDir): removeDir(stateDir)
    defer:
      if dirExists(stateDir): removeDir(stateDir)
    let gatewayProc = startProcess(
      "/usr/bin/env",
      args = ["-u", "OPENAI_AUTH_TOKEN", "-u", "CODEX_ACCESS_TOKEN",
              "-u", "OPENAI_API_KEY", "-u", "TELEGRAM_BOT_TOKEN",
              "GENE_GATEWAY_PORT=8998",
              "GENE_AGENT_STATE=fs:" & stateDir,
              geneExe, "run", "examples/ai_agent/gateway.gene"],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if gatewayProc.running: gatewayProc.terminate()
      gatewayProc.close()
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while true:
      var s = newSocket()
      try:
        s.connect("127.0.0.1", Port(8998), timeout = 500)
        s.close()
        break
      except OSError, TimeoutError:
        s.close()
        if getMonoTime() > deadline: raise
        sleep(50)

    proc parityCurl(attachment, call: string): string =
      let header =
        if attachment.len > 0:
          "-H 'X-Gene-Attachment: " & attachment & "' "
        else:
          ""
      let ran = execCmdEx("curl -sS --max-time 5 " & header & call)
      check ran.exitCode == 0
      ran.output

    check "\"id\":\"s1\"" in parityCurl("",
      "-X POST http://127.0.0.1:8998/api/sessions")
    proc attachClient(label: string): string =
      parseJson(parityCurl("",
        "-X POST -H 'content-type: application/json' " &
        "-d '{\"display_label\":\"" & label & "\"}' " &
        "http://127.0.0.1:8998/api/sessions/s1/attachments"))[
          "attachment_id"].getStr()
    let clientA = attachClient("tui-a")
    let clientB = attachClient("tui-b")
    check clientA != clientB

    # Client A drives a stateful shell worker through declared operations.
    let shellCreated = parityCurl(clientA,
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"kind\":\"shell\",\"config\":{\"title\":\"remote shell\"}}' " &
      "http://127.0.0.1:8998/api/sessions/s1/workers")
    check "\"worker_id\":\"w1\"" in shellCreated
    let ran = parityCurl(clientA,
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"args\":{\"command\":\"printf remote-parity-ok\"}}' " &
      "http://127.0.0.1:8998/api/sessions/s1/workers/w1/ops/run")
    check "\"ok\":true" in ran
    var tailText = ""
    let tailDeadline = getMonoTime() + initDuration(seconds = 5)
    while getMonoTime() < tailDeadline:
      tailText = parityCurl(clientA,
        "'http://127.0.0.1:8998/api/sessions/s1/workers/w1/tail?n=5'")
      if "remote-parity-ok" in tailText: break
      sleep(25)
    check "remote-parity-ok" in tailText

    # Client B observes the same session while holding its own cursor.
    let workersForB = parityCurl(clientB,
      "http://127.0.0.1:8998/api/sessions/s1/workers")
    check "remote shell" in workersForB
    check "\"acknowledged_cursor\":4" in parityCurl(clientA,
      "-X POST -H 'content-type: application/json' -d '{\"cursor\":4}' " &
      "http://127.0.0.1:8998/api/sessions/s1/attachments/" & clientA & "/ack")
    check "\"acknowledged_cursor\":1" in parityCurl(clientB,
      "-X POST -H 'content-type: application/json' -d '{\"cursor\":1}' " &
      "http://127.0.0.1:8998/api/sessions/s1/attachments/" & clientB & "/ack")

    # Artifacts pin over the wire and both clients list the same evidence.
    let pinned = parityCurl(clientA,
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"source\":\"tail\",\"worker_id\":\"w1\"}' " &
      "http://127.0.0.1:8998/api/sessions/s1/artifacts")
    check "\"id\":\"artifact:1\"" in pinned
    let artifactsForB = parityCurl(clientB,
      "http://127.0.0.1:8998/api/sessions/s1/artifacts")
    check "\"id\":\"artifact:1\"" in artifactsForB
    check "\"source_worker\":\"w1\"" in artifactsForB

    # Attachment provenance lands in the journal for A's mutations.
    let events = parityCurl(clientB,
      "'http://127.0.0.1:8998/api/sessions/s1/events?cursor=0'")
    check "\"attachment_id\":\"" & clientA & "\"" in events

    # In-process-only operations answer the typed local_only error remotely
    # (repl eval is bound to the local surface; the policy is enforced by the
    # core, so exercise it directly with a remote-shaped invocation).
    let fixture = "examples/ai_agent/remote_local_only_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [active_application make_application_with_task
         application_call_worker]
  from "./core.gene")
(import [open_repl_pane] from "./tui.gene")
(var app
  (make_application_with_task (cell []) (cell "") (cell [])
    (fn [_type, _props] nil) (cell nil)))
(active_application ~ set app)
(var pane (open_repl_pane app/main_agent/items app/main_agent/transcript
                          (cell [])))
(var repl pane/worker)
(var remote_invocation
  {^origin "remote" ^caller_worker_id nil ^attachment_id "att_test"
   ^principal "loopback"
   ^principal_capabilities
     ["observe" "session_write" "model_call" "host_read" "host_write"]})
(var denied
  (application_call_worker app repl/id "eval" {^form "(+ 1 2)"}
    remote_invocation))
(var observed
  (application_call_worker app repl/id "status" {} remote_invocation))
(println $"denied=${denied/error/kind} observed=${observed/ok}")
""")
    let localOnly = runGene(["run", fixture])
    if localOnly.exitCode != 0: checkpoint localOnly.output
    check localOnly.exitCode == 0
    check "denied=local_only observed=true" in localOnly.output

  test "web surface model conforms to the Gene surface semantics":
    ## Slice C9 stage 5 (design.md §10.12): the HTML client's SurfaceModel is
    ## an independent JS implementation — it never shares surface.gene.
    ## Conformance is one scripted scenario (pane open/title default/cap,
    ## focus rules, maximize/close interaction, bounded 256-event
    ## presentation ring) run through BOTH implementations; after
    ## normalizing surface instance ids the results must be identical.
    ## The JS under test is the exact bytes the gateway serves.
    buildGeneCli()
    let gatewayProc = startProcess(
      "/usr/bin/env",
      args = ["-u", "OPENAI_AUTH_TOKEN", "-u", "CODEX_ACCESS_TOKEN",
              "-u", "OPENAI_API_KEY", "-u", "TELEGRAM_BOT_TOKEN",
              "GENE_GATEWAY_PORT=9001",
              geneExe, "run", "examples/ai_agent/gateway.gene"],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if gatewayProc.running: gatewayProc.terminate()
      gatewayProc.close()
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while true:
      var s = newSocket()
      try:
        s.connect("127.0.0.1", Port(9001), timeout = 500)
        s.close()
        break
      except OSError, TimeoutError:
        s.close()
        if getMonoTime() > deadline: raise
        sleep(50)
    let modelJsPath = cliDir / "surface_model_under_test.js"
    let fetched = execCmdEx(
      "curl -sS --max-time 5 -o " & shellQuote(modelJsPath) &
      " http://127.0.0.1:9001/surface_model.js")
    check fetched.exitCode == 0
    check "GeneSurfaceModel" in readFile(modelJsPath)
    gatewayProc.terminate()

    let jsDriver = cliDir / "surface_conformance.mjs"
    writeFile(jsDriver, """
const SurfaceModel = require(process.argv[2]);
const model = new SurfaceModel('local_tui', 3);
const p4holder = [];
model.openPane({workerId: 'w1', kind: 'output', title: 'notes'},
               null, 'detach', null);
model.openPane({workerId: 'w2', kind: 'shell', title: 'shell'},
               null, 'detach', 'custom title');
model.openPane({workerId: 'w3', kind: 'output', title: 'third'},
               null, 'detach', '');
p4holder.push(model.openPane(
  {workerId: 'w4', kind: 'output', title: 'fourth'}, null, 'detach', null));
model.focusPane(1);
model.maximizedPane = 2;
model.closePane(2);
model.focusPane(0);
const strip = function (event) {
  const out = {};
  for (const key of Object.keys(event)) {
    if (key !== 'surface_id') out[key] = event[key];
  }
  return out;
};
const lifecycle = model.events.map(strip);
for (let i = 0; i < 300; i++) model.emit('note', { i: i });
const ring = model.events;
console.log(JSON.stringify({
  panes: model.panes.map(function (p) {
    return { id: p.id, worker_id: p.worker_id, kind: p.kind,
             title: p.title, hidden: p.hidden };
  }),
  focused: model.focusedPane,
  maximized: model.maximizedPane,
  next_pane_id: model.nextPaneId,
  cap_rejected: p4holder[0] === null,
  lifecycle_events: lifecycle,
  ring: { count: ring.length, first_v: ring[0].v,
          last_v: ring[ring.length - 1].v,
          next_event_v: model.nextEventV }
}));
""")
    # `.mjs` would force ESM; the model is UMD, so drive it through CJS.
    let cjsDriver = cliDir / "surface_conformance.cjs"
    moveFile(jsDriver, cjsDriver)
    let jsRun = execCmdEx("node " & shellQuote(cjsDriver) & " " &
                          shellQuote(modelJsPath))
    if jsRun.exitCode != 0: checkpoint jsRun.output
    check jsRun.exitCode == 0

    let fixture = "examples/ai_agent/surface_conformance_test.gene"
    defer:
      if fileExists(fixture): removeFile(fixture)
    writeFile(fixture, """
(import [make_application application_new_worker
         application_attach_worker_pane_as application_close_pane
         surface_emit! OutputController ShellController]
  from "./core.gene")
(import [application_focus_pane!] from "./tui.gene")
(import json [stringify])
(var app (make_application (cell []) (cell "") (cell []) (fn [_t, _p] nil)))
(var surface app/local_surface)
(var w1 (application_new_worker app "output" "notes" (cell "")
          (OutputController ^source "test" ^following (cell []))))
(application_attach_worker_pane_as app w1 nil "detach" nil)
(var w2 (application_new_worker app "shell" "shell" (cell "")
          (ShellController ^cwd (cell ".") ^environment (cell {}))))
(application_attach_worker_pane_as app w2 nil "detach" "custom title")
(var w3 (application_new_worker app "output" "third" (cell "")
          (OutputController ^source "test" ^following (cell []))))
(application_attach_worker_pane_as app w3 nil "detach" "")
(var w4 (application_new_worker app "output" "fourth" (cell "")
          (OutputController ^source "test" ^following (cell []))))
(var p4 (application_attach_worker_pane_as app w4 nil "detach" nil))
(application_focus_pane! app 1)
(surface/maximized_pane ~ set 2)
(application_close_pane app 2)
(application_focus_pane! app 0)
(fn strip_surface [event]
  (var out {})
  (for [key value] in event
    (if (!= $"${key}" "surface_id") (out ~ put! key value)))
  out)
(var lifecycle [])
(for event in (surface/events ~ get)
  (lifecycle ~ push! (strip_surface event)))
(repeat i in 300 (surface_emit! surface "note" {^i i}))
(var ring (surface/events ~ get))
(var last_v (cell 0))
(for event in ring (last_v ~ set event/v))
(var panes [])
(for pane in (surface/panes ~ get)
  (panes ~ push!
    {^id pane/id ^worker_id pane/worker_id ^kind pane/kind
     ^title pane/title ^hidden (pane/hidden ~ get)}))
(println (stringify
  {^panes panes
   ^focused (surface/focused_pane ~ get)
   ^maximized (surface/maximized_pane ~ get)
   ^next_pane_id (surface/next_pane_id ~ get)
   ^cap_rejected (== p4 nil)
   ^lifecycle_events lifecycle
   ^ring {^count (ring ~ size) ^first_v ring/0/v
          ^last_v (last_v ~ get)
          ^next_event_v (surface/next_event_v ~ get)}}))
""")
    let geneRun = execCmdEx(
      "GENE_AGENT_PANE_MAX_COUNT=3 " & shellQuote(geneExe) & " run " &
      shellQuote(fixture))
    if geneRun.exitCode != 0: checkpoint geneRun.output
    check geneRun.exitCode == 0

    proc canonJson(node: JsonNode): JsonNode =
      ## Key-order-insensitive comparison form: Gene map iteration order is
      ## an implementation detail (id-keyed PropTable), so sort keys.
      case node.kind
      of JObject:
        result = newJObject()
        var keys: seq[string]
        for key in node.keys: keys.add key
        for key in sorted(keys): result[key] = canonJson(node[key])
      of JArray:
        result = newJArray()
        for item in node: result.add canonJson(item)
      else:
        result = node
    let jsResult = canonJson(parseJson(jsRun.output.strip()))
    let geneResult = canonJson(parseJson(geneRun.output.strip().splitLines()[^1]))
    if jsResult != geneResult:
      checkpoint "js:   " & $jsResult
      checkpoint "gene: " & $geneResult
    check jsResult == geneResult

  test "agent gateway delivers events over a ticketed websocket":
    ## Slice C9 stage 4 (design.md §10.12): a full client mints a single-use
    ## expiring ws_ticket over its attached HTTP channel, upgrades with it,
    ## and receives the journal as frames. Mutations stay HTTP-only (text
    ## frames answer a typed notice), and a consumed ticket cannot upgrade a
    ## second socket. Long-poll remains untouched as the fallback.
    buildGeneCli()
    let gatewayProc = startProcess(
      "/usr/bin/env",
      args = ["-u", "OPENAI_AUTH_TOKEN", "-u", "CODEX_ACCESS_TOKEN",
              "-u", "OPENAI_API_KEY", "-u", "TELEGRAM_BOT_TOKEN",
              "GENE_GATEWAY_PORT=8999",
              geneExe, "run", "examples/ai_agent/gateway.gene"],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if gatewayProc.running: gatewayProc.terminate()
      gatewayProc.close()
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while true:
      var s = newSocket()
      try:
        s.connect("127.0.0.1", Port(8999), timeout = 500)
        s.close()
        break
      except OSError, TimeoutError:
        s.close()
        if getMonoTime() > deadline: raise
        sleep(50)

    var wsAttachment = ""
    proc wsCurl(call: string): string =
      let header =
        if wsAttachment.len > 0:
          "-H 'X-Gene-Attachment: " & wsAttachment & "' "
        else:
          ""
      let ran = execCmdEx("curl -sS --max-time 5 " & header & call)
      check ran.exitCode == 0
      ran.output

    check "\"id\":\"s1\"" in wsCurl(
      "-X POST http://127.0.0.1:8999/api/sessions")
    wsAttachment = parseJson(wsCurl(
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"display_label\":\"ws\"}' " &
      "http://127.0.0.1:8999/api/sessions/s1/attachments"))[
        "attachment_id"].getStr()
    let minted = parseJson(wsCurl(
      "-X POST http://127.0.0.1:8999/api/sessions/s1/ws_ticket"))
    let ticket = minted["ticket"].getStr()
    check ticket.startsWith("wst_")
    check minted["url"].getStr() == "/api/sessions/s1/ws"

    proc wsHandshake(ticket: string): Socket =
      result = newSocket()
      result.connect("127.0.0.1", Port(8999), timeout = 2000)
      result.send("GET /api/sessions/s1/ws?ticket=" & ticket &
        " HTTP/1.1\r\nHost: 127.0.0.1:8999\r\nUpgrade: websocket\r\n" &
        "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
        "Sec-WebSocket-Version: 13\r\n\r\n")

    proc wsReadHead(sock: Socket): string =
      while "\r\n\r\n" notin result:
        var ch: char
        if sock.recv(addr ch, 1, 2000) != 1: break
        result.add ch

    proc wsRecvExact(sock: Socket, n: int): string =
      result = newString(n)
      var got = 0
      while got < n:
        let r = sock.recv(addr result[got], n - got, 5000)
        if r <= 0:
          raise newException(IOError, "ws socket closed early")
        got += r

    proc wsRecvFrame(sock: Socket): tuple[opcode: int, payload: string] =
      let hdr = wsRecvExact(sock, 2)
      result.opcode = int(byte(hdr[0]) and 0x0F)
      var ln = int(byte(hdr[1]) and 0x7F)
      if ln == 126:
        let ext = wsRecvExact(sock, 2)
        ln = (int(byte(ext[0])) shl 8) or int(byte(ext[1]))
      elif ln == 127:
        let ext = wsRecvExact(sock, 8)
        ln = 0
        for i in 0 ..< 8:
          ln = (ln shl 8) or int(byte(ext[i]))
      result.payload = if ln > 0: wsRecvExact(sock, ln) else: ""

    proc wsSendText(sock: Socket, text: string) =
      # Client frames must be masked; a zero mask keeps payload bytes as-is.
      var frame = ""
      frame.add char(0x81)
      frame.add char(0x80 or text.len)   # test payloads stay under 126 bytes
      frame.add "\0\0\0\0"
      frame.add text
      sock.send(frame)

    let ws = wsHandshake(ticket)
    defer: ws.close()
    let head = wsReadHead(ws)
    check "101" in head.splitLines()[0]
    check "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" in head
    let hello = wsRecvFrame(ws)
    check hello.opcode == 1
    check "\"type\":\"ws_hello\"" in hello.payload
    check "\"attachment_id\":\"" & wsAttachment & "\"" in hello.payload

    check "\"ok\":true" in wsCurl(
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"text\":\"list it\"}' " &
      "http://127.0.0.1:8999/api/sessions/s1/messages")
    var sawTypes: seq[string]
    let frameDeadline = getMonoTime() + initDuration(seconds = 10)
    while getMonoTime() < frameDeadline:
      let frame = wsRecvFrame(ws)
      if frame.opcode != 1: continue
      let parsed = parseJson(frame.payload)
      if parsed["type"].getStr() != "event": continue
      sawTypes.add parsed["event"]["type"].getStr()
      if sawTypes[^1] == "turn_done": break
    check "user_input" in sawTypes
    check "tool_call" in sawTypes
    check "turn_done" in sawTypes

    # Mutations never ride the socket: text frames answer the typed notice.
    wsSendText(ws, "attempted mutation")
    var notice = ""
    let noticeDeadline = getMonoTime() + initDuration(seconds = 5)
    while getMonoTime() < noticeDeadline:
      let frame = wsRecvFrame(ws)
      if frame.opcode != 1: continue
      if "\"type\":\"event\"" in frame.payload: continue
      notice = frame.payload
      break
    check "mutations_are_http_only" in notice

    # Consumed tickets cannot upgrade again, even as a genuine upgrade.
    let reuse = wsHandshake(ticket)
    defer: reuse.close()
    var reuseResponse = wsReadHead(reuse)
    var bodyChunk = newString(256)
    let bodyLen = reuse.recv(addr bodyChunk[0], 256, 2000)
    if bodyLen > 0:
      bodyChunk.setLen(bodyLen)
      reuseResponse.add bodyChunk
    check "401" in reuseResponse.splitLines()[0]
    check "ws_ticket_invalid" in reuseResponse

    # Long-poll stays live beside the socket (the designed fallback).
    check "turn_done" in wsCurl(
      "'http://127.0.0.1:8999/api/sessions/s1/events?cursor=0'")

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

    var cancelAttachment = ""
    proc curl(call: string): tuple[output: string, exitCode: int] =
      let attachmentHeader =
        if cancelAttachment.len > 0:
          "-H 'X-Gene-Attachment: " & cancelAttachment & "' "
        else:
          ""
      execCmdEx("curl -sS --max-time 5 " & attachmentHeader & call)

    check "\"id\":\"s1\"" in
      curl("-X POST http://127.0.0.1:8973/api/sessions").output
    cancelAttachment = parseJson(curl(
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"display_label\":\"test\"}' " &
      "http://127.0.0.1:8973/api/sessions/s1/attachments").output)[
        "attachment_id"].getStr()
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
    check "\"operation_kind\":\"cancel\"" in events
    check "\"origin\":\"remote\"" in events
    check "turn_done" in events
    check (getMonoTime() - started).inMilliseconds < 2000

  test "agent gateway binds pending confirmations to the initiating attachment":
    buildGeneCli()
    let endpoint = writeCliProgram("confirmation_chat_endpoint.gene", """
(import net/http [Server serve Response])
(var calls (cell 0))
(fn handle [req]
  (calls ~ set (+ (calls ~ get) 1))
  (if (== (calls ~ get) 1)
    (Response ^status 200
              ^headers {^content-type "text/event-stream"}
              ^body "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"tool_calls\":[{\"index\":0,\"id\":\"gw_confirm\",\"type\":\"function\",\"function\":{\"name\":\"run_shell\",\"arguments\":\"{\\\"command\\\":\\\"git reset --hard\\\"}\"}}]}}]}\n\ndata: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n")
    (Response ^status 200
              ^headers {^content-type "text/event-stream"}
              ^body "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"denial handled\"}}]}\n\ndata: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")))
(serve (Server ^host "127.0.0.1" ^port 8974) handle ^max_requests 2)
""")
    let endpointProc = startProcess(geneExe, args = ["run", endpoint],
                                    options = {poUsePath, poStdErrToStdOut})
    defer:
      if endpointProc.running: endpointProc.terminate()
      endpointProc.close()
    let gatewayProc = startProcess(
      "/usr/bin/env",
      args = ["-u", "CODEX_ACCESS_TOKEN", "-u", "OPENAI_API_KEY",
              "-u", "OPENAI_API", "OPENAI_AUTH_TOKEN=dummy",
              "OPENAI_BASE_URL=http://127.0.0.1:8974/v1",
              "OPENAI_MODEL=fake-chat", "GENE_GATEWAY_PORT=8975",
              geneExe, "run", "examples/ai_agent/gateway.gene"],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if gatewayProc.running: gatewayProc.terminate()
      gatewayProc.close()

    for port in [8974, 8975]:
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(port), timeout = 500)
          s.close()
          break
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline: raise
          sleep(50)

    var attachment = ""
    proc curl(call: string): string =
      let header =
        if attachment.len > 0:
          "-H 'X-Gene-Attachment: " & attachment & "' "
        else:
          ""
      let ran = execCmdEx("curl -sS --max-time 5 " & header & call)
      check ran.exitCode == 0
      ran.output

    check "\"id\":\"s1\"" in curl(
      "-X POST http://127.0.0.1:8975/api/sessions")
    let initiating = parseJson(curl(
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"display_label\":\"initiator\"}' " &
      "http://127.0.0.1:8975/api/sessions/s1/attachments"))
    let initiatingId = initiating["attachment_id"].getStr()
    let resumeCredential = initiating["resume_credential"].getStr()
    attachment = initiatingId
    check "\"ok\":true" in curl(
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"text\":\"do the destructive thing\"}' " &
      "http://127.0.0.1:8975/api/sessions/s1/messages")

    var events = ""
    let confirmationDeadline = getMonoTime() + initDuration(seconds = 5)
    while getMonoTime() < confirmationDeadline:
      events = curl(
        "'http://127.0.0.1:8975/api/sessions/s1/events?cursor=0'")
      if "confirmation_requested" in events: break
      sleep(20)
    check "confirmation_requested" in events
    check "\"confirmation_id\":\"c1\"" in events
    check "\"attachment_id\":\"" & initiatingId & "\"" in events

    let resumed = curl(
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"resume_credential\":\"" & resumeCredential & "\"}' " &
      "http://127.0.0.1:8975/api/sessions/s1/attachments/" &
      initiatingId & "/resume")
    check "\"pending_confirmations\":[{\"confirmation_id\":\"c1\"" in
      resumed

    let observer = parseJson(curl(
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"display_label\":\"observer\"}' " &
      "http://127.0.0.1:8975/api/sessions/s1/attachments"))
    attachment = observer["attachment_id"].getStr()
    let rejected = curl(
      "-w '\n%{http_code}' -X POST -H 'content-type: application/json' " &
      "-d '{\"decision\":\"deny\"}' " &
      "http://127.0.0.1:8975/api/sessions/s1/confirmations/c1")
    check "confirmation_not_owned" in rejected
    check rejected.strip().endsWith("403")

    attachment = initiatingId
    check "\"decision\":\"deny\"" in curl(
      "-X POST -H 'Idempotency-Key: confirmation-c1' " &
      "-H 'content-type: application/json' " &
      "-d '{\"decision\":\"deny\"}' " &
      "http://127.0.0.1:8975/api/sessions/s1/confirmations/c1")
    let doneDeadline = getMonoTime() + initDuration(seconds = 5)
    while getMonoTime() < doneDeadline:
      events = curl(
        "'http://127.0.0.1:8975/api/sessions/s1/events?cursor=0'")
      if "turn_done" in events: break
      sleep(20)
    check "confirmation_resolved" in events
    check "destructive command was not confirmed" in events
    check "denial handled" in events
    check "turn_done" in events

  test "agent gateway persists sessions across restarts":
    ## Milestone 11 e2e: run a turn with GENE_GATEWAY_DB set, kill the
    ## gateway, restart on the same db — the event history must be intact,
    ## the restored session must accept another turn (versions continue),
    ## and new session ids must not collide with restored ones.
    buildGeneCli()
    let dbPath = cliDir / "gateway_persist.sqlite"
    # A prior run's WAL/journal sidecars would replay old sessions into the
    # "fresh" db (session ids start at s2+, breaking the s1 expectations), so
    # every SQLite file must go, not just the main db.
    for suffix in ["", "-wal", "-shm", "-journal"]:
      removeFile(dbPath & suffix)

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

    var persistAttachment = ""

    proc persistCurl(call: string): tuple[output: string, exitCode: int] =
      let attachmentHeader =
        if persistAttachment.len > 0:
          "-H 'X-Gene-Attachment: " & persistAttachment & "' "
        else:
          ""
      execCmdEx("curl -sS --max-time 5 " & attachmentHeader & call)

    proc attachPersistedSession() =
      persistAttachment = ""
      persistAttachment = parseJson(persistCurl(
        "-X POST -H 'content-type: application/json' " &
        "-d '{\"display_label\":\"persistence-test\"}' " &
        "http://127.0.0.1:8997/api/sessions/s1/attachments").output)[
          "attachment_id"].getStr()

    proc waitTurn(cursor: int): string =
      let deadline = getMonoTime() + initDuration(seconds = 15)
      while getMonoTime() < deadline:
        let ran = persistCurl(
          "'http://127.0.0.1:8997/api/sessions/s1/events?cursor=" &
          $cursor & "'")
        if ran.exitCode == 0:
          result = ran.output
          if "turn_done" in result:
            return
        sleep(200)
      checkpoint "turn never completed: " & result
      check false

    # A crashed earlier run can orphan a gateway that still owns the port; the
    # fresh gateway then fails to bind and every request below hits the stale
    # process instead (session ids drift past s1). Reclaim the port up front,
    # and wait for the kill to actually release it before binding.
    discard execCmdEx("lsof -ti tcp:8997 | xargs kill 2>/dev/null")
    block waitPortFree:
      let deadline = getMonoTime() + initDuration(seconds = 5)
      while getMonoTime() < deadline:
        var probe = newSocket()
        try:
          probe.connect("127.0.0.1", Port(8997), timeout = 200)
          probe.close()
          sleep(50)
        except OSError, TimeoutError:
          probe.close()
          break waitPortFree

    var gw = startGw()
    defer:
      if gw.running:
        gw.terminate()
      gw.close()
    waitPort()
    let created = persistCurl(
      "-X POST http://127.0.0.1:8997/api/sessions")
    check "\"id\":\"s1\"" in created.output
    attachPersistedSession()
    discard persistCurl(
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"text\":\"list it\"}' " &
      "http://127.0.0.1:8997/api/sessions/s1/messages")
    let firstTurn = waitTurn(0)
    check "list_dir tool" in firstTurn
    # Slice A / review #2: the per-session log carries the full tool trail, not
    # just streamed text — the demo transport invokes list_dir.
    check "tool_call" in firstTurn
    check "tool_result" in firstTurn
    let durableWorker = persistCurl(
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"kind\":\"output\",\"config\":{\"title\":\"durable-checks\",\"text\":\"saved\"}}' " &
      "http://127.0.0.1:8997/api/sessions/s1/workers")
    check "\"worker_id\":\"w1\"" in durableWorker.output
    gw.terminate()
    discard gw.waitForExit()
    gw.close()

    gw = startGw()
    waitPort()
    attachPersistedSession()
    # History restored verbatim, including the structured tool events.
    let restored = persistCurl(
      "'http://127.0.0.1:8997/api/sessions/s1/events?cursor=0'")
    check "\"v\":1" in restored.output
    check "list it" in restored.output
    check "list_dir tool" in restored.output
    check "tool_call" in restored.output
    check "tool_result" in restored.output
    let restoredWorkers = persistCurl(
      "http://127.0.0.1:8997/api/sessions/s1/workers")
    check "\"worker_id\":\"w1\"" in restoredWorkers.output
    check "\"title\":\"durable-checks\"" in restoredWorkers.output
    let restoredSnapshot = persistCurl(
      "http://127.0.0.1:8997/api/sessions/s1/snapshot")
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
    let second = persistCurl(
      "-X POST http://127.0.0.1:8997/api/sessions")
    check "\"id\":\"s2\"" in second.output
    # The restored session keeps working, with versions continuing past maxV.
    discard persistCurl(
      "-X POST -H 'content-type: application/json' " &
      "-d '{\"text\":\"again\"}' " &
      "http://127.0.0.1:8997/api/sessions/s1/messages")
    let contTurn = waitTurn(maxV)
    check ("\"v\":" & $(maxV + 1)) in contTurn

  test "C9 acceptance: one scenario is semantically identical across shapes":
    ## design.md §10.12 acceptance: one scripted scenario — attach two
    ## clients, run a destructive turn to a confirmation and deny it as the
    ## initiator (the observer's answer is rejected), delegate to a
    ## sub-agent, observe it, read+incorporate its result, /pin it, and
    ## resume the initiating attachment by credential — runs in Shape A
    ## (combined TUI+gateway under a PTY), Shape B (headless service,
    ## long-poll), and Shape C (headless service, WebSocket delivery).
    ## Comparison is SEMANTIC: after dropping provenance (v, attachment,
    ## principal, surface, timing), renaming correlation ids by first
    ## appearance, and collapsing the standalone journal's compatibility
    ## double-write, the event type sequence, causal order, and operation
    ## results must be identical across shapes. The observer stays attached
    ## throughout; a silent third client neither stalls anyone nor loses
    ## its from-zero read (journal-trim gaps + recovery are separately
    ## covered by the headless-lifecycle test; WS bounded-queue gaps by the
    ## stage-4 test).
    buildGeneCli()
    let endpoint = writeCliProgram("acceptance_chat_endpoint.gene", """
(import net/http [Server serve Response])
(import str [contains?])
(var calls (cell 0))
(fn sse [body]
  (Response ^status 200
            ^headers {^content-type "text/event-stream"}
            ^body body))
(fn handle [req]
  (if (contains? req/path "/reset")
    (do
      (calls ~ set 0)
      (Response ^status 200 ^body "reset"))
    (do
      (calls ~ set (+ (calls ~ get) 1))
      (match (calls ~ get)
        (when 1
          (sse "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"tool_calls\":[{\"index\":0,\"id\":\"acc_confirm\",\"type\":\"function\",\"function\":{\"name\":\"run_shell\",\"arguments\":\"{\\\"command\\\":\\\"git reset --hard\\\"}\"}}]}}]}\n\ndata: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n"))
        (when 2
          (sse "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"denial handled\"}}]}\n\ndata: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"))
        (else
          (sse "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"sub agent report\"}}]}\n\ndata: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"))))))
(serve (Server ^host "127.0.0.1" ^port 9002) handle)
""")
    let endpointProc = startProcess(geneExe, args = ["run", endpoint],
                                    options = {poUsePath, poStdErrToStdOut})
    defer:
      if endpointProc.running: endpointProc.terminate()
      endpointProc.close()

    proc waitPort(port: int) =
      let deadline = getMonoTime() + initDuration(seconds = 15)
      while true:
        var s = newSocket()
        try:
          s.connect("127.0.0.1", Port(port), timeout = 500)
          s.close()
          break
        except OSError, TimeoutError:
          s.close()
          if getMonoTime() > deadline: raise
          sleep(50)
    waitPort(9002)

    type ShapeResult = object
      events: JsonNode        # normalized scenario events, in order
      results: JsonNode       # scalar operation results

    proc runScenario(port: int, sessionId: string): ShapeResult =
      let base = "http://127.0.0.1:" & $port
      proc api(attachment, call: string): string =
        let header =
          if attachment.len > 0:
            "-H 'X-Gene-Attachment: " & attachment & "' "
          else:
            ""
        let ran = execCmdEx("curl -sS --max-time 10 " & header & call)
        check ran.exitCode == 0
        ran.output
      proc attach(label: string): JsonNode =
        parseJson(api("",
          "-X POST -H 'content-type: application/json' " &
          "-d '{\"display_label\":\"" & label & "\"}' " &
          base & "/api/sessions/" & sessionId & "/attachments"))
      let c1 = attach("initiator")
      let c2 = attach("observer")
      let c3 = attach("silent")
      let c1Id = c1["attachment_id"].getStr()
      let c2Id = c2["attachment_id"].getStr()
      let baseline = c2["acknowledged_cursor"].getInt()
      let credential = c1["resume_credential"].getStr()

      proc eventsFrom(attachment: string, cursor: int): JsonNode =
        parseJson(api(attachment,
          "'" & base & "/api/sessions/" & sessionId & "/events?cursor=" &
          $cursor & "'"))
      proc waitEvent(kind: string): JsonNode =
        let deadline = getMonoTime() + initDuration(seconds = 20)
        while getMonoTime() < deadline:
          let batch = eventsFrom(c2Id, baseline)
          for ev in batch["events"]:
            if ev["type"].getStr() == kind:
              return ev
          sleep(100)
        checkpoint "event never arrived: " & kind
        check false
      proc waitTurnDone(count: int) =
        let deadline = getMonoTime() + initDuration(seconds = 25)
        while getMonoTime() < deadline:
          let batch = eventsFrom(c2Id, baseline)
          var seen = 0
          for ev in batch["events"]:
            if ev["type"].getStr() == "turn_done": inc seen
          if seen >= count: return
          sleep(100)
        checkpoint "turn " & $count & " never completed"
        check false

      # 1. Destructive turn -> initiator-bound confirmation, denied by c1.
      discard api(c1Id,
        "-X POST -H 'Idempotency-Key: acc-m1' " &
        "-H 'content-type: application/json' " &
        "-d '{\"text\":\"please reset\"}' " &
        base & "/api/sessions/" & sessionId & "/messages")
      let confirmation = waitEvent("confirmation_requested")
      let confirmationId = confirmation["confirmation_id"].getStr()
      let rejected = api(c2Id,
        "-w '\n%{http_code}' -X POST -H 'content-type: application/json' " &
        "-d '{\"decision\":\"deny\"}' " &
        base & "/api/sessions/" & sessionId & "/confirmations/" &
        confirmationId)
      check "confirmation_not_owned" in rejected
      check rejected.strip().endsWith("403")
      discard api(c1Id,
        "-X POST -H 'Idempotency-Key: acc-c1' " &
        "-H 'content-type: application/json' " &
        "-d '{\"decision\":\"deny\"}' " &
        base & "/api/sessions/" & sessionId & "/confirmations/" &
        confirmationId)
      waitTurnDone(1)

      # 2. Delegate, observe, read + incorporate the sub-agent result.
      let agentCreated = parseJson(api(c1Id,
        "-X POST -H 'Idempotency-Key: acc-a1' " &
        "-H 'content-type: application/json' " &
        "-d '{\"assignment\":\"review the reset\",\"title\":\"reviewer\"}' " &
        base & "/api/sessions/" & sessionId & "/agents"))
      let agentId = agentCreated["agent_id"].getStr()
      discard api(c1Id,
        "-X POST -H 'Idempotency-Key: acc-a1m' " &
        "-H 'content-type: application/json' " &
        "-d '{\"text\":\"report\"}' " &
        base & "/api/sessions/" & sessionId & "/agents/" & agentId &
        "/messages")
      var agentResult = ""
      block waitAgentResult:
        let deadline = getMonoTime() + initDuration(seconds = 25)
        while getMonoTime() < deadline:
          agentResult = api(c1Id,
            base & "/api/sessions/" & sessionId & "/agents/" & agentId &
            "/result")
          if "sub agent report" in agentResult: break waitAgentResult
          sleep(150)
        checkpoint "sub-agent result never arrived: " & agentResult
        check false
      let status = parseJson(api(c2Id,
        base & "/api/sessions/" & sessionId & "/workers/" & agentId &
        "/status"))
      let tail = api(c2Id,
        "'" & base & "/api/sessions/" & sessionId & "/workers/" & agentId &
        "/tail?n=3'")
      discard api(c1Id,
        "-X POST " & base & "/api/sessions/" & sessionId & "/agents/" &
        agentId & "/result/read")
      discard api(c1Id,
        "-X POST " & base & "/api/sessions/" & sessionId & "/agents/" &
        agentId & "/incorporate")

      # 3. Pin the result as durable evidence.
      let pinned = parseJson(api(c1Id,
        "-X POST -H 'Idempotency-Key: acc-pin' " &
        "-H 'content-type: application/json' " &
        "-d '{\"source\":\"result\",\"worker_id\":\"" & agentId & "\"}' " &
        base & "/api/sessions/" & sessionId & "/artifacts"))

      # 4. Reconnect: resume the initiating attachment by credential, then
      # acknowledge the current cursor.
      let resumed = parseJson(api("",
        "-X POST -H 'content-type: application/json' " &
        "-d '{\"resume_credential\":\"" & credential & "\"}' " &
        base & "/api/sessions/" & sessionId & "/attachments/" & c1Id &
        "/resume"))
      let latest = eventsFrom(c2Id, baseline)
      let lastCursor = latest["cursor"].getInt()
      let ackedNode = parseJson(api(c1Id,
        "-X POST -H 'Idempotency-Key: acc-ack' " &
        "-H 'content-type: application/json' " &
        "-d '{\"cursor\":" & $lastCursor & "}' " &
        base & "/api/sessions/" & sessionId & "/attachments/" & c1Id &
        "/ack"))

      # The silent third client never stalled anyone; its from-zero read
      # still works after the whole scenario.
      let silentRead = eventsFrom(c3["attachment_id"].getStr(), baseline)
      check silentRead.hasKey("events")

      result.events = latest["events"]
      result.results = %*{
        "confirmation_rejected_for_observer": true,
        "agent_status_kind": status["result"]["kind"].getStr(),
        "agent_status_lifecycle": status["result"]["lifecycle"].getStr(),
        "tail_has_report": "sub agent report" in tail,
        "result_text_seen": "sub agent report" in agentResult,
        "artifact_ok": pinned["ok"].getBool(),
        "resume_attachment_matches":
          resumed["attachment_id"].getStr() == c1Id,
        "acked_cursor_advanced":
          ackedNode["acknowledged_cursor"].getInt() > 0}

    proc normalize(shape: ShapeResult): JsonNode =
      ## Provenance-normalized semantic view (the acceptance rule): drop
      ## journal cursors/attachment/principal/surface/timing, rename
      ## correlation ids by first appearance, collapse the standalone
      ## compatibility double-write of identical adjacent events.
      var idMap = newJObject()
      var counters = %*{"T": 0, "A": 0, "W": 0, "C": 0}
      proc mapId(prefix, raw: string): string =
        let key = prefix & ":" & raw
        if not idMap.hasKey(key):
          counters[prefix] = %(counters[prefix].getInt() + 1)
          idMap[key] = %(prefix & $counters[prefix].getInt())
        idMap[key].getStr()
      proc normWorker(raw: string): string =
        if raw == "main": "main"
        elif raw.startsWith("a"): mapId("A", raw)
        else: mapId("W", raw)
      result = newJArray()
      var previous = ""
      for ev in shape.events:
        # text_delta/agent_text are the additive agent-protocol
        # compatibility records; the canonical producer boundary both
        # shapes share is the derived worker_output event (same text), so
        # the semantic comparison runs on that.
        if ev["type"].getStr() in ["text_delta", "agent_text"]:
          continue
        var obj = newJObject()
        for key in ev.keys:
          if key in ["v", "attachment_id", "principal", "surface",
                     "duration_ms", "turn", "seq", "source_v",
                     "created_ms", "pane_id"]:
            continue
          obj[key] = ev[key]
        if obj.hasKey("task_id") and obj["task_id"].kind == JString:
          obj["task_id"] = %mapId("T", obj["task_id"].getStr())
        if obj.hasKey("confirmation_id"):
          obj["confirmation_id"] = %mapId("C", obj["confirmation_id"].getStr())
        for key in ["worker_id", "agent_id", "caller_worker_id",
                    "parent_agent_id"]:
          if obj.hasKey(key) and obj[key].kind == JString:
            obj[key] = %normWorker(obj[key].getStr())
        let canonical = $obj
        if canonical == previous:
          continue
        previous = canonical
        result.add obj

    # ---- Shape B: headless service over long-poll --------------------------
    let stateB = cliDir / "acceptance_state_b"
    if dirExists(stateB): removeDir(stateB)
    defer:
      if dirExists(stateB): removeDir(stateB)
    var shapeBProc = startProcess(
      "/usr/bin/env",
      args = ["-u", "CODEX_ACCESS_TOKEN", "-u", "OPENAI_API_KEY",
              "-u", "OPENAI_API", "-u", "TELEGRAM_BOT_TOKEN",
              "OPENAI_AUTH_TOKEN=dummy",
              "OPENAI_BASE_URL=http://127.0.0.1:9002/v1",
              "OPENAI_MODEL=fake-chat", "GENE_GATEWAY_PORT=9102",
              "GENE_AGENT_STATE=fs:" & stateB,
              geneExe, "run", "examples/ai_agent/gateway.gene"],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if shapeBProc.running: shapeBProc.terminate()
      shapeBProc.close()
    waitPort(9102)
    check "\"id\":\"s1\"" in execCmdEx(
      "curl -sS --max-time 5 -X POST http://127.0.0.1:9102/api/sessions").output
    let shapeB = runScenario(9102, "s1")
    shapeBProc.terminate()
    discard shapeBProc.waitForExit(5000)
    discard execCmdEx("curl -sS --max-time 5 http://127.0.0.1:9002/reset")

    # ---- Shape C: headless service, WebSocket delivery ---------------------
    let stateC = cliDir / "acceptance_state_c"
    if dirExists(stateC): removeDir(stateC)
    defer:
      if dirExists(stateC): removeDir(stateC)
    var shapeCProc = startProcess(
      "/usr/bin/env",
      args = ["-u", "CODEX_ACCESS_TOKEN", "-u", "OPENAI_API_KEY",
              "-u", "OPENAI_API", "-u", "TELEGRAM_BOT_TOKEN",
              "OPENAI_AUTH_TOKEN=dummy",
              "OPENAI_BASE_URL=http://127.0.0.1:9002/v1",
              "OPENAI_MODEL=fake-chat", "GENE_GATEWAY_PORT=9103",
              "GENE_AGENT_STATE=fs:" & stateC,
              geneExe, "run", "examples/ai_agent/gateway.gene"],
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if shapeCProc.running: shapeCProc.terminate()
      shapeCProc.close()
    waitPort(9103)
    check "\"id\":\"s1\"" in execCmdEx(
      "curl -sS --max-time 5 -X POST http://127.0.0.1:9103/api/sessions").output
    # WS delivery rides beside the scenario: attach, mint a ticket, upgrade,
    # and count delivered event frames while the same scenario runs over
    # HTTP. Frame delivery must reach the same terminal event.
    let wsAttachment = parseJson(execCmdEx(
      "curl -sS --max-time 5 -X POST -H 'content-type: application/json' " &
      "-d '{\"display_label\":\"ws-observer\"}' " &
      "http://127.0.0.1:9103/api/sessions/s1/attachments").output)[
        "attachment_id"].getStr()
    let wsTicket = parseJson(execCmdEx(
      "curl -sS --max-time 5 -X POST -H 'X-Gene-Attachment: " &
      wsAttachment & "' " &
      "http://127.0.0.1:9103/api/sessions/s1/ws_ticket").output)[
        "ticket"].getStr()
    var wsSock = newSocket()
    wsSock.connect("127.0.0.1", Port(9103), timeout = 2000)
    wsSock.send("GET /api/sessions/s1/ws?ticket=" & wsTicket &
      " HTTP/1.1\r\nHost: 127.0.0.1:9103\r\nUpgrade: websocket\r\n" &
      "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
      "Sec-WebSocket-Version: 13\r\n\r\n")
    var wsHead = ""
    while "\r\n\r\n" notin wsHead:
      var ch: char
      if wsSock.recv(addr ch, 1, 2000) != 1: break
      wsHead.add ch
    check "101" in wsHead.splitLines()[0]
    let shapeC = runScenario(9103, "s1")
    # Drain WS frames accumulated during the scenario; the stream must have
    # delivered the same terminal turn_done the journal shows.
    proc wsRecvAll(sock: Socket): seq[string] =
      var buf = ""
      var chunk = newString(4096)
      while true:
        var n: int
        try:
          n = sock.recv(addr chunk[0], 4096, 500)
        except OSError, TimeoutError:
          break
        if n <= 0: break
        buf.add chunk[0 ..< n]
      var pos = 0
      while pos + 2 <= buf.len:
        let b1 = int(byte(buf[pos + 1])) and 0x7F
        var ln = b1
        var header = 2
        if b1 == 126:
          if pos + 4 > buf.len: break
          ln = (int(byte(buf[pos + 2])) shl 8) or int(byte(buf[pos + 3]))
          header = 4
        elif b1 == 127:
          break
        if pos + header + ln > buf.len: break
        result.add buf[pos + header ..< pos + header + ln]
        pos += header + ln
    let wsFrames = wsRecvAll(wsSock)
    wsSock.close()
    var wsSawTurnDone = false
    for frame in wsFrames:
      if "\"turn_done\"" in frame: wsSawTurnDone = true
    check wsSawTurnDone
    shapeCProc.terminate()
    discard shapeCProc.waitForExit(5000)
    discard execCmdEx("curl -sS --max-time 5 http://127.0.0.1:9002/reset")

    # ---- Shape A: combined TUI + gateway under a PTY -----------------------
    let stateA = cliDir / "acceptance_state_a"
    if dirExists(stateA): removeDir(stateA)
    defer:
      if dirExists(stateA): removeDir(stateA)
    let shapeALog = cliDir / "acceptance_shape_a.ts"
    let shapeACmd =
      "tail -f /dev/null | script -q " & shellQuote(shapeALog) &
      " /usr/bin/env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY -u OPENAI_API " &
      "-u TELEGRAM_BOT_TOKEN OPENAI_AUTH_TOKEN=dummy " &
      "OPENAI_BASE_URL=http://127.0.0.1:9002/v1 OPENAI_MODEL=fake-chat " &
      "GENE_AGENT_STATE=fs:" & shellQuote(stateA) & " " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene --gateway=9104"
    var shapeAProc = startProcess("/bin/sh", args = ["-c", shapeACmd],
                                  options = {poUsePath, poStdErrToStdOut})
    defer:
      if shapeAProc.running: shapeAProc.terminate()
      shapeAProc.close()
      discard execCmdEx("lsof -ti tcp:9104 | xargs kill 2>/dev/null")
    waitPort(9104)
    let shapeA = runScenario(9104, "local")

    # ---- Semantic comparison ----------------------------------------------
    let normA = normalize(shapeA)
    let normB = normalize(shapeB)
    let normC = normalize(shapeC)
    if normB != normC:
      checkpoint "shape B: " & $normB
      checkpoint "shape C: " & $normC
    check normB == normC
    if normA != normB:
      checkpoint "shape A: " & $normA
      checkpoint "shape B: " & $normB
    check normA == normB
    if shapeA.results != shapeB.results or shapeB.results != shapeC.results:
      checkpoint "results A: " & $shapeA.results
      checkpoint "results B: " & $shapeB.results
      checkpoint "results C: " & $shapeC.results
    check shapeA.results == shapeB.results
    check shapeB.results == shapeC.results

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
(import gene/stream [to_stream into])

(var served-updates (cell false))
(var served-commands (cell false))
(var outbox (cell []))
(var next-mid (cell 100))

(fn append-out [entry]
  (outbox ~ set ((to_stream [entry]) ~ into (outbox ~ get))))

(fn outbox-has-answer? []
  (var found (cell false))
  (for entry in (outbox ~ get)
    (if (contains? (stringify entry) "I listed the workspace")
      (found ~ set true)))
  (found ~ get))

(fn json_response [value]
  (Response ^status 200
            ^headers {^content-type "application/json"}
            ^body (stringify value)))

(fn handle [req]
  (if (contains? req/path "/getUpdates")
    (if (served-updates ~ get)
      (if (&& (! (served-commands ~ get)) (outbox-has-answer?))
        (do
          # C9 stage 6: channel-tier commands go out only after the first
          # turn's final answer is mirrored, so their responses are
          # deterministic.
          (served-commands ~ set true)
          (json_response
            {^ok true
             ^result [{^update_id 3
                       ^message {^message_id 12 ^chat {^id 42}
                                 ^text "/status main"}}
                      {^update_id 4
                       ^message {^message_id 13 ^chat {^id 42}
                                 ^text "/run main printf hi"}}
                      {^update_id 5
                       ^message {^message_id 14 ^chat {^id 42}
                                 ^text "/frobnicate main"}}
                      {^update_id 6
                       ^message {^message_id 15 ^chat {^id 42}
                                 ^text "/operations"}}]}))
        (do
          (sleep 400)
          (json_response {^ok true ^result []})))
      (do
        (served-updates ~ set true)
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
        (next-mid ~ set (+ (next-mid ~ get) 1))
        (append-out {^method "sendMessage" ^chat_id payload/chat_id
                     ^text payload/text ^message_id (next-mid ~ get)})
        (json_response {^ok true
                        ^result {^message_id (next-mid ~ get)}}))
      (if (contains? req/path "/editMessageText")
        (do
          (var payload (parse req/body))
          (append-out {^method "editMessageText" ^chat_id payload/chat_id
                       ^message_id payload/message_id ^text payload/text})
          (json_response {^ok true ^result true}))
        (if (== req/path "/outbox")
          (json_response {^outbox (outbox ~ get)})
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

    # C9 stage 6: after the turn, the fake serves channel-tier commands. The
    # allowlist derives from the operation registry (observe-only effects);
    # everything else answers a typed denial, and unknown commands point at
    # /operations.
    block waitChannelCommands:
      let deadline = getMonoTime() + initDuration(seconds = 20)
      while getMonoTime() < deadline:
        let ran = execCmdEx("curl -sS --max-time 5 http://127.0.0.1:8994/outbox")
        if ran.exitCode == 0:
          outbox = ran.output
          if "observe-only tier" in outbox and "unknown_command" in outbox:
            break waitChannelCommands
        sleep(250)
      checkpoint "telegram channel commands never answered: " & outbox
      check false
    check "/status main -> " in outbox
    check "\\\"kind\\\":\\\"agent\\\"" in outbox
    check ("channel_denied: /run requires effects [host_write] beyond the " &
           "observe-only channel tier") in outbox
    check "unknown_command: /frobnicate" in outbox
    check "/tail <worker> - Read recent bounded output." in outbox
    check "/run <worker>" notin outbox
    # The turn also shows up in the gateway session log under tg-42. Reading
    # events is an attached-client action (C9), so establish an attachment
    # and pass its header.
    let att = execCmdEx(
      "curl -sS --max-time 5 -X POST " &
      "'http://127.0.0.1:8995/api/sessions/tg-42/attachments'")
    check att.exitCode == 0
    let attId = parseJson(att.output)["attachment_id"].getStr()
    let events = execCmdEx(
      "curl -sS --max-time 5 -H 'X-Gene-Attachment: " & attId & "' " &
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

  test "style guide is the byte-exact formatter contract":
    buildGeneCli()
    let source = readFile("examples/style_guide.gene")
    let formatted = execCmdEx(
      shellQuote(geneExe) & " fmt examples/style_guide.gene")
    check formatted.exitCode == 0
    check formatted.output == source

    let path = writeCliProgram("fmt_style_layout.gene",
      "(fn layout [cond]\n" &
      "    (var value\n" &
      "        (build_value cond))\n" &
      "    (if_yes cond\n" &
      "        (record value)\n" &
      "        (publish value))\n" &
      "    (if cond\n" &
      "      (then\n" &
      "      (record value)\n" &
      "      (publish value))\n" &
      "      (else\n" &
      "      (discard value)))\n" &
      "    (if cond (accept value)\n" &
      "      (reject value))\n" &
      "    #(item ^value value))\n")
    let layout = runGene(["fmt", path])
    check layout.exitCode == 0
    check layout.output ==
      "(fn layout [cond]\n" &
      "  (var value (build_value cond))\n" &
      "  (if_yes cond\n" &
      "    (record value)\n" &
      "    (publish value))\n" &
      "  (if cond\n" &
      "    (then\n" &
      "      (record value)\n" &
      "      (publish value))\n" &
      "    (else\n" &
      "      (discard value)))\n" &
      "  (if cond\n" &
      "    (accept value)\n" &
      "    (reject value))\n" &
      "  #(item ^value value))\n"

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
    ## Stages 3-4 (docs/serialization.md §5-§7): type/enum/variant/
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
  (ctor [start] (println "COUNTER-CTOR-RAN") (self ~ set_prop! `n start)))
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
(reg2 ~ set_prop! `marker 99)
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
