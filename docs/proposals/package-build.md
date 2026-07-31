# Package build steps, native dependencies, and distribution packages

Status: design proposal. Not implemented.

Extends `package.md` (Stages 1-3 implemented) and `native-type.md`. Unblocks
the build integration `native-type.md` deferred on 2026-07-28 — the missing
`gene build` that produces a linked native artifact. (`native-type.md` spells
the existing backend `gene compile --target c`; a `gene build` with a native
target is what this proposal defines.)

---

## 1. Goal

Three things are missing, and they are one problem:

- **A package cannot declare a native library it links against.** `package.md`
  models Gene dependencies only — there is no way to say "this needs sqlite3,
  its headers are here, link it like this."
- **A package cannot produce a build artifact.** `examples/native/build.sh`
  drives `cc` by hand. `native-type.md` deferred build integration explicitly
  because "both answers come from the dependency graph," and that graph did not
  model native libraries. It still does not.
- **A package cannot ship prebuilt.** Every consumer must have a C toolchain
  and rebuild from source, on every machine.

---

## 2. Phases

`package.md` §13 requires data-only manifest parsing — manifests are parsed,
never executed as code — and §6 names install-time execution as "the
`postinstall` failure mode." That rule is about **resolution**, which happens
implicitly and transitively on every
import, before any trust decision. This proposal does not weaken it.

Producing an artifact is a different phase, and the current design does not
have one:

| Phase | When | May execute? |
|---|---|---|
| **Resolve** | every import, transitively, implicitly | **No.** Manifest is data. §13 unchanged. |
| **Build** | once, explicitly, per package version and platform (§7) | Yes — declarative build steps only (§3) |
| **Load** | import | module initialization only |

The distinction that matters is *implicit and transitive* versus *explicit and
one-time*. Resolution must stay inert because a package can be dragged into it
without anyone choosing that package. A build is a named act on a named package,
and it is where the cost of producing an artifact belongs.

---

## 3. Steps declare their inputs; some steps are commands

**Idempotence needs known inputs, not a restricted vocabulary.**

A step can be skipped only if the system can decide it has already run, which
requires knowing everything its output depends on. The tempting conclusion is
that steps must therefore be declarative and a shell escape hatch is impossible.
That is wrong, and Cargo shows why: `build.rs` is arbitrary Rust, and it is
still incremental, because the script emits `cargo:rerun-if-changed=PATH` and
thereby **declares its own inputs**.

So the axis is not declarative-versus-shell. It is *who declares the inputs*.
A command whose inputs and outputs are declared is exactly as fingerprintable
as a built-in step, and the developer carries the obligation the declaration
implies.

Two kinds of step, sharing one keying rule:

**Built-in steps** know their own inputs, because the runtime performs them:

```gene
(c_library "sqlite_shim"
  ^sources ["native/shim.c"]
  ^include ["native/include"]
  ^defines {^GENE_SQLITE_SHIM 1}
  ^uses ["sqlite3"])          # a ^native_dependencies entry

(web_module "client"
  ^entry "src/client.gene")   # gene build --target web
```

**Command steps** run a program, and must declare what they read and write:

```gene
(command "atlas"
  ^run ["node" "tools/gen_atlas.mjs"]
  ^inputs ["tools/gen_atlas.mjs"]
  ^outputs ["assets/tiles.png" "assets/tiles_preview.png"])
```

- `^run` is an argv vector, never a shell string: no word splitting, no glob
  expansion, no `$VAR` interpolation, no `&&`. A shell is available by asking
  for one explicitly (`^run ["sh" "-c" "…"]`), which makes that choice visible
  in review rather than implicit in every step.
- `^inputs` is required and may be empty only if the command genuinely depends
  on nothing in the package. It is what the key hashes.
- `^outputs` is required. It is what gets moved into the keyed build directory,
  and what a distribution can carry.
