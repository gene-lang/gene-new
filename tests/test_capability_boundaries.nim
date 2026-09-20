import std/[os, strutils, tables, tempfiles, unittest]
import gene/[capabilities, compiler, fs_capabilities, gir, gir_codec, printer, reader, types, vm]
when defined(posix):
  import std/posix

proc boundaryApp(root = "", http = ""): Application =
  result = newApplication(if root.len > 0: root else: getCurrentDir())
  var grants: seq[CapabilityGrant]
  if root.len > 0:
    let row = result.capabilities.normalizeCapabilityRow(readCapabilityLiteral(
      "[(fs/ReadWrite " & newStr(root).print() & ")]", cuGrant,
      CapabilitySourceContext()), cuGrant)
    grants.add result.filesystemCapabilities.initializeFilesystemGrant(row.entries[0].policy)
  if http.len > 0:
    let row = result.capabilities.normalizeCapabilityRow(
      readCapabilityLiteral(http, cuGrant, CapabilitySourceContext()), cuGrant)
    for entry in row.entries:
      grants.add result.hostCapabilities.mintPolicyGrant(entry.policy)
  result.setRootCapabilities(result.capabilities.newPolicyContext(grants))

proc boundaryRun(app: Application, source: string, sourceName = ""): Value =
  run(compileSource(source, sourceName, useLocalSlots = false), newGlobalScope(app))

suite "inert source capability contracts":
  test "variables, executable forms, metadata and reader extensions are rejected":
    for row in [
      "*", "net/Http", "[(fs/Read path)]", "[(fs/Read (compute))]",
      "[(net/Http ^methods [GET])]", "[(net/Http ^methods void)]",
      "[(net/Http @hidden void)]", "[(net/Http ^methods #[\"GET\"])]",
      "[(net/Http ^methods [\"GET\", \"POST\"])]",
      "[_ (fs/Read \"/secret\") net/Http]",
      "[(net/Http ^^optional ^optional false)]",
      "[(net/Http ^hosts [\"a\"] ^hosts [\"b\"])]"]:
      checkpoint row
      expect GeneError:
        discard compileSource("(fn f [] ^capabilities " & row & " 1)")

  test "capability literal macros are not expanded":
    expect GeneError:
      discard compileSource("""
(macro dir [] "/tmp")
(fn f [] ^capabilities [(fs/Read (dir))] 1)
""")
    expect GeneError:
      discard compileSource("""
(macro dir [] "/tmp")
(with_capabilities [(fs/Read (dir))] 1)
""")

  test "duplicate declaration rows cannot replace an earlier requirement":
    expect GeneError:
      discard compileSource("(fn f [] ^capabilities [net/Http] ^capabilities [] 1)")

  test "module capability rows and legacy mode switches are rejected":
    for annotation in ["^capabilities []", "^capabilities_mode open",
                       "^capabilities_mode strict", "^^require_strict_dependencies"]:
      expect GeneError:
        discard compileSource("(mod m " & annotation & " 1)")

  test "source and text parser both enforce literal property separation":
    for row in ["""[(net/Http^methods ["GET"])]""",
                """[(net/Http ^methods["GET"])]"""]:
      expect CapabilityLiteralError:
        discard readCapabilityLiteral(row, cuRequest, CapabilitySourceContext())
      expect GeneError:
        discard compileSource("(fn f [] ^capabilities " & row & " 1)")

