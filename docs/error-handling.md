# Gradual error checking for Gene

Implemented in the native VM and wasm VM. The transpiled web backend enforces runtime error
contracts and explicitly rejects `warn` and `strict` checking. See the runnable
[error-handling example](../examples/error_handling.gene) for recovery, open
rows, checked callable views, captured errors, and deferred stream failures
under the VM's strict policy.

Gene keeps quick scripts easy to write while allowing application code to
require deliberate error handling. Both use the same error values and execution
model; static checking is an opt-in policy.

The central rule is **catch or declare**: an ordinary error must be handled
by an enclosing `try`, or be permitted to escape by the enclosing function's
error declaration. A declaration delegates handling to callers. It does not
handle an error or convert it to another type.

An unknown error is represented by `Error`. A declaration such as
`^errors [SomeError Error]` identifies `SomeError` as a known possible failure
while permitting other ordinary errors. Callers can recover from `SomeError`
and allow the remaining errors to propagate or terminate the program.

## Runtime failure classification

Use three classifications for failures delivered through ordinary `catch`:
ordinary error, generated type failure, and generated error-contract violation.
Panic and cancellation retain their existing separate control paths. A failure's
classification comes from runtime-controlled provenance, not its nominal type
name or user-writable fields.

| Origin | Static error obligation | Runtime payload and catch behavior | Error-row validation |
| --- | --- | --- | --- |
| Ordinary domain/native error or an otherwise unclassified runtime error | Catch or declare its type; use `Error` when unknown. | Original error value; matching typed catches and `catch Error` apply. | Check each escaping invocation's row. |
| Explicit `fail` of a newly constructed `TypeError` | Catch or declare `TypeError`. | That ordinary TypeError value; typed and Error catches apply. | Check rows normally. |
| Generated argument/result type failure | No ordinary error obligation. | A TypeError value tagged as generated; `catch TypeError` and `catch Error` apply. | Pass through without row validation or relabeling. |
| A declared row or checked callable view rejects an ordinary error | No additional ordinary error obligation for the generated violation. | A generated `ErrorContractViolation` implementing Error; matching typed and Error catches apply. | Outer validators pass the same violation through. |
| Panic | No ordinary error obligation. | Ordinary catches do not run. | Bypass error rows; preserve established cleanup. |
| Cancellation | No ordinary error obligation. | Ordinary catches do not run. | Bypass error rows; preserve established cleanup. |

`ErrorContractViolation` carries a string message, the rejecting function or
view and source location, expected error coverage, actual error type, and the
original typed error as `cause`. It is created once, at the first rejecting
row. Additional callers may contribute trace information but do not wrap or
reclassify an existing generated failure, even if their rows are empty.

For a view declaring `[ConfigError]` whose target raises `NetworkError`:

```text
NetworkError
  -> ErrorContractViolation(cause = original NetworkError)
  -> unchanged through enclosing ^errors [] invocations
```

`catch ConfigError` does not match that violation. `catch ErrorContractViolation`
or `catch Error` does; `$err` holds the violation value and `$err/cause` is the
NetworkError. This preserves catchability of runtime diagnostics while keeping
them outside the ordinary errors promised by a closed contract.

Caught error values retain private failure provenance along with their typed
payload. `(fail $err)`, including through an alias or a captured catch binding,
preserves classification, original cause, and diagnostic origin. Source code
cannot fabricate an exemption by constructing a TypeError or
ErrorContractViolation with matching fields. Constructing and failing a new
value creates an ordinary error, even if it uses one of those nominal types or
stores a generated failure as its cause.

The compiler tracks the ordinary possibilities represented by a caught value
when checking a rethrow. Generated-only provenance contributes no ordinary
error; mixed or imprecise provenance conservatively retains the possible
ordinary types or `Error`. A rethrow does not become an ordinary failure merely
because the source uses `fail`.

Every runtime route, including default evaluation, checked callable views,
tasks, streams, and native error transport, must preserve the classification.
Do not exempt all RuntimeError values or classify TypeError solely by name.
Other runtime/native errors stay ordinary until their origin has an explicit
rule. The same classification and catch behavior apply in every checking mode.

## The catch binding is $err

`catch` binds the original typed error value as `$err`, matching the language's
`Error` terminology. Use `$err_msg` or `$err/.Error:message` for its display
message and `(fail $err)` to re-raise it. Other fields remain accessible on
the same value.

The binding remains local to its recovery branch. A nested catch gets its own
`$err`; the outer binding is available again after the nested branch ends.
Closures created in a recovery branch can capture that branch's binding.

This is a spelling change to the existing catch binding. Compiler-generated
bindings, backend implementations, diagnostics, editor tooling, documentation,
examples, and tests must use the new name.

## Error messages through the protocol

Give the built-in `Error` protocol a `message` method with this default
implementation and an explicit empty ordinary-error row:

```gene
(protocol Error
  (message message [] : Str ^errors []
    self/message))
```

The default reads the receiver's `message` property. `self/message` is a data
lookup, so it does not recursively invoke the method. An ordinary error type
with a `^message Str` property needs only an empty impl to use the default:

```gene
(type InputError ^props {^message Str})
(impl Error for InputError)

(try
  (fail (InputError ^message "Invalid input"))
  catch Error $err/.Error:message)
# "Invalid input"
```