- The command runs with the package root as its working directory and a
  **minimal environment** — `PATH`, `HOME`, and anything the step names in
  `^env` — so that an unrelated variable in a developer's shell cannot change
  the result without changing the key.

**The developer owns idempotence, and the runtime checks the part it can.**
After a command step runs, every path in `^outputs` must exist or the step
fails. Under `--verify-steps` the step is run a second time into a scratch
directory and the outputs compared, which turns "I believe this is idempotent"
into something CI can answer. That check is opt-in because it doubles build
time; it is the mechanism a package author uses before publishing, not
something every consumer pays for.

What the runtime cannot check is a command that reads an undeclared input — a
file outside `^inputs`, a network resource, the clock. Such a step will be
skipped when it should have run, and the symptom is a stale artifact. This is
the same contract Cargo's `rerun-if-changed` has, with the same failure mode,
and it is the price of the escape hatch being genuinely useful.

## 4. Manifest additions

```gene
{
  ^name "acme/sqlite"
  ^version "0.1.0"

  # External native libraries this package links against. Discovery is the
  # host's job — pkg-config where available, explicit paths otherwise.
  ^native_dependencies [
    (native "sqlite3" ^pkg_config "sqlite3" ^min_version "3.40")
    (native "z" ^link ["-lz"])
  ]

  ^build [
    (c_library "sqlite_shim"
      ^sources ["native/shim.c"]
      ^uses ["sqlite3"])
  ]
}
```

| Field | Required | Default | Meaning |
|---|---:|---|---|
| `^native_dependencies` | no | `[]` | External native libraries, by name |
| `^build` | no | `[]` | Build steps — built-in or `command` (§3) |
| `^platform` | no | `nil` | Set only on a distribution package (§6) |

`^native_dependencies` names a library and how to find it; it never contains a
path to a specific machine's filesystem in a published package. `^pkg_config`
is the portable form. Explicit `^headers`/`^link` exist for libraries without a
pkg-config file and are expected to be rare.

A missing native dependency is an **install-time** error naming the library, the
package that wants it, and the pkg-config query that failed — not a link error
in the middle of a C build.

`^native_dependencies` is a build-time declaration: it resolves headers and link
flags for `c_library` steps. It is not the runtime `^library` reference an
`ffi/fn` declaration uses to open a shared object (`native-type.md` §6.3.1); the
two stay separate, and nothing here unifies them.

---

## 5. The build directory and build keys

Build outputs live under the package root, never mixed with source:

```text
acme/sqlite/
├── package.gene
├── src/
├── native/shim.c
└── build/
    └── aarch64-macos/
        └── 9f3a2c7e…/
            ├── stamp.gene           # inputs this was built from
            └── libsqlite_shim.dylib
```

`build/` is generated, gitignored, and safe to delete: deleting it costs a
rebuild and nothing else. It is also the only place a step may write. A
`command` step declares `^outputs` as paths relative to the package root
because that is where the command naturally puts them, and the runtime moves
them into the keyed directory afterwards — so a command cannot leave the
package dirty, and two targets cannot overwrite each other.

There are two keys, because the local rebuild decision and cross-machine
distribution matching answer different questions.

**The source key** is the hash of everything the step's output depends on that
is reproducible from the same inputs on any machine:

- the step declaration, canonically printed;
- the contents of every input file it names — for an entry-based step such as
  `web_module`, the transitive closure of modules the entry imports; for a
  `command` step, exactly the paths in `^inputs`, which is where the developer's
  obligation from §3 lands;
- the values of any environment variables the step names in `^env`;
- the resolved native dependencies (name and version, as discovered);
- the target triple.

The toolchain identity is deliberately **not** part of the source key: it
differs between publisher and consumer, so including it would break the
cross-machine verification in §6. It belongs to the **local build key** — the
source key plus the toolchain identity — which names
`build/<target>/<key>/` directories and is what a rebuild no-op checks. A
toolchain change therefore forces a local rebuild while a distribution still
matches on the stable source key.

