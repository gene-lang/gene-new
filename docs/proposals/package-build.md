# Package build steps, native dependencies, and distribution packages

Status: design proposal. Not implemented.

Extends `package.md` (Stages 1-3 implemented). Unblocks the build integration
deferred there on 2026-07-28, and the `gene build --target native` gap in
`native-type.md`.

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

`package.md` §13 requires that manifests are parsed as data and never executed,
and rejects install-time execution as "the `postinstall` failure mode." That
rule is about **resolution**, which happens implicitly and transitively on every
import, before any trust decision. This proposal does not weaken it.

Installation is a different phase, and the current design does not have one:

| Phase | When | May execute? |
|---|---|---|
| **Resolve** | every import, transitively, implicitly | **No.** Manifest is data. §13 unchanged. |
| **Install** | once, explicitly, per package version and platform | Yes — declarative build steps only (§3) |
| **Load** | import | module initialization only |

The distinction that matters is *implicit and transitive* versus *explicit and
one-time*. Resolution must stay inert because a package can be dragged into it
without anyone choosing that package. Installation is a named act on a named
package, and it is where the cost of producing an artifact belongs.

---

## 3. A build step is declared, not scripted

**Idempotence forces this, before any security argument does.**

A step is idempotent only if the system can decide it has already run. That
requires knowing the step's complete inputs. A shell command's inputs are
unknowable — it may read any file, any environment variable, the network, the
clock. There is no fingerprint that means "this command's result is still
valid," so a shell step can only ever be re-run blindly or skipped blindly.

A declared step has exactly known inputs, so it can be keyed (§5), skipped when
current, and cached across machines as a distribution (§6). The safety property
— that installing a package cannot run arbitrary code — falls out of the same
decision rather than being bolted on.

Initial step vocabulary, kept deliberately small:

```gene
(c_library "sqlite_shim"
  ^sources ["native/shim.c"]
  ^include ["native/include"]
  ^defines {^GENE_SQLITE_SHIM 1}
  ^uses ["sqlite3"])          # a ^native_dependencies entry

(web_module "client"
  ^entry "src/client.gene")   # gene build --target web
```

`c_library` and `web_module` cover the two artifact kinds that exist today. A
step kind is added only when something needs it, and each one has to be
fingerprintable to qualify.

**No shell escape hatch in v1.** If a package genuinely cannot express its build
declaratively, the answer is to ship a distribution (§6) built by its author,
not to hand every consumer a shell. Revisit only with evidence.

---

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
| `^build` | no | `[]` | Declared build steps, run at install |
| `^platform` | no | `nil` | Set only on a distribution package (§6) |

`^native_dependencies` names a library and how to find it; it never contains a
path to a specific machine's filesystem in a published package. `^pkg_config`
is the portable form. Explicit `^headers`/`^link` exist for libraries without a
pkg-config file and are expected to be rare.

A missing native dependency is an **install-time** error naming the library, the
package that wants it, and the pkg-config query that failed — not a link error
in the middle of a C build.

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
rebuild and nothing else.

**The build key** is the hash of everything the step's output depends on:

- the step declaration, canonically printed;
- the contents of every input file it names;
- the resolved native dependencies (name and version, as discovered);
- the toolchain identity;
- the target triple.

A step whose key directory exists with a valid `stamp.gene` is a **no-op**. That
is what makes automatic invocation on install safe to repeat, and it is why
`gene pkg install` on an already-installed package does no work rather than
rebuilding.

The key changes when any input changes, so a stale artifact is never reused —
the failure mode that makes hand-rolled build scripts untrustworthy.

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
`x86_64-linux-musl`. The triple is part of the build key, so a distribution can
never be materialized for the wrong platform.

Because `^build_key` is carried, a consumer can verify that a distribution
corresponds to the source it claims — the same key the consumer would have
computed building locally.

---

## 7. `gene pkg install`

```console
$ gene pkg install
acme/sqlite 0.1.0   distribution aarch64-macos   verified
acme/imaging 2.1.0  building c_library "resize"  3.2s
gene/utils 0.1.0    no build steps
```

- Idempotent by §5: a second run reports and does nothing.
- Runs for the application package and its dependency graph.
- `--offline` refuses to fetch a distribution and builds from source.
- `--rebuild` ignores existing keys, for diagnosing a stale-artifact suspicion.

Building is reported per package with its duration, because a silent multi-second
install is how build steps become invisible.

---

## 8. Non-goals for the first version

- **Cross-compilation.** Build for the host triple only. Producing distributions
  for other platforms is the publisher's problem, solved with real machines or
  CI, not with a cross-toolchain contract invented here.
- **A shell step** (§3).
- **Publishing distributions.** This proposal defines what a distribution *is*
  and how it is consumed. How one is uploaded, signed, and discovered belongs
  with `distribution.md` and the registry work.
- **Dependency-graph link ordering.** One package's steps see that package's own
  native dependencies. Transitive native linking is a real problem and is
  deferred until something needs it.

---

## 9. Stages

1. **`^native_dependencies` + discovery.** Manifest schema, pkg-config probe,
   install-time diagnostics. No build steps yet — this alone replaces the
   hardcoded paths in `examples/native/build.sh`.
2. **`c_library` steps and build keys.** `build/<target>/<key>/`, `stamp.gene`,
   idempotent re-run. `gene pkg install` gains its build phase.
   `examples/native` drops its shell script.
3. **`web_module` steps.** Folds `gene build --target web` into the same
   mechanism, so `examples/new_world/build.sh` becomes a manifest.
4. **Distribution packages.** `^platform`, `^provides`, hash verification,
   preference order.

Stages 1-2 are what `native-type.md` was waiting for. Stage 3 is a
simplification with no new concepts. Stage 4 is what makes a toolchain optional.

---

## 10. Open questions

- **Toolchain identity in the build key.** `cc --version` is unstable across
  distro rebuilds that do not change codegen, which would cause spurious
  rebuilds; a coarser identity risks reusing an artifact across a toolchain
  change that mattered. Leaning toward compiler name plus major version, and
  accepting occasional over-caching in exchange for stability.
- **Where a pkg-config result enters the key.** Recording the resolved version
  is right; recording the resolved *paths* would make a key machine-specific and
  defeat distribution matching.
- **Whether `build/` belongs in the package root or a store.** Root is simpler
  and keeps a package self-contained; a store would deduplicate identical keys
  across packages. Root first.
- **What a distribution is allowed to contain.** Restricting `^provides` to
  artifacts a declared step could have produced keeps a distribution verifiable
  against its source. Allowing anything makes it an opaque binary drop.
