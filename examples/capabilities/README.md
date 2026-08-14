# Capability examples

Six runnable programs for `docs/proposals/capabilities.md`. Each one shows a
denial as well as a success, because a capability system you only ever see
succeed teaches you nothing about where its edges are.

Build the CLI first:

```bash
nimble build          # produces bin/gene
cd examples/capabilities
```

All commands below assume that working directory, and `G=../../bin/gene`.

---

## The two rules everything else follows from

**1. The launcher's root is the launch directory.** `gene run` grants the
directory you ran it from, plus the nominal host capabilities. Reaching
outside it is denied until `--allow_read_dir` / `--allow_write_dir` /
`--allow_read_write_dir` or an embedding host says otherwise. Confinement is
something someone chooses; it is not a default that silently arrives.

**2. A relative path resolves against the granted directory, not the process
cwd.** Under `(fs/WriteDir "out")`, the path `"private.txt"` means
`out/private.txt`. This is the single most surprising thing here, and it is
why example 3 needs an *absolute* path to demonstrate an escape — a relative
one cannot escape, it just lands inside.

A corollary: **a granted directory must already exist**, because the runtime
opens it as a handle. Examples 4 and 5 ask you to `mkdir -p` first.

---

## 1. Open mode — no capability code at all

A program that attenuates nothing writes nothing.

```bash
$G run 01_open_mode.gene
```

```
written under the launcher's root
```

## 2. The default root, and widening it

```bash
echo "demo payload" > /tmp/gene_cap_demo.txt
$G run 02_outside_root.gene /tmp/gene_cap_demo.txt
```

Denied — `/tmp` is outside the launch directory:

```
Error: MissingCapability: fs/read_text requires fs/ReadFile
  at .../02_outside_root.gene:8:13
     8 |   ($println ($fs/read_text args/0))
       |             ^
```

The same program with the host policy that grants it:

```bash
$G run --allow_read_dir /tmp 02_outside_root.gene /tmp/gene_cap_demo.txt
```

```
demo payload
```

> **Known limitation.** `--allow_*` cannot grant a *symlinked* directory. The
> anchor is opened `O_NOFOLLOW`, so `--allow_read_dir /etc` on macOS (where
> `/etc -> private/etc`) mints a grant that can never be opened and every
> operation reports `filesystem capability root is unavailable`. Pass the
> resolved path (`/private/etc`) instead. This affects macOS `/tmp` and
> `$TMPDIR` too.

## 3. A declared row is checked before the body runs

`save_report` declares `(fs/WriteFile path)` — exactly the file it was handed.
The entry narrows the application to `reports/`.

```bash
$G run 03_declared_function.gene "$PWD/escaped.txt"
```

```
wrote  ok.txt
denied:  /…/escaped.txt  is outside (fs/WriteDir "reports")
```

```bash
find reports -type f     # reports/ok.txt
ls escaped.txt           # No such file
```

The denial happens at the boundary, so the body never ran and nothing partial
was written. Note `"ok.txt"` landed in `reports/ok.txt` — rule 2.

## 4. Narrowing one call with `with_capabilities`

```bash
mkdir -p out/public
$G run 04_with_capabilities.gene
```

```
wrote  private.txt
wrote  inside.txt
denied under with_capabilities: ../private_again.txt
wrote  after.txt
```

```bash
find out -type f
# out/after.txt
# out/private.txt
# out/public/inside.txt
```

The wrapped call is confined to `out/public`; the `..` escape is refused; and
the call *after* the block has the wider authority back. Attenuation is
dynamically scoped and one-directional — it can never widen.

## 5. Bounding a dependency you do not control

`plugin.gene` declares nothing, so it would inherit whatever the entry holds.
The importer bounds it once, at the import, rather than remembering to wrap
every call site:

```gene
(import [write_where] from "./plugin.gene"
  ^capabilities [(fs/WriteDir "plugin")])
```

```bash
mkdir -p out/plugin
$G run 05_import_ceiling.gene
```

```
plugin wrote  allowed.txt
denied: the import ceiling confines the plugin to out/plugin
```

```bash
find out -type f          # out/plugin/allowed.txt — and nothing else
```

A call into the module receives
`caller ∩ module_ceiling ∩ import_ceiling`. The dependency also *initializes*
under the bound, which is what stops it capturing anything at load time that a
later call-site narrowing could not retract.

## 6. Requiring dependencies to carry contracts

```bash
$G run 06_strict_dependencies.gene
```

```
Error: ^require_strict_dependencies: these modules were compiled in open mode
and declare no capability contract: /…/examples/capabilities/open_dep.gene
```

This is a *link* check against interface metadata. It names every offender at
once, and it never recompiles a dependency under a mode its author did not
choose — the open-mode library stays open-mode; the application declines to
depend on it.

---

## Cleaning up

```bash
rm -rf out reports "/tmp/gene_cap_demo.txt"
```

## Where to read more

- `docs/proposals/capabilities.md` §5.1 (host root and `--allow_*`), §5.3.1
  (import-site ceilings), §5.0.2 (`^require_strict_dependencies`), §5.6
  (call-site attenuation), §7.5 (path confinement).
