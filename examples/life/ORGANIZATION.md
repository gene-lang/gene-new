# Saved code and cognitive organization

Code revisions are immutable. Saving a revision does not select it. Every cycle
retains the organization ID and selected code references used for its context;
execution resolves that exact organization.

`code.save(name, quoted_expression)` retains a function expression or other
ordinary Gene expression. `code.load(revision)` evaluates it in a fresh scope.
Its lexical locals are not a persistence mechanism.

`code.save_module(name, files, ^entry "main.gene")` retains a map of relative
`.gene` paths to source strings. The revision identifies the entry and complete
file bundle, including imported dependencies. Absolute paths and traversal are
rejected. `code.load` on such a revision returns an ordinary module namespace:

```gene
(do
  (let revision
    (code .save_module "garden/helpers"
      {^main.gene "(mod helpers) (import [double] ^from \"./math\") (fn answer [x] (+ (double x) 1))"
       ^math.gene "(mod math) (fn double [x] (* x 2))"}))
  (let library (code .load revision))
  (library/answer 20))
```

The normal module loader compiles declarations, types, methods, and imports.
Preparation and calls carry execution limits. Module initialization has no
standard-library namespace grants. Applications pass the supported API objects
to exported functions explicitly.

## Organization definitions

A definition has a unique `id`, generic `roots`, immutable `code` references,
and `documentation` describing its layout and access functions. Optional
`module` identifies a saved module exporting `bind(api) -> Map`. Its returned
entries replace or extend the starter execution bindings. It may define
ordinary nominal types in its module and return instances from `bind`.
Construction should be pure; data access belongs in the resulting methods.

With `context: true`, the same module also exports `context(api, basis) -> Map`.
It receives its selected bindings and the starter experience view. Its returned
map is the exact context passed to the brain and ensuing program. The builder
runs with read-only application operations over one immutable read view.
The host retains the input basis, returned context, event identities, code
references, and immutable revisions of records it read. The result is limited
to 64 KiB.

With `attention: true`, the module exports `attention(api, basis) -> List`, which
selects event IDs from that basis before context construction. Duplicate or
unavailable IDs are rejected. Unselected events remain unconsidered and durable.
They are revisited when fresh observations or explicit wakes arrive, or when a
new organization is selected. A quiet heartbeat does not repeatedly reconsider
the same deferred observations. Returning an empty list defers thought without
a model call. The final view and exact selected/deferred event references are
retained independently in the cycle record.

With `ownership: true`, the module exports `ownership(api, basis) -> List` of
generic `{^id ... ^generation ...}` tokens. `life.inspect_owner(id)` reads an
owner without modifying it. The policy chooses which dependencies matter; the
host records and checks those declared tokens before inference admission,
execution, and operations. Retiring an unrelated owner does not invalidate the
decision. Changing a declared owner invalidates stale work and supplies a
non-waking error observation for bounded reconsideration. This metadata remains
separate from the brain's chosen intention and commitment layouts.

For example, `body/visitor_memory.gene` exports a new `memory`, a new `state`,
and a context builder. The host has no `visitor`, `energy`, or commitment-layout
field. These remain ordinary stored Gene data interpreted by the selected code.

## Atomic selection

```gene
(code .select
  {^id "visitors@2"
   ^module revision
   ^code [revision]
   ^roots ["mind/"]
   ^context true
   ^documentation "Visitor document and a shared working document."}
  ^migration (quote
    (do
      (let preference (store .get "state/preference" ^tx input/tx))
      (store .put "mind/visitor"
        {^preference preference ^source "retained visitor observation"}
        ^tx input/tx)
      (let migrated (store .get "mind/visitor" ^tx input/tx))
      ($assert (== preference migrated/preference))
      {^before preference ^after migrated/preference}))
  ^queued "invalidate")
```

The return value is a selection request ID. Inspect `selection/<id>` to distinguish
requested, migrating, selected, deferred, failed, or interrupted states. A request
from the current program takes effect only after that program settles; migration
therefore reads its latest committed writes.

Migration runs against the stable API, independently of the old organization.
It uses `input/tx` for every participating read/write. It may inspect generic
records and immutable revisions, but cannot send messages, start jobs, enqueue
one-shot schedules, open nested groups, or publish its own transaction. It may stage routine
registrations and retire old ones in the selection transaction. Its serializable return
value is retained as comparison evidence. Candidate module preparation must
succeed before migration begins. A failed or interrupted migration publishes no
staged data. Successful publication selects code, roots, queued-work dispositions,
and migration writes in one durable commit.

Queued-work policy is explicit:

| Policy | Behavior |
| --- | --- |
| `defer` (default) | Defer selection if affected work lacks a disposition. |
| `invalidate` | Preserve work, provenance, ownership and checkpoints; invalidate execution and request reconsideration. |
| `compatible` | Reassign admitted work to the new organization while retaining its original organization; the definition must explicitly list the old ID in `compatible`. |

A still-valid in-flight response finishes under the old organization first.
`^invalidate_inflight true` instead invalidates its authority. Its later output
is retained as a diagnostic and cannot perform effects. A fresh cycle uses the
new organization. Running foreground effects settle before selection, and local
movement pauses at its committed checkpoint while selection is pending.

## Operator repair

The local command adapter accepts `save-module` with `name`, `files` and optional
`entry`, and `select` with `definition`, optional migration source string,
`queued`, and `invalidate_inflight`. These operations do not invoke cognitive
code to inspect or prepare the repair.

Pause the body before repairing a broken context organization. Submit the
`select` command with `recovery: true` to authorize that migration while paused.
The body remains paused afterward. Use a new organization ID and choose code
compatible with the latest retained records. Repair never restores an older
database snapshot or discards newer memories and conversations. Raw records remain
available through the `inspect` operator command.

The process tests kill the host during staging, immediately before selection
commit, and immediately after commit. A fresh process restores either the complete
old code/data selection or the complete new one, before asking the brain anything.
