## Every compiler head is classified, once.
##
## `tools/declaration_heads.nim` is where the language server, the token
## outline, and the documentation builder learn which forms declare
## something. The compiler's `CoreSpecialFormNames` is the list of heads the
## compiler itself dispatches. Before this test, the two were maintained
## separately: a head added to the compiler was silently invisible to the
## editor and (later) to the docs. This test makes that a failure.
##
## It imports the compiler on purpose. `gene-doc` must never link the
## compiler; a test may, because it is checking a compile-time constant.

import std/[sets, tables, unittest]
import gene/compiler
import tools/declaration_heads

suite "declaration heads":
  test "every CoreSpecialFormNames head is classified exactly once":
    var seen = initTable[string, int]()
    for (head, _) in classifiedHeads:
      inc seen.mgetOrPut(head, 0)
    for info in declarationTable:
      inc seen.mgetOrPut(info.head, 0)
    for head in CoreSpecialFormNames:
      checkpoint "compiler head: " & head
      let (found, _) = headClass(head)
      check found
      check seen.getOrDefault(head, 0) == 1
    # The statement and ignored-form tables are exactly compiler heads.
    for (head, _) in classifiedHeads:
      check head in CoreSpecialFormNames

  test "a declaration head is classified as a declaration, once":
    var heads = initHashSet[string]()
    for info in declarationTable:
      checkpoint "declaration head: " & info.head
      check heads.containsOrIncl(info.head) == false
      let (found, class) = headClass(info.head)
      check found
      check class == dhcDeclaration
      check geneKindName(info.kind).len > 0
      # A named declaration must be able to read a name from somewhere.
      if info.class == dhcDeclaration:
        check info.name != dnkNone or
          info.kind in {dkImport, dkImportImpl, dkDerive}

  test "every declaration kind has a name and an editor kind":
    for kind in DeclKind:
      checkpoint "kind: " & $kind
      check geneKindName(kind).len > 0
      check lspKind(kind) in [skModule, skNamespace, skClass, skMethod,
                              skFunction, skVariable, skConstructor,
                              skEnum, skEnumMember, skInterface, skObject]

  test "an unclassified head is reported as unknown, not guessed":
    for head in ["my_macro", "make_handler", "not_a_declaration", ""]:
      let (found, _) = headClass(head)
      check not found
      check not isDeclarationHead(head)

  test "statement and data heads never count as declarations":
    for (head, kind) in classifiedHeads:
      if kind != dhcDeclaration:
        check not isDeclarationHead(head)
