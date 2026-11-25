## One table of declaration heads, shared by the language server's document
## symbols, the token outline, and the documentation builder.
##
## `declaration_kinds.nim` shares the numeric symbol kinds because a second
## literal table is how the editor and the server quietly stop agreeing. This
## module is the same idea one level up: the *set of forms that declare
## something*, and the answer to "what should a walker read from this form".
## Before it, `tools/lsp/analysis.nim` knew eleven heads and
## `tools/source_outline.nim` copied them; the builder would have been a third
## copy, and a new compiler head would have been invisible to all three.
##
## Every head in `CoreSpecialFormNames` must be classified here, as exactly one
## of a declaration, a statement, or an ignored form. `tests/test_declaration_heads.nim`
## enforces that against the compiler's list, so a head added to the compiler
## fails a test instead of silently becoming a doc gap.

import std/strutils
import ./declaration_kinds
import ../gene/types

type
  DeclHeadClass* = enum
    ## What a top-level form with this head is to a declaration walker.
    dhcDeclaration   ## declares something: read it
    dhcStatement     ## executable statement: ignore it, and record nothing
    dhcIgnored       ## a data/quotation form, not a statement: ignore it

  DeclKind* = enum
    ## The one shared spelling of a declaration's kind. It is deliberately
    ## finer grained than the LSP SymbolKind: the builder needs `let` distinct
    ## from `var`, and `ffi/struct` distinct from `type`.
    dkFn, dkMacro, dkType, dkEnum, dkProtocol, dkImpl, dkMessage, dkCtor,
    dkNs, dkMod, dkLet, dkVar, dkConst, dkAlias, dkImport, dkImportImpl,
    dkDerive, dkWebModule, dkFfiLibrary, dkFfiFn, dkFfiStruct, dkFfiUnion,
    dkFfiCallback, dkFfiSignature

  DeclNameKind* = enum
    ## Where a declaration's name is, if it has one of its own.
    dnkFirst     ## the first positional operand is the name (a symbol)
    dnkImpl      ## `impl P for T`: a computed label
    dnkCtor      ## a constructor is named `ctor`
    dnkMod       ## `mod name`: names the enclosing module
    dnkNone      ## no name of its own (`import`, `derive`)

  DeclHeadInfo* = object
    head*: string
    class*: DeclHeadClass
    kind*: DeclKind
    name*: DeclNameKind
    callable*: bool       ## carries a parameter vector / signature
    recurse*: bool        ## this form's body is a list of nested declarations
    symbol*: bool         ## appears in the editor's symbol tree
    exportable*: bool     ## `^private`/`^^private` applies
    doc*: bool            ## `@doc` and the other doc meta apply

const declarationTable* = [
  # Callables.
  DeclHeadInfo(head: "fn", class: dhcDeclaration, kind: dkFn,
    name: dnkFirst, callable: true, symbol: true, exportable: true, doc: true),
  DeclHeadInfo(head: "macro", class: dhcDeclaration, kind: dkMacro,
    name: dnkFirst, callable: true, symbol: true, exportable: true, doc: true),
  DeclHeadInfo(head: "message", class: dhcDeclaration, kind: dkMessage,
    name: dnkFirst, callable: true, symbol: true, doc: true),
  DeclHeadInfo(head: "ctor", class: dhcDeclaration, kind: dkCtor,
    name: dnkCtor, callable: true, symbol: true, doc: true),
  # Types and their behaviour.
  DeclHeadInfo(head: "type", class: dhcDeclaration, kind: dkType,
    name: dnkFirst, recurse: true, symbol: true, exportable: true, doc: true),
  DeclHeadInfo(head: "enum", class: dhcDeclaration, kind: dkEnum,
    name: dnkFirst, symbol: true, exportable: true, doc: true),
  DeclHeadInfo(head: "alias", class: dhcDeclaration, kind: dkAlias,
    name: dnkFirst, symbol: true, exportable: true, doc: true),
  DeclHeadInfo(head: "protocol", class: dhcDeclaration, kind: dkProtocol,
    name: dnkFirst, recurse: true, symbol: true, exportable: true, doc: true),
  DeclHeadInfo(head: "impl", class: dhcDeclaration, kind: dkImpl,
    name: dnkImpl, symbol: true, doc: true),
  DeclHeadInfo(head: "derive", class: dhcDeclaration, kind: dkDerive,
    name: dnkNone, doc: true),
  # Bindings.
  DeclHeadInfo(head: "let", class: dhcDeclaration, kind: dkLet,
    name: dnkFirst, symbol: true, exportable: true, doc: true),
  DeclHeadInfo(head: "var", class: dhcDeclaration, kind: dkVar,
    name: dnkFirst, symbol: true, exportable: true, doc: true),
  DeclHeadInfo(head: "const", class: dhcDeclaration, kind: dkConst,
    name: dnkFirst, symbol: true, exportable: true, doc: true),
  # Modules and namespaces.
  DeclHeadInfo(head: "ns", class: dhcDeclaration, kind: dkNs,
    name: dnkFirst, recurse: true, symbol: true, exportable: true, doc: true),
  DeclHeadInfo(head: "mod", class: dhcDeclaration, kind: dkMod,
    name: dnkMod, symbol: true, doc: true),
  DeclHeadInfo(head: "web_module", class: dhcDeclaration, kind: dkWebModule,
    name: dnkFirst, symbol: true, exportable: true, doc: true),
  # Imports. They bind names but declare nothing of this module's own.
  DeclHeadInfo(head: "import", class: dhcDeclaration, kind: dkImport,
    name: dnkNone),
  DeclHeadInfo(head: "import_impl", class: dhcDeclaration, kind: dkImportImpl,
    name: dnkNone),
  # FFI declarations (path heads: `ffi/fn` reads as (path ffi fn)).
  DeclHeadInfo(head: "ffi/library", class: dhcDeclaration, kind: dkFfiLibrary,
    name: dnkFirst, symbol: true, doc: true),
  DeclHeadInfo(head: "ffi/fn", class: dhcDeclaration, kind: dkFfiFn,
    name: dnkFirst, callable: true, symbol: true, doc: true),
  DeclHeadInfo(head: "ffi/struct", class: dhcDeclaration, kind: dkFfiStruct,
    name: dnkFirst, symbol: true, doc: true),
  DeclHeadInfo(head: "ffi/union", class: dhcDeclaration, kind: dkFfiUnion,
    name: dnkFirst, symbol: true, doc: true),
  DeclHeadInfo(head: "ffi/callback", class: dhcDeclaration, kind: dkFfiCallback,
    name: dnkFirst, callable: true, symbol: true, doc: true),
  DeclHeadInfo(head: "ffi/signature", class: dhcDeclaration,
    kind: dkFfiSignature, name: dnkFirst, callable: true, symbol: true,
    doc: true)
]

