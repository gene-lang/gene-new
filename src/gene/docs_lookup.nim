## Reading the generated documentation corpus.
##
## One implementation serves the `gene doc` commands and the `$docs` builtins.
## It reads files under `build/docs/` (or a corpus elsewhere) and never loads a
## documented module. SQLite is loaded dynamically, so building this module
## does not add a link-time dependency.

import std/[algorithm, os, strutils, tables]
when not defined(geneWasm):
  import std/dynlib
import ./types
import ./reader
import ./printer

type
  DocPageRef* = object
    id*, kind*, parent*, title*, summary*: string
    size*: int

  DocNameRow* = object
    spelling*, id*, kind*, introducedIn*: string
    canonical*: bool

  DocHit* = object
    id*, title*, summary*: string

  ScoredId = tuple[score: int, id: string]

  DocsCorpus* = object
    root*: string
    pages*: seq[DocPageRef]
    names*: seq[DocNameRow]
    byId*: Table[string, int]
    byName*: Table[string, int]

const
  ftsLimit = 20
  # A binary built from a checkout knows that checkout's corpus, the way it
  # knows the generator's path. `$docs` describes the binary that is running.
  docsCorpusAtBuild = parentDir(parentDir(parentDir(currentSourcePath()))) /
    "build" / "docs"


# ---------------------------------------------------------------------------
# Corpus location

proc isCorpusDir(dir: string): bool =
  fileExists(dir / "manifest.gene") and dirExists(dir / "md")

proc corpusDirOf(candidate: string): string =
  if candidate.len == 0:
    return ""
  let direct = normalizedPath(absolutePath(candidate))
  if isCorpusDir(direct):
    return direct
  let built = direct / "build" / "docs"
  if isCorpusDir(built):
    return built
  ""

proc findCorpus*(override = ""): string =
  ## `--corpus` / `GENE_DOCS_ROOT` may name a package root or a corpus
  ## directory. An explicit override that names no corpus is an error: it
  ## never falls through to another corpus. Otherwise prefer the corpus of
  ## the checkout built beside the binary, then `<prefix>/share/gene/docs`,
  ## then a `build/docs/` above the working directory.
  if override.len > 0:
    return corpusDirOf(override)
  let env = getEnv("GENE_DOCS_ROOT")
  if env.len > 0:
    return corpusDirOf(env)
  let built = corpusDirOf(docsCorpusAtBuild)
  if built.len > 0:
    return built
  let installed = parentDir(getAppDir()) / "share" / "gene" / "docs"
  if isCorpusDir(installed):
    return installed
  var dir = getCurrentDir()
  while true:
    let found = corpusDirOf(dir)
    if found.len > 0:
      return found
    let parent = parentDir(dir)
    if parent.len == 0 or parent == dir:
      break
    dir = parent

proc loadData(path: string): Value =
  let forms = readAll(readFile(path), path)
  if forms.len != 1 or forms[0].kind != vkMap:
    raise newException(ValueError, "invalid documentation data: " & path)
  forms[0]

proc loadCorpus*(root: string): DocsCorpus =
  result.root = root
  let manifest = loadData(root / "manifest.gene")
  let entries = manifest.mapEntries
  if entries.hasKey("pages"):
    for page in entries["pages"].listItems:
      let m = page.mapEntries
      var page = DocPageRef()
      if m.hasKey("id"): page.id = m["id"].strVal
      if m.hasKey("kind"): page.kind = m["kind"].strVal
      if m.hasKey("parent"): page.parent = m["parent"].strVal
      if m.hasKey("title"): page.title = m["title"].strVal
      if m.hasKey("summary"): page.summary = m["summary"].strVal
      if m.hasKey("size"): page.size = int(m["size"].intVal)
      result.byId[page.id] = result.pages.len
      result.pages.add page
  let namesPath = root / "names.gene"
  if fileExists(namesPath):
    let names = loadData(namesPath)
    let nentries = names.mapEntries
    if nentries.hasKey("names"):
      for row in nentries["names"].listItems:
        let m = row.mapEntries
        var name = DocNameRow()
        if m.hasKey("spelling"): name.spelling = m["spelling"].strVal
        if m.hasKey("id"): name.id = m["id"].strVal
        if m.hasKey("kind"): name.kind = m["kind"].strVal
        if m.hasKey("introduced_in"): name.introducedIn = m["introduced_in"].strVal
        if m.hasKey("canonical"): name.canonical = m["canonical"].boolVal
        result.byName[name.spelling] = result.names.len
        result.names.add name

# ---------------------------------------------------------------------------
# Names and nearest matches

proc nameVariants(name: string): seq[string] =
  result = @[name]
  if name.startsWith("$"):
    result.add name[1 .. ^1]
  if name.startsWith("gene/"):
    result.add name[5 .. ^1]
    result.add "$" & name[5 .. ^1]
  else:
    result.add "gene/" & name
    result.add "$" & name

proc pageIdFor*(corpus: DocsCorpus, query: string): string =
  if corpus.byId.hasKey(query):
    return query
  for variant in nameVariants(query):
    if corpus.byName.hasKey(variant):
      let row = corpus.names[corpus.byName[variant]]
      if row.id.len > 0 and corpus.byId.hasKey(row.id):
        return row.id

