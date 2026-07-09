import std/[monotimes, net, os, osproc, strutils, times, unittest]
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
      "(fn main [args] (if (= args/0 \"ok\") 0 4))")
    let ran = runGene(["run", argMain, "ok"])
    check ran.exitCode == 0

  test "main receives raw command-line argument tail":
    let rawMain = writeCliProgram("raw_arg_main.gene",
      "(fn main [args] (if (= args/raw \"a b, c\") 0 4))")
    let ran = runGene(["run", rawMain, "a", "b,", "c"])
    check ran.exitCode == 0

  test "main parameter boundary errors include source location":
    let typedMain = writeCliProgram("typed_arg_main.gene",
      "(fn main [args : (List Str)] nil)")
    let ran = runGene(["run", typedMain, "x"])
    check ran.exitCode == 1
    check "parameter 'args' expected (List Str), got vkNode" in ran.output
    check ("at " & normalizedPath(absolutePath(typedMain)) & ":1:1") in ran.output

  test "ai agent example runs offline demo without an auth token":
    buildGeneCli()
    let ran = execCmdEx("env -u OPENAI_AUTH_TOKEN -u OPENAI_API_KEY " &
                        "-u CODEX_ACCESS_TOKEN " &
                        shellQuote(geneExe) & " run examples/ai_agent.gene")
    check ran.exitCode == 0
    check "No OPENAI_AUTH_TOKEN, OPENAI_API_KEY, or CODEX_ACCESS_TOKEN set" in
      ran.output
    check "agent>   · tool list_dir" in ran.output
    check "Demo complete" in ran.output

  test "ai agent slash sh opens a shell loop":
    buildGeneCli()
    let command = "printf '/sh\\nprintf hi\\nexit\\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent.gene"
    let ran = execCmdEx(command)
    check ran.exitCode == 0
    check "Entering shell" in ran.output
    check "hi" in ran.output
    check "sh> \nyou>" in ran.output

  test "ai agent ignores blank input":
    buildGeneCli()
    let command = "printf '   \\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent.gene"
    let ran = execCmdEx(command)
    check ran.exitCode == 0
    check "agent>" notin ran.output

  test "ai agent slash repl exposes session binding":
    buildGeneCli()
    let command = "printf '/repl\\nsession/model\\n(var x 41)\\n(+ x 1)\\nquit\\n/quit\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent.gene"
    let ran = execCmdEx(command)
    check ran.exitCode == 0
    check "Entering Gene REPL" in ran.output
    check "gpt-5.4-mini" in ran.output
    check "41" in ran.output
    check "42" in ran.output

  test "ai agent repl eof returns to agent prompt":
    buildGeneCli()
    let command = "printf '/repl\\nsession/model\\n' | " &
                  "env -u OPENAI_AUTH_TOKEN CODEX_ACCESS_TOKEN=dummy " &
                  shellQuote(geneExe) & " run examples/ai_agent.gene"
    let ran = execCmdEx(command)
    check ran.exitCode == 0
    check "gpt-5.4-mini" in ran.output
    check "gene> \nyou>" in ran.output

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
        (if (&& (= m/role "assistant")
                (= m/tool_calls/0/id "call_fake_1")
                (= m/tool_calls/0/function/name "list_dir"))
          (Cell/set saw-assistant-call true)
          nil)
        (if (&& (= m/role "tool")
                (= m/tool_call_id "call_fake_1"))
          (Cell/set saw-tool-reply true)
          nil)))
  (if (! (= req/model "fake-chat"))
    "roundtrip-bad: model"
    (if (! (= req/tools/0/function/name "read_file"))
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
  (var chunks (if (= (Cell/get hits) 1) turn1 (turn2-chunks req/body)))
  (Response ^status 200
            ^headers {^content-type "text/event-stream"}
            ^body (sse-body chunks)))

(serve (Server ^host "127.0.0.1" ^port 8987) handle ^max-requests 2)
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
    let ran = execCmdEx("env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
                        "-u OPENAI_API OPENAI_AUTH_TOKEN=dummy " &
                        "OPENAI_BASE_URL=http://127.0.0.1:8987/v1 " &
                        "OPENAI_MODEL=fake-chat " &
                        shellQuote(geneExe) &
                        " run examples/ai_agent.gene 'what is here?'")
    check ran.exitCode == 0
    check "tool list_dir" in ran.output
    check "verdict: roundtrip-ok" in ran.output

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
  (var chunks (if (= (Cell/get hits) 1) turn1 (turn2-chunks req/body)))
  (Response ^status 200
            ^headers {^content-type "text/event-stream"}
            ^body (sse-body chunks)))

