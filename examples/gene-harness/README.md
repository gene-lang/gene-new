# gene-harness

A living plugin harness: seams, an effect ledger, and atomic activation.

```bash
gene run examples/gene-harness/src/main.gene
gene run --allow_read_dir /tmp examples/gene-harness/src/main.gene
```

Run it both ways. The only line that changes is the one where the local
filesystem provider is asked to do its job — which is the point.

The design and the argument behind it are in [`docs/design.md`](docs/design.md),
which also compares this to DeepSeek's `dsh` and says which of its ideas are
worth taking.

## What it is

A plugin architecture written as a subsystem — `Plugin` and `Harness` are types,
not a mapping onto packages and scoped impls. Those distribute and compile code;
this is about what happens at runtime.

| File | Role |
|---|---|
| `src/kernel.gene` | The kernel: lifecycle, the effect ledger, seam binding, replacement |
| `src/seams.gene` | One seam, all three roles: a protocol with an authority contract, two providers, a consumer |
| `src/main.gene` | A runnable tour; every line it prints is a claimed property |
| `plugins/fs_stub/` | An out-of-tree plugin loaded at runtime, granted nothing |
| `plugins/fs_rogue/` | The same, but reaching for `$fs` — kept honest by being run |
| `docs/design.md` | Why it is shaped this way, and what is still missing |

## The three ideas

**A plugin is a value.** An id, the seams it claims, and two entry points — not a
module. So it can come from a runtime-loaded file, a package dependency, or a
literal built in memory for a test.

**The kernel owns an effect ledger.** Plugins never touch the tables; they
contribute through `provide`, and every contribution is recorded against the
plugin id. The ledger holds *records*, not disposer closures, which makes "what
has this plugin registered?" a query and the ledger serializable.

**Activation is all-or-nothing.** A plugin that fails part-way through `activate`
leaves nothing behind, because the kernel knows what it registered and reverses
it without the plugin's cooperation. A plugin cannot forget to clean up, because
cleanup was never its job.

Binding is explicit: a seam already bound is refused rather than shadowed, so no
registration order decides behaviour. Changing a provider is `replace` — a named
operation an operator asked for, not a layer that wins by arriving later. The
ledger entry moves with the binding, so uninstalling a seam's former owner
cannot unbind a seam it no longer provides.

**A seam is a protocol, and the protocol carries the authority contract.** This
is the part TypeScript cannot copy. `HarnessFs` declares
`^capabilities [(fs/ReadDir "/tmp")]` once; a provider may restate it or declare
less, and the compiler rejects an impl that declares more — or that declares
nothing, since an absent row means unchecked authority. So a provider is bounded
by the interface it implements rather than by its own good manners, and the
in-memory test double advertises `^capabilities []` where a reviewer can see it.

The consumer names only the protocol. Swapping the provider therefore changes
what the consumer does *and* what authority the whole product needs, without the
consumer being touched — which is why the two commands above differ on exactly
one line.

**A plugin can arrive at runtime, bounded by grants.** `install_sandboxed` loads
a module from outside `src/` with `$runtime/load_sandboxed`. `grants` is the
operator-readable statement of reach — `[]` means the code cannot name `$fs`,
`$net`, or `$os` at all — and `shared` names the one file holding the seam
protocol, so the plugin implements *this* `HarnessFs` rather than a recompiled
copy of it. The same binding rules apply to code that arrived late: a bound seam
is refused, not shadowed.

`plugins/fs_rogue/` exists to keep that claim honest, and running it corrected
it. The boundary holds — the file is never read — but the plugin *loads* and
fails at the first call with `value is not callable: vkVoid`, because a denied
namespace is absent and the name fails where it is used. Timing and diagnostic,
recorded in [`docs/design.md`](docs/design.md) §5.

## Not done yet

The seam *table* is still keyed by a plain string, so the kernel does not check
that a value bound to `"HarnessFs"` actually implements `HarnessFs`. The
contract holds anyway — it is enforced at the impl and at the call — but a
mis-bound seam fails at first use rather than at `provide`.

Model-visible ⟺ logged (`docs/design.md` §3.6) is designed and not built; a
system recomposable at 3am needs replay more than a static one, not less.

Runtime plugin install via `$runtime/load_sandboxed` is designed and not built.

Module unload is deferred: uninstall removes a plugin's contributions, and its
code stays resident (`docs/scoped-impls.md` §6).
