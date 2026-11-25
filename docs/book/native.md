# Native code, builds, and deployment

This chapter builds and installs applications, calls C libraries, and runs
code you do not trust.

## Building a package

`gene build` builds a target that a package's manifest declares, such as an
application:

```sh
gene build hello
# Built acme/hello:hello -> .gene/build/dev/…/gene_application-hello
gene build --all --profile release --jobs 4
```

- The build snapshots the package's sources and reuses earlier artifacts
  when nothing they depend on has changed.
- `--locked` keeps the resolved dependency graph, `--offline` never fetches
  missing sources, and `--explain` says why each step ran or was reused.
- `gene run --snapshot file.gene` runs a package from the same captured
  sources instead of the files being edited, and records what ran.

## Installing an application

On macOS and Linux, a locked application can be installed under a prefix,
with a launcher in its `bin/`:

```sh
gene pkg resolve
gene install hello --prefix "$HOME/.local" --package-root .
"$HOME/.local/bin/hello"
gene uninstall acme/hello:hello --prefix "$HOME/.local"
```

`gene install` uses the lock offline and checks that the copy builds before
switching the launcher to it. An update keeps the earlier copy, and a running
program keeps its own copy until it exits, so uninstalling never pulls code
out from under it. The installed program no longer needs the source checkout.

## Calling C libraries

`$ffi/open` loads a shared library, and `$ffi/bind` binds one of its
functions with its C parameter and result types:

```gene
(let libc ($ffi/open "/usr/lib/libSystem.B.dylib"))
(let abs ($ffi/bind libc "abs" [C/Int] C/Int))
(abs -5)
# 5
```

The `C/…` types (`C/Int`, `C/Double`, `C/CStr`, `C/Ptr`, and the rest)
describe the C signature, and arguments are checked against them on each
call. A module can also declare bindings with `ffi/fn` and name a C struct
with `ffi/struct`:

```gene
(ffi/struct sqlite3_stmt ^fields [])
(type Stmt ^native {^abi sqlite3_stmt ^lifecycle manual})

(ffi/fn sqlite3_step
  ^library libsqlite3
  ^symbol "sqlite3_step"
  [stmt : Stmt] : C/Int)
```

A package can build its own C sources with a `c_library` recipe in its
manifest, and load the result with `$pkg/native_binary` or
`$pkg/native_module`. `gene compile --target c` compiles a typed subset of
Gene to C. It is experimental, and [the native
example](../../examples/native/README.md) shows the whole workflow.

> **Watch out:** native code runs in your process with your permissions.
> Loading a library is trusting it; nothing in Gene can sandbox native code.

## Running code you do not trust

`gene run` and `gene eval` run with the permissions of the user who starts
them, and Gene has no ambient permission system. Code that can name `$fs` or
`$os` can use them, and an `Env` or a namespace filter does not change that.

The sandbox loader is what limits untrusted code. It loads a module from a
directory, and grants it only the effectful namespaces you list:

```gene
(let plugin ($runtime/load_sandboxed "plugins/greeter" "main.gene" [] []))
(plugin/shout "hi")
# "HI"
(plugin/peek)
# fails: cannot call $fs/read_text: gene/fs is not defined here
```

- The third argument lists granted namespaces, such as `["fs" "net"]`. Pure
  libraries, such as `$str` and `$json`, are always available.
- The fourth argument lists modules the plugin may share with the host.
  Nothing else outside its directory is reachable.

To bound memory and time as well, bind the call with an execution policy:

```gene
(let invoke
  ($runtime/bind_call plugin/handle [request]
    ^policy {^max_memory_mb 64 ^timeout_ms 2000}))
(invoke)
```

Running past either limit raises a `LimitExceeded` in the caller.
