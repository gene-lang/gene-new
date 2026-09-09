## Shared identities for the native models used by error_analysis. Runtime
## constructors opt in explicitly; arbitrary host native functions have no
## inferred contract just because they use one of these names.

import std/strutils
import ./types

const NativeErrorModelVersion* = "2"

proc builtinNativeErrorMetadata*(name: string): NativeErrorMetadata =
  var local = if name.startsWith("gene/"): name[5..^1] else: name
  # These namespaces re-export the same native implementations as the root.
  # Their source paths must identify the implementation's model, not a second
  # contract that differs only because the caller imported it through an alias.
  if local.startsWith("stream/") and local[7..^1] in
      ["to_stream", "map", "filter", "filter_map", "each", "into", "take"]:
    local = local[7..^1]
  elif local.startsWith("parse/") and local[6..^1] in ["parse_int", "read_all"]:
    local = local[6..^1]
  elif local in ["List/size", "List/empty?"]:
    local = local.split('/')[1]
  case local
  of "assert", "test/assert_equal", "test/assert_raises",
     "==", "!=", "same?", "not", "nil?", "void?", "present?",
     "+", "-", "*", "<", ">", "<=", ">=", "/", "//", "$", "to_str",
     "range", "to_stream", "map", "filter", "filter_map", "each",
     "into", "take",
     "read_one", "read_all", "parse_int", "size", "empty?", "List/push",
     "Stream/next", "Stream/peek", "Stream/has_next", "Stream/try_next",
     "Stream/close", "Task/join":
    NativeErrorMetadata(identity: "gene/" & local,
                        version: NativeErrorModelVersion)
  else:
    NativeErrorMetadata()

proc nativeErrorAcceptsCall*(metadata: NativeErrorMetadata,
                             positionalCount, namedCount: int): bool =
  ## Shapes accepted by these native implementations before their body-specific
  ## work. All catalogued models reject named arguments. Invalid shapes raise
  ## ordinary RuntimeError, rather than a generated annotated-parameter failure.
  if namedCount != 0: return false
  case metadata.identity
  of "gene/assert": positionalCount in 1..2
  of "gene/test/assert_equal", "gene/test/assert_raises": positionalCount in 2..3
  of "gene/not", "gene/nil?", "gene/void?", "gene/present?", "gene/to_str",
     "gene/to_stream", "gene/read_one", "gene/read_all", "gene/parse_int",
     "gene/size", "gene/empty?", "gene/Stream/next", "gene/Stream/peek",
     "gene/Stream/has_next", "gene/Stream/try_next", "gene/Stream/close",
     "gene/Task/join": positionalCount == 1
  of "gene/same?", "gene///", "gene/each", "gene/List/push": positionalCount == 2
  of "gene//": positionalCount >= 2
  of "gene/range": positionalCount in 2..4
  of "gene/map", "gene/filter", "gene/filter_map", "gene/take", "gene/into": positionalCount in 1..2
  else: true # numeric folds, chained comparisons/equality, and string joining