proc editDistance(a, b: string): int =
  var previous = newSeq[int](b.len + 1)
  for j in 0 .. b.len:
    previous[j] = j
  for i in 1 .. a.len:
    var current = newSeq[int](b.len + 1)
    current[0] = i
    for j in 1 .. b.len:
      let cost = if a[i - 1] == b[j - 1]: 0 else: 1
      current[j] = min(min(current[j - 1] + 1, previous[j] + 1),
                       previous[j - 1] + cost)
    previous = current
  previous[b.len]

proc nearestIds*(corpus: DocsCorpus, query: string, limit = 5): seq[string] =
  ## Always returns something when the corpus has pages: the closest ids.
  var scored: seq[ScoredId]
  let q = query.toLowerAscii
  for page in corpus.pages:
    if page.kind == "entry" or page.kind == "namespace" or
        page.kind == "chapter" or page.kind == "section":
      let id = page.id
      let tail = id.rsplit('/', 1)[^1]
      let score = min(editDistance(q, tail.toLowerAscii),
                      editDistance(q, id.toLowerAscii))
      scored.add((score, id))
  algorithm.sort(scored)
  for item in scored:
    if result.len >= limit: break
    result.add item.id

proc showText*(corpus: DocsCorpus, query: string): string =
  let id = corpus.pageIdFor(query)
  if id.len > 0:
    let path = corpus.root / "md" / (id & ".md")
    if fileExists(path):
      return readFile(path)
  let nearest = corpus.nearestIds(query)
  if nearest.len == 0:
    return "no documentation in " & corpus.root & " matches '" & query & "'\n"
  result = "no page for '" & query & "'. Nearest ids:\n"
  for item in nearest:
    result.add "  " & item & "\n"

proc childrenOf*(corpus: DocsCorpus, id: string): seq[DocPageRef] =
  for page in corpus.pages:
    if id.len == 0:
      if page.parent.len == 0 or
          (page.kind == "namespace" and page.parent == "lib") or
          (page.kind == "namespace" and page.parent == "lib/gene"):
        result.add page
    elif page.parent == id:
      result.add page

proc lsText*(corpus: DocsCorpus, id: string): string =
  let children = corpus.childrenOf(id)
  if children.len == 0:
    if corpus.byId.hasKey(id):
      return id & " has no children\n"
    let nearest = corpus.nearestIds(id)
    result = "no page for '" & id & "'. Nearest ids:\n"
    for item in nearest:
      result.add "  " & item & "\n"
    return
  for page in children:
    result.add page.id
    result.add "  "
    result.add $page.size
    result.add " B  "
    result.add page.title
    if page.summary.len > 0:
      result.add " — " & page.summary
    result.add "\n"

proc indexText*(corpus: DocsCorpus): string =
  readFile(corpus.root / "llms.txt")

# ---------------------------------------------------------------------------
# Full-text search