suite "normalized callable and block boundaries":
  when defined(posix):
    test "provider inspection failures remain visible in reports and boundary errors":
      if geteuid() == 0:
        skip()
      else:
        let root = expandFilename(createTempDir("gene-provider-failure-v1-", ""))
        defer: removeDir(root)
        let app = boundaryApp(root)
        let scope = newGlobalScope(app)
        scope.define("file", newStr(root / "data"))
        scope.define("policy_text", newStr("[(fs/Read " & newStr(root).print() & ")]"))
        scope.define("optional_text", newStr("[(fs/Read " & newStr(root).print() & " ^^optional)]"))
        discard run(compileSource("""
          (var entered ($cell false))
          (var policy ($capabilities/parse policy_text))
          (var optional_policy ($capabilities/parse optional_text))
        """, useLocalSlots = false), scope)
        let permissions = getFilePermissions(root)
        setFilePermissions(root, {})
        defer: setFilePermissions(root, permissions)
        check run(compileSource("""
          (var report ($capabilities/check_requirements policy))
          [report/admitted report/entries/0/status report/entries/0/failure_scope]
        """, useLocalSlots = false), scope).print() == "[false \"provider_failure\" \"entry\"]"
        check run(compileSource("""
          (try (require_capabilities policy (entered .set true))
            false catch CapabilityProviderError $err/reason)
        """), scope).print() == "\"provider_failure\""
        check run(compileSource("(entered .get)"), scope).print() == "false"
        check run(compileSource("""
          (var optional_report ($capabilities/check_requirements optional_policy))
          [optional_report/admitted optional_report/entries/0/status
           (require_capabilities optional_policy 7)]
        """, useLocalSlots = false), scope).print() == "[true \"provider_failure\" 7]"
        check run(compileSource("""
          (try ($fs/read_text file) false catch CapabilityProviderError $err/reason)
        """), scope).print() == "\"entry_provider_failure\""

  test "the atomic-write adapter guards destination changes and rejects legacy logging":
    let root = expandFilename(createTempDir("gene-atomic-boundary-v1-", ""))
    defer: removeDir(root)
    let app = boundaryApp(root)
    let path = newStr(root / "data").print()
    writeFile(root / "data", "original")
    check app.boundaryRun("(try (with_capabilities [] ($fs/write_text_atomic " &
      path & " \"denied\")) false catch MissingCapability true)").boolVal
    check readFile(root / "data") == "original"
    discard app.boundaryRun("($fs/write_text_atomic " & path & " \"committed\")")
    check readFile(root / "data") == "committed"
    check app.filesystemCapabilities.initializedFilesystemFiles == 0
    check app.boundaryRun("(try ($log/new_file_logger \"app/test\" " &
      newStr(root / "log").print() & ") false catch UnsupportedCapability true)").boolVal
    check not fileExists(root / "log")

  test "unmigrated effect adapters explicitly reject normalized execution":
    let app = boundaryApp()
    for operation in [
      "($println \"unreachable output\")",
      "($os/read_line)",
      "($os/get_env \"GENE_TEST_UNDISCLOSED_ENV\" \"fallback\")",
      "($os/process_id)",
      "($os/monotonic_ms)",
      "($sleep 0)",
      "($crypto/random_hex 4)",
      "($os/exec ^cmd \"gene-command-that-must-not-run\")",
      "($ffi/open \"gene-library-that-must-not-load\")"]:
      checkpoint operation
      check app.boundaryRun("(try " & operation &
        " false catch UnsupportedCapability $err/reason)").print() ==
        "\"unsupported_operation\""

  test "compiled artifacts preserve requests, dynamic bounds, and lexical exits":
    let root = expandFilename(createTempDir("gene-gir-caps-v1-", ""))
    defer: removeDir(root)
    writeFile(root / "data", "artifact")
    let prefix = """
      (fn read [] ^capabilities [(fs/Read ".")]
        ($fs/read_text TARGET_PATH))
      (var empty ($capabilities/parse "[]"))
    """.replace("TARGET_PATH", newStr(root / "data").print())
    for (label, body, expected) in [
      ("direct", "(read)", "\"artifact\""),
      ("dynamic block", "(try (with_capabilities empty (read)) false catch MissingCapability true)", "true"),
      ("loop exit", "(loop (with_capabilities empty (break))) (read)", "\"artifact\""),
      ("dynamic Env", "(var saved (env ^capabilities empty)) (try (eval (quote (read)) ^in saved) false catch MissingCapability true)", "true")]:
      checkpoint label
      let source = prefix & body
      let identity = root / "entry.gene"
      let compiled = compileSource(source, identity)
      check run(compileSource(source, identity), newGlobalScope(boundaryApp(root))).print() == expected
      let artifact = ExecutableGir(entryIdentity: identity,
        modules: @[CompiledModule(identity: identity, chunk: compiled,
          macroExports: initTable[string, MacroDef](), syntaxFnExports: @[],
          compileInterface: CompileNamespaceInterface(
            entries: initTable[string, CompileInterfaceEntry]()))])
      let decoded = decodeExecutableGir(encodeExecutableGir(artifact))
      let originalRow = compiled.functions[0].capabilityRow.literal
      let restoredRow = decoded.modules[0].chunk.functions[0].capabilityRow.literal
      check restoredRow.source == originalRow.source
      check restoredRow.entries.len == originalRow.entries.len
      check restoredRow.entries[0].name == originalRow.entries[0].name
      check restoredRow.entries[0].body[0].text == originalRow.entries[0].body[0].text
      let app = boundaryApp(root)
      let request = app.capabilities.normalizeCapabilityRow(restoredRow, cuRequest)
      check app.capabilities.checkCapabilityRequirements(
        app.capabilities.policyRows(app.rootCapabilities), request).admitted
      check run(decoded.modules[0].chunk, newGlobalScope(app)).print() == expected

  test "operation denials retain typed capability details and ordinary I/O errors":
    let root = expandFilename(createTempDir("gene-denial-v1-", ""))
    defer: removeDir(root)
    let app = boundaryApp(root)
    let path = newStr(root / "missing").print()
    check app.boundaryRun("(try (with_capabilities [] ($fs/read_text " & path &
      ")) catch MissingCapability [$err/capability $err/operation $err/reason])").print() ==
      "[\"fs/Read\" \"fs/read_text\" \"no_permitting_entry\"]"
    check app.boundaryRun("(try ($fs/read_text " & path &
      ") false catch OsError true)").print() == "true"
    check app.boundaryRun("(try ($fs/try_lock " & path &
      ") false catch UnsupportedCapability $err/reason)").print() ==
      "\"unsupported_operation\""

  test "upper bounds do not impose admission and required blocks do":
    let app = boundaryApp()
    check app.boundaryRun("(with_capabilities [net/Http] 42)").print() == "42"
    check app.boundaryRun("(require_capabilities [(net/Http ^^optional)] 42)").print() == "42"
    expect GeneError:
      discard app.boundaryRun("(require_capabilities [net/Http] 42)")
    expect GeneError:
      discard compileSource("(with_capabilities [(net/Http ^optional false)] 42)")

  test "literal and dynamic required rows preserve the same typed failure":
    let app = boundaryApp()
    for row in ["[net/Http]", "($capabilities/parse \"[net/Http]\")"]:
      check app.boundaryRun("(try (require_capabilities " & row &
        " 42) catch MissingCapability [$err/reason $err/authority_row])").print() ==
        "[\"unmatched_requirement\" 0]"
    check app.boundaryRun("""
      (fn target [] 42)
      (try ($runtime/bind_call target []
        ^capabilities ($capabilities/parse "[(net/Http ^^optional)]"))
        false catch CapabilityTypeError $err/reason)
    """).print() == "\"invalid_policy\""

  test "mandatory admission occurs before defaults and body mutations":
    let app = boundaryApp()
    let scope = newGlobalScope(app)
    discard run(compileSource("""
(var entered ($cell 0))
(fn required [x = (entered .set 1)] ^errors []
  ^capabilities [net/Http] (entered .set 2))
""", useLocalSlots = false), scope)
    check run(compileSource(
      "(try (required) false catch MissingCapability true)"), scope).print() == "true"
    check run(compileSource("(entered .get)"), scope).print() == "0"

  test "optional families retain only the caller's available operations":
    let app = boundaryApp(http =
      """[(net/Http ^hosts ["a.example"] ^methods ["GET"])]""")
    check app.boundaryRun("""
(fn inspect [] ^capabilities [(net/Http ^^optional)]
  (var get ($net/http_client/describe_operation
    ($net/http_client/prepare "GET" "https://a.example/")))
  (var post ($net/http_client/describe_operation
    ($net/http_client/prepare "POST" "https://a.example/")))
  (var allowed ($capabilities/check_operation get))
  (var denied ($capabilities/check_operation post))
  [allowed/allowed denied/allowed])
(inspect)
""").print() == "[true false]"

  test "dynamic policy operands are validated values evaluated exactly once":
    let app = boundaryApp()
    check app.boundaryRun("""
(var count ($cell 0))
(fn bound [] (count .set (+ (count .get) 1)) ($capabilities/parse "[]"))
(var answer (with_capabilities (bound) 7))
[answer (count .get)]
""").print() == "[7 1]"
    expect GeneError:
      discard app.boundaryRun("(with_capabilities {^name \"net/Http\"} 1)")

  test "nested bounds cannot restore filesystem authority":
    let root = expandFilename(createTempDir("gene-boundary-v1-", ""))
    defer: removeDir(root)
    let app = boundaryApp(root)
    let target = newStr(root / "data").print()
    expect GeneError:
      discard app.boundaryRun("(with_capabilities [] " &
        "(with_capabilities [fs/ReadWrite] ($fs/write_text " & target & " \"no\")))")
    check not fileExists(root / "data")
    discard app.boundaryRun("($fs/write_text " & target & " \"yes\")")
    check readFile(root / "data") == "yes"

  test "return and errors restore the enclosing context":
    let root = expandFilename(createTempDir("gene-return-v1-", ""))
    defer: removeDir(root)
    let app = boundaryApp(root)
    check app.boundaryRun("(fn f [] (with_capabilities [] (return 7)) 9) (f)").print() == "7"
    expect GeneError:
      discard app.boundaryRun("(with_capabilities [] missing_boundary_name)")
    discard app.boundaryRun("($fs/write_text " & newStr(root / "after").print() & " \"restored\")")
    check readFile(root / "after") == "restored"

  test "relative declaration paths retain their defining source base":
    let root = expandFilename(createTempDir("gene-base-v1-", ""))
    defer: removeDir(root)
    createDir(root / "data")
    writeFile(root / "data" / "value", "ok")
    let app = boundaryApp(root)
    let source = "(fn f [] ^capabilities [(fs/Read \"data\")] " &
      "($fs/read_text " & newStr(root / "data" / "value").print() & ")) (f)"
    check app.boundaryRun(source, root / "module.gene").print() == "\"ok\""

  test "while break and continue cross capability and ensure frames":
    let app = boundaryApp()
    check app.boundaryRun("""
(fn calculate []
  (var i 0)
  (var total 0)
  (var cleaned 0)
  (while (< i 5)
    (set i (+ i 1))
    (with_capabilities []
      (try
        (if (== i 2) (continue) nil)
        (if (== i 4) (break) nil)
        (set total (+ total i))
       ensure (set cleaned (+ cleaned 1)))))
  [i total cleaned])
(calculate)
""").print() == "[4 4 4]"

  test "repeat and for preserve their lexical loop targets":
    let app = boundaryApp()
    check app.boundaryRun("""
(var total 0)
(repeat i in 6
  (with_capabilities []
    (if (== i 1) (continue) nil)
    (if (== i 4) (break) nil)
    (set total (+ total i))))
(for n in [1 2 3 4]
  (require_capabilities []
    (if (== n 2) (continue) nil)
    (if (== n 4) (break) nil)
    (set total (+ total n))))
total
""").print() == "9"

  test "a loop exit restores authority before the following effect":
    let root = expandFilename(createTempDir("gene-loop-v1-", ""))
    defer: removeDir(root)
    let app = boundaryApp(root)
    let target = newStr(root / "after-loop").print()
    discard app.boundaryRun("(loop (with_capabilities [] (break))) " &
      "($fs/write_text " & target & " \"restored\")")
    check readFile(root / "after-loop") == "restored"

