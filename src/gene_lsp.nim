## `gene-lsp` — the Gene language server, speaking JSON-RPC over stdio
## (docs/lsp.md).
##
## Built as its own executable rather than linked into `gene`. `gene lsp` execs
## this binary, which is why the delegation is invisible to an editor: execv
## replaces the process, so the client's stdin/stdout pipes are inherited
## directly with no forwarding layer between them.

import std/[os, strutils]
import gene/ext/logging
import tools/lsp/server as lsp_server

proc configureLspLogging() =
  ## Quiet by default: an LSP server shares stdout with the protocol, so
  ## diagnostics are opt-in via GENE_LSP_LOG.
  var config = defaultLoggingConfig()
  if getEnv("GENE_LSP_LOG", "").strip().toLowerAscii() in
      ["1", "true", "yes", "on"]:
    config.overrides.add LogRouteOverride(name: "gene/lsp", hasLevel: true,
                                          level: llDebug)
  installLoggingConfig(config)

configureLspLogging()
quit(runLspServer())
