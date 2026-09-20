## Run with --threads:off. Unsupported transport must fail before CA-file I/O.
import std/unittest
import gene/[capabilities, compiler, printer, types, vm]

static:
  doAssert not compileOption("threads")

suite "HTTP capability transport without native workers":
  test "request rejects the backend before reading an explicit CA file":
    let app = newApplication()
    let row = app.capabilities.normalizeCapabilityRow(readCapabilityLiteral(
      "[net/Http]", cuGrant, CapabilitySourceContext()), cuGrant)
    let grant = app.hostCapabilities.mintPolicyGrant(row.entries[0].policy)
    app.setRootCapabilities(app.capabilities.newPolicyContext([grant]))
    check run(compileSource("""
      (try ($net/http_client/request ^url "https://example.com/"
        ^ca_file "/must-not-be-read.pem")
        false catch UnsupportedCapability $err/reason)
    """), newGlobalScope(app)).print() == "\"unsupported_transport\""

  test "pure preparation and operation checking still work":
    let app = newApplication()
    app.setRootCapabilities(app.capabilities.newPolicyContext([]))
    check run(compileSource("""
      (var prepared ($net/http_client/prepare "GET" "https://example.com/?"))
      (var decision ($capabilities/check_operation
        ($net/http_client/describe_operation prepared)))
      decision/allowed
    """), newGlobalScope(app)).print() == "false"
