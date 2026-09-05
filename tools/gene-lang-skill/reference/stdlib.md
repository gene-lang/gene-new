# Standard library inventory

Dumped from the live global scope of the built binary, not from prose. Two
surfaces reach it: the `$` sigil (`$x` is sugar for `gene/x`) and messages on
the receiving type.

`docs/stdlib.md` is a *plan* document and describes modules that may not exist —
trust this file and a probe over it. Regenerate after stdlib changes:

```console
$ nim c --path:src -o:/tmp/dump_globals tools/gene-lang-skill/scripts/dump_globals.nim
$ /tmp/dump_globals
```

## Root functions

Reached bare-with-`$`: `($println x)`, `($size xs)`.

```text
$ != * + - / // < <= == > >= not panic same?
absent? nil? present? void? empty? leaf? contains? size first last
head props body meta declarations construct_type
map filter take into to_stream to_pairs_stream
freeze freeze_shallow thaw assoc_in update_in key range
to_str to_sym to_int to_float hash chars graphemes
cell atomic_cell channel buffer bytes Set set_has? set_size Regex
date datetime time duration timezone now today sleep
read_all read_one lex_all print println
capabilities_of capability_type_info check_capabilities
```

Arithmetic is prefix, and **`//` is remainder, not floor division**: `(/ 7 2)`
is `3` (Int division truncates, `(/ 7.0 2)` is `3.5`) while `(// 7 2)` is `1`.

`map`, `filter`, `take`, and `into` operate on a **Stream** — open one with
`to_stream`.

## Root types

Bare, no sigil, because annotations resolve names structurally.

```text
Nil Void Bool Int Float Str Sym Char List Map Node Range
I8 I16 I32 I64 U8 U16 U32 U64 F32 F64 Buffer
Cell AtomicCell Channel Task TaskOutcome Actor ReplyTo Stream
Date DateTime Time Timezone Duration
Env CallerEnv Module Namespace Call SyntaxCall Match Token
Capability TryNext TryRecv FsChange FsWatcher
SandboxGeneration SandboxTransaction
```

`Any` (gradual top) and `Never` (bottom) resolve in **annotation position only** —
they are not bound values, so `($println Any)` is an undefined symbol. Sets are
built by the `Set` function (`(Set 1 2)`) and read with `$set_size` / `$set_has?`.

Error types: `Error` (protocol) plus `TypeError` `MessageError` `CallKindError`
`MatchError` `ParseError` `LexError` `CompileError` `SelectorMissing`
`ChannelClosed` `ActorError` `ActorClosed` `ActorFailure` `ReplyAlreadySent`
`OsError` `HttpError` `HttpClientError` `JsonError` `SerdeError` `DbError`
`StoreError` `UrlError` `TerminalError` `CursesError` `RefError`
`RuntimeLaneError` `WatcherClosed` and the
capability errors (`MissingCapability`, `AmbiguousCapability`,
`CapabilityError`, `CapabilityScopeError`, `CapabilityTypeError`,
`UnknownCapabilityType`, `UnsupportedCapability`).

Root protocols: `Callable` `CapabilitySpec` `Error` `Send` `SerdeRef` `ToStr`.

## Namespaces