(serve (Server ^host "127.0.0.1" ^port 8991) handle ^max-requests 2)
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
    let ran = execCmdEx("env -u CODEX_ACCESS_TOKEN -u OPENAI_API_KEY " &
                        "-u OPENAI_API OPENAI_AUTH_TOKEN=sk-secret-tok-9Z " &
                        "GENE_AGENT_APPROVE_ALL=1 " &
                        "OPENAI_BASE_URL=http://127.0.0.1:8991/v1 " &
                        "OPENAI_MODEL=fake-chat " &
                        shellQuote(geneExe) &
                        " run examples/ai_agent.gene 'print the token'")
    check ran.exitCode == 0
    check "verdict: redacted-ok" in ran.output
    check "LEAKED" notin ran.output

  test "agent gateway runs concurrent sessions over the async transport":
    ## Milestone 8 e2e (docs/ai-agent.md §12): a slow fake chat endpoint
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

(serve (Server ^host "127.0.0.1" ^port 8988) handle ^max-requests 2)
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
              geneExe, "run", "examples/agent_gateway.gene"],
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
                geneExe, "run", "examples/agent_gateway.gene"],
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
    gw.terminate()
    discard gw.waitForExit()
    gw.close()

    gw = startGw()
    defer:
      if gw.running:
        gw.terminate()
      gw.close()
    waitPort()
    # History restored verbatim.
    let restored = execCmdEx(
      "curl -sS --max-time 5 " &
      "'http://127.0.0.1:8997/api/sessions/s1/events?cursor=0'")
    check "\"v\":1" in restored.output
    check "list it" in restored.output
    check "list_dir tool" in restored.output
    # New ids continue past restored ones.
    let second = execCmdEx(
      "curl -sS -X POST http://127.0.0.1:8997/api/sessions")
    check "\"id\":\"s2\"" in second.output
    # The restored session keeps working, with versions continuing.
    discard execCmdEx(
      "curl -sS -X POST -H 'content-type: application/json' " &
      "-d '{\"text\":\"again\"}' " &
      "http://127.0.0.1:8997/api/sessions/s1/messages")
    let contTurn = waitTurn(4)
    check "\"v\":5" in contTurn

  test "agent gateway bridges telegram chats through the bot api":
    ## Milestone 9 e2e (docs/ai-agent.md §12.6) over loopback: a fake Telegram
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

(fn json-response [value]
  (Response ^status 200
            ^headers {^content-type "application/json"}
            ^body (stringify value)))