`$err/.Error:message` invokes the Error protocol's message method and returns a
`Str`. Generic recovery, logging, and error reporting use this accessor.
`$err/message` remains a direct property lookup for code that intentionally
depends on a particular error's representation.

An error can compute its message instead of storing a `message` property by
overriding the protocol method:

```gene
(type StatusError ^props {^code Int})
(impl Error for StatusError
  (message message [] : Str ^errors []
    $"Operation failed with status ${self/code}"))

(try
  (fail (StatusError ^code 503))
  catch Error $err/.Error:message)
# "Operation failed with status 503"
```

`Error:message` promises to introduce no ordinary recoverable error. Every
custom implementation must satisfy `^errors []`; an omitted implementation
uses the checked default. This makes a generic handler that returns `$err_msg`
compatible with an empty ordinary-error row. The promise does not imply purity
or termination. Returning the wrong type or violating the row produces a
generated failure under the classification above.

An explicit `impl Error` still establishes conformance. The presence of a
`message` property alone does not make a value an Error. When an impl selects
the default and its type schema is known, reject conformance if the schema
does not guarantee a present string `message` property. This includes a missing,
optional, or non-string property. Types with another representation supply a
custom method instead. Apply this check after choosing inherited/custom bodies,
so overriding the default does not require the property.

For a dynamic or native schema that cannot be proved statically, check the
raw backing property when admitting a value as an Error using the default.
Do not invoke the message method eagerly. If the backing property cannot be
inspected, require a native/custom implementation instead. Invalid backing
data produces a generated TypeError. Keep the normal Str return check on every
method invocation, including after mutation of an admitted value. Migrate
built-in/native errors and propertyless marker-only test types accordingly.

`$err/.Error:message` is a protocol-qualified send. On a raised error it uses
the retained Error conformance described below. An independent type-direct
`message` method may coexist and return different text: qualified Error access
and `$err_msg` use only `Error:message`. No bare accessor or forwarding alias
is proposed; unrelated [message dispatch](../docs/spec/protocols.md) is unchanged.

The message method provides display text; `$err` remains the original typed
error with its other fields and cause. `(fail $err)` re-raises that value,
without converting it to a string or rebuilding it from its message. If a
custom message method itself fails while the runner reports an error, reporting
must retain the original error and fall back to an existing diagnostic or a
basic type label rather than replace it with the formatting failure. The
fallback does not invoke either failure's message method again.

## Error conformance survives scope changes

Retain conformance evidence with a raised error. Scoped Error implementations
remain supported; canonical-only Error conformance is not an MVP restriction.
This preserves local and plugin-defined errors without depending on the
catcher's implementation imports.

At `fail`, or the first admission of a native failure, resolve the built-in
Error protocol in the raising scope and retain the selected implementation,
its bound Self/default or custom message body, and its declaration environment.
This is an Error conformance witness. Missing or ambiguous conformance produces
a generated admission TypeError; an invalid value is not admitted as an
ordinary error. Runtime-generated failures have built-in witnesses.

A native task producer must pass its producing scope when it supplies a typed
payload that has not yet been admitted. An already-admitted error can be
transferred without selecting another scope. Message-only failures become
ordinary RuntimeError values and still undergo deferred-row checking, including
when exposed through `Task/join`.

The witness and failure classification travel with the logical caught error
value. `$err` still exposes its original nominal payload, properties, equality,
and identity behavior; it is not converted to a generic wrapper type solely
to retain this evidence. The runtime representation of the private metadata
must preserve these observable properties.

Publish witness and diagnostic updates atomically. Concurrent first admissions
select one complete witness; later raises retain it. Readers see consistent
diagnostic snapshots, and concurrent trace contributions must not overwrite
one another.

- `catch Error`, open-row admission, and Error protocol type checks recognize
  the retained witness without rechecking conformance in the catcher's scope.
- Specific error rows and typed catches still use nominal error-type coverage.
- A qualified `Error:message` send on a witnessed error invokes its retained
  implementation, even if the catcher cannot otherwise see that impl or has
  a different scoped impl for the same type. Other protocol sends follow
  their usual rules. An error value that has not been admitted as a failure
  uses normal scoped Error lookup until it acquires a witness.
- Aliases, rethrow, captured catch bindings, and ordinary task/stream/native
  error transfers retain the witness. Explicitly constructing a new error
  value establishes a new failure and selects its own conformance at admission.
- Retain the selected method and module generation while a witnessed error
  remains reachable. Reload or removal cannot silently replace its formatter
  or invalidate its conformance.

On a worker or foreign native lane, admission and retained formatter access
require a formatter whose captures satisfy the worker's Send rules. Reject an
unsafe formatter with a generated admission TypeError before installing it.
Native task failures also validate the complete payload before settling a task;
a rejected publication leaves the task unsettled so the native producer can
report or handle that rejection. Accepted native payloads retain their identity;
the producer makes them Send-safe before calling the publication API.
Actor replies and supervisor delivery apply
the payload check before publishing the failure. A Send-safe live handle in a
diagnostic need not support deep freezing; an immutable outer container is
sufficient when all of its contents satisfy Send.

This is an Error-specific witness rule for qualified dispatch. Bare-name
resolution keeps its normal rules.

## The message shortcut is $err_msg

`$err_msg` is a read-only expression shortcut for `$err/.Error:message`,
available wherever the catch-bound `$err` is lexically in scope. It makes
common recovery code shorter while using the same protocol method:

```gene
(type InputError ^props {^message Str})
(impl Error for InputError)

(try
  (fail (InputError ^message "Invalid input"))
  catch Error $err_msg)
# "Invalid input"
```

Evaluate the message method on each evaluated use of `$err_msg`. Entering a
catch does not compute a message, and the shortcut does not cache the string.
Repeated reads behave like repeated explicit protocol sends, including custom
overrides and return-type checks. Each read has the protocol's empty ordinary
error row, but a generated failure, panic, or cancellation still propagates
as it would from the explicit send. There is no additional recovery or fallback
in the shortcut itself.

Nested catches use their own `$err` and therefore their own `$err_msg`.
A closure referencing `$err_msg` captures the corresponding `$err` and invokes
its message method when that expression executes in the closure. The shortcut
does not create a global error binding or permit assignment to the message.
Use an ordinary local binding when a computed message should be saved once.

## Choosing how much checking to require

Module syntax:

```gene
(mod app ^errors_mode strict)
```

| Mode | Static checking policy |
| --- | --- |
| `dynamic` (default) | No new error-handling obligations. Existing runtime contracts still apply. |
| `warn` | Report unhandled errors, including uncovered `Error`, and violated declarations without blocking execution. |
| `strict` | Reject those diagnostics before execution. |

A "strict function" means a function checked under its module's strict policy.
Private helpers and lambdas may omit error declarations and use inference.
Public invocation interfaces in strict modules must publish an explicit
`^errors` row: exported functions, type-direct messages, protocol requirements
and defaults, custom constructors, and exported callable values. Use `[]` when
appropriate; `[Error]` and `[SomeError Error]` are valid public contracts too.
The detailed rules below keep private inference from becoming an accidental
public promise.

A loose module may call a strict library without acquiring the library's
checking policy. Conversely, checking a strict caller does not force its loose
dependencies to add annotations. The caller still needs trustworthy information
about errors from those dependencies.

Strict module initialization has an implicit empty escaping row. An executable
entrypoint must explicitly choose its contract: `^errors []` requires local
handling, while `^errors [Error]` deliberately permits any remaining ordinary
error to reach the runner. The runner reports its protocol message, retains
the original error's diagnostic context, and exits unsuccessfully;
it is the terminal handler. An entrypoint may also declare a narrower row.
This makes "recover from known failures, fail the program on other errors"
available in strict mode without converting ordinary errors into panics.

Ordinary scripts retain implicit top-level propagation and the same runner
behavior. Use `gene run --errors-mode strict file.gene`,
`gene eval --errors-mode warn 'source'`, or
`gene test --errors-mode strict` to override the application package's policy;
dependencies retain their own module policies. Named application builds do not
yet accept this override; use their source entry path. The web profile currently
rejects `warn` and `strict` explicitly instead of claiming an unchecked proof.

## Open error rows with Error

`Error` is the top of the ordinary error contract: it permits every admitted
ordinary error value with Error conformance. A row containing `Error` is open;
a row without it is closed. Generated failures are catchable Error values too,
but their provenance exempts them from these ordinary-error row checks.

| Row | Meaning |
| --- | --- |
| `^errors []` | No ordinary errors may escape. |
| `^errors [SomeError]` | Only `SomeError` and its subtypes may escape. |
| `^errors [Error]` | Any ordinary error may escape. |
| `^errors [SomeError Error]` | `SomeError` is a known possible error; other ordinary errors may also escape. |

For coverage, `[SomeError Error]` and `[Error]` allow the same set of errors.
Keep `SomeError` in the authored contract and inferred summary: documentation,
editor completion, diagnostics, and suggested recovery branches benefit from
that information. Normalization must not discard named errors merely because
`Error` is present. A named error is a possible outcome, not a guarantee that
the function throws it on every call.

Catch clauses still run in source order. With `catch SomeError` followed by
`catch Error`, the specific branch recovers first and the general branch
receives other errors. Catching `SomeError` leaves `Error` in the escaping
summary; catching `Error` covers all ordinary errors from the protected body.
Recovery and cleanup can introduce new escaping errors of their own.

An open row does not force callers to catch every named error separately.
A caller can catch `SomeError` and declare `[Error]` for the rest, catch all
errors, or simply propagate the full row. Panic and cancellation remain
separate control paths; `Error` does not make them ordinarily catchable.

## Compare coverage separately from diagnostic information

An error row has distinct semantic and informational parts:

```text
ErrorRow:
    declared       # an explicit contract versus an omitted declaration
    coverage       # Error, or a normalized set of ordinary error types
    named_errors   # authored/inferred names retained for callers
    origins        # diagnostic provenance graph
```

Use coverage for catch-or-declare, runtime row admission, and the error-row
portion of callable/protocol signature comparison. Names and origins affect
documentation and diagnostics, not compatibility. An explicit declaration
remains distinct from omission where the existing contract rules require one;
an inferred empty set does not silently install a runtime `^errors []` guard.

| Rows | Coverage relationship |
| --- | --- |
| `[SomeError Error]` and `[Error]` | Equivalent; retain SomeError as information. |
| `[Never]` and `[]` | Equivalent empty coverage. |
| `[A B A]` and `[B A]` | Equivalent; order and duplicates do not change coverage. |
| `[FsError NotFound]` and `[FsError]`, with NotFound <: FsError | Equivalent; retain the more specific name as information. |
| An omitted declaration and explicit `[]` | Omission is not an empty declared contract; infer it or conservatively use Error. |

