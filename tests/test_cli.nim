import std/[algorithm, json, monotimes, net, os, osproc, sequtils, streams,
            strutils, times, unittest]
when defined(posix):
  import std/posix
when defined(macosx):
  const SigWinch = 28
import gene/[package, repl, vm, web]

let cliDir = getTempDir() / "gene_cli_tests"
let geneExe = cliDir / "gene-test-bin"
let cliArtifactStore = cliDir / "artifact_store"
var cliBuilt = false

proc buildGeneCli() =
  if cliBuilt:
    return
  createDir(cliDir)
  if dirExists(cliArtifactStore):
    makeMaterializedTreeWritable(cliArtifactStore)
    removeDir(cliArtifactStore)
  let build = execCmdEx("nim c --path:src --hints:off -o:" & geneExe & " src/gene.nim")
  if build.exitCode != 0:
    checkpoint build.output
  check build.exitCode == 0
  # `gene fmt|lsp|view` exec a sibling binary resolved from getAppDir(), so the
  # tools must sit next to geneExe for those subcommands to work here. Building
  # them means the delegation path itself is under test, not stubbed.
  for (module, exe) in [("gene_fmt", "gene-fmt"), ("gene_lsp", "gene-lsp"),
                        ("gene_viewer", "gene-viewer")]:
    let toolBuild = execCmdEx("nim c --path:src --hints:off -o:" &
                              (cliDir / exe) & " src/" & module & ".nim")
    if toolBuild.exitCode != 0:
      checkpoint toolBuild.output
    check toolBuild.exitCode == 0
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
  let hadStore = existsEnv("GENE_ARTIFACT_STORE")
  let savedStore = getEnv("GENE_ARTIFACT_STORE")
  putEnv("GENE_ARTIFACT_STORE", cliArtifactStore)
  try:
    result = execCmdEx(command)
  finally:
    if hadStore: putEnv("GENE_ARTIFACT_STORE", savedStore)
    else: delEnv("GENE_ARTIFACT_STORE")