suite "exact inherited capability contracts":
  test "an implementation cannot strengthen optional into mandatory":
    let app = boundaryApp()
    expect GeneError:
      discard app.boundaryRun("""
(protocol P (message act [] ^capabilities [(net/Http ^^optional)]))
(type T)
(impl P for T (message act [] ^capabilities [net/Http] 1))
""")

  test "an omitted implementation inherits an empty requirement":
    let app = boundaryApp(http = "[net/Http]")
    check app.boundaryRun("""
(protocol P (message act [] ^capabilities []))
(type T)
(impl P for T (message act []
  (var op ($net/http_client/describe_operation
    ($net/http_client/prepare "GET" "https://a.example/")))
  (var decision ($capabilities/check_operation op))
  decision/allowed))
((T) .P:act)
""").print() == "false"

  test "absent and empty inherited contracts are distinct":
    let app = boundaryApp()
    expect GeneError:
      discard app.boundaryRun("""
(protocol P (message act []))
(type T)
(impl P for T (message act [] ^capabilities [] 1))
""")

  test "type-direct overrides inherit the parent's row":
    let app = boundaryApp(http = "[net/Http]")
    check app.boundaryRun("""
(type Parent (message allowed [] ^capabilities [] false))
(type Child : Parent
  (message allowed [] ^^override
    (var op ($net/http_client/describe_operation
      ($net/http_client/prepare "GET" "https://a.example/")))
    (var decision ($capabilities/check_operation op))
    decision/allowed))
((Child) .allowed)
""").print() == "false"

  test "binding a target preserves its mandatory contract":
    let app = boundaryApp(http = "[net/Http]")
    check app.boundaryRun("""
(fn target [] ^capabilities [net/Http] 1)
(var bound ($runtime/bind_call target [] ^capabilities ($capabilities/parse "[]")))
(try (bound) false catch MissingCapability true)
""").print() == "true"

  test "binding unavailable authority does not make an optional target mandatory":
    let app = boundaryApp()
    check app.boundaryRun("""
(fn target [] ^capabilities [(net/Http ^^optional)]
  (var op ($net/http_client/describe_operation
    ($net/http_client/prepare "GET" "https://a.example/")))
  (var decision ($capabilities/check_operation op))
  decision/allowed)
(var bound ($runtime/bind_call target [] ^capabilities ($capabilities/parse "[net/Http]")))
(bound)
""").print() == "false"

  test "direct, held, bound and adapted protocol calls keep mandatory admission":
    for invocation in [
      "((T) .P:act)",
      "(held (T))",
      "(( $runtime/bind_call held [(T)]))",
      "(adapted (T))"]:
      let app = boundaryApp()
      let scope = newGlobalScope(app)
      discard run(compileSource("""
(protocol P (message act [] : Int ^capabilities [net/Http]))
(type T)
(impl P for T (message act [] : Int 1))
(var held (msg P act))
(var adapted : (Callable [Any] Int) held)
""", useLocalSlots = false), scope)
      checkpoint invocation
      expect GeneError:
        discard run(compileSource(invocation), scope)

  test "callee defaults execute under the selected authority":
    let root = expandFilename(createTempDir("gene-defaults-v1-", ""))
    defer: removeDir(root)
    let app = boundaryApp(root)
    let target = newStr(root / "default-effect").print()
    let source = "(fn f [x = ($fs/write_text " & target &
      " \"no\")] ^capabilities [] 1) (f)"
    expect GeneError:
      discard app.boundaryRun(source)
    check not fileExists(root / "default-effect")

  test "per-invocation admission observes revocation before default effects":
    let app = boundaryApp(http = "[net/Http]")
    let scope = newGlobalScope(app)
    discard run(compileSource("""
(var count ($cell 0))
(fn f [x = (count .set (+ (count .get) 1))] ^capabilities [net/Http] 1)
(f)
""", useLocalSlots = false), scope)
    let grant = app.rootCapabilities.grants[0]
    app.hostCapabilities.revoke(grant)
    expect GeneError:
      discard run(compileSource("(f)"), scope)
    check run(compileSource("(count .get)"), scope).print() == "1"
