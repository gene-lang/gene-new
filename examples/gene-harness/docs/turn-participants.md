# Turn participant transaction contract

This defines the transaction boundary for batch 5 of the architecture review.
The production loop uses the transaction for delegation and card progress.
Public registration followed qualification of those two internal consumers.
Broader qualification is in progress. These are harness application contracts;
Gene syntax is unchanged. The separate batch 4 commit is `14fb61b7`.

## Transaction boundary

The coordinator acquires one composition lease for a turn. It captures the
ordered participant rows and extension schemas from that lease once. Initiator
policy has its own admission lease, and its result is persisted in the receipt.
A turn phase never looks up a newer generation. Ordering uses explicit
priority and a stable participant name; cleanup reverses successful acquisition
order. The ordinary optional-hook dispatcher is not used.

The transaction is an ordered protocol over durable subsystems, not a claim of
cross-store ACID rollback. Files already patched, recorded model calls, admitted
image-provider attempts and previously committed child receipts cannot be
rolled back. Each subsystem retains its existing journal and recovery rules.

## Phases

1. `begin` acquires per-turn participant state. Register a participant for
   cleanup before entering it, so partial acquisition can unwind.
2. `request_items` supplies additional input before request rendering. The
   coordinator keeps the input provenance and receiving-turn records.
3. `request_admitted` records durable correlation immediately before the model
   call. Delegation uses this for its existing request-source checkpoint.
4. `bindings` supplies the participant's response context. Internal adapters
   can install existing card/delegation bindings. Public participants supply
   inert, namespaced data; they cannot overwrite `Outcome`, core helpers or
   another participant's bindings. Callable capabilities continue to use the
   supervised functions registry and narrow host services.
5. `response_recorded` acknowledges inputs only after response/history records
   are flushed. Delegation's existing before/after acknowledgment crash points
   remain at this boundary.
6. `validate_outcome` runs alongside unconditional core validation. It may
   reject its own fields or defer completion while owned work remains. It may
   not make an invalid base Outcome valid or suppress core records.
7. `commit` admits staged feature work only after evaluation and validation.
   Each participant is entered once. A later failure does not rerun an earlier
   commit; durable receipts determine recovery.
8. `finalize` attempts durable boundary work for every acquired participant,
   including after invalid Outcome, exception, cancellation or panic. Card
   progress uses this phase. A failed finalizer does not skip the other
   finalizers or the coordinator's terminal record.
9. `release` attempts every acquired participant in reverse order, on success,
   invalid Outcome, exception, cancellation or panic. It receives the observed
   completion state, including whether `turn/end` is durable. Delegation must
   keep children fenced until that durable boundary. Cleanup errors are
   recorded and surfaced even if other cleanup succeeds.

The internal finisher always orders feature finalization, the core-only
terminal-record callback, then release. Release receives `turn_end_durable`;
it must not dispatch fenced work when terminal recording failed. A release
failure after a durable terminal record makes the round fail with a separate
diagnostic; it cannot rewrite or duplicate the terminal record.

The in-memory phase journal marks entry before invocation. A lost result or
thrown callback never causes another invocation. A process restart
reconciles subsystem receipts rather than replaying arbitrary plugin phases.

When the round is already at its ceiling and no model turn will run, a separate
`limit` boundary checks existing owned work under one live workspace lease.
It does not allocate another turn, run response phases or invent a terminal
record. Only participants declaring that boundary are selected, and their
acquired state is still released. This preserves delegation's existing
collection/parking behavior without a feature branch in the model loop.

Published phase callables require an exact live coordinator frame, including
the selected participant, phase, context and private state. That frame admits
one invocation and expires after the callback joins. Reading a callable through
registry introspection does not admit another phase or extend its lifetime.

## Failure and compatibility rules

A mandatory callback error, timeout or panic aborts the round. It does not
become an optional-hook warning or another model iteration. Expected rejection
of model-authored field data is a typed validation result; it produces the
existing repair request without admitting that turn's staged child work.

A stored plugin's unexpected participant failure also quarantines that owner's
participant callbacks for later turns. The failing turn still fails with its
participant and phase, and all acquired cleanup slots are attempted. Quarantine
survives restart. The next round receives a `[N.plugins]` explanation and can
reach the model to repair the source. The plugin's functions, providers and other
capabilities remain available, so recovery does not remove the model provider
or the functions needed to repair it. A successful republish, explicit re-enable,
restore or reversion retries the participants. A late failure from a replaced
generation cannot quarantine its replacement. Operator cancellation does not
quarantine a healthy participant.

Native host participants remain mandatory and are never automatically excluded.
This containment changes future selection only; it never replays a failed phase
or treats a partial turn as successful. The plugin catalog reports participant
quarantine separately from activation state.

An invalid Outcome discards new delegation staging. Already admitted external
effects retain their receipts. Card progress still flushes at the turn boundary
and image-attempt cleanup still records interrupted work. A commit failure is
reported as a failure with its participant and phase, with no automatic retry.
Every allocated turn has an unambiguous terminal record, and cleanup failures
must not be presented as an ordinary successful round.

Existing model-visible `audio_reply`, `wait`, `result` and `wake_on_questions`
remain accepted during this additive batch. Their eventual retirement follows
batch 6's interface policy. New fields use `Outcome ^extensions {...}` with
owned, schema-checked keys; no unvalidated property bag is accepted.

## Ownership

An extension key has exactly one contributor and schema. Claiming another
owner's namespace, duplicating a key or shadowing a core field fails
registration. Schemas and callbacks use the contributor's budget and activation
generation. Returned public data is immutable; participant-private state is
never passed to a different participant.

Initiator kinds are owned rows with matching/validation policy and explicit
operator-versus-automated behavior. The round controller keeps admission,
sequence handling, cancellation and durable round identity. Slack's existing
initiator spelling remains readable, including continuations and old receipts.