proc runGeneInput(args: openArray[string],
                  input: string): tuple[output: string, exitCode: int] =
  buildGeneCli()
  var command = shellQuote(geneExe)
  for arg in args:
    command.add " " & shellQuote(arg)
  let hadStore = existsEnv("GENE_ARTIFACT_STORE")
  let savedStore = getEnv("GENE_ARTIFACT_STORE")
  putEnv("GENE_ARTIFACT_STORE", cliArtifactStore)
  try:
    result = execCmdEx(command, input = input)
  finally:
    if hadStore: putEnv("GENE_ARTIFACT_STORE", savedStore)
    else: delEnv("GENE_ARTIFACT_STORE")

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

  test "run reports tail-call fallback reasons once per source site":
    let program = writeCliProgram("tail_fallback.gene",
      "(fn typed_bounce [f n] : Str " &
      "  (if (== n 0) \"done\" (f f (- n 1)))) " &
      "(fn main [] (typed_bounce typed_bounce 5) nil)")
    let quiet = runGene(["run", program])
    check quiet.exitCode == 0
    check "Tail-call fallback" notin quiet.output

    let reported = runGene(["run", "--report_tail_fallbacks", program])
    check reported.exitCode == 0
    check reported.output.count("Tail-call fallback [return_type]") == 1
    check "tail_fallback.gene" in reported.output

  test "gene harness registry and turn transaction seams":
    for (fixture, marker) in [
      ("examples/gene-harness/tests/registry_smoke.gene",
       "registry_smoke: ok"),
      ("examples/gene-harness/tests/seam_registry_smoke.gene",
       "seam_registry_smoke: ok"),
      ("examples/gene-harness/tests/turn_transaction_smoke.gene",
       "turn_transaction_smoke: ok"),
      ("examples/gene-harness/tests/recording_view_smoke.gene",
       "recording_view_smoke: ok"),
      ("examples/gene-harness/tests/prompt_skill_smoke.gene",
       "prompt_skill_smoke: ok"),
      ("examples/gene-harness/tests/callback_supervision_smoke.gene",
       "callback_supervision_smoke: ok"),
      ("examples/gene-harness/tests/view_output_smoke.gene",
       "view_output_smoke: ok"),
      ("examples/gene-harness/tests/view_swap_smoke.gene",
       "view_swap_smoke: ok")
    ]:
      let ran = runGene(["run", fixture])
      if ran.exitCode != 0: checkpoint ran.output
      check ran.exitCode == 0
      check marker in ran.output

  test "gene harness recovery nucleus has no plugin imports":
    for path in [
      "examples/gene-harness/src/kernel.gene",
      "examples/gene-harness/src/plugin_api.gene",
      "examples/gene-harness/src/state.gene",
      "examples/gene-harness/src/view_api.gene",
      "examples/gene-harness/src/workspace.gene"
    ]:
      for line in readFile(path).splitLines:
        let stripped = line.strip
        if stripped.startsWith("(import"):
          check "plugins/" notin stripped

  test "filesystem checkpoint generation claims are cross-process exclusive":
    let root = cliDir / "harness_store_process_cas"
    if dirExists(root): removeDir(root)
    createDir(root)
    let contender = writeCliProgram("harness_store_contender.gene", """
(import $store/fs [open : store_open Store StoreError])
(import $fs [write_text exists?])
(fn main [args]
  (var root args/0)
  (var id args/1)
  (write_text $"${root}/ready-${id}" "ready")
  (while (! (&& (exists? $"${root}/ready-a")
                (exists? $"${root}/ready-b"))) nil)
  (var store (store_open ^root root))
  (try
    (store .Store:checkpoint 1 {^state {^winner id}})
    ($println $"committed ${id}")
  catch StoreError
    ($println $"${$ex/kind} ${id}")))
""")
    let first = startProcess(geneExe,
      args = ["run", "--allow_read_write_dir", root, contender, root, "a"],
      options = {poStdErrToStdOut})
    let second = startProcess(geneExe,
      args = ["run", "--allow_read_write_dir", root, contender, root, "b"],
      options = {poStdErrToStdOut})
    let firstCode = first.waitForExit(10000)
    let secondCode = second.waitForExit(10000)
    let firstOutput = first.outputStream.readAll()
    let secondOutput = second.outputStream.readAll()
    first.close()
    second.close()
    check firstCode == 0
    check secondCode == 0
    let combined = firstOutput & secondOutput
    check combined.count("committed ") == 1
    check combined.count("conflict ") == 1

    let reader = writeCliProgram("harness_store_reader.gene", """
(import $store/fs [open : store_open Store])
(fn main [args]
  (var store (store_open ^root args/0))
  (var loaded (store .Store:load_checkpoint))
  ($println loaded/generation loaded/records/state/winner))
""")
    let loaded = runGene(["run", "--allow_read_write_dir", root,
                          reader, root])
    if loaded.exitCode != 0: checkpoint loaded.output
    check loaded.exitCode == 0
    check loaded.output.strip in ["1 a", "1 b"]

  test "gene harness durable composition restore and scoped state":
    proc resetHarnessDir(name: string): string =
      result = cliDir / name
      if dirExists(result): removeDir(result)
      createDir(result)

    var root = resetHarnessDir("harness_event_store")
    var ran = runGene(["run", "--allow_read_write_dir", root,
      "examples/gene-harness/tests/event_store_smoke.gene", root])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "event_store_smoke: ok" in ran.output

    root = resetHarnessDir("harness_event_concurrency")
    ran = runGene(["run", "--allow_read_write_dir", root,
      "examples/gene-harness/tests/event_concurrency_smoke.gene", root])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "event_concurrency_smoke: ok" in ran.output

    root = resetHarnessDir("harness_interrupted_turn")
    ran = runGene(["run", "--allow_read_write_dir", root,
      "examples/gene-harness/tests/interrupted_turn_smoke.gene", root])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "interrupted_turn_smoke: ok" in ran.output

    root = resetHarnessDir("harness_event_catalog")
    ran = runGene(["run", "--allow_read_write_dir", root,
      "examples/gene-harness/tests/event_catalog_smoke.gene", root])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "event_catalog_smoke: ok" in ran.output

    root = resetHarnessDir("harness_workspace_cas")
    ran = runGene(["run", "--allow_read_write_dir", root,
      "examples/gene-harness/tests/workspace_cas_smoke.gene", root])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "workspace_cas_smoke: ok" in ran.output

    for (name, fixture, marker) in [
      ("harness_register", "register_module_smoke.gene",
       "register_module_smoke: ok"),
      ("harness_quarantine", "quarantine_smoke.gene",
       "quarantine_smoke: ok"),
      ("harness_attenuation", "attenuation_smoke.gene",
       "attenuation_smoke: ok"),
      ("harness_bounded_preflight", "bounded_preflight_smoke.gene",
       "bounded_preflight_smoke: ok"),
      ("harness_dependency_closure", "dependency_closure_smoke.gene",
       "dependency_closure_smoke: ok"),
      ("harness_blob_repair", "blob_repair_smoke.gene",
       "blob_repair_smoke: ok"),
      ("harness_descriptor_context", "descriptor_context_smoke.gene",
       "descriptor_context_smoke: ok"),
      ("harness_phased_boot", "phased_boot_smoke.gene",
       "phased_boot_smoke: ok"),
      ("harness_typed_provider", "typed_provider_supervision_smoke.gene",
       "typed_provider_supervision_smoke: ok"),
      ("harness_llm_session_resume", "llm_session_resume_smoke.gene",
       "llm_session_resume_smoke: ok"),
      ("harness_workspace_turn", "workspace_turn_smoke.gene",
       "workspace_turn_smoke: ok"),
      ("harness_codegen_seam", "codegen_seam_smoke.gene",
       "codegen_seam_smoke: ok"),
      ("harness_queued_registration", "queued_registration_smoke.gene",
       "queued_registration_smoke: ok"),
      ("harness_build_replace", "build_replace_smoke.gene",
       "build_replace_smoke: ok"),
      ("harness_duplicate_blob", "duplicate_blob_smoke.gene",
       "duplicate_blob_smoke: ok"),
      ("harness_build_provenance", "build_provenance_smoke.gene",
       "build_provenance_smoke: ok")
    ]:
      root = resetHarnessDir(name)
      ran = runGene(["run", "--allow_read_write_dir", root,
        "examples/gene-harness/tests/" & fixture, root])
      if ran.exitCode != 0: checkpoint ran.output
      check ran.exitCode == 0
      check marker in ran.output

    let compositionRoot = resetHarnessDir("harness_plugin_state_composition")
    let eventRoot = resetHarnessDir("harness_plugin_state_events")
    ran = runGene(["run",
      "--allow_read_write_dir", compositionRoot,
      "--allow_read_write_dir", eventRoot,
      "examples/gene-harness/tests/plugin_state_smoke.gene",
      compositionRoot, eventRoot])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "plugin_state_smoke: ok" in ran.output

    let auditComposition = resetHarnessDir("harness_audit_composition")
    let auditEvents = resetHarnessDir("harness_audit_events")
    ran = runGene(["run",
      "--allow_read_write_dir", auditComposition,
      "--allow_read_write_dir", auditEvents,
      "examples/gene-harness/tests/composition_audit_smoke.gene",
      auditComposition, auditEvents])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "composition_audit_smoke: ok" in ran.output

    let stateConflictComposition =
      resetHarnessDir("harness_state_conflict_composition")
    let stateConflictEvents = resetHarnessDir("harness_state_conflict_events")
    ran = runGene(["run",
      "--allow_read_write_dir", stateConflictComposition,
      "--allow_read_write_dir", stateConflictEvents,
      "examples/gene-harness/tests/workspace_state_conflict_smoke.gene",
      stateConflictComposition, stateConflictEvents])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "workspace_state_conflict_smoke: ok" in ran.output

    let pluginEventComposition =
      resetHarnessDir("harness_plugin_event_composition")
    let pluginEventEvents = resetHarnessDir("harness_plugin_event_events")
    ran = runGene(["run",
      "--allow_read_write_dir", pluginEventComposition,
      "--allow_read_write_dir", pluginEventEvents,
      "examples/gene-harness/tests/plugin_event_smoke.gene",
      pluginEventComposition, pluginEventEvents])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "plugin_event_smoke: ok" in ran.output

    let home = resetHarnessDir("harness_main_resume")
    let envPrefix = "GENE_HARNESS_HOME=" & shellQuote(home) & " "
    var command = envPrefix & shellQuote(geneExe) &
      " run --allow_read_write_dir " & shellQuote(home) &
      " examples/gene-harness/src/main.gene web build greet hello"
    ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "registered greet at revision 1 (ready)" in ran.output
    command = envPrefix & shellQuote(geneExe) &
      " run --allow_read_write_dir " & shellQuote(home) &
      " examples/gene-harness/src/main.gene web tool greet world"
    ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "greet(world) -> hello" in ran.output
    command = envPrefix & shellQuote(geneExe) &
      " run --allow_read_write_dir " & shellQuote(home) &
      " examples/gene-harness/src/main.gene web disable greet"
    ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "composition revision 2" in ran.output
    command = envPrefix & shellQuote(geneExe) &
      " run --allow_read_write_dir " & shellQuote(home) &
      " examples/gene-harness/src/main.gene web tool greet world"
    ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "no tool greet" in ran.output
    command = envPrefix & shellQuote(geneExe) &
      " run --allow_read_write_dir " & shellQuote(home) &
      " examples/gene-harness/src/main.gene web enable greet"
    ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "composition revision 3" in ran.output
    command = envPrefix & shellQuote(geneExe) &
      " run --allow_read_write_dir " & shellQuote(home) &
      " examples/gene-harness/src/main.gene web tool greet world"
    ran = execCmdOnce(command)
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "greet(world) -> hello" in ran.output

    let catalog = execCmdOnce(
      "python3 tools/generate_harness_event_catalog.py --check")
    if catalog.exitCode != 0: checkpoint catalog.output
    check catalog.exitCode == 0
    check "harness event catalog: current" in catalog.output

  test "inference-depth qualification stage is exact and public-only":
    let checked = execCmdEx(
      "python3 tools/qualify_inference_depth.py --self-test")
    check checked.exitCode == 0
    check "tasks=12 primitives_covered=12 max_admissible=8" in checked.output
    check "round_ceiling=5 attempts=2" in checked.output
    check "minimum_liveness=0.9 minimum_solve=0.5 public_hidden_fields=0" in
      checked.output

  test "episode-depth qualification stage keeps the subject's checker rules":
    let checked = execCmdEx(
      "python3 tools/qualify_episode_depth.py --self-test")
    check checked.exitCode == 0
    check "episodes=10 components=20 round_ceiling=9 attempts=2" in
      checked.output
    check "public_hidden_fields=0 soundness_verified=true" in checked.output
    check "framing=episode programs=stage_two_identical" in checked.output

  test "--grant is an ordinary program argument, not an authority channel":
    let grantedMain = writeCliProgram("grant_is_argv.gene",
      "(fn main [args] " &
      "  (if (== args/0 \"--grant\") 0 4))")
    var ran = runGene(["run", grantedMain, "--grant", "config=$fs/ReadDir"])
    check ran.exitCode == 0

    let missingMain = writeCliProgram("missing_grant_main.gene",
      "(fn main [args, ^config : Capability] " &
      "  (do ($println \"BODY-RAN\") 0))")
    ran = runGene(["run", missingMain, "--grant", "config=$fs/ReadDir"])
    check ran.exitCode == 1
    check "missing named argument: config" in ran.output
    check ("at " & normalizedPath(absolutePath(missingMain)) & ":1:1") in
      ran.output
    check not ran.output.startsWith("BODY-RAN\n")

  test "pre-entry directory policy mints host grants without Gene values":
    let externalDir = getTempDir() / "gene_cli_external_capability"
    createDir(externalDir)
    let externalFile = externalDir / "message.txt"
    writeFile(externalFile, "allowed")
    defer:
      if fileExists(externalFile): removeFile(externalFile)
      if dirExists(externalDir): removeDir(externalDir)
    let readerMain = writeCliProgram("host_read_policy.gene", """
      (import $fs [read_text])
      (fn main [args]
        (if (== (read_text args/0) "allowed") 0 4))
    """)

    var ran = runGene(["run", readerMain, externalFile])
    check ran.exitCode == 1
    check "MissingCapability: fs/read_text requires fs/ReadFile" in ran.output

    ran = runGene(["run", "--allow_read_dir", externalDir,
                   readerMain, externalFile])
    check ran.exitCode == 0

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
(import $log [new_logger])
(var logger (new_logger "app/cli" ^payload {^service "test"}))
(logger .info "started" ^payload {^token "secret" ^count 2})
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
      "(import $fs [write_text WriteDir]) " &
      "(write_text " & geneQuote(marker) & " \"ran\")")
    let ran = runGene(["run", "--log-config", configPath, fixture])
    check ran.exitCode == 1
    check "unknown sink 'missing'" in ran.output
    check not fileExists(marker)

  test "main parameter boundary errors include source location":
    let typedMain = writeCliProgram("typed_arg_main.gene",
      "(fn main [args : (List Str)] nil)")
    let ran = runGene(["run", typedMain, "x"])
    check ran.exitCode == 1
    check "parameter 'args' expected (List Str), got Node" in ran.output
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
        b'(import [util_fn] from "./util") ($println (+ (util_fn) 1))',
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
(import $curses [open close dimensions next_event])
(import $json [stringify])
(var screen (open))
(try
  (do
    (var dims (dimensions screen))
    (var abandoned (next_event screen))
    (abandoned .cancel)
    ($sleep 50)
    (var text_event (await (next_event screen)))
    (var resize_event (await (next_event screen)))
    (close screen)
    ($println $"CURSES-EVENTS:${(stringify {^dims dims
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
(import $curses [open close next_event])
(import $json [stringify])
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
    ($println $"CURSES-CONTROLS:${(stringify [paste_start text_event
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

  test "public curses ownership suppresses only diagnostic console output":
    when defined(macosx):
      buildGeneCli()
      let fixture = writeCliProgram("curses_log_suppression.gene", """
(import $curses [open close draw])
(import $log [new_logger log_warn])
(var logger (new_logger "app/curses_test"))
(var screen (open))
(try
  (do
    (draw screen ^output "screen active" ^output_scroll 0)
    (log_warn logger "hidden while screen owns terminal")
    (close screen)
    ($println "CURSES-LOG-SUPPRESSION:ok"))
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
(import $curses [open close read_input])
(var screen (open))
(try
  (do
    (var input (read_input screen ^prompt "" ^multiline true))
    (close screen)
    ($println $"CURSES-PASTE:${input}"))
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
(import $curses [open close read_input])
(var screen (open))
(try
  (do
    (var input
      (read_input screen ^prompt "" ^multiline true
                  ^history ["first command" "second command"]))
    (close screen)
    ($println $"CURSES-HISTORY:${input}"))
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
(import $curses [open close read_input])
(var screen (open))
(try
  (do
    (var input
      (read_input screen ^prompt "" ^multiline true
        ^output "MAIN-TRANSCRIPT"
        ^panes [{^title "ext 1" ^output "EXTENSION-ONE\nready"}
                {^title "ext 2" ^output "EXTENSION-TWO\ndone"}]))
    (close screen)
    ($println $"CURSES-PANES:${input}"))
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
(import $curses [open close read_input])
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
    ($println $"CURSES-PANE-SCROLL:${input}"))
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
(import $curses [open close read_input])
(var screen (open))
(try
  (do
    (var input
      (read_input screen ^prompt "" ^multiline true
        ^output "MAIN-HIDDEN"
        ^panes [{^title "shell" ^output "FOCUSED-NARROW"
                 ^focused true}]))
    (close screen)
    ($println $"CURSES-FOCUSED:${input}"))
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
(import $curses [open close read_input escape_pressed?])
(var screen (open))
(var found false)
(try
  (do
    (while (! found)
      ($sleep 25)
      (set found (escape_pressed? screen)))
    (var input (read_input screen ^prompt "" ^multiline true
                           ^history ["old "]))
    (close screen)
    ($println $"CURSES-ESCAPE:${found}:${input}"))
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
(import $os [begin_interrupt take_interrupt end_interrupt])
(import $curses [open close escape_pressed?])
(var screen (open))
(var running ($cell true))
(var cancelled ($cell false))
(var done ($channel ^capacity 1))
(var task
  (spawn
    (try
      (do
        ($sleep 5000)
        ($println "too late"))
    ensure
      (done .close))))
(var armed (begin_interrupt))
(var watcher
  (spawn
    (while (running .get)
      ($sleep 25)
      (if (|| (take_interrupt) (escape_pressed? screen))
        (do
          (cancelled .set true)
          (task .cancel))
        nil))))
(try (done .recv) catch ChannelClosed nil)
(running .set false)
(watcher .cancel)
(if armed (end_interrupt) nil)
(close screen)
(if (cancelled .get)
  ($println "turn cancelled; enter steering to continue")
  nil)
($println "AGENT-ESCAPE-DONE")
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
(import $curses [open close read_input])
(var screen (open))
(try
  (do
    (var input
      (read_input screen ^prompt "" ^multiline true
        ^output "SCROLL-TOP\nline-01\nline-02\nline-03\nline-04\nline-05\nline-06\nline-07\nline-08\nline-09\nline-10\nline-11\nline-12\nline-13\nline-14\nline-15\nline-16\nline-17\nline-18\nline-19\nline-20\nline-21\nline-22\nline-23\nline-24\nline-25\nline-26\nline-27\nline-28\nSCROLL-BOTTOM"))
    (close screen)
    ($println $"CURSES-SCROLL:${input}"))
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
(import $curses [open close read_input])
(var screen (open))
(try
  (do
    (var input
      (read_input screen ^prompt "" ^multiline true
        ^output "MOUSE-SCROLL-TOP\nline-01\nline-02\nline-03\nline-04\nline-05\nline-06\nline-07\nline-08\nline-09\nline-10\nline-11\nline-12\nline-13\nline-14\nline-15\nline-16\nline-17\nline-18\nline-19\nline-20\nline-21\nline-22\nline-23\nline-24\nline-25\nline-26\nline-27\nline-28\nMOUSE-SCROLL-BOTTOM"))
    (close screen)
    ($println $"CURSES-MOUSE-SCROLL:${input}"))
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
(import $curses [open close read_input])
(var screen (open))
(try
  (do
    (var input
      (read_input screen ^prompt "" ^multiline true
        ^output "assistant|WRAP-BEGIN alpha beta gamma delta epsilon zeta eta theta WRAP-END"))
    (close screen)
    ($println $"CURSES-WRAP:${input}"))
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
      "#B64#SGk= # after bytes\n" &
      "2026-07-04T09:30Z # after datetime\n")
    let lexicalFmt = runGene(["fmt", lexical])
    check lexicalFmt.exitCode == 0
    check lexicalFmt.output.count("# after ") == 5
    check "#\"a#b\"im" in lexicalFmt.output

    let pipeline = writeCliProgram("fmt_pipeline.gene",
      "(source -> parse options => validate schema -> save db _)\n")
    let pipelineFmt = runGene(["fmt", pipeline])
    check pipelineFmt.exitCode == 0
    check pipelineFmt.output ==
      "(source\n" &
      "  -> parse options\n" &
      "  => validate schema\n" &
      "  -> save db _)\n"

  test "fmt output is parse-equivalent and idempotent on the todo app":
    buildGeneCli()
    let f1 = execCmdEx(shellQuote(geneExe) & " fmt examples/todo_app/src/main.gene")
    check f1.exitCode == 0
    let fmtPath = writeCliProgram("todo_fmt.gene", f1.output)
    # Same canonical forms as the original source.
    let p0 = execCmdEx(shellQuote(geneExe) & " parse examples/todo_app/src/main.gene")
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
      "(macro twice [x] `(+ %x %x))\n" &
      "(panic \"dependency runtime should not run\")\n")
    let path = writeCliProgram("compile_macro_user.gene",
      "(import [twice] from \"./compile_macro_dep\")\n" &
      "(var answer (twice 21))\n")
    let ran = runGene(["compile", path])
    check ran.exitCode == 0
    check "twice" notin ran.output
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
    check "const GeneAotModuleFunction gene_aot_module[] GENE_MAYBE_UNUSED = {" in ran.output
    # Manifest rows carry an entry_symbol between the C symbol and the repr;
    # it is empty for a function without ^native_entry.
    check "{\"add64\", \"gene_native_add64\", \"\", \"I64\", 2, &gene_frame_add64}," in
      ran.output
    check "extern size_t GENE_FFI_CDECL strlen(const char * s);" in ran.output
    check "GeneStatus gene_ffi_strlen" in ran.output
    check "Panic:" notin ran.output

  test "compile target c lowers scalar kernels with locals, loops, and math":
    # The shape numeric Gene is actually written in: a module `let` constant, a
    # `$math/...` call, division by that constant, un-annotated locals, a
    # `while` loop, and a nested call as an argument. Every one of these used to
    # push a function back to the interpreter, and together they meant no
    # ordinary numeric kernel lowered at all.
    let path = writeCliProgram("compile_c_kernel.gene",
      "(let two32 4294967296.0)\n" &
      "(fn wrap32 [v : F64] : F64\n" &
      "  (- v (* ($math/floor (/ v two32)) two32)))\n" &
      "(fn mix32 [h : F64] : F64 (wrap32 (+ (* h 1664525.0) 1013904223.0)))\n" &
      "(fn drive [n : F64] : F64\n" &
      "  (var acc 0.0)\n" &
      "  (var i 0.0)\n" &
      "  (while (< i n)\n" &
      "    (set acc (+ acc (mix32 (wrap32 i))))\n" &
      "    (set i (+ i 1.0)))\n" &
      "  acc)\n" &
      "(fn main [] (panic \"compile c should not run\"))")
    let ran = runGene(["compile", "--target", "c", path])
    check ran.exitCode == 0
    # The module constant is inlined, so the emitted C never names it.
    check "floor((v / 4294967296.0))" in ran.output
    check "two32" notin ran.output
    # Un-annotated locals get their representation inferred.
    check "double acc = 0.0;" in ran.output
    check "while ((i < n))" in ran.output
    # A nested call as a call argument.
    check "gene_native_mix32(gene_native_wrap32(i))" in ran.output
    # Gene rounds every float operation separately, so the compiled form must
    # not be allowed to contract a multiply-add into an FMA.
    check "#pragma STDC FP_CONTRACT OFF" in ran.output
    check "Panic:" notin ran.output

  test "compile target c refuses division by a non-constant divisor":
    # Gene raises on division by zero; C yields an infinity and says nothing.
    # A lowered function has no way to raise, so only a provably non-zero
    # divisor may lower — otherwise the function stays interpreted.
    let path = writeCliProgram("compile_c_divzero.gene",
      "(fn ratio [a : F64 b : F64] : F64 (/ a b))\n" &
      "(fn main [] nil)")
    let ran = runGene(["compile", "--target", "c", path])
    check ran.exitCode == 0
    check "gene_native_ratio" notin ran.output

  # A dedicated root, because `gene build` leaves package state beside its
  # input; sharing `cliDir` with the workspace-build tests made those resolve
  # against it and fail.
  proc writeGlProgram(name, src: string): string =
    let root = cliDir / "web_gl_root"
    createDir(root)
    result = root / name
    writeFile(result, src)

  test "build target web emits WebGL2 calls with compile-time enums":
    let path = writeGlProgram("web_gl.gene",
      "(mod web_gl ^profile web)\n" &
      "(fn upload [gl : Gl verts : (Buffer F32)] : Gl/Buffer\n" &
      "  (var vbo ($gl/create_buffer gl))\n" &
      "  ($gl/bind_buffer gl \"array\" vbo)\n" &
      "  ($gl/buffer_data gl \"array\" verts \"static\")\n" &
      "  ($gl/draw_elements gl \"triangles\" 36.0 \"u16\" 0.0)\n" &
      "  vbo)\n")
    let outDir = cliDir / "web_gl_root" / "out"
    let ran = runGene(["build", "--target", "web", path, "--out-dir", outDir])
    check ran.exitCode == 0
    let emitted = readFile(outDir / "web_gl.mjs")
    # Enum arguments are resolved to WebGL constants at compile time, so no
    # Gene-side spelling survives into the output.
    check "gl.bindBuffer(gl.ARRAY_BUFFER, vbo)" in emitted
    check "gl.bufferData(gl.ARRAY_BUFFER, verts, gl.STATIC_DRAW)" in emitted
    check "gl.drawElements(gl.TRIANGLES, 36.0, gl.UNSIGNED_SHORT, 0.0)" in emitted
    check "\"array\"" notin emitted
    check "\"static\"" notin emitted
    # `createBuffer` returns `WebGLBuffer | null`; Gene's type says non-null,
    # so the null is refused where it happens rather than at the draw call.
    check "$gene_gl_require(gl.createBuffer()" in emitted

  test "build target web rejects an unknown WebGL enum at compile time":
    let path = writeGlProgram("web_gl_bad.gene",
      "(mod web_gl_bad ^profile web)\n" &
      "(fn go [gl : Gl] : Nil ($gl/enable gl \"depth_testing\"))\n")
    let ran = runGene(["build", "--target", "web", path,
                       "--out-dir", cliDir / "web_gl_root" / "bad_out"])
    check ran.exitCode == 1
    check "unknown WebGL enum: depth_testing" in ran.output

  test "compile rejects reserved native targets explicitly":
    let path = writeCliProgram("compile_reserved_target.gene",
      "(fn main [] nil)")
    let ran = runGene(["compile", "--target", "llvm", path])
    check ran.exitCode == 1
    check "unsupported compile target: llvm" in ran.output

  test "build target web emits runnable ESM, TypeScript, declarations, and a source map":
    let path = writeCliProgram("web_slice.gene",
      "(mod web_slice ^profile web)\n" &
      "(fn choose [flag : Bool a : Str b : Str] : Str\n" &
      "  (if flag a b))\n")
    let outDir = cliDir / "web_slice_out"
    createDir(outDir)
    let ran = runGene(["build", "--target", "web", "--out-dir", outDir, path])
    checkpoint ran.output
    check ran.exitCode == 0
    let jsPath = outDir / "web_slice.mjs"
    let tsPath = outDir / "web_slice.ts"
    let dtsPath = outDir / "web_slice.d.ts"
    let mapPath = outDir / "web_slice.mjs.map"
    let tsMapPath = outDir / "web_slice.ts.map"
    check fileExists(jsPath)
    check fileExists(tsPath)
    check fileExists(dtsPath)
    check fileExists(mapPath)
    check fileExists(tsMapPath)
    if fileExists(jsPath):
      let js = readFile(jsPath)
      check "export function choose(flag, a, b)" in js
      check "sourceMappingURL=web_slice.mjs.map" in js
      check "eval(" notin js
      check "Function(" notin js
    if fileExists(dtsPath):
      check "export declare function choose(flag: boolean, a: string, b: string): string;" in
        readFile(dtsPath)
    if fileExists(mapPath):
      let sourceMapText = readFile(mapPath)
      let sourceMap = parseJson(sourceMapText)
      check normalizedPath(absolutePath(path)) in sourceMapText
      check sourceMap["mappings"].getStr().contains(';')
      check sourceMap["mappings"].getStr() != "AAAA"
    if fileExists(jsPath):
      let executed = execCmdEx(
        "node --input-type=module -e " & shellQuote(
          "import { choose } from " & jsPath.absolutePath.escape() &
          "; console.log(choose(true, 'left', 'right'));"))
      checkpoint executed.output
      check executed.exitCode == 0
      check executed.output.strip == "left"

  test "web names are mangled injectively into legal JavaScript identifiers":
    check mangleWebName("ready?") == "ready$q"
    check mangleWebName("ready$q") == "ready$$q"
    check mangleWebName("ready?") != mangleWebName("ready$q")
    check mangleWebName("class") == "$r$class"
    check mangleWebName("2d") == "$n$2d"

  test "web list literals preserve shallow mutability":
    let path = writeCliProgram("web_list_mutability.gene",
      "(mod web_list_mutability ^profile web)\n" &
      "(fn mutable [] : (List Int) [1 2])\n" &
      "(fn immutable [] : (List Int) #[1 2])\n")
    let outDir = cliDir / "web_list_mutability_out"
    createDir(outDir)
    let ran = runGene(["build", "--target", "web", "--out-dir", outDir, path])
    checkpoint ran.output
    check ran.exitCode == 0
    let jsPath = outDir / "web_list_mutability.mjs"
    if fileExists(jsPath):
      let js = readFile(jsPath)
      check "return [1n, 2n];" in js
      check "return Object.freeze([1n, 2n]);" in js
      let executed = execCmdEx(
        "node --input-type=module -e " & shellQuote(
          "import { mutable, immutable } from " & jsPath.absolutePath.escape() &
          "; console.log(Object.isFrozen(mutable()), Object.isFrozen(immutable()))"))
      checkpoint executed.output
      check executed.exitCode == 0
      check executed.output.strip == "false true"

  test "build target web rejects VM-only forms with a profile reason":
    let path = writeCliProgram("web_rejected.gene",
      "(mod web_rejected ^profile web)\n" &
      "(fn raw! [x] x)\n")
    let outDir = cliDir / "web_rejected_out"
    createDir(outDir)
    let ran = runGene(["build", "--target", "web", "--out-dir", outDir, path])
    check ran.exitCode == 1
    check "fexpr 'raw!' is outside the web profile" in ran.output

  test "build target web reserves trailing bang for fexpr calls":
    let path = writeCliProgram("web_bang_message.gene",
      "(mod web_bang_message ^profile web)\n" &
      "(type Box ^props {}\n" &
      "  (message mutate! [] : Int 1))\n" &
      "(fn main [] : Int 0)\n")
    let outDir = cliDir / "web_bang_message_out"
    createDir(outDir)
    let ran = runGene(["build", "--target", "web", "--out-dir", outDir, path])
    check ran.exitCode == 1
    check "message names may not end in !" in ran.output

  test "web macro diagnostics point at the expansion call site":
    let path = writeCliProgram("web_macro_diagnostic.gene",
      "(mod web_macro_diagnostic ^profile web)\n" &
      "(macro broken [value] `(missing_web_fn %value))\n" &
      "\n" &
      "(fn run [] : Int (broken 1))\n")
    let outDir = cliDir / "web_macro_diagnostic_out"
    createDir(outDir)
    let ran = runGene(["build", "--target", "web", "--out-dir", outDir, path])
    check ran.exitCode == 1
    check "web_macro_diagnostic.gene:4:" in ran.output
    check "missing_web_fn" in ran.output

  test "web JS extern rejects an import name that cannot form ESM syntax":
    let path = writeCliProgram("web_bad_js_import.gene",
      "(mod web_bad_js_import ^profile web)\n" &
      "(js/fn host ^from \"./host.mjs\" ^import \"not-an-id\" [] : Nil)\n")
    let outDir = cliDir / "web_bad_js_import_out"
    createDir(outDir)
    let ran = runGene(["build", "--target", "web", "--out-dir", outDir, path])
    check ran.exitCode == 1
    check "js/fn ^import must be a JavaScript identifier" in ran.output

  test "build target web follows a closed graph of unconditional relative imports":
    discard writeCliProgram("web_dep.gene",
      "(mod web_dep ^profile web)\n" &
      "(fn invert [value : Bool] : Bool (! value))\n")
    let path = writeCliProgram("web_importer.gene",
      "(mod web_importer ^profile web)\n" &
      "(import [invert] from \"./web_dep.gene\")\n" &
      "(fn result [] : Bool (invert false))\n")
    let outDir = cliDir / "web_import_out"
    createDir(outDir)
    let ran = runGene(["build", "--target", "web", "--out-dir", outDir, path])
    checkpoint ran.output
    check ran.exitCode == 0
    check fileExists(outDir / "web_dep.mjs")
    check fileExists(outDir / "web_importer.mjs")
    if fileExists(outDir / "web_importer.mjs"):
      check "import { invert } from \"./web_dep.mjs\";" in
        readFile(outDir / "web_importer.mjs")
      let executed = execCmdEx(
        "node --input-type=module -e " & shellQuote(
          "import { result } from " &
          (outDir / "web_importer.mjs").absolutePath.escape() &
          "; console.log(result());"))
      checkpoint executed.output
      check executed.exitCode == 0
      check executed.output.strip == "true"

  test "web ABI checks exported calls, JS imports, and callbacks in both directions":
    writeFile(cliDir / "web_host.mjs",
      "export function upper(value, callback) {\n" &
      "  return callback(value.toUpperCase());\n" &
      "}\n")
    let path = writeCliProgram("web_interop.gene",
      "(mod web_interop ^profile web)\n" &
      "(js/fn host_upper ^from \"./web_host.mjs\" ^import \"upper\" " &
      "  [value : Str callback : (Fn [Str] Str)] : Str)\n" &
      "(fn decorate [value : Str] : Str ($ \"<\" value))\n" &
      "(fn run [value : Str] : Str (host_upper value decorate))\n" &
      "(fn run_with [value : Str callback : (Fn [Str] Str)] : Str " &
      "  (host_upper value callback))\n")
    let ran = runGene(["build", "--target", "web", "--out-dir", cliDir, path])
    checkpoint ran.output
    check ran.exitCode == 0
    let jsPath = cliDir / "web_interop.mjs"
    if fileExists(jsPath):
      let js = readFile(jsPath)
      check "from \"./web_host.mjs\"" in js
      check "$gene_check_str" in js
      check "$gene_check_callback" in js
      let executed = execCmdEx(
        "node --input-type=module -e " & shellQuote(
          "import { run, run_with } from " & jsPath.absolutePath.escape() &
          "; console.log(run('ada')); try { run(1) } catch (e) { console.log(e.name) }" &
          "; try { run_with('ada', () => 7) } catch (e) { console.log(e.name) }"))
      checkpoint executed.output
      check executed.exitCode == 0
      check executed.output.strip.splitLines ==
        @["<ADA", "TypeError", "TypeError"]

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
(protocol Drawable (message draw [] : Str))
(fn area [p : Point] : Int (* p/x p/y))
(type Counter ^props {^n Int}
  (ctor [start] ($println "COUNTER-CTOR-RAN") (self .set_prop `n start)))
(type Conn ^props {^host Str ^live Bool}
  (message serde_state [self] {^host self/host})
  (message serde_restore [state] (Conn ^host state/host ^live true)))
(type Handle ^repr native_wrapper ^props {^host Str}
  (ctor [host : Str] (set self/host host))
  (message serde_state [self] {^host self/host})
  (message serde_restore [state] (new Handle state/host)))
(type Opaque ^repr native_wrapper ^props {^host Str}
  (ctor [host : Str] (set self/host host)))
(type Registry ^props {^label Str ^marker Int?})
(impl SerdeRef for Registry)
(var REGISTRY (Registry ^label "the-one"))
""")
    discard writeCliProgram("serde_sidefx.gene", """
(mod serde-sidefx)
($println "SIDEFX-RAN")
(type Widget ^props {^n Int})
""")
    let prog = writeCliProgram("serde_refs.gene", """
(import $serde [write read write_data SerdePolicy SerdeError])
(import $str [contains? join])
(import [Point Line Shape Result Drawable area Counter Conn Handle Opaque REGISTRY] from "./serde_geometry")
(fn check [label ok] ($println (join [label (if ok "ok" "FAIL")] " ")))
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
       catch SerdeError (contains? $ex/message "not loaded")))
# stage 4: typed instances via direct construction
(var p (Point ^x 3 ^y 4))
(check "inst" (== p (read (write p))))
(check "inst-nested"
  (== (Line ^a (Point ^x 1 ^y 2) ^b (Point ^x 5 ^y 6))
     (read (write (Line ^a (Point ^x 1 ^y 2) ^b (Point ^x 5 ^y 6))))))
(check "inst-variant-payload" (== (Result/ok 42) (read (write (Result/ok 42)))))
(check "inst-wd-reject"
  (try (do (write_data p) false) catch SerdeError (contains? $ex/message "not data")))
(check "inst-unknown-field"
  (try (do (read "(serde_v1 (serde_inst (serde_type_ref ^module \"serde_geometry\" ^path \"Point\") (serde_map false [\"x\" 1 \"y\" 2 \"z\" 9]) []))") false)
       catch SerdeError (contains? $ex/message "no field")))
# ctor must NOT run on read-back (`new` runs it once, printing the marker)
(var c (new Counter 7))
(var c2 (read (write c)))
(check "inst-no-ctor" (&& (== c c2) (== 7 c2/n)))
# stage 5: Serde hooks behind ^allow_restore
(var conn (Conn ^host "db" ^live false))
(var ht (write conn))
(check "hooked-form" (&& (contains? ht "serde_hooked") (! (contains? ht "live"))))
(check "hooked-no-allow"
  (try (do (read ht) false) catch SerdeError (contains? $ex/message "allow_restore")))
(var conn2 (read ht ^policy (SerdePolicy ^allow_restore true)))
(check "hooked-restore" (&& (== "db" conn2/host) (== true conn2/live)))
# native wrappers (design §16.6): reopened by their own restore hook, never
# reconstructed as data — and a blob can never forge one
(var handle (new Handle "db"))
(var wt (write handle))
(check "wrapper-hooked-form" (contains? wt "serde_hooked"))
(var handle2 (read wt ^policy (SerdePolicy ^allow_restore true)))
(check "wrapper-hooked-restore" (== "db" handle2/host))
(check "wrapper-no-hook-reject"
  (try (do (write (new Opaque "db")) false)
       catch SerdeError (contains? $ex/message "native wrapper")))
(check "wrapper-inst-blob-reject"
  (try (do (read "(serde_v1 (serde_inst (serde_type_ref ^module \"serde_geometry\" ^path \"Opaque\") (serde_map false [\"host\" \"forged\"]) []))") false)
       catch SerdeError (contains? $ex/message "native wrapper")))
# stage 6: SerdeRef module singleton -> identity value_ref
(check "value-ref-form" (contains? (write REGISTRY) "serde_value_ref"))
(var reg2 (read (write REGISTRY)))
(reg2 .set_prop `marker 99)
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
    check "wrapper-hooked-form ok" in ran.output
    check "wrapper-hooked-restore ok" in ran.output
    check "wrapper-no-hook-reject ok" in ran.output
    check "wrapper-inst-blob-reject ok" in ran.output
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

suite "cli — Gene package builds":
  proc buildCliRoot(): string =
    result = cliDir / "package_build"
    if dirExists(result):
      removeDir(result)
    createDir(result)

  proc writeBuildFixture(path, source: string) =
    createDir(parentDir(path))
    writeFile(path, source)

  proc runBuildGeneIn(dir: string,
                      args: openArray[string]): tuple[output: string,
                                                      exitCode: int] =
    buildGeneCli()
    let saved = getCurrentDir()
    setCurrentDir(dir)
    try:
      result = runGene(args)
    finally:
      setCurrentDir(saved)

  test "build selects products, writes views, and explains no-op reuse":
    let root = buildCliRoot()
    writeBuildFixture(root / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^applications [
   (application "cli" ^entry "src/cli.gene")
   (application "admin" ^entry "src/admin.gene")]}
""")
    writeBuildFixture(root / "src/cli.gene", "(fn main [] 0)")
    writeBuildFixture(root / "src/admin.gene", "(fn main [] 0)")

    var ran = runGene(["build", "--package-root", root, "cli", "--explain"])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "Built acme/app:cli -> " in ran.output
    check "rebuilt 1 derivation" in ran.output
    check fileExists(root / "package.gene.lock")

    ran = runGene(["build", "--package-root", root, "cli", "--locked",
                   "--explain"])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "cache hit" in ran.output

  test "build all includes independent co-lived workspace products":
    let root = buildCliRoot()
    writeBuildFixture(root / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^workspace {^members ["packages/*"]}
 ^applications [(application "app" ^entry "src/main.gene")]}
""")
    writeBuildFixture(root / "src/main.gene", "(fn main [] 0)")
    writeBuildFixture(root / "packages/tool/package.gene", """
{^format 1 ^name "acme/tool" ^version "1.0.0"
 ^library {^entry "src/index.gene"}
 ^applications [(application "tool" ^entry "src/main.gene")]}
""")
    writeBuildFixture(root / "packages/tool/src/index.gene", "(var answer 42)")
    writeBuildFixture(root / "packages/tool/src/main.gene", "(fn main [] 0)")

    let ran = runGene(["build", "--package-root", root, "--all"])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "Built acme/app:app -> " in ran.output
    check "Built acme/tool:library -> " in ran.output
    check "Built acme/tool:tool -> " in ran.output

  test "run builds a named project application before executing it":
    let root = buildCliRoot()
    writeBuildFixture(root / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^applications [(application "cli" ^entry "src/main.gene")]}
""")
    writeBuildFixture(root / "src/main.gene",
      "(fn main [args] ($println args/0))")
    let ran = runGene(["run", "--package-root", root, "cli", "hello"])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check ran.output.strip == "hello"
    check dirExists(root / ".gene/build")
    let cached = runGene(["run", "--package-root", root, "cli", "again"])
    if cached.exitCode != 0: checkpoint cached.output
    check cached.exitCode == 0
    check cached.output.strip == "again"

  test "test discovers, builds, and runs isolated Gene test entries":
    let root = buildCliRoot()
    writeBuildFixture(root / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^library {^entry "src/index.gene"}
 ^tests {^root "tests"}}
""")
    writeBuildFixture(root / "src/index.gene", "(var answer 42)")
    writeBuildFixture(root / "tests/one.gene", "(fn main [] nil)")
    writeBuildFixture(root / "tests/two.gene", "(fn main [] nil)")
    let ran = runBuildGeneIn(root, ["test", "one"])
    if ran.exitCode != 0: checkpoint ran.output
    check ran.exitCode == 0
    check "[OK] tests/one.gene" in ran.output
    check "tests/two.gene" notin ran.output

suite "cli — gene pkg (docs/proposals/package.md §11)":
  proc pkgCliDir(): string =
    result = cliDir / "pkg"
    removeDir(result)
    createDir(result)

  proc writePkgFile(path, source: string) =
    createDir(parentDir(path))
    writeFile(path, source)

  proc runGeneIn(dir: string,
                 args: openArray[string]): tuple[output: string,
                                                 exitCode: int] =
    buildGeneCli()
    let saved = getCurrentDir()
    setCurrentDir(dir)
    try:
      result = runGene(args)
    finally:
      setCurrentDir(saved)

  test "pkg init writes a format-1 package and lock":
    let root = pkgCliDir() / "mixed_app"
    createDir(root)
    let initialized = runGeneIn(root, ["pkg", "init", "--mixed"])
    check initialized.exitCode == 0
    check fileExists(root / "package.gene")
    check fileExists(root / "package.gene.lock")
    check "^format 1" in readFile(root / "package.gene")
    check dirExists(root / "packages")
    check fileExists(root / "src/index.gene")
    check fileExists(root / "src/main.gene")

  test "pkg init registers a co-lived package in the enclosing workspace":
    let root = pkgCliDir() / "workspace_init"
    writePkgFile(root / "package.gene", """
{^format 1 ^name "acme/app" ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]}
""")
    writePkgFile(root / "src/main.gene", "(fn main [] 0)")
    let initialized = runGeneIn(root,
      ["pkg", "init", "packages/pkg1", "--lib"])
    if initialized.exitCode != 0: checkpoint initialized.output
    check initialized.exitCode == 0
    check fileExists(root / "packages/pkg1/package.gene")
    check "packages/pkg1" in readFile(root / "package.gene")
    check fileExists(root / "package.gene.lock")
    let members = runGeneIn(root / "packages/pkg1", ["pkg", "members"])
    check members.exitCode == 0
    check "local/pkg1 " & canonicalPath(root / "packages/pkg1") in
      members.output

  test "resolve, sync, tree, why, and members share one workspace graph":
    let root = pkgCliDir()
    writePkgFile(root / "app/package.gene", """
{^format 1
 ^name "acme/app"
 ^version "1.0.0"
 ^workspace {^members ["packages/*"]}
 ^applications [(application "app" ^entry "src/main.gene")]
 ^dependencies {
   ^tool (dep "acme/tool" "1.0.0" ^workspace true)}}
""")
    writePkgFile(root / "app/src/main.gene", "(fn main [] 0)")
    writePkgFile(root / "app/packages/tool/package.gene", """
{^format 1
 ^name "acme/tool"
 ^version "1.0.0"
 ^library {^entry "src/index.gene"}}
""")
    writePkgFile(root / "app/packages/tool/src/index.gene", "(var answer 42)")

    let resolved = runGeneIn(root / "app", ["pkg", "resolve"])
    check resolved.exitCode == 0
    check "Resolved 2 package instance(s)" in resolved.output
    check fileExists(root / "app/package.gene.lock")

    let synced = runGeneIn(root / "app", ["pkg", "sync", "--locked", "--offline"])
    check synced.exitCode == 0
    check "Synchronized 2 package instance(s)" in synced.output

    let tree = runGeneIn(root / "app", ["pkg", "tree"])
    check tree.exitCode == 0
    check "acme/app 1.0.0" in tree.output
    check "tool -> workspace:acme/tool@1.0.0#" in tree.output

    let why = runGeneIn(root / "app", ["pkg", "why", "acme/tool"])
    check why.exitCode == 0
    check "acme/app --tool--> acme/tool" in why.output

    let members = runGeneIn(root / "app/packages/tool", ["pkg", "members"])
    check members.exitCode == 0
    check "acme/app " & canonicalPath(root / "app") in members.output
    check "acme/tool " & canonicalPath(root / "app/packages/tool") in
      members.output

  test "pkg add and remove mutate aliases transactionally":
    let root = pkgCliDir()
    writePkgFile(root / "app/package.gene", """
{^format 1
 ^name "acme/app"
 ^version "1.0.0"
 ^workspace {^members ["packages/*"]}
 ^applications [(application "app" ^entry "src/main.gene")]}
""")
    writePkgFile(root / "app/src/main.gene", "(fn main [] 0)")
    writePkgFile(root / "app/packages/tool/package.gene", """
{^format 1
 ^name "acme/tool"
 ^version "1.0.0"
 ^library {^entry "src/index.gene"}}
""")
    writePkgFile(root / "app/packages/tool/src/index.gene", "(var answer 42)")

    let added = runGeneIn(root / "app",
      ["pkg", "add", "tool=acme/tool@1.0.0", "--workspace"])
    check added.exitCode == 0
    let manifest = readFile(root / "app/package.gene")
    check "^tool" in manifest
    check "(dep" in manifest
    check "^^workspace" in manifest
    check "\"acme/tool\"" in manifest
    check fileExists(root / "app/package.gene.lock")

    let removed = runGeneIn(root / "app", ["pkg", "remove", "tool"])
    check removed.exitCode == 0
    check not readFile(root / "app/package.gene").contains("^tool")

  test "prototype pkg commands and manifests are rejected":
    let root = pkgCliDir()
    writePkgFile(root / "package.gene",
      "{^name \"acme/app\" ^version \"1.0.0\"}")
    let oldManifest = runGeneIn(root, ["pkg", "resolve"])
    check oldManifest.exitCode == 1
    check "manifest requires ^format 1" in oldManifest.output
    let oldCommand = runGeneIn(root, ["pkg", "install", root])
    check oldCommand.exitCode == 1
    check "unknown pkg subcommand: install" in oldCommand.output

  test "run discovers a format-1 package from the entry file":
    let root = pkgCliDir()
    writePkgFile(root / "app/package.gene", """
{^format 1
 ^name "acme/app"
 ^version "1.0.0"
 ^applications [(application "app" ^entry "src/main.gene")]}
""")
    writePkgFile(root / "app/src/main.gene",
      "(fn main [] ($println this_pkg/name))")
    createDir(root / "elsewhere")
    let ran = runGeneIn(root / "elsewhere",
      ["run", root / "app/src/main.gene"])
    check ran.exitCode == 0
    check ran.output.strip == "acme/app"