Resolve aliases and compare nominal identities, not printed type names.
Where Gene currently requires an exact inherited callable signature, require
equal semantic error coverage while retaining its other signature rules.
This does not introduce general callable variance or permit arbitrary error-row
narrowing in an exact-signature position. In particular, two otherwise equal
Callable contracts declaring `[Error]` and `[SomeError Error] are compatible.

Subtract a catch only when it covers every value represented by an inferred
entry. For an entry E and a catch type C, remove E when E is a subtype of C,
or when C is Error. Do not reverse this test:

```text
Escaping [FsError], catch NotFound <: FsError -> remaining [FsError]
Escaping [NotFound], catch FsError           -> remaining []
Escaping [SomeError Error], catch SomeError -> remaining [Error]
```

After subtraction, add escaping ordinary errors from recovery and cleanup.
An implementation may improve precision later, but must not erase the broader
obligation merely because one subtype was caught.

## Calling a function that has no error declaration

**An omitted `^errors` is not equivalent to `^errors []`.** The checker first
tries to infer what can escape from the callee, including every nested call.
If it cannot obtain a closed conservative summary, it includes `Error` in the
row. There is no separate unknown-error category with stricter handling rules.

| What the checker knows about the callee | What a strict caller must account for |
| --- | --- |
| Explicit error row backed by a checked function contract | The declared errors. Contract violations remain runtime failures. |
| No row, but the body and relevant call targets can be analyzed | The transitively inferred escaping errors. |
| Some known errors plus an unresolved nested call | An open row such as `[SomeError Error]`. |
| Opaque function, dynamic dispatch without a contract, `eval`, or native callable without metadata | `[Error]`. |

The analysis belongs to the code being checked, not to the callee's chosen
mode. Available source from a dynamic module can supply an inferred summary
without changing that module's runtime behavior. Published compiler summaries
can avoid reanalyzing its source.

For example, both helpers below omit `^errors`:

```gene
(mod config ^errors_mode strict)

(type ConfigError ^props {^message Str})
(impl Error for ConfigError)

(fn decode ^private true [bad : Bool] : Str
  (if bad
    (fail (ConfigError ^message "Invalid configuration"))
    "ready"))

(fn load_config ^private true [bad : Bool] : Str
  (decode bad))

(fn start [bad : Bool] : Str ^errors []
  (load_config bad))
```

The checker infers `decode -> [ConfigError]`, then
`load_config -> [ConfigError]`. It rejects `start` with a diagnostic such as:

```text
start permits no escaping recoverable errors.
load_config may raise ConfigError.
Origin: start -> load_config -> decode -> fail ConfigError.
Catch ConfigError here, or add it to start's ^errors declaration.
```

Either of these replacements is valid:

```gene
# Delegate handling to the caller.
(fn start [bad : Bool] : Str ^errors [ConfigError]
  (load_config bad))

# Handle the failure locally.
(fn start [bad : Bool] : Str ^errors []
  (try (load_config bad)
    catch ConfigError "default"))
```

These are alternatives, not two definitions to place in the same module.
If `start` is the actual application entrypoint, the propagation alternative
deliberately permits the runner to report `ConfigError` and exit unsuccessfully.
The handling alternative returns normally with its fallback value.

Adding another unannotated helper in the middle does not hide the error.
Calling several helpers unions their possible escaping errors. Catching an
error inside a helper removes it from that helper's escaping summary, unless
the recovery code raises it again. The analysis checks possible execution
paths; it does not depend on tests having exercised the failure.

## How transitive inference works

The compiler maintains the coverage and informational summary defined above.
It may remember whether an open row came from an explicit declaration or an
unresolved call for diagnostics, but both have the same error-coverage rules.

For each expression:

- `fail` of a fresh error contributes its possible ordinary types. An unresolved
  value contributes `Error`. A rethrow follows retained provenance and propagates
  its ordinary possibilities; it does not change generated failures to ordinary.
- A call contributes the callee's invocation errors, plus errors from
  evaluating its callee expression and arguments. Its invocation contract
  already includes its own possible default evaluation errors.
- Branches contribute the union of their possible errors.
- Combining `[SomeError]` with `[Error]` yields `[SomeError Error]`; retain the
  named error even though `Error` already covers it semantically.
- A `try` removes only errors covered by its catches, respecting type
  relationships. Errors from recovery and `ensure` bodies contribute separately;
  sibling catches do not handle errors raised by a recovery body.
- Catching a specific type from an open row removes its named entry but keeps
  `Error`. The analysis need not introduce an "Error except SomeError" type;
  the remaining `Error` is a conservative summary of the uncaught cases.
- Defining a lambda or local function does not execute its body. Its summary
  follows the function value and matters when that function is invoked.

Recursive and mutually recursive functions are analyzed together until their
summaries stop changing. An unfinished recursive summary must never be
mistaken for a proven empty row. Dynamic operations within a recursive group
still contribute `Error`.

Compute convergence over finite semantic coverage. Intern named error types
and keep diagnostic origins in a bounded graph keyed by declarations and call
sites; represent recursion as graph edges. Do not grow an expanded call-chain
string on every iteration or include that string in fixed-point equality.
Unsupported or unbounded specialization widens conservatively to Error.

Private functions with omitted rows expose their inferred summaries to the
analysis. For a function with an explicit row, the checker verifies that all
escaping ordinary errors fit that row. A closed row cannot cover an inferred
`Error`; an explicit open row can. Thus `^errors [SomeError Error]` is enough
to propagate errors from an unknown nested call. No adapter is required solely
because the callee was unannotated or opaque.

Knowing a function's source is insufficient if the call can target a different
function at runtime. Rebinding, hot replacement, and scoped message dispatch
must preserve an enforced contract, invalidate the proof, or widen the call's
row to include `Error` before installing strict executable code. Summaries
must track callable identity and dependency versions rather than trusting a
matching name. The replacement policy below governs already-installed code.

Built-in native effect models have explicit identities and versions, attached
to their implementations and retained in executable proof dependencies. A
native function with the same display name but missing or stale metadata cannot
satisfy that proof. Namespace aliases of the same implementation share its
model identity. Opaque host callables still require an open row or a checked
callable view.

Inference here means a conservative upper bound, not a promise to discover
the exact behavior of arbitrary dynamic code. Unsupported analysis produces
`Error`. Strict checking rejects it only when neither a handler nor an open
declaration covers it.

The current checker does not specialize protocol `Self` error rows to every
concrete conformance. A caller promising a particular nominal error can
therefore be rejected even when that binding would make the call valid. Use
an open `Error` contract or an explicit checked callable view at that boundary.

## When a nested call remains unknown

Suppose `start -> load_config -> plugin_callback`, and the callback has no
usable contract. Knowing the other functions' source cannot reveal the
callback's behavior. `load_config` therefore has an inferred `[Error]` row,
even if its own body has no `fail` expression. If the analysis also discovers
`SomeError`, its summary is `[SomeError Error]`.

These leave an error obligation unresolved:

- Declaring `start ^errors []`.
- Declaring only specific expected types, with no `Error` entry.
- Catching only `SomeError` while permitting no other errors to escape.

A strict caller can explicitly propagate `Error`, handle it, or choose an
adapter that converts or bounds errors.

**Recover from a known error and propagate the rest.** The preferred open
contract requires no wrapper around the unknown call:

```gene
(type SomeError ^props {^message Str})
(impl Error for SomeError)

