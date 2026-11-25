# Input and output

This chapter reads and writes files, works with paths, JSON, and CSV, runs
other programs, reads standard input, and stores data in SQLite.

## Files

`$fs` reads and writes files. Relative paths resolve against the current
directory:

```gene
(import $fs [read_text write_text])
(write_text "greeting.txt" "Hello")
(read_text "greeting.txt")
# "Hello"
```

| Function | What it does |
| --- | --- |
| `read_text`, `write_text` | read or replace a file as UTF-8 text |
| `read_bytes`, `write_bytes` | the same for `Bytes` |
| `write_text_atomic`, `write_bytes_atomic` | write a temporary file and rename it into place, so readers never see a partial file |
| `exists?`, `info` | test for a path, or read its `kind`, `size`, and `mode` |
| `list_dir`, `make_dir`, `remove`, `remove_dir`, `rename` | manage directories and files |

A failure such as a missing file raises an `OsError`, which is an `Error`:
`($fs/read_text "nope.txt")` fails with
`OsError: fs/read_text: cannot open: nope.txt`.

`write_text_atomic` with `^^owner_only` makes the file readable only by its
owner before any content is written, which suits a secret such as a token.

## Paths

`$path` works on path strings without touching the filesystem:

```gene runnable
(import $path [extension join relative])
[(join "reports" "2026" "summary.csv")
 (relative "reports/2026" "reports")
 (extension "summary.csv")]
# ["reports/2026/summary.csv" "2026" ".csv"]
```

`$fs/walk` lists a directory tree as a lazy Stream of records with `path`,
`relative_path`, `kind`, and `size`. Close the Stream if you stop before the
end:

```gene
(let entries ($fs/walk "reports" ^max_depth 2))
(try
  (for entry in entries ($println entry/relative_path))
  ensure (entries .close))
```

## JSON

`$json/parse` reads JSON into Gene values, and `$json/stringify` writes it.
A JSON object becomes a property map, and `null` becomes `nil`:

```gene runnable
(import $json [parse stringify])
(let data (parse "{\"name\":\"Ada\",\"scores\":[3,5]}"))
[data/name data/scores (stringify {^ok true ^missing nil})]
# ["Ada" [3 5] "{\"ok\":true,\"missing\":null}"]
```

Invalid input raises a `JsonError` that names the offset. For input from an
untrusted peer, `(parse text ^^strict ^max_depth 16)` also rejects repeated
keys and invalid UTF-8, and bounds the nesting. `^^omit_nil` on
`stringify` leaves out keys whose value is `nil`.

## CSV

`$csv/parse_rows` reads CSV text. Fields stay strings, and `^^headers` turns
each row into a property map keyed by the header row:

```gene runnable
(import $csv [encode_row parse_rows])
[(parse_rows "name,count\nAda,3\n" ^^headers)
 ($binary/to_str (encode_row ["a,b" "two"]))]
# [[{^name "Ada" ^count "3"}] "\"a,b\",two\r\n"]
```

A malformed row raises a `CsvError` that gives its offset, record, and field.

## Running programs

`$os/exec` runs a program with literal string arguments and returns a map
with `status`, `stdout`, `stderr`, and `timed_out`:

```gene
(let result ($os/exec "git" "log" "--oneline" "-5" ^dir "/work/project"))
(if (== result/status 0) result/stdout else result/stderr)
```

- Arguments are passed as they are, with no shell, so spaces and `*` need no
  quoting. Spread a List with `args...`.
- `^^full` with a single string runs it through the shell, for pipelines
  and redirection: `($os/exec ^^full "printf abc | tr a-z A-Z")`.
- `^dir` sets the program's directory, and `^env` adds or replaces variables
  (`nil` removes one). `^timeout_ms` bounds the run; a timed-out run has
  `status -1` and `timed_out true`.
- A nonzero exit status is data in the result, not an error. A program that
  cannot be started raises an `OsError`, such as
  `os/exec could not start 'nope': No such file or directory`.

`$os/exec_async` takes the same arguments and returns a Task, so other work
continues while the program runs ([Tasks, channels, and
actors](concurrency.md)):

```gene
(let result (await ($os/exec_async "make" "test")))
```

## The environment and standard input

`($os/get_env "HOME" "")` reads an environment variable with a fallback, and
`($os/env? "NAME")` gives `nil` for an unset one. `$os/read_line` reads one
line of standard input, or `nil` at the end:

```gene
(fn main [args]
  (var line ($os/read_line))
  (while ($present? line)
    ($println ($str/upper line))
    (set line ($os/read_line))))
```

```sh
printf 'ada\ngrace\n' | gene run upper.gene
# ADA
# GRACE
```

`$println` writes to standard output and `$eprintln` to standard error
([Printing](values.md#printing)).

## SQLite

`$db/sqlite` opens a database and speaks the `Db` protocol. Pass values as
parameters, never by building SQL strings:

```gene runnable
(import $db/sqlite [Db open])
(let db (open ":memory:"))
(try
  (db .Db:exec "create table people (name text, age int)")
  (db .Db:execute "insert into people(name, age) values (?, ?)" "Ada" 36)
  (db .Db:query "select name, age from people")
  ensure (db .Db:close))
# [{^name "Ada" ^age 36}]
```

- `query` returns a List of property maps.
- `query_one` returns one row or `nil`.
- `execute` runs one statement with parameters.
- `exec` runs SQL text without parameters.

For a long-lived file, `(open_file "app.sqlite" ^^create)` writes only the
pages each commit changes. `open` instead keeps an image of the database and
rewrites the whole file on every commit. `$db/postgres` speaks the same `Db`
protocol.

## Serializing Gene data

`$serde/write_data` writes a Gene value as text, and `$serde/read_data` reads
it back to an equal value:

```gene runnable
(import $serde [read_data write_data])
(let original {^name "Ada" ^scores [3 5]})
[(write_data {^a 1}) (== original (read_data (write_data original)))]
# ["(serde_v1 {^a 1})" true]
```

This covers data, not functions or open resources. For named records that
survive a restart, `$store/fs` keeps them in a directory:

```gene
(import $store/fs [Store open])
(let state (open ^root ".state"))
(try
  (state .Store:put "settings" {^theme "dark"})
  (state .Store:get "settings")
  ensure (state .Store:close))
```