when not defined(geneWasm):
  type
    SqliteApi = object
      lib: LibHandle
      open: proc(filename: cstring, db: ptr pointer): cint {.cdecl.}
      close: proc(db: pointer): cint {.cdecl.}
      prepare: proc(db: pointer, sql: cstring, n: cint,
                    stmt: ptr pointer, tail: ptr cstring): cint {.cdecl.}
      bindText: proc(stmt: pointer, index: cint, text: cstring, n: cint,
                     destructor: pointer): cint {.cdecl.}
      step: proc(stmt: pointer): cint {.cdecl.}
      columnText: proc(stmt: pointer, index: cint): cstring {.cdecl.}
      finalize: proc(stmt: pointer): cint {.cdecl.}
      errmsg: proc(db: pointer): cstring {.cdecl.}

  var sqlite: SqliteApi
  var sqliteTried = false

  proc sqliteLibName(): seq[string] =
    when defined(macosx):
      @["libsqlite3.dylib", "/usr/lib/libsqlite3.dylib"]
    elif defined(windows):
      @["sqlite3.dll"]
    else:
      @["libsqlite3.so.0", "libsqlite3.so"]

  proc loadSqlite(): bool =
    if sqliteTried:
      return sqlite.lib != nil
    sqliteTried = true
    for name in sqliteLibName():
      let lib = loadLib(name)
      if lib != nil:
        template sym(field: untyped, name: string): untyped =
          field = cast[typeof(field)](symAddr(lib, name))
        sqlite.open = cast[typeof(sqlite.open)](symAddr(lib, "sqlite3_open"))
        sqlite.close = cast[typeof(sqlite.close)](symAddr(lib, "sqlite3_close"))
        sqlite.prepare = cast[typeof(sqlite.prepare)](symAddr(lib, "sqlite3_prepare_v2"))
        sqlite.bindText = cast[typeof(sqlite.bindText)](symAddr(lib, "sqlite3_bind_text"))
        sqlite.step = cast[typeof(sqlite.step)](symAddr(lib, "sqlite3_step"))
        sqlite.columnText = cast[typeof(sqlite.columnText)](symAddr(lib, "sqlite3_column_text"))
        sqlite.finalize = cast[typeof(sqlite.finalize)](symAddr(lib, "sqlite3_finalize"))
        sqlite.errmsg = cast[typeof(sqlite.errmsg)](symAddr(lib, "sqlite3_errmsg"))
        if sqlite.open != nil and sqlite.prepare != nil and
            sqlite.step != nil and sqlite.columnText != nil:
          sqlite.lib = lib
          return true
        unloadLib(lib)
    false

  proc searchDocs*(corpus: DocsCorpus, text: string):
      tuple[hits: seq[DocHit], error: string] =
    if not loadSqlite():
      return (@[], "SQLite could not be loaded; search is unavailable")
    let dbPath = corpus.root / "gene-docs.sqlite"
    if not fileExists(dbPath):
      return (@[], "search database is missing: " & dbPath &
        "; run `gene doc build`")
    var db: pointer
    if sqlite.open(dbPath.cstring, addr db) != 0:
      return (@[], "could not open the search database: " & dbPath)
    defer: discard sqlite.close(db)
    let sql = "select id, title, summary from search where search match ? " &
              "order by rank limit " & $ftsLimit
    var stmt: pointer
    if sqlite.prepare(db, sql.cstring, -1, addr stmt, nil) != 0:
      let detail = sqlite.errmsg(db)
      return (@[], "search query failed: " &
        (if detail == nil: "sqlite could not prepare the query" else: $detail))
    defer: discard sqlite.finalize(stmt)
    let quoted = "\"" & text.replace("\"", "\"\"") & "\""
    discard sqlite.bindText(stmt, 1, quoted.cstring, -1, cast[pointer](-1))
    var code = sqlite.step(stmt)
    while code == 100:
      var hit: DocHit
      let id = sqlite.columnText(stmt, 0)
      let title = sqlite.columnText(stmt, 1)
      let summary = sqlite.columnText(stmt, 2)
      if id != nil: hit.id = $id
      if title != nil: hit.title = $title
      if summary != nil: hit.summary = $summary
      result.hits.add hit
      code = sqlite.step(stmt)
    if code != 101:
      let detail = sqlite.errmsg(db)
      return (@[], "search query failed: " &
        (if detail == nil: "sqlite step failed" else: $detail))

else:
  proc searchDocs*(corpus: DocsCorpus, text: string):
      tuple[hits: seq[DocHit], error: string] =
    (@[], "search is unavailable in the wasm profile")

proc searchText*(corpus: DocsCorpus, text: string): string =
  let (hits, error) = searchDocs(corpus, text)
  if error.len > 0:
    return "Error: " & error & "\n"
  if hits.len == 0:
    return "no pages match '" & text & "'\n"
  for hit in hits:
    result.add hit.id & "  " & hit.title
    if hit.summary.len > 0:
      result.add " — " & hit.summary
    result.add "\n"

# ---------------------------------------------------------------------------
# Values for `$docs`

proc pageValue(page: DocPageRef): Value =
  var props = initPropTable()
  props["id"] = newStr(page.id)
  props["kind"] = newStr(page.kind)
  props["title"] = newStr(page.title)
  props["summary"] = newStr(page.summary)
  props["size"] = newInt(page.size.int64)
  newMap(props)

proc hitValue(hit: DocHit): Value =
  var props = initPropTable()
  props["id"] = newStr(hit.id)
  props["title"] = newStr(hit.title)
  props["summary"] = newStr(hit.summary)
  newMap(props)

proc spellingsForValue*(value: Value): seq[string] =
  ## The names a runtime value can be addressed by.
  case value.kind
  of vkString: result.add value.strVal
  of vkSymbol: result.add value.symVal
  of vkNativeFn: result.add value.nativeFnName
  of vkFunction:
    if value.fnName.len > 0: result.add value.fnName
  of vkType:
    if value.typeName.len > 0: result.add value.typeName
  of vkProtocol:
    if value.protocolName.len > 0: result.add value.protocolName
  of vkProtocolMessage:
    if value.protocolMessageName.len > 0:
      result.add value.protocolMessageName
  else:
    discard

proc docsIndexValue*(corpus: DocsCorpus): Value = newStr(corpus.indexText())
proc docsShowValue*(corpus: DocsCorpus, query: string): Value =
  newStr(corpus.showText(query))

proc docsLsValue*(corpus: DocsCorpus, id: string): Value =
  var items: seq[Value]
  for page in corpus.childrenOf(id):
    items.add pageValue(page)
  newList(items)

proc docsHitsValue*(hits: seq[DocHit]): Value =
  var items: seq[Value]
  for hit in hits:
    items.add hitValue(hit)
  newList(items)

proc docsPageByValue*(corpus: DocsCorpus, value: Value): Value =
  ## `$docs/show` with a runtime value: the first spelling that names a page.
  for spelling in spellingsForValue(value):
    let id = corpus.pageIdFor(spelling)
    if id.len > 0:
      return newStr(corpus.showText(id))
  newStr("no documentation for " & print(value))
