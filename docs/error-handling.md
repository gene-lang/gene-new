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

## Throwable, Error and Fault

Every value `fail` raises is a `Throwable`. It belongs to one of two branches,
decided by its type's parent chain when the type is declared:

```text
Throwable                ^props {^_msg Str? ^_cause Throwable?}, message [] : Str ^errors []
├── Error                failures a correct program can meet; checked by ^errors rows
│   ├── IoError, FsError, JsonError, HttpError, DbError, CompileError, ...
│   ├── DecodeError, TimeError, NativeLibraryError, LimitExceeded
│   └── user types: (type InputError : Error ^props {^field Str})
└── Fault                defects; never in ^errors rows
    ├── Panic            raised by (panic v); carries ^value
    ├── TypeFault, CallKindFault, MessageFault
    ├── MatchFault, PathMissing
    ├── ContractViolation, AssertionFault, RefFault, ReplyAlreadySent
    ├── RuntimeFault     a message-only runtime failure
    └── user types: (type Invariant : Fault)
```

Cancellation and policy expiry inside its own policy are not Throwables. They
are control transfers: no `catch` sees them, and `ensure` and `unwind` run.
Every type named `*Error` is an Error and every `*Fault` is a Fault; a name
with neither suffix can be on either side.

| | Error value | Fault value | Cancellation |
| --- | --- | --- | --- |
| `catch Error` | caught | not caught | not caught |
| `catch Fault` | not caught | caught | not caught |
| `catch T` | caught if `T` covers it | caught if `T` covers it | not caught |
| `catch Throwable` | caught | caught | not caught |
| `^errors` rows | checked | passed through | n/a |
| `Task/join` | `TaskOutcome/error` | `TaskOutcome/fault` | `TaskOutcome/cancelled` |

`catch Any`, or a clause naming a value type such as `Str`, is a compile error.
`(fail v)` rejects a value that is not an Error or a Fault, including a bare
`Throwable`. Building `(Error ^_msg "...")` or `(Fault ^_msg "...")` directly
is allowed.

An error row names Error types only; `^errors [TypeFault]` is rejected with
"Fault types are unchecked". When a row rejects an Error, the runtime raises a
`ContractViolation` once, at the first rejecting row, with the original error in
`_cause`.

### Messages and causes

```gene
(type InputError : Error ^props {^field Str})
(fail (InputError ^field "age" ^_msg "age must be positive"))

(type StatusError : Error ^props {^status Int}
  (message message [] : Str ^errors [] ^^override
    $"Operation failed with status ${self/status}"))

(type NotFound : Error)      # no message; .message returns ""
```

`message` is a type-direct message on `Throwable`. It returns the stored
`_msg`, or `""` when none is stored. A subtype overrides it with `^^override`
and must keep the contract `[] : Str ^errors []` exactly. Overrides are
expected to be side-effect-free and to always return. A handler reads the
message with `$err/.message`; `$err/_msg` reads the stored field and may be
`nil`. There is no `$err_msg` shortcut.

`_cause` holds the Throwable this one wraps. A boundary that turns a defect
into a domain Error keeps the defect as the cause:

```gene
(try (call_plugin plugin request)
  catch Throwable
    (fail (PluginError ^_msg "plugin failed" ^_cause $err)))
```

A Throwable reads an undeclared name as `nil`, so a handler holding an error of
unknown type can probe `$err/code`. When the runner reports an error whose
message is `""`, or whose `message` override fails, it shows the type name.

### The catch binding is $err

`catch` binds the original error value as `$err`. The binding is lexical: a
closure created in a catch body keeps its own `$err`, and a nested catch gets
its own. `(fail $err)` re-raises that value unchanged.

### Panic

`(panic v)` raises `(Panic ^_msg <text> ^value v)`. `catch Panic`,
`catch Fault` and `catch Throwable` catch it; `catch Error` never does.
`ensure` and `unwind` run as it unwinds. A task that panics joins as
`TaskOutcome/fault` carrying the Panic.