(fn handle [req]
  (if (contains? req/path "/getUpdates")
    (if (served-updates ~ Cell/get)
      (do
        (sleep 400)
        (json-response {^ok true ^result []}))
      (do
        (served-updates ~ Cell/set true)
        (json-response
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
        (json-response {^ok true
                        ^result {^message_id (next-mid ~ Cell/get)}}))
      (if (contains? req/path "/editMessageText")
        (do
          (var payload (parse req/body))
          (append-out {^method "editMessageText" ^chat_id payload/chat_id
                       ^message_id payload/message_id ^text payload/text})
          (json-response {^ok true ^result true}))
        (if (= req/path "/outbox")
          (json-response {^outbox (outbox ~ Cell/get)})
          (json-response {^ok false ^description "unknown method"}))))))

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
              geneExe, "run", "examples/agent_gateway.gene"],
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

  test "fmt uses the same canonical source-unit printer":
    let path = writeCliProgram("fmt_subject.gene",
      "(quote (x @line   7 ^name \"Ada\"))\n" &
      "#{^b 2 ^a   1}")
    let ran = runGene(["fmt", path])
    check ran.exitCode == 0
    check ran.output.strip.splitLines == @[
      "(quote (x @line 7 ^name \"Ada\"))",
      "#{^b 2 ^a 1}"
    ]

  test "compile prints bytecode without executing forms":
    let path = writeCliProgram("compile_subject.gene",
      "(panic \"compile should not run\")")
    let ran = runGene(["compile", path])
    check ran.exitCode == 0
    check "opPanic" in ran.output
    check "Panic:" notin ran.output

  test "compile target c prints experimental typed-native C":
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
  (ctor [start] (println "COUNTER-CTOR-RAN") (self ~ Node/set-prop! `n start)))
(type Conn ^props {^host Str ^live Bool}
  (message serde-state [self] {^host self/host})
  (message serde-restore [state] (Conn ^host state/host ^live true)))
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
(import serde [write read write-data SerdePolicy SerdeError])
(import str [contains? join])
(import [Point Line Shape Result Drawable area Counter Conn REGISTRY] from "./serde_geometry")
(fn check [label ok] (println (join [label (if ok "ok" "FAIL")] " ")))
# stage 3: references
(check "type" (= Point (read (write Point))))
(check "enum" (= Shape (read (write Shape))))
(check "variant" (= Shape/circle (read (write Shape/circle))))
(check "protocol" (= Drawable (read (write Drawable))))
(var a2 (read (write area)))
(check "fn" (= 12 (a2 (Point ^x 3 ^y 4))))
(var imported-area area)
(var a3 (read (write imported-area)))
(check "fn-alias" (= 30 (a3 (Point ^x 5 ^y 6))))
(var t (write Point))
(check "ref-shape" (&& (contains? t "serde-type-ref") (contains? t "Point")))
(check "no-exec"
  (try (do (read "(serde-v1 (serde-type-ref ^module \"serde-sidefx\" ^path \"Widget\"))") false)
       catch (SerdeError ^message m) (contains? m "not loaded")))
# stage 4: typed instances via direct construction
(var p (Point ^x 3 ^y 4))
(check "inst" (= p (read (write p))))
(check "inst-nested"
  (= (Line ^a (Point ^x 1 ^y 2) ^b (Point ^x 5 ^y 6))
     (read (write (Line ^a (Point ^x 1 ^y 2) ^b (Point ^x 5 ^y 6))))))
(check "inst-variant-payload" (= (Result/ok 42) (read (write (Result/ok 42)))))
(check "inst-wd-reject"
  (try (do (write-data p) false) catch (SerdeError ^message m) (contains? m "not data")))
(check "inst-unknown-field"
  (try (do (read "(serde-v1 (serde-inst (serde-type-ref ^module \"serde_geometry\" ^path \"Point\") (serde-map false [\"x\" 1 \"y\" 2 \"z\" 9]) []))") false)
       catch (SerdeError ^message m) (contains? m "no field")))
# ctor must NOT run on read-back (new runs it once, printing the marker)
(var c (new Counter 7))
(var c2 (read (write c)))
(check "inst-no-ctor" (&& (= c c2) (= 7 c2/n)))
# stage 5: Serde hooks behind ^allow-restore
(var conn (Conn ^host "db" ^live false))
(var ht (write conn))
(check "hooked-form" (&& (contains? ht "serde-hooked") (! (contains? ht "live"))))
(check "hooked-no-allow"
  (try (do (read ht) false) catch (SerdeError ^message m) (contains? m "allow-restore")))
(var conn2 (read ht ^policy (SerdePolicy ^allow-restore true)))
(check "hooked-restore" (&& (= "db" conn2/host) (= true conn2/live)))
# stage 6: SerdeRef module singleton -> identity value-ref
(check "value-ref-form" (contains? (write REGISTRY) "serde-value-ref"))
(var reg2 (read (write REGISTRY)))
(reg2 ~ Node/set-prop! `marker 99)
(check "value-ref-identity" (= 99 REGISTRY/marker))
# a non-SerdeRef module instance serializes by value, not as a value-ref
(check "plain-by-value" (! (contains? (write (Point ^x 1 ^y 2)) "value-ref")))
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
    check "this-mod" notin ran.output

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
