import std/[strutils, tables, unittest]
import gene/[compiler, repl_completion, types, vm]

proc completionNames(scope: Scope, source: string): seq[string] =
  completeRepl(scope, source, source.len).candidates

suite "REPL completion":
  test "uses visible bindings, including nil and wildcard imports":
    let outer = newGlobalScope()
    outer.define("shadowed", newInt(1))
    outer.define("reserved_only", newInt(1))
    outer.define("ambiguous", newInt(1))
    let scope = newScope(outer)
    scope.slotNames = @["reserved_only", "shadowed", "private_slot"]
    scope.slots = @[NIL, NIL, newInt(2)]
    scope.slotDefinedBits = 0b110'u64
    scope.privateSlots = @[2]
    scope.vars["shadowed"] = newInt(3) # a stale mirror
    scope.wildcardFallbacks["imported"] = WildcardFallback(value: NIL)
    scope.wildcardFallbacks["ambiguous"] = WildcardFallback(value: NIL,
      conflicts: @["other"])
    let choices = scope.completionNames("")
    check choices[0 .. 1] == @["imported", "shadowed"]
    check "reserved_only" notin choices
    check "private_slot" notin choices
    check "ambiguous" notin choices
    check scope.completionNames("shad") == @["shadowed"]
    check scope.replBinding("shadowed").kind == vkNil

  test "lists readable members of nested paths, namespaces, and the library":
    let scope = newGlobalScope()
    discard run(compileReplSource("""
      (let account {^name "Ada" ^"odd key" 1 ^roles [{^id 7}]})
      (ns tools (let hidden ^^private 0) (let shown 1))
      (enum Color Red Green)
    """), scope)
    check scope.completionNames("account/") == @["name", "roles"]
    check scope.completionNames("account/roles/0/") == @["id"]
    check scope.completionNames("tools/") == @["shown"]
    check scope.completionNames("Color/") == @["Green", "Red"]
    check "str" in scope.completionNames("$")
    check scope.completionNames("$str/up") == @["upper"]
    check scope.completionNames("$str/") == scope.completionNames("gene/str/")
    let source = "[account/namx account/roles]"
    let completion = completeRepl(scope, source, source.find("mx") + 1)
    check completion.candidates == @["name"]
    check source[completion.first ..< completion.last] == "namx"

  test "filters direct messages by receiver-only arity and never runs the draft":
    let scope = newGlobalScope()
    discard run(compileReplSource("""
      (var calls 0)
      (type Base ^props {^name Str ^nickname Str?}
        (message greet [] (set calls (+ calls 1)) self/name))
      (type Person : Base ^props {^age Int}
        (message greet_with [word] word)
        (message greet_optional [word = "hi"] word)
        (message greet_named [^word word] word))
      (let ada (Person ^name "Ada" ^age 1))
      (let ada_name "Ada")
      (let items [1 2])
      (fn receiver [] (set calls (+ calls 1)) ada)
    """), scope)
    check scope.completionNames("ada/") == @["age", "name", "nickname"]
    check scope.completionNames("(ada .gr") ==
      @["greet", "greet_named", "greet_optional", "greet_with"]
    check scope.completionNames("ada/.gr") == @["greet", "greet_optional"]
    check scope.completionNames("items/.si") == @["size"]
    check scope.completionNames("items/.pu").len == 0
    check scope.completionNames("ada_name/.up") == @["upper"]
    check scope.completionNames("ada_name/.sp").len == 0
    for source in ["((receiver) .gr", "ada/%field/", "ada/.greet/", "\"ada/",
        "# ada/", "#< ada/", "#_ (ada/", "#_ (ada/ "]:
      check scope.completionNames(source).len == 0
    check scope.lookup("calls").intVal == 0
