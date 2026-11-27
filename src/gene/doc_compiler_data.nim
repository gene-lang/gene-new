## Compiler data the documentation generator needs. The builder (`gene-doc`)
## never links the compiler, so `gene doc build` writes this data as files
## for the generator to read:
##
## - `build/docs/heads.gene`: the compiler's special-form heads.
## - `build/docs/macros.gene`: the macros the compiler supplies for standard
##   namespaces (`$test/describe`, `$log/log_info`, ...), which are not
##   runtime namespace members and so are invisible to reflection.

import std/[algorithm, os, strutils, tables]
import ./[compiler, gir, printer, types]

proc quoted(text: string): string =
  "\"" & text.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

proc patternText(pattern: Value): string =
  if pattern.kind == vkSymbol: pattern.symVal else: print(pattern)

proc macroEntryText(ns, name: string, def: MacroDef): string =
  var positional: seq[string]
  for param in def.params:
    positional.add "{^name " & quoted(patternText(param.pattern)) &
      " ^optional " & $param.defaultValue.optional & "}"
  var named: seq[string]
  for param in def.named:
    named.add "{^name " & quoted(param.arg) &
      " ^optional " & $param.defaultValue.optional & "}"
  "{^ns " & quoted(ns) & " ^name " & quoted(name) &
    " ^positional [" & positional.join(" ") & "]" &
    " ^named [" & named.join(" ") & "]" &
    " ^rest " & quoted(def.rest) & "}"

proc compilerMacrosText*(): string =
  var lines: seq[string]
  for ns in BuiltinMacroNamespaces:
    let defs = builtinNamespaceMacros([ns])
    var names: seq[string]
    for name in defs.keys: names.add name
    names.sort()
    for name in names:
      lines.add " " & macroEntryText(ns, name, defs[name])
  "[\n" & lines.join("\n") & "\n]\n"

proc compilerHeadsText*(): string =
  var items: seq[string]
  for name in CoreSpecialFormNames:
    items.add quoted(name)
  "[" & items.join(" ") & "]\n"

proc writeCompilerDocData*(root: string) =
  let docsDir = root / "build" / "docs"
  createDir(docsDir)
  writeFile(docsDir / "heads.gene", compilerHeadsText())
  writeFile(docsDir / "macros.gene", compilerMacrosText())
