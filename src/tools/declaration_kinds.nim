## LSP SymbolKind constants for Gene declarations.
##
## One module owns the numeric kinds because they are the contract between
## tools, not an implementation detail of the language server
## (docs/workflows.md): the LSP document-symbol tree, the browser editor's
## outline, and the parity test between them all name the same numbers. A
## second literal table is how the outline would quietly drift from the server
## the editor is supposed to agree with.

const
  # LSP SymbolKind constants (the protocol's numeric encoding).
  skModule* = 2
  skNamespace* = 3
  skClass* = 5
  skMethod* = 6
  skEnum* = 10
  skInterface* = 11
  skFunction* = 12
  skVariable* = 13
  skConstructor* = 9
  skEnumMember* = 22
  skObject* = 19

proc declarationKindName*(kind: int): string =
  ## A stable, human-facing name for a kind number. The numbers stay the wire
  ## contract; this is what an outline tooltip or a request log can show.
  case kind
  of skModule: "module"
  of skNamespace: "namespace"
  of skClass: "class"
  of skMethod: "method"
  of skEnum: "enum"
  of skInterface: "interface"
  of skFunction: "function"
  of skVariable: "variable"
  of skConstructor: "constructor"
  of skEnumMember: "enum member"
  of skObject: "object"
  else: "kind " & $kind