A step whose local-key directory exists with a valid `stamp.gene` is a
**no-op**. That is what makes automatic invocation on install safe to repeat,
and it is why `gene pkg build` on an already-built package does no work
rather than rebuilding.

The local key changes when any input changes, including the toolchain, so a
stale artifact is never reused — the failure mode that makes hand-rolled build
scripts untrustworthy.

---

## 6. Source packages and distribution packages

A distribution is not a new concept. **It is a `build/<target>/<key>/` directory
that someone else produced**, shipped so the consumer does not have to.

| | Source package | Distribution package |
|---|---|---|
| `^platform` | absent | set, e.g. `"aarch64-macos"` |
| Contains | sources, `^build` steps | prebuilt artifacts + `stamp.gene` |
| Install does | run steps (§3), keyed (§5) | verify hashes, materialize into `build/` |
| Needs a toolchain | yes | no |

```gene
{
  ^name "acme/sqlite"
  ^version "0.1.0"
  ^platform "aarch64-macos"
  ^build_key "9f3a2c7e…"       # the source build this reproduces
  ^provides [
    (c_library "sqlite_shim" ^file "libsqlite_shim.dylib" ^sha256 "…")
  ]
}
```

**Install preference order**, per package:

1. an already-valid `build/<target>/<key>/` — no work;
2. a distribution matching the host target — fetch, verify every `^sha256`,
   materialize;
3. the source package's `^build` steps — build locally;
4. no `^build` — nothing to do.

Falling back from (2) to (3) is expected and normal: a platform with no
published distribution still works if a toolchain is present. A platform with
neither is an install-time error that says which of the two is missing.

**Target triples** are `<arch>-<os>`: `aarch64-macos`, `x86_64-linux`,
`x86_64-windows`. Linux libc variance (`gnu` vs `musl`) is a real distinction
that changes ABI compatibility, so it is part of the triple where it applies:
`x86_64-linux-musl`. The triple is part of the source key, so a distribution can
never be materialized for the wrong platform.

Because `^build_key` is carried, a consumer can verify that a distribution
corresponds to the source it claims — it is the source key §5, which any
consumer can recompute from the same inputs without needing a matching
toolchain.

---

## 7. Command surface

The verbs follow Cargo, because the model is the same one: a package with
declared inputs, a keyed output directory, and a build that is a no-op when
nothing changed.

| Command | Does | Status |
|---|---|---|
| `gene pkg build` | run the application package's steps and its dependencies' | v1 |
| `gene pkg clean` | delete `build/`, or one target under it | v1 |
| `gene pkg install <dir>` | copy a package into a store **and build it** | v1, extends the existing command |
| `gene pkg release` | optimized build, then emit a distribution package (§6) | later |

**`install` keeps its current meaning and gains a build.** `gene pkg install
<dir> [--user|--app]` already ships as "copy a package into a store," and that
is the same sense Cargo uses — `cargo install` makes something available beyond
the current project. Installing therefore runs the package's build steps as
part of making it usable, which is what "the build step should be invoked when
a package is installed" asks for. Because steps are keyed (§5), installing an
already-built package does no work.

`gene pkg build` is a separate verb rather than a zero-argument `install`
because it operates on the *current* application and its graph, not on a
package being brought in from elsewhere. Distinguishing two operations by
argument count would be overloading one word with two meanings.

**`clean` deletes only generated output.** `build/` is the sole location a step
may write into the package (§5), so `clean` is `rm -rf build/` and cannot touch
source. `gene pkg clean --target aarch64-macos` drops one target's outputs;
`--older-than <duration>` drops stale keys while keeping current ones, since a
long-lived checkout accumulates a directory per input change.

**`release` is deferred but shapes v1.** A release build is not a different
build — it is the same steps at a different optimization level, plus emitting
§6's `^platform`/`^provides` manifest. The only thing v1 must get right for it
is that the optimization level is part of the source key, so a debug artifact
can never be mistaken for a release one.