(fn call_plugin [callback : Callable] : Any ^errors [SomeError Error]
  (callback))

(fn run_plugin [callback : Callable] : Any ^errors [Error]
  (try (call_plugin callback)
    catch SomeError "recovered"
    catch Error (fail $err)))
```

`call_plugin` publishes an expected error plus an open remainder. Its row
allows unknown nested failures without relabeling their original error values.
`run_plugin` returns its recovery value for `SomeError` and re-raises other
errors unchanged. Omitting the final `catch Error (fail $err)` has the same
error-propagation behavior: unmatched errors escape automatically. A re-raise
is propagation, so `run_plugin` must retain `Error` in its declaration.

The next strict caller can handle the remaining `Error` or declare it again.
If it reaches an entrypoint declaring `[Error]`, the runner reports the error
and exits unsuccessfully. This is the intended "recover here, fail on other
errors" path. The compiler need not prove that callers meaningfully recover
from every possible failure; it enforces the chosen error contract.

**Handle all ordinary errors and optionally normalize them.** For example:

```gene
(type IntegrationError ^props {^message Str ^cause Any})
(impl Error for IntegrationError)

(fn call_plugin [callback : Callable] : Any ^errors [IntegrationError]
  (try (callback)
    catch Error
      (fail (IntegrationError
        ^message "Plugin operation failed"
        ^cause $err))))
```

Bare `Callable` contributes `Error`. `catch Error` handles every ordinary
error from invocation, and the replacement `fail` contributes only
`IntegrationError`. The caller of `call_plugin` must catch or declare that
type. This broad catch deliberately includes diagnostics delivered through
Gene's ordinary error channel; panic and cancellation retain their separate
control behavior.

**Admit the callable through an explicit runtime contract.** The existing
checked view syntax can express that assertion:

```gene
(let checked : (Callable [] Any ^errors [ConfigError]) plugin_callback)
```

Strict callers then account for `ConfigError` when invoking `checked`.
This is a runtime-checked assertion about opaque code, not a static proof of
its implementation. A different escaping error is a contract violation; the
view neither converts it to `ConfigError` nor silently ignores it. Such a
violation is a generated ErrorContractViolation with the original error as its
cause, catchable by Error and exempt from further row wrapping. Tooling should
distinguish inferred proofs from contracts asserted at a dynamic seam.

Use this narrowing assertion only when the caller wants a closed contract.
An open declaration is sufficient when other errors should propagate normally.
Accurate native/compiler metadata can supply a closed inferred contract without
an assertion. Dynamic mode remains available for code where static enforcement
is unnecessary.

## Public invocation contracts, defaults, and imports

Strict public interfaces publish explicit rows on exported functions,
type-direct messages, protocol requirements/defaults, and custom constructors.
Effective impl bodies must satisfy their protocol or inherited contract using
the existing signature rules plus semantic error-row comparison. An inherited
or default body reuses that explicit contract.

An exported callable value must carry an explicit invocation signature, such
as `(Callable [] Any ^errors [Error])`, or the explicit contract of its known
function/message target. Moving a function into a method, constructor, or
callable binding cannot silently turn a published explicit row into a changing
inferred promise. Explicitly open rows remain available.

A factory's invocation row applies only to producing its returned value.
To publish a closed contract for a returned callback, annotate that callback's
own callable signature. Compiler interfaces retain both contracts. An Any or
bare Callable result is still allowed, but later calls through it contribute
Error; an empty factory row supplies no evidence about those calls. Apply the
same separation to Task and Stream result contracts.

The callee's invocation row covers its body and all default expressions that
any supported argument shape can evaluate. For example, assuming load_options
can raise ConfigError, strict checking rejects this declaration:

```gene
(fn run [options = (load_options)] : Any ^errors []
  options)