### Cleanup that runs only on failure

```gene
(try (open_session) handle
  unwind (close_partial_session)
  ensure (release_lock))
```

Clauses are ordered `catch...`, then `unwind`, then `ensure`. `unwind` runs only
when the try is left by unwinding: a Throwable no catch handled, a failing
catch body, cancellation or policy expiry. It does not run on normal completion
or when `return`, `break` or `continue` leaves the try. Its order is catch,
then `unwind`, then `ensure`. A failing `unwind` or `ensure` body during an
unwind is dropped, and the original failure continues; under cancellation or
expiry the terminal reason stays terminal.

### Message-only runtime failures

A runtime failure with no more specific type reaches a handler as a
`RuntimeFault` carrying only its message. Each such raise in the runtime is on a
reviewed list, `tests/fixtures/message_only_raises.txt`, as a defect; a test
fails when an unlisted one appears. Failures a correct program can meet use
Error types instead: bad base64 or UTF-8 is a `DecodeError`, bad RFC3339 or
TZif data and an ambiguous local time are `TimeError`s, a library that cannot be
loaded is a `NativeLibraryError`, and a compile failure reached through `eval`
or a module import is a `CompileError`. Policy expiry seen from the caller that
set the policy is `(LimitExceeded ^reason "timeout")` or `^reason "memory"`.

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

`Error` is the top of the ordinary error contract: it permits every value of
the Error branch. A row containing `Error` is open; a row without it is closed.
Faults are never checked by rows: they pass through every row unchanged.

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

A `catch` clause names an error type. `catch Error` is the general recoverable
catch. `catch Any`, and a clause naming a built-in value type such as `Str` or
`Int`, is a compile error: no such value can be raised, so the clause could
never run.

An open row does not force callers to catch every named error separately.
A caller can catch `SomeError` and declare `[Error]` for the rest, catch all
errors, or simply propagate the full row. Faults, `Panic` among them, and
cancellation are outside `Error`: an open row does not cover them, and
`catch Error` does not catch them.

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

(type ConfigError : Error)

(fn decode ^^private [bad : Bool] : Str
  (if bad
    (fail (ConfigError ^_msg "Invalid configuration"))
    "ready"))

