# gene-harness

A living plugin harness: seams, an effect ledger, and atomic activation.

```bash
gene run examples/gene-harness/src/main.gene
```

The design and the argument behind it are in [`docs/design.md`](docs/design.md),
which also compares this to DeepSeek's `dsh` and says which of its ideas are
worth taking.

## What it is

A plugin architecture written as a subsystem — `Plugin` and `Harness` are types,
not a mapping onto packages and scoped impls. Those distribute and compile code;
this is about what happens at runtime.

| File | Role |
|---|---|
| `src/kernel.gene` | The kernel: lifecycle, the effect ledger, seam binding |
| `src/main.gene` | A runnable tour; every line it prints is a claimed property |
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
registration order decides behaviour.

## Not done yet

Seams here are plain string keys holding plain values. `docs/design.md` §3.2
describes the version that matters — a seam as a *protocol* whose `^capabilities`
row bounds every provider, so a plugin cannot exceed the interface it implements
regardless of what its own module holds. That property is verified in the design
doc and is the reason to build this; wiring it into the kernel is the next step.

Module unload is deferred: uninstall removes a plugin's contributions, and its
code stays resident (`docs/scoped-impls.md` §6).