```

Its body is harmless, but omitting options may fail before the body starts.
The public row must include ConfigError or handle it within default evaluation.
Passing options explicitly skips the default at runtime; it does not change
the declared upper bound used by callers. The MVP does not narrow public rows
by call shape. The same rule applies to messages and constructors.

Runtime row guards must cover callee-owned default evaluation as well as the
body. Errors in caller-supplied argument expressions belong to the caller and
are not attributed to the callee. Generated parameter/result type failures
retain their separate classification.

Native summaries also include ordinary argument-validation and state failures.
For example, native operations that report wrong arity or invalid collection
arguments as `RuntimeError` retain that ordinary error obligation. An annotated
parameter boundary's generated TypeError remains a separate classification.

Each source module has an initialization summary, separate from its exported
callables. A runtime import contributes the dependency's possible initialization
errors, including transitive runtime imports, plus ordinary errors of the load
operation itself. Compile-time macro discovery does not execute initialization.
Compute summaries from source or versioned interfaces; never use the compiler
process's current module cache or a previous test's warm cache as evidence
that initialization cannot fail. The MVP conservatively accounts for each
potentially initializing import without an initialization-dominance optimization.

Strict initialization's implicit row is empty. An unconditional import that
cannot legally be protected by a catch must therefore have an empty ordinary
initialization/load row. Move fallible startup into an explicitly errorful
function called from main, or handle the failure inside the dependency's
initializer. Do not invent a catch-around-import form that Gene does not allow.
Existing read/compile failures remain governed by their compilation phase;
runtime evaluation of code still contributes its runtime invocation errors.

## Tasks, streams, and callbacks

The checker must separate invocation errors from deferred errors:

- Returning `(Task T E)` does not raise `E` at the return site. `await`
  contributes `E` to the awaiting code's error summary, plus any invocation
  state errors described below.
- Returning `(Stream T E)` does not consume it. Iteration and consuming
  operations contribute its producer errors, plus their own invocation errors.
- A catch around task, stream, or closure creation does not handle a failure
  that occurs after the value escapes that catch.
- Higher-order functions must describe how callback errors contribute to
  invocation or to a returned task/stream. Until that relationship is known,
  the checker conservatively includes `Error` in the potentially affected
  invocation/deferred summaries.
- Omitted or opaque deferred error contracts also contribute `Error` at
  consumption. `(Task T Error)` and `(Stream T Error)` explicitly admit any
  ordinary deferred error. Retain known named errors in compiler summaries
  even when the permitted deferred error type is broad.

Normal `scope` exit waits for its children without consuming their results or
raising their stored failures. An escaped task can still be awaited afterward.
The checker conservatively includes `RuntimeError` for structured waiting
(for example, scheduler deadlock), separately from errors in the scope body and
cleanup. It does not add each child's deferred error row at scope exit.
`Task/join` and `Stream/try_next` return producer failures in outcome variants.
Requiring consumers to inspect those values, or to observe every child failure,
is a separate policy and is not guaranteed by catch-or-declare checking.

The VM consumes a task's result on its first `await`, even when that await
raises its producer error. A later await through any alias raises `RuntimeError`.
Concurrent awaits claim that result atomically; exactly one receives its value
or failure, and the others receive the already-consumed state error.
`(Task T E)` describes result and producer errors; it does not promise an
unconsumed handle. Awaiting a parameter or other task of unknown state therefore
also requires handling or declaring `RuntimeError`:

```gene
(fn recover [task : (Task Int ConfigError)] : Int ^errors [RuntimeError]
  (try (await task) catch ConfigError 0))