(fn load_config ^^private [bad : Bool] : Str
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

- `fail` of an Error value contributes its type. An unresolved value
  contributes `Error`. A Fault contributes nothing: faults are never part of a
  row. A rethrow of `$err` contributes what the catch could have caught.
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
(type SomeError : Error)

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
(type IntegrationError : Error ^props {^cause Any})

(fn call_plugin [callback : Callable] : Any ^errors [IntegrationError]
  (try (callback)
    catch Error
      (fail (IntegrationError
        ^_msg "Plugin operation failed"
        ^cause $err))))
```

Bare `Callable` contributes `Error`. `catch Error` handles every ordinary
error from invocation, and the replacement `fail` contributes only
`IntegrationError`. The caller of `call_plugin` must catch or declare that
type. This broad catch covers every Error the plugin raises. A plugin's Fault
passes it by; a boundary that must also contain defects writes
`catch Throwable` and keeps the defect as `_cause`.

**Admit the callable through an explicit runtime contract.** The existing
checked view syntax can express that assertion:

```gene
(let checked : (Callable [] Any ^errors [ConfigError]) plugin_callback)
```

Strict callers then account for `ConfigError` when invoking `checked`.
This is a runtime-checked assertion about opaque code, not a static proof of
its implementation. A different escaping error is a contract violation; the
view neither converts it to `ConfigError` nor silently ignores it. Such a
violation is a ContractViolation, a Fault, with the original error as its
`_cause`; outer rows pass it through. Tooling should
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
Native operations that can only fail with a defect, such as wrong arity or an
invalid argument, add no obligation: those failures are Faults.

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
The checker conservatively includes `RuntimeFault` for structured waiting
(for example, scheduler deadlock), separately from errors in the scope body and
cleanup. It does not add each child's deferred error row at scope exit.
`Task/join` and `Stream/try_next` return producer failures in outcome variants.
Requiring consumers to inspect those values, or to observe every child failure,
is a separate policy and is not guaranteed by catch-or-declare checking.

The VM consumes a task's result on its first `await`, even when that await
raises its producer error. A later await through any alias raises a
`RuntimeFault`. Concurrent awaits claim that result atomically; exactly one
receives its value or failure, and the others receive the already-consumed
`RuntimeFault`. A second await is a defect, so it adds no obligation: awaiting a
parameter or another task of unknown state requires handling only the task's own
row, and the checker tracks no consumption state.

```gene
(fn recover [task : (Task Int ConfigError)] : Int ^errors []
  (try (await task) catch ConfigError 0))
```

Joining an already-awaited task also raises a `RuntimeFault`; joining does not
itself consume the await result. `Stream/next` and `Stream/peek` can raise
`EndOfStream`, an Error that callers include separately from the producer's
deferred row. A reentered pull is a defect and adds nothing.

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
value can raise MessageFault during dispatch, separately from the selected
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
calls as runtime assertions, and report a single contract violation
if the target violates the retained contract. Do not promote an unguarded
mutable binding into a fixed-target proof. Any runtime replacement mechanism
unable to enforce these rules must reject the update while strict dependents
are live.

A caught error formats through its own type's `message`, so it keeps that
type, and the module generation that declared it, alive while it is held.

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
bugs. Faults are exempt from rows whoever constructs them, because the branch is
the type's parent chain; cancellation is a control transfer. Changing checking
mode must not change which catch executes or whether cleanup runs.

## Acceptance coverage

The runtime, compiler, lifetime, concurrency, CLI, and backend tests cover:

1. The branch split, one-time contract violations, original causes, and
   rethrows across immediate and deferred execution.
2. Nominal identity of error types across scopes, sandbox generations and
   threads, under the existing rules for transporting values.
3. Lexical `$err`, `$err/.message`, `message` overrides, return checks, and
   reporting fallback.
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
| An undeclared NetworkError crosses a closed checked view and several checked callers | Create one ContractViolation with the original cause; outer row validators pass it through. |
| A handler catches that violation | ContractViolation and Error catches match; ConfigError does not. |
| A catch handles an error | Bind the original typed value as branch-local `$err`. |
| Catches are nested | The inner `$err` shadows the outer binding only within its recovery branch. |
| A closure captures `$err` | Retain the error bound by the closure's own recovery branch. |
| A recovery branch reads `$err/.message` | An ordinary send: the error's `message`, a `Str`. |
| A nested catch or closure uses `$err/.message` | Use its lexically associated `$err`. |
| A generic recovery branch returns `$err/.message` | Message access adds no ordinary error obligation. |
| A message override can raise an ordinary error | Reject it against the inherited empty row; otherwise a runtime row violation is generated if it escapes. |
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
| An open row sees a Fault or cancellation | Pass the Fault through unchecked; cancellation stays a control transfer. |
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
| An await raises and its error is caught | Its task result is still consumed; a later await raises a RuntimeFault, which adds no obligation. |
| A task parameter has an empty deferred row | Awaiting it adds no obligation, whatever its consumption state. |
| A scope exits with a failed child | Wait without raising or consuming its stored failure; account separately for waiting and cleanup errors. |
| A dependency or impl update broadens an installed strict proof assumption | Reject publication until affected dependents are revalidated. |
| A replacement changes only named hints alongside Error | Do not treat it as broader semantic error coverage. |
| A runtime-mutable target violates its retained checked view | Report the single contract violation; do not continue as if the proof were updated. |
| A quick script omits all error declarations | Preserve dynamic behavior. |

Nim's [exception tracking and inference](https://nim-lang.org/docs/manual.html#effect-system-exception-tracking)
provide a precedent for propagating callee errors and inferring helper rows.
Gene's dynamic calls and deferred values use `Error` for unknown possibilities
and the runtime-contract rules above for optional narrowing.
