## A parameter's declared type is kept on the activation whenever something
## other than the function's own body can assign it. The Int fast binders
## skipped that for a nested function, so the assignment went unchecked.
import gene/[compiler, printer, types, vm]
import std/unittest

template paramCk(src, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

suite "a typed parameter assigned from a nested function":
  test "the Int fast binders keep the parameter's type on the activation":
    paramCk """
      (fn one [a : Int] : Int (fn g [] (set a "x")) (g) 1)
      (fn two [a : Int b : Int] : Int (fn g [] (set a "x")) (g) 1)
      (fn str [a : Str] : Int (fn g [] (set a 5)) (g) 1)
      (fn fine [a : Int] : Int (fn g [] (set a 7)) (g) a)
      [(try (one 1) catch TypeError $err_msg)
       (try (two 1 2) catch TypeError $err_msg)
       (try (str "s") catch TypeError $err_msg)
       (fine 1)]""",
      """["set 'a' expected Int, got Str" "set 'a' expected Int, got Str" """ &
      """"set 'a' expected Str, got Int" 7]"""