const classifiedHeads* = [
  # Statements: executable forms with no declaration to read.
  ("do", dhcStatement), ("if", dhcStatement), ("if_not", dhcStatement),
  ("if_present", dhcStatement), ("&&", dhcStatement), ("||", dhcStatement),
  ("??", dhcStatement), ("!", dhcStatement), ("set", dhcStatement),
  ("new", dhcStatement), ("match", dhcStatement), ("while", dhcStatement),
  ("loop", dhcStatement), ("repeat", dhcStatement), ("for", dhcStatement),
  ("map_for", dhcStatement), ("break", dhcStatement), ("continue", dhcStatement),
  ("yield", dhcStatement), ("return", dhcStatement), ("try", dhcStatement),
  ("scope", dhcStatement), ("supervisor", dhcStatement),
  ("spawn", dhcStatement), ("await", dhcStatement), ("fail", dhcStatement),
  ("panic", dhcStatement), ("env", dhcStatement), ("eval", dhcStatement),
  # Data and quotation forms: not statements, and not declarations.
  ("quote", dhcIgnored), ("quasiquote", dhcIgnored), ("Path", dhcIgnored),
  ("path", dhcIgnored), ("msg", dhcIgnored)
]

proc declarationHeadInfo*(head: string): tuple[found: bool, info: DeclHeadInfo] =
  ## The table entry for a declaration head, or `found = false`.
  for info in declarationTable:
    if info.head == head:
      return (found: true, info: info)

proc headClass*(head: string): tuple[found: bool, class: DeclHeadClass] =
  ## How a walker must treat a top-level form with this head. `found = false`
  ## means no head knows it: a user macro call, a call that defines names, or a
  ## new compiler form that has not been classified yet.
  for (name, kind) in classifiedHeads:
    if name == head:
      return (found: true, class: kind)
  let decl = declarationHeadInfo(head)
  if decl.found:
    return (found: true, class: dhcDeclaration)

proc isDeclarationHead*(head: string): bool =
  declarationHeadInfo(head).found

proc headText*(head: Value): string =
  ## The source spelling of a form's head: a symbol as written, or a
  ## slash-joined path for a node head such as `(path ffi fn)`.
  if head.kind == vkSymbol:
    return head.symVal
  if head.kind == vkNode and head.head.kind == vkSymbol and
      head.head.symVal == "path":
    var segments: seq[string]
    for segment in head.body:
      if segment.kind != vkSymbol:
        return ""
      segments.add segment.symVal
    return segments.join("/")

proc geneKindName*(kind: DeclKind): string =
  ## The Gene spelling of a kind, as written in a data file.
  case kind
  of dkFn: "fn"
  of dkMacro: "macro"
  of dkType: "type"
  of dkEnum: "enum"
  of dkProtocol: "protocol"
  of dkImpl: "impl"
  of dkMessage: "message"
  of dkCtor: "ctor"
  of dkNs: "ns"
  of dkMod: "mod"
  of dkLet: "let"
  of dkVar: "var"
  of dkConst: "const"
  of dkAlias: "alias"
  of dkImport: "import"
  of dkImportImpl: "import_impl"
  of dkDerive: "derive"
  of dkWebModule: "web_module"
  of dkFfiLibrary: "ffi/library"
  of dkFfiFn: "ffi/fn"
  of dkFfiStruct: "ffi/struct"
  of dkFfiUnion: "ffi/union"
  of dkFfiCallback: "ffi/callback"
  of dkFfiSignature: "ffi/signature"

proc lspKind*(kind: DeclKind): int =
  ## The editor symbol kind for a declaration kind. One mapping, so the LSP
  ## document-symbol tree and the token outline cannot disagree.
  case kind
  of dkFn, dkMacro, dkFfiFn: skFunction
  of dkMessage: skMethod
  of dkCtor: skConstructor
  of dkType, dkAlias, dkFfiStruct, dkFfiUnion, dkFfiCallback,
     dkFfiSignature: skClass
  of dkEnum: skEnum
  of dkProtocol: skInterface
  of dkImpl: skObject
  of dkNs: skNamespace
  of dkMod: skModule
  of dkLet, dkVar, dkConst, dkWebModule, dkFfiLibrary: skVariable
  of dkImport, dkImportImpl, dkDerive: skVariable

proc lspDetail*(kind: DeclKind, generator: bool): string =
  ## The small one-word detail the editor shows beside a symbol.
  if kind == dkMacro:
    return "macro"
  if generator and kind in {dkFn, dkMessage}:
    return "generator"
  ""