```

The checker can prove the first await of a fresh local task safe from repeated
consumption. That proof follows aliases, branches, catches, cleanup, and loops;
a call that might consume an alias invalidates it. Fresh allocations in a loop
are distinct from handles retained from previous iterations. When inferred
factory results supply freshness or producer-isolation facts, live replacement
checks preserve those facts along with the deferred row.

Those outcomes do not remove an operation's own state requirements. Joining an
already-awaited task raises RuntimeError; joining does not itself consume the
await result. `Stream/next` and `Stream/peek` can raise EndOfStream, and pulls
can fail when reentered. Include these invocation errors separately from the
producer's deferred row.

## Keeping strict executable code valid during replacement

Register the callable identities, error coverage, and dispatch/module versions
that installed strict code relies on. Keep those dependencies live as long as
the strict executable, a retained closure, or a suspended invocation can use
them. Invalidating a summary cache alone does not update an installed caller.

For the MVP, reject a replacement that broadens any retained strict assumption
before publishing the new binding, module generation, or impl. The diagnostic
identifies affected dependents and requires their revalidation. A future
transaction may recheck and replace affected dependents together; the MVP does
not silently recompile them or temporarily run them under invalid assumptions.
Already-running invocations retain their admitted code/implementation version.

When inference follows a private factory's returned callable, task, or stream,
retain the consumed result's contract separately from the factory's invocation
row. Forwarding helpers and captured source bindings participate in that proof.
Discarding a result adds no consumption dependency. Lazy adapter construction
can depend on the receiver remaining a Stream without consuming its errors.

Retain the identities of lexical types and aliases used by closed proofs,
including typed catches, signatures, and constructed failures. Rebinding a catch
alias can invalidate a handler without changing the callee's error row, so it
requires the same revalidation before publication. Built-in annotation terms
that the runtime resolves structurally do not depend on lexical bindings.

Scalar and collection results need an explicit return annotation when a closed
proof depends on their type or element shape. The MVP does not preserve those
facts from an unannotated factory body across replacement. Such results remain
unknown to the caller; annotating a result installs the shared runtime type
contract. This restriction also applies to unannotated factories' task result
and stream element types, independently of their retained deferred error rows.

Returned native callables retain their native model identity. Constructor
results retain their nominal declaration identity and source type bindings;
types declared inside a factory also belong to its compiled generation. A held
protocol message retains its declaration and binding scope. Calling that held
value can raise MessageError during dispatch, separately from the selected
implementation's declared row.

A replacement needs enough validated metadata to preserve these inferred
contracts. When the inference depends on replaceable source bindings, the new
producer must have live guards for those bindings; warning-only metadata does
not provide them. Revalidate such a producer under strict checking before
publication. The replacement check never executes a factory to guess its result.

Sandbox commit rechecks retained assumptions at publication, including callers
installed after preparation. Releasing a generation validates the proposed
impl removal before changing registries or caches. A rejected release leaves
the generation and its callers usable.

A replacement whose error coverage is contained by all retained assumptions
can pass this effect check, subject to Gene's other signature and reload rules.
Changes only to named errors or diagnostic origins do not broaden coverage.
Preserve the existing exact-signature rules where applicable; a subset test on
a proof dependency does not itself add callable variance to the language.

Calls through genuinely mutable or unresolved targets are analyzed as Error
unless an enforced checked callable contract protects the slot. Treat guarded
calls as runtime assertions, and report a single generated contract violation
if the target violates the retained contract. Do not promote an unguarded
mutable binding into a fixed-target proof. Any runtime replacement mechanism
unable to enforce these rules must reject the update while strict dependents
are live.

Retained Error witnesses also keep their selected formatter generation alive.
Unloading cannot remove behavior still referenced by a caught error. The
replacement checks and witness lifetime rules must be included in module and
impl transactions, not only in editor caches.

Module interface digests include invocation, returned-callable, deferred, and
initialization error contracts. Source versions and diagnostic call graphs
remain separate from the contract key used to converge dependency summaries.

## What strict checking guarantees

Within the checked surface, every possible ordinary error is covered by a
handler or a declared contract. Unknown calls contribute `Error`, which must
be caught or declared like any other error. An open declaration explicitly
chooses propagation; it is fully valid strict code. Static inference and
explicit runtime contracts are distinct sources of contract information.

This does not prove successful recovery, termination, or freedom from runtime
bugs. Generated type failures and contract violations remain catchable but
exempt from ordinary error rows; panic and cancellation preserve their separate
control paths. A fresh user-created failure is ordinary regardless of its type
name, and a rethrow preserves its existing classification. Changing checking
mode must not change which catch executes or whether cleanup runs.

## Acceptance coverage

The runtime, compiler, lifetime, concurrency, CLI, and backend tests cover:

1. Failure provenance, one-time contract violations, original causes, and
   rethrows across immediate and deferred execution.
2. Retained Error conformance and formatter environments, preserving nominal
   identity and the existing rules for transporting values between threads.
3. Lexical `$err`, lazy `$err_msg`, default-backed and custom formatters,
   return checks, and reporting fallback.
4. Semantic row comparison, catch subtraction, and diagnostic names.
5. Invocation, default, deferred, and initialization summaries in compiler
   interfaces and versioned native metadata.
6. Transitive inference, finite recursive fixed points, and rejection of
   updates that invalidate a live strict dependency.
7. Dynamic, warn, and strict policy behavior, with explicit rejection of
   unsupported checking modes by the transpiled web backend.

Key conformance cases:

| Case | Expected strict result |
| --- | --- |
| An undeclared NetworkError crosses a closed checked view and several checked callers | Create one generated ErrorContractViolation with the original cause; outer row validators pass it through. |
| A handler catches that violation | ErrorContractViolation and Error catches match; ConfigError does not. |
| A generated TypeError and a newly constructed TypeError are failed | Generated provenance bypasses row checks; the fresh explicit failure is an ordinary TypeError obligation. |
| A handler rethrows a generated failure through an alias | Preserve classification, cause, and Error witness without repeated wrapping. |
| A handler constructs a new error using a generated failure as its cause | Track the new value as an ordinary error. |
| A catch handles an error | Bind the original typed value as branch-local `$err`. |
| Catches are nested | The inner `$err` shadows the outer binding only within its recovery branch. |
| A closure captures `$err` | Retain the error bound by the closure's own recovery branch. |
| A recovery branch reads `$err_msg` | Evaluate `$err/.Error:message` and return the same string. |
| A recovery branch never reads `$err_msg` | Do not invoke the message method for the shortcut. |
| A recovery branch reads `$err_msg` twice | Invoke the message method twice, as with two explicit sends. |
| A nested catch or closure uses `$err_msg` | Use its lexically associated `$err`; evaluate at the point of use. |
| A message method fails through `$err_msg` | No ordinary error is declared; propagate any generated failure or separate control event exactly as the explicit send does. |
| A generic recovery branch returns `$err_msg` | Message access adds no ordinary error obligation. |
| A custom message method can raise an ordinary error | Reject it against the protocol's empty row in strict mode; otherwise a runtime row violation is generated if it escapes. |
| An error has `^message Str` and an empty Error impl | `$err/.Error:message` returns the stored string through the protocol default. |
| An error overrides `Error:message` without a message property | `$err/.Error:message` returns the computed string. |
| A known type selects the default without a required Str message property | Reject the default-backed conformance. |
| An opaque value selects the default with invalid backing data | Reject Error admission with a generated TypeError without invoking the formatter. |
| An error escapes its scoped Error implementation | Catch Error and open rows recognize its retained witness; formatting invokes the retained provider. |
| The catcher has a different scoped Error implementation | It does not replace the incoming failure's retained provider. |
| A type has both a direct message and Error:message | Both are legal; qualified Error access and `$err_msg` use only the protocol method. |
| A value has a message property but no Error impl | It does not gain Error conformance automatically. |
| A message method returns a non-string value | Apply ordinary return-type checking. |
| Message formatting fails during terminal reporting | Preserve the original error and use fallback display text. |
| A caught error is re-raised after reading its message | Preserve its original type, fields, and cause. |
| Unannotated helper directly fails | Infer its error and require catch or declaration. |
| Several unannotated wrappers lead to that helper | Propagate the error through every wrapper. |
| A helper handles the error completely | Remove it from the helper's escaping summary. |
| A catch handles only NotFound from an FsError summary | Retain FsError conservatively. |
| A catch handles FsError from a NotFound summary | Remove that covered entry. |
| Recovery or cleanup fails | Include the newly escaping error. |
| A recursive cycle reaches a failing operation | Infer the error across the cycle. |
| Recursive diagnostic origins revisit a call site | Converge on finite coverage and retain bounded graph edges instead of growing call-chain strings. |
| A nested call is opaque | Infer `[Error]`; require catch or declaration. |
| A known error and an opaque nested call coexist | Infer `[SomeError Error]` and retain the named error. |
| A function declares `[SomeError Error]` and calls opaque code | Accept propagation of any ordinary error. |
| A function declares `[SomeError]` or `[]` and leaves an opaque call uncovered | Reject the uncovered `Error`. |
| Only `SomeError` is caught from `[SomeError Error]` | `Error` remains and must be caught or declared. |
| `catch SomeError` precedes `catch Error` | Recover specific errors in the first branch; handle other ordinary errors in the second. |
| `catch Error (fail $err)` rethrows an open ordinary-error call | Preserve the original value and retain its escaping Error obligation. |
| An open row is normalized or displayed | Keep named errors alongside `Error`. |
| Callable rows `[SomeError Error]` and `[Error]` are compared | Equal coverage gives no signature mismatch due to the retained name. |
| Error rows differ only by order, duplicates, Never, or redundant subtypes | Compare normalized coverage; retain useful diagnostic names separately. |
| An omitted declaration has inferred empty coverage | Do not confuse it with an explicit checked empty contract. |
| An open row sees panic or cancellation | Preserve their separate runtime control behavior. |
| An entrypoint declares `[Error]` and an ordinary error escapes | Report it and exit unsuccessfully. |
| A catch-all normalizes unknown errors | Require only the adapter's escaping errors. |
| An opaque callable is admitted through a checked view | Accept its asserted row; verify violation behavior at runtime. |
| A default can fail before a function, message, or constructor body | Include it in the callee's declared row and check it within the invocation's runtime guard. |
| A caller explicitly supplies an optional argument | Skip its default at runtime; keep the public declared upper bound for static calls. |
| Fallible work moves from a function into a public method or exported callable | Require an explicit public invocation contract in either form. |
| A factory returns a callback | Separate factory invocation errors from the callback's errors. |
| An import may initialize a fallible dependency | Account for initialization regardless of the compiler/test process's warm cache. |
| A strict unconditional import has no legal surrounding handler | Require empty ordinary initialization/load coverage or refactor fallible startup into a callable. |
| A created task, stream, or closure fails later | Require handling at execution/consumption, not merely creation. |
| An await raises and its error is caught | Its task result is still consumed; a later await adds RuntimeError. |
| A task parameter has an empty deferred row | Its unknown consumption state still adds RuntimeError at await. |
| A scope exits with a failed child | Wait without raising or consuming its stored failure; account separately for waiting and cleanup errors. |
| A dependency or impl update broadens an installed strict proof assumption | Reject publication until affected dependents are revalidated. |
| A replacement changes only named hints alongside Error | Do not treat it as broader semantic error coverage. |
| A runtime-mutable target violates its retained checked view | Report the single generated contract violation; do not continue as if the proof were updated. |
| A generation's formatter is retained by a caught error | Keep the method/environment alive until the witness is released. |
| A quick script omits all error declarations | Preserve dynamic behavior. |

Nim's [exception tracking and inference](https://nim-lang.org/docs/manual.html#effect-system-exception-tracking)
provide a precedent for propagating callee errors and inferring helper rows.
Gene's dynamic calls and deferred values use `Error` for unknown possibilities
and the runtime-contract rules above for optional narrowing.

