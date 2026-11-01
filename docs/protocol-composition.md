# Composing protocols across modules

How to let independent modules supply types and behavior to a generic container
without the container naming either. The executable reference is
[`examples/protocol-message-exp`](../examples/protocol-message-exp/README.md); its
[findings](../examples/protocol-message-exp/reports/findings.md) hold the measurements.
Precise rules live in the [protocol contract](spec/protocols.md) and
[calls](spec/calls.md).

## Who may supply an impl

| Route | Where the impl lives | Needs at the use site | Recurses into third-party types? |
| --- | --- | --- | --- |
| Canonical, operation owner | the module that declares the protocol | nothing | only types it can import |
| Canonical, type owner | the module that declares the type | nothing | yes, it is global |
| Scoped, exported | any other module, marked `^^export` | a root `import_impl` per pair | only through an operation the **root** authored |
| Dedicated policy protocol | the policy module owns its own protocol | nothing; pass the protocol's message | as canonical, type modules must name each policy |

A canonical impl applies application-wide, so a scoped policy for the same pair cannot
coexist with it; give the policy its own protocol instead.

## Root-authored operations

A body-authored `child/.Render:render` resolves in the body's module, so a generic container
never sees impls that only the application imported. Author the operation at the composition
root and thread it through the contract:

```gene
# contracts: decide the threaded parameter before the container is frozen
(protocol Render (message render [visit] : Str))

# the container: no knowledge of child types or providers
(impl Render for Section ^^export
  (message render [visit] : Str
    (var out self/title)
    (for child in self/children (set out ($to_str out " / " (visit child visit))))
    out))

# composition root: its imports select the policy for every node
(import_impl Render for Section ^from "./policies/plain")
(import_impl Render for Figure ^from "./policies/plain")
(fn operation [] Render:render)

# generic consumers import no impls
(fn preview [operation document] (operation document operation))
```

The held `Render:render` keeps the root's scope at every node, through Callable views,
closures and Paths, and across module reload. Costs to plan for: the threaded parameter (the
experiment calls it `each`) and its propagation, one `import_impl` per (protocol, type, root), and a held call being
resolved on every application (roughly 7x a cached qualified send; see the findings).

An operation whose body calls a second protocol needs that selection carried too. Pass a
record authored at one root (`{^render Render:render ^mark Mark:mark}`), or a nominal record
with `(Callable ...)` fields to fail at construction rather than during traversal.

## Placement

A module's impls are final once it has loaded, so `import_impl` is a declaration of the
module: write it directly at module level, with the module's other imports and before any
statement that runs code. A function, lambda, `message`, `ctor`, `spawn` body, block,
conditional, `ns` body or macro expansion cannot hold one, and neither can a position after a
`let`, `var`, call or other code. Both mistakes are compile-time errors that say what to do.
To use another policy for a call, pass the operation from the composition root instead of
importing a different pair there. A relative `^from` resolves against the module that wrote it.

## Checking a root before traversal

A held message resolves in its authored scope, so a declared sample set can be checked
without running any body:

```gene
(fn unsupported [operation samples]
  (var missing [])
  (for sample in samples
    (try ($runtime/signature operation sample)
      catch Any (missing .push ($to_str sample))))
  missing)
```