## Public registration

Require the registries used by a plugin, for example
`^requires [{^registry "turn_participants"} {^registry "outcome_extensions"}]`.
Contribute through the ordinary PluginHost API. Every name is `OWNER/NAME`;
`OWNER` is the contributing plugin's id. Duplicates and namespace claims for
another owner fail registration. Host aliases, record annotations and the
round-limit boundary are reserved to native adapters.

All participant callbacks take `[context state value]`. `state` is a mutable
map private to that participant for this turn, including partial acquisition.
`context` is immutable data: `workspace_root`, `session_id`, `round_id`, `turn`,
`round_turn`, `turn_limit`, `composition_revision`, `collection` and `boundary`.
It contains no runtime, manager, snapshot object or round/turn cells.

| Phase | Return contract |
| --- | --- |
| `begin`, `request_admitted`, `response_recorded`, `finalize`, `release` | Return value ignored; raised errors remain mandatory failures. |
| `request_items` | Nil or up to 64 items `{^id "local_id" ^value "text"}`. Optional `source` and boolean `settled` are supported. The host assigns owned ids, headers and source namespaces. |
| `bindings` | Nil or a map of inert data. For participant `notes/memory`, it is available in response code as `notes/memory/...`. Host helpers and selected functions cannot be overwritten. |
| `validate_outcome` | Nil or `{^error TEXT ^request_items [...] ^defer_done BOOL}`, with each field optional. A rejection becomes a model repair request. Deferral needs nonempty owned request context. |
| `commit` | Nil or request items. Commits run in order; later participants observe changes to the result's completion status made by earlier commits. |

Result-oriented callbacks receive immutable projections with `kind`, `error`,
`outcome`, `questions`, `request_items` and `media`. The outcome projection has
`done`, `reply`, `attention`, presence flags
and checked `extensions`. Use `value/kind == "done"` for final-only writes;
another participant may have deferred the requested completion already.
Release receives `{^result ... ^turn_end_durable BOOL ^errors [...]}`. Error
summaries contain data, without exception objects or journal internals.

Data may contain inert scalars, lists and string/symbol-keyed maps, up to 32
levels. Functions, cells, services and other live values are rejected. Public
callbacks retain their contributing activation and effective callback budget;
stored descriptor limits and callback limits are distinct, as described in
[the plugin contract](plugins.md#provider-and-callback-budgets).

## Checked Outcome fields

An Outcome schema takes `[context value]` and returns exactly one of
`{^value NORMALIZED_DATA}` or `{^error "reason"}`. It is a pure validation
operation; durable work belongs in the transaction's journal/commit phases.
An optional textual `warning` can accompany accepted data. Context and input
data are immutable. A schema rejection repairs model input; an exception,
panic or budget failure aborts the round and does not replay the schema.

```gene
(host .PluginHost:contribute "outcome_extensions"
  {^name "notes/facts"
   ^schema (fn [context value]
     (if (!= ($head value) List)
       (return {^error "facts must be a list"}))
     {^value value})})
```

After registering that field, the model may return:

```gene
(Outcome ^^done ^reply "Saved." ^extensions {^notes/facts ["A preference."]})
```

The participant's commit callback can persist it with PluginHost state or an
owned durable receipt. Omitted fields require no write. Plugins should explain
their optional fields in their prompt/docs contributions so the model knows
when to supply them. Unknown keys, malformed containers and unvalidated bags
are refused. Checked extension data survives optional audio normalization.

For example, inside the same plugin activation:

```gene
(host .PluginHost:contribute "turn_participants"
  {^name "notes/memory"
   ^commit (fn [context state value]
     (let facts (value/outcome/extensions .get "notes/facts"))
     (if (&& (== value/kind "done") (! ($absent? facts)))
       (host .PluginHost:update_state {^facts facts}))
     nil)})
```

State writes default to the workspace; pass `^session context/session_id` for
session state. The explicit nil honors the commit return contract. A plugin
doing external work keeps its own durable intent/result receipt rather than
relying on replay of this callback after a crash.

The host currently owns `voice/audio_reply`, `delegation/wait`,
`delegation/result` and `delegation/wake_on_questions`. Their older top-level
spellings remain accepted under the compatibility interval. Supplying both a
canonical field and its older spelling in one Outcome is rejected.

## Initiator policies

The `initiators` registry owns route validation and operator-versus-automated
policy. A row declares `name`, `prefix`, `kind`, boolean `operator` and a
`normalize [context input]` callback. `exact` selects an exact spelling instead
of a prefix. Public kinds are `channel` and `plugin`; their names and prefixes
belong to the contributor. Channel rows also declare their owned `transport`.
Overlapping routes are rejected rather than resolved by activation order.

The channel host keeps producer authorization, queues and delivery. Its Slack
adapter registers `slack/channel` independently of transport activation so
already queued work retains its validation path. The round controller uses the
selected row and stores `initiator_kind` and `operator` in the admitted receipt.
An existing round retains that policy through source disable/replacement;
claimed continuations retain their already-admitted plugin metadata. Old
receipts without explicit policy use the historical reader.

## Implementation and qualification order

Delegation migrated first, followed by card bindings/progress. Both passed the
new internal interface and production integration checks before public
participant and extension registration was enabled.

Qualification covers phase ordering, one leased selection through replacement,
mandatory failure at each phase, invalid Outcome staging, partial begin,
commit/result loss without replay, cancellation/panic cleanup, owned-schema
collisions and initiator validation. Existing delegation recovery, cards,
images, questions, pause/continuation and core model-record fixtures remain
acceptance boundaries. The turn-limit fixture now asserts an operator pause,
durably retained input and an explicit continuation rather than a synthetic
final limit reply.