| Namespace | Functions | Types / sub-namespaces |
|---|---|---|
| `$fs` | `exists?` `list_dir` `make_dir` `read_bytes` `read_text` `read_text_async` `real_path` `remove` `watch` `write_bytes` `write_text` `write_text_async` `write_text_atomic` | `FsChange` `FsWatcher` `WatcherClosed`; `ReadDir` `ReadFile` `ReadWriteDir` `WriteDir` `WriteFile` (capabilities) |
| `$str` | `byte_size` `contains?` `ends_with?` `from_utf8` `join` `lower` `slice_bytes` `split` `starts_with?` `to_utf8` `trim` | — |
| `$stream` | `each` `filter` `into` `map` `take` `to_pairs_stream` `to_stream` | — |
| `$math` | `abs` `acos` `asin` `atan` `atan2` `ceil` `clamp` `cos` `exp` `floor` `hypot` `log` `log10` `log2` `max` `min` `pow` `round` `sign` `sin` `sqrt` `tan` `trunc` | `e` `pi` `tau` |
| `$bit` | `and` `not` `or` `shl` `shr` `xor` | — |
| `$json` | `parse` `stringify` | `JsonError` |
| `$regex` | `find_all` `match` `replace` `replace_all` `split` | — |
| `$parse` | `parse_int` `read_all` | `ParseError` |
| `$node` | `body` `declarations` `head` `meta` `props` | — |
| `$binary` | `concat` `from_list` `from_str` `get` `get_f32` `get_f64` `get_i32` `get_u16` `get_u32` `put_f32` `put_f64` `put_i32` `put_u16` `put_u32` `put_u8` `size` `slice` `to_buffer` `to_list` `to_str` | — |
| `$os` | `begin_interrupt` `close_input` `end_interrupt` `env?` `exec` `exec_async` `exec_stdio` `exec_stdio_async` `exec_stream` `exec_stream_async` `executable_path` `get_env` `launch_dir` `monotonic_ms` `process_id` `read_input` `read_line` `refresh_input` `stdin_tty?` `take_interrupt` | `Env` `Exec` `OsError` `Process` `Pty` |
| `$actor` | `continue` `spawn` `stop` | — |
| `$log` | `child` `debug` `emit` `enabled?` `error` `info` `new_file_logger` `new_logger` `trace` `warn` `with` | `LogLevel` `Logger` |
| `$crypto` | `random_hex` `secure_equal?` `sha256` | `Random` |
| `$url` | `decode_component` `encode_component` `format_query` `parse_query` | `UrlError` |
| `$html` | `attr_escape` `escape` `render` | — |
| `$css` | `class_name` `css` `decl_value` `frame` `keyframes` `media` `render` `rule` `scoped` | — |
| `$web` | `asset_base` `script` `set_asset_base` `set_source_maps` `stylesheet` | — |
| `$net/http` | `actor_pool` `bytes` `html` `json` `listen` `not_found` `redirect` `route` `serve` `status` `stop` `supervisor_policy` `text` `ws_accept` `ws_close` `ws_send` | `HttpError` `Request` `RequestMsg` `Response` `Server` |
| `$net/http_client` | `request` `stream` | `Http` `HttpClientError` |
| `$net` | `tcp_read_text_async` `tcp_write_text_async` | `Connect` `Listen` |
| `$db/sqlite`, `$db/postgres` | `open` | `SqliteDb` `PostgresDb` `Db` `DbError` |
| `$store/fs`, `$store/sqlite` | `open` | `FsStore` `SqliteStore` `Store` `StoreError` |
| `$serde` | `data?` `read` `read_data` `write` `write_data` | `SerdeError` `SerdePolicy` `SerdeRef` |
| `$terminal` | `capture_text` `close` `focus` `key` `mouse` `next_update` `open` `paste` `pump` `request_stop` `resize` `signal` `snapshot` `stop` `write` | `Session` `TerminalError` |
| `$curses` | `close` `dimensions` `draw` `escape_pressed?` `next_event` `open` `read_input` `refresh_input` | `Screen` `CursesError` |
| `$repl` | `close` `discard_pending` `eval_guard_begin` `eval_guard_end` `eval_source` `open` `run` | `Session` |
| `$ffi` | `bind` `open` | `Callable` `Library` `Load` |
| `$aot` | `load` | — |
| `$device` | `buffer` | `Buffer` `Compute` |
| `$runtime` | `bind_call` `callable?` `configure_module` `gc_stats` `guard_call` `load_sandboxed` `require_root_lane` `sandbox_transaction` | `RuntimeLaneError` `SandboxGeneration` `SandboxTransaction` |
| `$C` | — | C ABI type constructors for FFI (`Int`, `Ptr`, `CStr`, `Slice`, …) |

`$fs` calls require a capability grant — see `reference/declarations.md`.

## Type message surfaces

Sent bare on the receiver: `xs/.size`, `(xs .push v)`.

| Type | Messages |
|---|---|
| `List` | `assoc` `set` `push` `size` `empty?` `first` `last` `contains?` `to_stream` |
| `Map` | `assoc` `get` `put` `delete` `to_stream` `to_pairs_stream` |
| `Node` | `set_prop` `set_body` `push_body` `head` `props` `body` `meta` |
| `Stream` | `has_next` `peek` `next` `try_next` `close` `map` `filter` `take` `into` `each` `to_pairs_stream` |
| `Buffer` | `len` `get` `set` `fill` `copy_from` `to_list` `to_bytes` `elem_type` |
| `Cell` | `get` `set` `swap` `update` |
| `AtomicCell` | `load` `store` `swap` `compare_exchange` |
| `Channel` | `send` `try_send` `recv` `try_recv` `close` |
| `Task` | `cancel` `detach` `join` |
| `FsWatcher` | `recv` `close` |
| `SandboxTransaction` | `prepare` `commit` `discard` |
| `SandboxGeneration` | `module` `graph` `release` |
| `Actor` | `send` `try_send` `ask` `snapshot` `upgrade` |
| `ReplyTo` | `send` |
| `Range` | `start` `stop` `step` `inclusive?` `size` |
| `Date` | `year` `month` `day` |
| `Time` | `hour` `minute` `second` `microsecond` `offset` `timezone` |
| `DateTime` | `year` `month` `day` `hour` `minute` `second` `microsecond` `offset` `timezone` |
| `Timezone` | `offset` `name` |
| `Duration` | `microseconds` `milliseconds` `seconds` |
| `Namespace` | `bindings` `lookup` `declarations` |
| `Module` | `root_namespace` `name` `path` `meta` `declarations` |
| `Env` | `extend` |
| `CallerEnv` | `snapshot` |
| `Capability` | `name` |

`Str` carries no messages of its own — string work goes through `$str/*`,
`$chars`, and `$graphemes`. `$size` is a *collection* function and rejects a
string, so length is `($str/byte_size s)` for bytes or `($size ($chars s))` for
code points.

Where a name appears both as a root function and a message (`size`, `empty?`,
`first`, `last`, `contains?`, `to_stream`), they are the *same* function value,
so `($size xs)` and `xs/.size` are interchangeable.
