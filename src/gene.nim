## Gene language CLI entry point
import std/[os]
import gene/reader
import gene/printer

proc main() =
  if paramCount() == 0:
    echo "Gene — a homoiconic general purpose language"
    echo "Usage: gene <file.gene>"
    quit(0)
  let filename = paramStr(1)
  if not fileExists(filename):
    echo "Error: file not found: ", filename
    quit(1)
  let src = readFile(filename)
  let forms = readAll(src)
  for f in forms:
    echo f.print()

main()
