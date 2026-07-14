import std/[monotimes, net, os, osproc, streams, strutils, times, unittest]
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

  test "ai agent slash sh opens a shell loop":
    buildGeneCli()
    let command = "printf '/sh\\nprintf hi\\nexit\\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    check "Entering shell" in ran.output
    check "hi" in ran.output
    check "sh> \nyou>" in ran.output

  test "ai agent ignores blank input":
    buildGeneCli()
    let command = "printf '   \\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    check "agent>" notin ran.output

  test "ai agent slash repl exposes session binding":
    buildGeneCli()
    let command = "printf '/repl\\nsession/config/model\\n(var x 41)\\n(+ x 1)\\nquit\\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    check "Entering Gene REPL" in ran.output
    # session/config/model is a real projection (model lives under config,
    # §9.1); the quoted form is the REPL value, distinct from the banner text.
    check "\"gpt-5.4-mini\"" in ran.output
    check "41" in ran.output
    check "42" in ran.output

  test "ai agent repl eof returns to agent prompt":
    buildGeneCli()
    let command = "printf '/repl\\nsession/model\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    check "gpt-5.4-mini" in ran.output
    check "gene> \nyou>" in ran.output

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
    check "model: gpt-5.4-mini" in second.output
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
    let command = "printf '/sh\\nrm -rf /nonexistent-gene-guard-root\\necho ran-normal\\nexit\\n/quit\\n' | " &
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
      "(classify_command \"rm -rf /\")\\n" &
      "(classify_command \"rm -rf $HOME\")\\n" &
      "(classify_command \"shutdown -h now\")\\n" &
      "(classify_command \"git reset --hard HEAD~1\")\\n" &
      "(classify_command \"npm test\")\\n" &
      "quit\\n/quit\\n' | " &
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
      "(session ~ add_tool (Tool ^name \"badres\" ^description \"demo\" " &
      "^risk \"read\" ^params [] ^handler (fn [a] nil)))\\n" &
      "(session ~ resume)\\nexit\\n/quit\\n' | " &
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
    let input = "go\n/diff\n/sh\nprintf external > dirty.txt\nexit\n" &
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
    let command = "printf '/repl\n(session/evidence ~ Cell/get)\nquit\n" &
      "go\n/trace type=check\n/repl\n(session/evidence ~ Cell/get)\n" &
      "quit\n/quit\n' | env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
      "OPENAI_AUTH_TOKEN=dummy OPENAI_API=chat " &
      "GENE_AGENT_STATE=" & shellQuote(stateDir) & " " &
      "OPENAI_BASE_URL=http://127.0.0.1:8965/v1 OPENAI_MODEL=fake-chat " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(command)
    check ran.exitCode == 0
    check "gene> []" in ran.output
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
      "printf '/status\n/repl\nsession/config\nquit\n/quit\n' | " &
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
      " && printf 'go\n/status\n/repl\n(session/instructions ~ Cell/get)\n" &
      "quit\n/quit\n' | env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
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
      "(session ~ add_tool (Tool ^name \"ping\" ^description \"demo\" " &
      "^risk \"read\" ^params [] ^handler (fn [a] \"pong\")))\\n" &
      "(session ~ resume)\\nexit\\n/quit\\n' | " &
      "env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY -u OPENAI_API " &
      "OPENAI_AUTH_TOKEN=dummy " &
      "OPENAI_BASE_URL=http://127.0.0.1:8992/v1 OPENAI_MODEL=fake-chat " &
      shellQuote(geneExe) & " run examples/ai_agent/tui.gene"
    let ran = execCmdOnce(script)
    check ran.exitCode == 0
    check "verdict: ping-visible" in ran.output

  test "ai agent SIGINT cancels a model turn and accepts steering":
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
      check "agent> steered" in output
      check "tool_call run_shell" in output
      check "check command status=nil" in output
      let events = readFile(eventsFile)
      check "^type \"check\"" in events
      check "^cancelled true" in events
      check events.count("^kind \"cancelled\"") == 1

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
      # newest -> oldest -> newest, then submit
      terminal.inputStream.write("\e[A\e[A\e[B\n")
      terminal.inputStream.flush()
      terminal.inputStream.close()
      let exitCode = terminal.waitForExit(5000)
      let output = readFile(outputFile)
      if exitCode != 0: checkpoint output
      check exitCode == 0
      check "CURSES-HISTORY:second command" in output
      check "[SCROLL +" notin output
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
    # Concurrency: serial turns would take >= 1800ms against a 900ms
    # endpoint; parallel sessions finish in roughly one latency. The margin
    # is generous (vs. the 1800ms serial floor) because a full `nimble verify`
    # run contends for cores and can stretch the two concurrent turns.
    check elapsedMs < 1750

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
