import std/[os, strutils]
import gene/registry_https

if paramCount() notin [6, 9]:
  quit("usage: probe <base> <curl> <ca|-> <path> <limit> <seconds> [object <digest> <staging>]", 2)
try:
  let ca = if paramStr(3) == "-": "" else: paramStr(3)
  let transport = newRegistryHttpsTransport(paramStr(1), paramStr(2), ca,
                                            parseInt(paramStr(6)))
  if paramCount() == 6:
    stdout.write fetchRegistryBytes(transport, paramStr(4),
                                    parseInt(paramStr(5)))
  elif paramStr(7) == "object":
    stdout.write fetchRegistryObject(transport, paramStr(4), paramStr(8),
      parseBiggestInt(paramStr(5)), paramStr(9))
  else:
    quit("unknown registry probe mode", 2)
except RegistryHttpsError as error:
  stderr.writeLine error.msg
  quit(2)