```console
$ gene pkg build
acme/sqlite 0.1.0    distribution aarch64-macos   verified
acme/imaging 2.1.0   c_library "resize"           3.2s
gene/new_world 0.1.0 command "atlas"              0.4s
                     web_module "world"           1.1s
gene/utils 0.1.0     no build steps

$ gene pkg build
5 packages, nothing to do
```

- `--offline` refuses to fetch a distribution and builds from source.
- `--rebuild` ignores existing keys, for diagnosing a stale-artifact suspicion.
- `--verify-steps` re-runs each command step and compares outputs (§3).

Building is reported per package per step with its duration, because a silent
multi-second build is how steps become invisible. A build that does nothing
says so in one line.

## 8. Non-goals for the first version

- **Cross-compilation.** Build for the host triple only. Producing distributions
  for other platforms is the publisher's problem, solved with real machines or
  CI, not with a cross-toolchain contract invented here.
- **Publishing distributions.** This proposal defines what a distribution *is*
  and how it is consumed. How one is uploaded, signed, and discovered belongs
  with the registry work. `distribution.md` is a different kind of distribution
  — application images and standalone executables, not package-catalog prebuilts
  — so the two documents use the word for different things and the registry
  design should not conflate them.
- **Dependency-graph link ordering.** One package's steps see that package's own
  native dependencies. Transitive native linking is a real problem and is
  deferred until something needs it.

---

## 9. Stages

1. **`^native_dependencies` + discovery.** Manifest schema, pkg-config probe,
   install-time diagnostics. No build steps yet — this alone replaces the
   hardcoded paths in `examples/native/build.sh`.
2. **`c_library` steps and build keys.** `build/<target>/<key>/`, `stamp.gene`,
   idempotent re-run. `gene pkg build` lands.
   `examples/native` drops its shell script.
3. **`web_module` and `command` steps.** Folds `gene build --target web` into
   the same mechanism, and gives command steps their input declaration,
   sandboxed environment, and output check. `examples/new_world/build.sh`
   becomes a manifest in full — four `web_module` steps, plus `command` steps
   for the atlas generator and the `gene run` that prints `index.html` — which
   is the test of whether the vocabulary is real.
4. **Distribution packages and `release`.** `^platform`, `^provides`, hash
   verification, preference order, and the optimized build that produces one.

Stages 1-2 are what `native-type.md` was waiting for. Stage 3 is a
simplification with no new concepts. Stage 4 is what makes a toolchain optional.

---

## 10. Open questions

- **Toolchain identity in the *local* key.** §5 keeps it out of the source key;
  how coarse to make it is still open. `cc --version` is unstable across distro
  rebuilds that do not change codegen, which would cause spurious rebuilds; a
  coarser identity risks reusing an artifact across a toolchain change that
  mattered. Leaning toward compiler name plus major version, and accepting
  occasional over-caching in exchange for stability.
- **How far to sandbox a command step.** A minimal environment and an argv
  vector (§3) stop accidental non-determinism, not a deliberate escape. Whether
  to go further — a working-directory jail, no network — is a real question, and
  the answer probably differs between a package you wrote and one you installed.
- **Whether `--verify-steps` should be required before publishing.** It is the
  only mechanism that turns a claimed idempotence into a checked one, and a
  distribution built from a non-idempotent step is exactly the artifact nobody
  can reproduce.
- **Where a pkg-config result enters the key.** Recording the resolved version
  is right; recording the resolved *paths* would make a key machine-specific and
  defeat distribution matching.
- **Whether `build/` belongs in the package root or a store.** Root is simpler
  and keeps a package self-contained; a store would deduplicate identical keys
  across packages. Root first.
- **What a distribution is allowed to contain.** Restricting `^provides` to
  artifacts a declared step could have produced keeps a distribution verifiable
  against its source. Allowing anything makes it an opaque binary drop.
