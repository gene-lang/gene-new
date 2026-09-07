# Capability-context rationale

**Status:** detailed design reference and rationale. The implemented contracts
are [authority](../spec/authority.md).
Deferred sections describe future work. Original chapter numbers are retained
for source comments and older discussions. [Reference index](README.md).

## 14. Ambient capability contexts

MVP has no static `^effects` checker. External authority instead lives in an
immutable runtime capability context created by the host and attenuated at
module, function, protocol-message, and call-site boundaries. Grants are
sealed runtime objects and never Gene values.

Capability names construct inert specifications:

```gene
(fs/ReadDir "config")
(fs/WriteFile "run.log")
```

Effectful APIs use the active context and require the exact operation; no
grant is passed as an ordinary argument:

```gene
($fs/read_text "config/app.gene")
($fs/write_text "run.log" text)
```

Open mode is the compatibility default and inherits its parent's context.
Strict declarations make the contract explicit:

```gene
(fn write_report [filename text]
  ^capabilities [(fs/WriteFile filename)]
  ($fs/write_text filename text))
```

`gene run [--allow_read_dir dir] [--allow_write_dir dir]
[--allow_read_write_dir dir] file [--] [args...]` passes only positional
program arguments to `main`; the pre-entry options mint host grants directly,
while `--grant` is not an authority channel. The entry module may declare an
application ceiling, while embedding hosts construct the root context
directly. `with_capabilities` can attenuate one call or dynamic block.
[The normative implemented authority contract](../spec/authority.md) defines the
layers and boundary rules, including retained-context intersections and current
CLI defaults. [The capability proposal](../capabilities.md) retains
historical rationale and deferred design, not blanket implementation claims.

---
