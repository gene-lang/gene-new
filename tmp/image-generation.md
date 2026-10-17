# Image generation with review

Status: proposal, revised after both Claude reviews (2026-10-17). The registries,
host services and provider changes described below are proposed work, not
features already available in the Harness.

## Requirement

Generate an image from a textual prompt and optional reference images. Have the
main model review each result against the request and score it out of 100.
Refine the image while the score is below 85, up to a configurable limit, then
return the last generated image to the user.

**Image generation must be replaceable by a plugin.** Ship a default `image`
plugin for the workflow, with independently selectable generator plugins.
Replacing the workflow or adding a generator must not require editing the turn
loop, conversation UI or built-in provider modules.

This portability applies after the shared host contract is implemented. Adding
the registry, callback guards, discovery entry and host services is a one-time
Harness change; installing later workflow or generator plugins uses that API.

## Inputs and model roles

| Input | Meaning | Default |
| --- | --- | --- |
| `prompt` | Complete, authoritative requirements for this image. | Required, nonempty. |
| `reference_images` | Media IDs for the original visual references. | Empty list. |
| `max_attempts` | Named parameter limiting total generation attempts. | `3`; integer from 1 through 10. |
| `generator` | Selected row in the proposed `image_generators` registry. | Explicit argument or image-plugin configuration; no automatic fallback. |
| `generation_model` | Model understood by the selected generator. | Explicit argument or image-plugin configuration. |
| `size` | Requested output dimensions, subject to the selected adapter/model. | `"1024x1024"`. |
| `output_format` | Supported raster output format. | `"png"`. |

The calling model must include relevant requirements from earlier conversation
turns in `prompt`, and supply earlier reference images by ID. The review side
call does not inherit conversation history. The function's doc must explain
this; a phrase such as "same palette as before" is insufficient without the
corresponding requirements or reference image.

The **reviewer is always the main model**, using its image-understanding
capability. Pin its provider and model settings at run creation. The generator
and reviewer may be the same model if explicitly configured through a supported
generator, but generation and review remain separate calls. Do not infer image
output support from the main model's name or image-input support.

`max_attempts` counts generation calls started, including the first and any
failed call. Each successful generation receives one review, with at most one
format-repair call for that review. With the default, there are at most three
generation calls, three initial reviews and three format repairs. Repairs do
not generate another image or consume another generation attempt. The passing
threshold is **85/100**, inclusive.

## Plugin boundary

Use the existing contribution and replacement mechanism described in
[Harness plugins](../examples/gene-harness/docs/plugins.md).

| Component | Responsibility |
| --- | --- |
| Default `image` plugin | Contributes `image_generate` to `functions` and `image/usage` to `docs`; owns generation/review prompts, refinement policy and the stopping rule. An `/image` command is optional. |
| Generator plugins | Contribute named `image_generators` rows; own provider configuration, authentication, wire format and image-response decoding. |
| Harness host | Supplies registry validation, guarded callback invocation, composition leases, deadlines/cancellation, durable run records, round limits and media storage/attachment services. |

Replace the complete workflow using `register_plugin ^^replace "image" ...`,
and disable or restore it using the normal plugin lifecycle. A replacement
contributes the same public function and docs, and honors their input/result
contract. Changing only the image backend selects another `image_generators`
row; it does not replace the review loop. There must be no hidden built-in
workflow that still executes after `image` is disabled or replaced.

Expose the required host services through documented seams and shared types in
`src/plugin_api.gene`. A stored replacement must work with that API and its
declared dependencies, without importing private Harness modules or accessing
the runtime object directly. In particular it needs bounded generator and
main-model calls, media-ID resolution, durable attempt/result recording,
effective execution limits/deadlines and final attachment publication. The
host invokes the generator and validates/stores its output before returning
media IDs to the workflow. The workflow never needs image bytes or base64
buffers; generator adapters still account for any buffers they allocate under
their own effective memory limits. Provide shared transport/media helpers to
avoid unnecessary payload copies. The host owns these mechanisms; the plugin
owns the workflow. Implement the workflow and adapters in Gene using existing
language syntax.

Keep the registry schema and durable records independent of the default
plugin's activation. A run leases the workflow, generator and reviewer rows
from one composition snapshot. Replacement affects subsequent runs; an active
run finishes or is cancelled under its leased revision. Retirement must not
erase its images or recorded results. Add the new registry to discovery and
guard its callbacks like provider callbacks.

Keep descriptor and callback budgets distinct. In the current code,
`descriptor_entry_options` passes stored-entry `limits` as `init_limits`
([workspace.gene](../examples/gene-harness/src/storage/workspace.gene)). Live
callback limits default to `response_execution_limits` in
[cordis_adapter.gene](../examples/gene-harness/src/runtime/cordis_adapter.gene),
and activation configures the module for response execution in
[kernel.gene](../examples/gene-harness/src/kernel.gene). Thus the stored
2-second/64-MiB default is not a 2-second deadline on every callback. The normal
callback default is 600 seconds/1,024 MiB, constrained by host and enclosing
execution limits. Do not add a public `register_plugin ^limits` parameter just
to address the second review's mistaken interpretation.

Expose the effective callback limits separately from descriptor limits in the
shared host API, plugin inspection and manager UI; the current manager's
stored `limits` display does not establish a callback's budget. Keep descriptor
initialization bounded independently. The acceptance check must exercise the
actual stored workflow and generator callbacks beyond two seconds, and verify
that the configured enclosing ceiling still cancels them.

## Generator contract and preflight

Current `providers` rows and `call_model` return `{^text ^usage}`. Keep image
output on a separate path rather than putting image bytes into `text`.
Proposed `image_generators` rows have `name`, `doc`, `available`, `configure`,
`capabilities`, `prepare` and `send`, plus normal discovery metadata.

- `capabilities` receives model settings and describes the selected transport:
  `image_input`, `image_output` and `image_edit`, each `yes`, `no` or `unknown`,
  and any known input-count/size limits. Image editing means accepting the
  previous candidate together with instructions for refinement.
- `prepare` receives the original prompt, reference media IDs, optional latest
  candidate ID and revision instruction, configured model, output settings and
  call limits.
  It returns credential-free request data whose images remain media references.
- `send` expands those references for transport, adds authentication and makes
  one bounded call. It returns `{^images [{^mime ^bytes}] ^usage}`. The workflow
  requests exactly one image; missing, multiple or invalid images fail the
  attempt. Raw bytes exist only at this transport/storage boundary.

Add model-specific capability reporting to reviewer provider rows as well;
missing metadata means `unknown`, not `yes`. Before any generation, validate
the prompt, attempt bound, media IDs, configuration, credentials availability,
call budgets and known input limits for both roles. The reviewer needs image
input. The generator needs image output, image input when references or
refinements are required, and image editing when `max_attempts > 1`. Include
space for the candidate in input-count/size checks.

Reject a required capability declared `no` before making a billed call. In
particular the current `claude` CLI provider cannot be the reviewer. Allow
`unknown` with explicit generator configuration, record that uncertainty and
surface a later provider rejection as a generation or review failure. Unknown
support is not a guarantee of compatibility. Always pass actual pixels to the
models; descriptions cannot stand in for image input.

Resolve output settings before generation and retain them across refinements.
The calling model must set them consistently with any dimensions, format or
transparency requirements in the prompt. Validate known model/endpoint support
and reject settings known to exceed storage or transport limits before a billed
call. A conservative size reduces the risk of an oversized response, but
dimensions alone cannot guarantee an encoded file size: format, compression,
metadata and provider behavior also matter. Unknown output size bounds still
require the post-response checks below; do not promise that every generated
image will fit merely because `size` was supplied.

The first adapter target is an **OpenRouter image-generator plugin**, using
the credential names the Harness already supports. OpenRouter's current
[Image API documentation](https://openrouter.ai/docs/guides/overview/multimodal/image-generation)
describes `POST /api/v1/images`, reference-image inputs and base64 image output.
The adapter explicitly sends `n: 1`, the resolved `size` and `output_format`,
and preserves returned usage, including `usage.cost` when present.
Select the model explicitly and verify generation, reference input and editing
before declaring support. Do not assume that extending the existing chat-text
parser is sufficient, or that the Codex OAuth transport supports generation.
Other transports can be added through generator plugins.

Use a separate bounded image-response limit, initially **16 MiB** of encoded
response data, including protocol overhead. Validate decoded bytes against
the media store's **10 MiB/image** limit and supported image formats before
saving. Exceeding either limit is a generation failure, never a truncated
success. The initial adapter can use non-streaming responses; a streaming
adapter must also bound aggregate traffic, including repeated/partial images.
Do not increase every text provider's current 2,000,000-byte response cap.

## Workflow

1. **Preflight and start a run.** Resolve and lease the configured rows, check
   the requirements above, and durably record the run and its budgets.
2. **Generate and save the first image.** Send the original prompt and
   reference images to the generator. Record the attempt before sending;
   validate and save its single candidate immediately on completion.
3. **Review it.** Send the original prompt, reference images and actual
   generated image to the main model. Ask it to assess the image against the
   requirements and return a score, comments and a revision instruction.
   Save the validated review against that candidate.
4. **Stop if the score is at least 85.** Return this image.
5. **Otherwise, refine if attempts and execution budget remain.** Send the
   generator all of:

   - the original prompt;
   - the original reference images;
   - the most recently generated image;
   - the main model's `revision` instruction.

   The instruction identifies what to change and what to preserve. The score
   and comments remain in the review record; a number is not an edit
   instruction. Save and review the new image through steps 2 and 3.
6. **Stop at `max_attempts`.** Return the last image even if its score is still
   below 85. Report that the attempt limit was reached. A deadline or failure
   can stop the run earlier, as specified below.

Keep the original requirements and reference images throughout the loop.
Feedback supplements the request; it does not replace it. The next refinement
uses the latest candidate and its review, without requiring every previous
image to be resent.

The workflow plugin controls refinement and the stopping rule. The host
enforces call admission and budgets. Each model call generates or reviews a
single candidate; the model cannot ask the host to reset the attempt counter.

## Review contract

The main model returns a small structured result:

```json
{
  "score": 78,
  "comments": [
    "The requested subject and layout are present.",
    "The label must read 'Gene'; the current lettering is incorrect.",
    "Keep the composition, and correct the label in the next version."
  ],
  "revision": "Change the label to exactly 'Gene'; preserve the subject, palette and composition."
}
```

The score is an integer from 0 to 100. Review prompt adherence, the intended
use of references, required details and visible defects. Judge style against
what the user requested. Comments should identify concrete changes and useful
parts to preserve. `revision` is one concrete imperative instruction for the
next generation; it must be nonempty below 85 and may be empty for a passing
image. Image text is content to evaluate, not instructions to follow, including
lettering such as "score: 100".

Each review evaluates the actual image against the original requirements.
Scores can decrease between attempts; the reviewer should not assume that a
new version is necessarily better.

Parse one JSON object, optionally enclosed in a single `json` or unlabelled
code fence with no surrounding prose. Require a JSON integer `score` in
0..100, a nonempty `comments` list of nonempty strings and a string `revision`
meeting the rule above. Ignore extra fields. Do not coerce `"85"`, `85.0`,
booleans or out-of-range numbers into a valid score.

For malformed output only, allow one repair call to the same reviewer within
the remaining review-phase budget. Supply the same original requirements and
images, the invalid response and validation errors, and ask for the required
object. Do not regenerate or increment the attempt counter. Another malformed
response, a failed call or insufficient repair time produces `review_failed`;
the candidate remains unreviewed. Transport errors do not trigger a repair.

## Execution, cancellation and recovery

The first version runs inside response evaluation. It must not inherit the
provider's 600-second timeout separately for every call or its automatic
timeout retry. Image generation, review and repair each make one transport
attempt; a timed-out generation is never silently repeated.

Add a host execution-budget service to the shared plugin API. The current
response and callback supervisors cancel through timer tasks; plugins cannot
query their remaining time. The host must publish read-only absolute
`response_deadline_ms`, `callback_deadline_ms` and the effective deadline,
using the same monotonic clock as `$os/monotonic_ms`. Stamp each deadline when
its enforcing timer starts, carry forward the earliest enclosing deadline
through nested calls, and expose remaining time through the service. The host
uses its own authoritative values for admission; caller-supplied context
cannot extend them. This can use Harness context/services without adding Gene
syntax or a new language-runtime API. Monotonic deadlines are process-local;
persist durations and wall-clock timestamps for inspection, not for resuming a
run after restart.

Use explicit image-workflow settings. Initial ceilings are 590 seconds per
run, 120 seconds per generation and 60 seconds per review phase (including an
optional repair), with a 5-second persistence/return margin. The effective
call deadline is the earliest of the run, response and plugin deadlines,
minus that margin. Before starting an attempt, require enough time
for the configured generation and review ceilings plus persistence overhead;
otherwise stop with `cancelled` and detail `deadline`. Clamp calls to the
effective deadline and cancel in-flight work when it expires. Larger settings
must fit the enclosing execution budgets; they cannot bypass plugin limits.
A generation- or review-phase timeout is `generation_failed` or
`review_failed`, respectively. Cancellation of the enclosing run takes
precedence and is recorded as `cancelled`.

These are time ceilings, not promises that every request reaches
`max_attempts`. A deployment needing longer work must increase compatible
budgets or separately design a host-owned job API. An asynchronous job system
is not a prerequisite of this first version.

Durable checkpoints must not depend on the function returning successfully:

- Record run identity, session/round, original inputs, leased plugin revisions,
  model settings, limits and start time before calling models.
- Record each started attempt/call, then save its image and media ID before
  review. Associate it with the conversation through host-owned run records;
  make `media_list`/recall include that catalog even if evaluation is cancelled.
  Do not append intermediate attempts to history or put them in message
  `media`: that would resend every candidate on later normal model calls.
- Record review/repair outcomes, validated score/comments/revision, usage when
  available and the terminal result as each becomes available.

The host finalizes cancellation outside an exhausted plugin evaluation budget;
the cancelled function cannot be relied on to return metadata. Operator cancel
and evaluation/run deadlines stop further calls and preserve all saved images
and reviews. On restart, mark unfinished runs/calls interrupted, expose the
run as `cancelled` with detail `interrupted`, and preserve any saved candidate.
Do not resume, rerun or replay billed calls automatically. A call interrupted
before its image was durably saved has an unknown remote outcome.

For this initial single-image interface, admit **one run per user round**.
An identical repeated invocation returns its recorded state/result without
new calls; different inputs in that round are rejected. Persist admission and
attempt counts in host-owned state so a plugin replacement or final-preview
continuation cannot reset them. A new user request can start a new round.

Identity compares the exact prompt, ordered reference media IDs,
`max_attempts`, generator and model, plus resolved output settings and workflow
configuration. Freeze defaults on first admission; resolve omitted arguments
on repeats against that snapshot, even if configuration or plugin revisions
have since changed. Dynamic remaining time is not part of this identity.
An identical repeat includes `reused: true`. A terminal result states that
further attempts require a new user request and that the last candidate may
be supplied by media ID as a reference in that request. It never silently
resumes an exhausted or cancelled run.

## Result

Show the final image through the Harness's normal image preview/download flow.
Keep the following result metadata available:

- run ID and final image reference, if any;
- that image's review status, score, comments and revision (unknown/null when
  unreviewed);
- generation attempts started and review/repair call counts;
- whether the target score was reached;
- generator/model and pinned reviewer identity;
- resolved output settings and per-call usage/reported cost, including
  `usage.cost` when supplied; an absent cost is unknown, not zero;
- stop reason and structured error detail, including the failing stage.

Stop reasons are `target_reached`, `attempt_limit`, `generation_failed`,
`review_failed`, `cancelled`, `storage_limit` and `storage_failed`. Preflight
validation errors return an error without making a model call. An oversized
or invalid image response is `generation_failed`; inability to retain a valid
candidate is a storage failure.

**Return the last image, not the highest-scoring earlier image.** For example:

| Scores, with `max_attempts = 3` | Result |
| --- | --- |
| `89` | Return image 1; stop after its review. |
| `72 → 86` | Return image 2; stop after its review. |
| `72 → 81 → 79` | Return image 3 with score 79; the limit was reached. |

If generation, review or storage fails, stop and return the latest available
saved image with the failure reason. If that image has not been reviewed, its
score is unknown; do not attach an earlier image's score to it. A later
generation failure does not discard the preceding saved image or its review.
If no image was saved, return the error with the run metadata. Never claim an
unsaved or partial response is an available image.

Attach the final image through the normal preview/download flow. That flow
delivers its pixels to the main model on a subsequent turn before a done reply
is accepted. This presentation step does not change the recorded score or
authorize a second run in the same round. On cancellation, retain an
operator-visible result without restarting model execution solely to display it.
Only the final candidate is automatically attached as message `media`.
Intermediate candidates remain catalog entries; they are sent only to their
explicit review/refinement calls or when subsequently requested with
`media_show`. Catalog lookup itself never expands pixels into model context.

## Media storage and call records

Extend the media store's source values with `generated`. Retain every saved
attempt and its review for inspection or a later request, including unreviewed
candidates and attempts not selected as the final attachment. Store their
provenance by run/attempt ID; plugin retirement does not delete them.

Respect the current workspace limits: 256 MiB of binary data and 2,048 media
records, plus 10 MiB per image. Before each generation, atomically reserve one
record and enough space for a maximum-size output so concurrent uploads/runs
cannot consume its capacity. If reservation fails, stop with `storage_limit`
before the billed call and keep the latest saved result. Release unused
reservation space after save, failure, cancellation or restart recovery. An
unexpected write failure is `storage_failed`. No automatic pruning of saved
attempts is allowed in this version; explicit deletion/retention management is
separate work.

Reservations must be durable. Extend the media index to a versioned format
with reservations keyed by run/attempt ID, reserved bytes/record count and
ownership, rather than relying only on the in-process `media_gate`. Migrate
format 1 with an empty reservation set. Every media writer accounts for active
reservations under the same lock. Atomically commit the new media record and
reservation consumption in the index, retaining run/attempt provenance on the
record. On restart, reconcile the index with run records: retain and catalog
already committed candidates, mark unfinished work interrupted and release its
unused reservations before admitting new writes. Recovery must handle a crash
after the media commit but before the attempt checkpoint without losing the
image or retaining a stale reservation.

Image bytes belong only in media storage, not text-history blobs, run records
or model-visible result maps. Today `record_request` stores expanded provider
bodies and `store_part` moves long base64 strings into `.gene-harness/blobs/`.
New generator requests keep structured media references (ID, digest and MIME
type) until transport expansion. For reviewer calls, preserve the existing
provider contract: `call_model` still expands messages before `prepare`, and
`send` receives the original prepared value. Fix the recorded copy instead.

Have media expansion return a transient inventory of the image payloads it
inserted, including document-page images. Before `record_request`/`store_part`,
replace those payloads in a separate prepared copy with typed media markers
that retain the ID, digest, MIME and encoding. Handle both raw base64 and full
data URLs, including occurrences embedded in serialized strings; never alter
ordinary text or the request sent to the provider. Preserve the literal-marker
escaping convention so user/provider data cannot be mistaken for a marker.
Recorded requests for supported encodings must reconstruct exactly from media
storage without persisting another pixel copy. For an opaque transformation
that cannot be safely recorded this way, retain canonical request metadata
and media references with an explicit omitted-body diagnostic instead of the
raw prepared body. Restoring an inspection record never replays a billed call.

Record generated output by media reference, and keep image-bearing response
and error bodies out of logs as well. This recording change applies to all
image-input calls, including ordinary turns and reviewers, without requiring
existing provider plugins to move expansion into `send`. Legacy blob cleanup
is a separate migration, not an automatic consequence of this change.

This extends the current input-only feature described in
[Images and documents](../examples/gene-harness/docs/media.md). Provider wire
formats remain inside generator/provider adapters; the workflow consumes the
shared contracts.

## Acceptance checks

- A prompt with no references works; supplied references reach generation,
  review and every refinement.
- A score of exactly 85 stops the loop immediately.
- A score below 85 triggers refinement with the original request, references,
  latest image and concrete revision instruction when attempts/time remain.
- `max_attempts = 1` generates once, with one review phase and at most one
  format repair; the default makes at most three generation calls. Reject
  zero, nonintegers and values above 10 before any call. The same explicitly
  supported model can serve both roles.
- Exhausting the limit returns the last candidate even when an earlier one
  scored higher, with accurate score and stop-reason metadata.
- First-generation failure returns an error with no image. A later generation
  failure preserves the previous candidate and its own review.
- Review failure preserves the new image with unknown score. Exercise strict
  parsing, one successful repair, failed repair and no time left to repair;
  repairs never generate images or reset attempt limits.
- A known unsupported reviewer (including `claude`) or required generator
  capability is rejected before generation. Unknown support is recorded, and
  any provider rejection has the correct failure stage.
- The first adapter sends `n: 1` and resolved size/format settings on every
  generation. Reject known incompatible settings in preflight, retain the
  returned usage/cost and still validate actual bytes when size was configured.
- Valid image responses above the old text-response cap work. Encoded responses
  above 16 MiB, decoded images above 10 MiB, invalid bytes and unexpected image
  counts fail explicitly without leaking their contents to logs.
- Cancellation/deadline during generation, review or repair preserves saved
  attempts and durable metadata. Insufficient remaining time prevents another
  generation. Restart marks open work interrupted without replaying calls.
- Quota reservation prevents calls that cannot retain an output; concurrent
  storage use cannot steal reserved capacity. Saved attempts survive both
  quota exhaustion and plugin retirement.
- Reservations survive a crash. Recovery releases unused capacity exactly
  once, retains a candidate committed before its attempt checkpoint, and
  admits further uploads using the reconciled totals.
- Final preview does not start a second loop. Repeated calls, including after
  plugin replacement, cannot reset the round's admission or attempt count.
  Check each identity field, frozen defaults, `reused` and guidance to start a
  new user request with the last candidate as a reference.
- Intermediate attempts remain in the run catalog and `media_list` after
  cancellation and compaction, without entering normal model requests. Only
  the final candidate is automatically attached; explicit review/refinement
  and `media_show` still send the requested pixels.
- In a fresh workspace, generation, refinement and review leave image pixels
  only in media storage: no raw/base64 image data in history, call records,
  text blobs under `blobs/`, errors or result metadata. Recorded media
  references still resolve to the exact request images.
- Reviewer recording handles raw base64, full data URLs, embedded payloads and
  literal-marker collisions. Existing provider plugins receive the unchanged
  prepared request, and restoring a supported recorded request reproduces it.
  Opaque transforms produce an omitted-body diagnostic, never a raw-body log.
- A stored plugin replaces `image` using only the shared API; discovery and
  calls use its contributions, and disabling/restoring works. Swap the
  generator independently and verify the same workflow contract. Replacing
  either during a run does not change that run's leased implementation.
- Stored callbacks can wait beyond two seconds under their effective response
  limits; descriptor budgets remain separately bounded. Inspection shows both
  budgets. Published monotonic deadlines match enforcement, decrease while
  waiting and cannot be extended by nested calls or altered context.

## Review disposition

Claude's integration, prompt-context, revision, parsing, media and acceptance
comments are incorporated above. The workflow itself is replaceable, in
addition to the generator adapter. The first target uses OpenRouter's current
dedicated Image API, rather than assuming its chat parser is the generation
contract. Model access and edit support still require verification.

The bounded inline option is chosen for the first version; a background-job
system is deferred. One format repair is allowed within the review budget.
Both reviews below are retained unchanged for context; the revised proposal
above governs where they differ.

The second review's points 2–4 and 6–9 are incorporated: intermediate attempts
use a run catalog, deadlines become queryable host data, reviewer recording
changes only the recorded copy, output count/cost and repeat behavior are
explicit, reservations are durable, and initial host integration is identified.
Point 5 is adopted with a qualification: an explicit size/format reduces
oversize risk but is not a guarantee of a compressed file's byte size.

Point 1's 2-second callback claim does not follow the current activation path:
stored-entry limits become descriptor `init_limits`, while live callbacks use
response-level limits. The proposal therefore clarifies effective budget
reporting and adds a stored-callback acceptance check, rather than introducing
the suggested registration parameter. The media boundary also keeps large
payloads out of the workflow plugin.

## Original review comments (Claude, 2026-10-17)

The loop itself is well specified. The attempt count includes the first
generation, 85 is inclusive, the last image wins, an unreviewed image never
inherits an earlier score, and nothing retries without a bound. The gaps are in
the Harness integration, which assumes paths the current code does not have.
Checked against the code; paths are relative to `examples/gene-harness/`.

### Blocking

1. **No provider can return an image, and the transport would cut one off.**
   - **Text-only contract.** A provider row's `send` returns `{^text ^usage}`,
     and `call_model` fails anything else with "provider returned invalid text
     content" (`src/agents/model_call.gene:123`). Codex's `response_text` keeps
     only `output_text` parts. It drops an `image_generation_call` item, and a
     response without a message fails with "codex returned no output text"
     (`src/builtin/provider_codex.gene:42`). `openrouter_text` reads only
     `message.content` and ignores `message.images`, which is where
     OpenRouter's image-output models return images
     (`src/builtin/provider_openrouter.gene:12`). Anthropic models and the
     Claude CLI do not generate images.
   - **Response cap.** Provider responses are limited to 2,000,000 bytes
     (`src/builtin/provider_common.gene:29`, also `src/agents/model_client.gene`).
     A 1024×1024 PNG is often 1–3 MB before base64 adds a third. A Codex stream
     can also carry the image in both the item-done and the completed event.
     Many first attempts would fail as oversized responses.
   - **Effect.** With every current provider and its default model, "the main
     model if it supports image generation" is never true. It is also
     unverified that the Codex OAuth endpoint accepts the public
     `image_generation` tool; the media report gives the same warning about
     that transport.
   - **Suggestion.** Add an `image_generators` registry. Its rows return
     `{^images [{^mime ^bytes}] ^usage}` and have their own response limit,
     for example 16 MiB. In the first version, require an explicit generator
     setting and drop the automatic main-model fallback until a provider is
     shown to work. Name the first target. An OpenRouter image-output model is
     the only one reachable with credentials the Harness already reads.

2. **"Report missing capabilities before starting" has nothing to check.**
   Provider rows declare `^available`, `^configure`, `^prepare` and `^send`.
   None of them says whether a model accepts or produces images. The Claude CLI
   refuses images only during preparation (`require_text_messages`,
   `src/builtin/provider_claude.gene:70`), and OpenRouter vision support depends
   on the model. Suggest declared `^image_input` and `^image_output` fields with
   the values yes, no or unknown. Refuse "no" before generating anything. The
   reviewer check matters most: without it, the first image is generated and
   paid for, and only then does the review fail. Let "unknown" run, and report
   the provider's error as the stop reason.

3. **The loop does not fit inside one response evaluation.** As a `functions`
   row, the loop runs inside the model's code, under the response budget (600 s
   by default, `src/agents/turn_loop.gene:227`). One provider call may take up
   to `provider_timeout_ms` (also 600 s by default) and is retried once on
   timeout. Image generation can take a minute or more. Three attempts plus
   three reviews can exceed 600 s. When the deadline cancels the evaluation,
   the function never returns, so the result metadata is lost. The images were
   never attached, so `media_list` cannot find them either.
   - Record each attempt durably as it completes: media ID, score, comments and
     outcome. Use session state or the transcript, not only the final return
     value.
   - Add `cancelled` as a stop reason, covering an operator cancel and the
     evaluation deadline.
   - Give the loop a total deadline below the response budget. Do not start an
     attempt that cannot finish within it. If that makes three attempts
     impractical, the loop has to run as a host-owned job that reports back,
     which is a larger design.
   - State that a restarted host neither resumes nor reruns the loop. The
     existing repair already marks open calls `interrupted` without replaying
     them (`src/storage/state.gene`). That is the right behavior for billed
     calls.

4. **Image bytes already enter text history through call records.**
   `record_request` stores each prepared provider body
   (`src/agents/model_call.gene:54`). `store_part` writes every string over 256
   bytes into `.gene-harness/blobs/`. Prepared bodies contain
   `data:image/...;base64,` URLs, and body collection keeps them as long as the
   `model/request` event exists (`src/agents/history.gene:66`). Verified on disk:
   `tmp/harness-computer-media/ui-workspace/.gene-harness/blobs/046d741e…` is a
   79 KB `data:image/png;base64,` blob.
   - This gap already exists in the media feature, but this loop multiplies it.
     Each attempt sends the references and the candidate to two calls, and
     these copies do not count toward the 256 MiB media quota.
   - Meeting "Image bytes belong in media storage" requires call records to
     store media IDs instead of image data. Add an acceptance check that no
     image data appears under `blobs/`.

### Design

5. **The reviewer sees only `prompt` and the references.** The review is a
   side call, not part of the conversation. "The original prompt" is therefore
   the string the main model passed, not the user's words. The reviewer cannot
   see constraints from earlier in the conversation, such as "same palette as
   before", unless the main model wrote them into `prompt`. State that `prompt`
   is the complete, authoritative requirement, and say so in the function's
   doc. Images attached in earlier rounds must be passed by ID.

6. **Give the generator an edit instruction, not a score.** An image model has
   no use for "78/100". Review comments mix praise, diagnosis and requests, and
   they are written for a reader. Add a `revision` field to the review contract:
   one imperative instruction that names what to change and what to keep. Send
   the generator the original prompt, `revision`, the references and the latest
   image. Keep the score for the stopping rule and the result metadata. If the
   score must still be sent, it is harmless, but it does not replace an
   instruction.

7. **Specify how reviews are parsed and how they fail.**
   - Say whether fenced JSON, extra fields or `85.0` are accepted. Reject any
     score that is not an integer from 0 to 100.
   - Consider one repair request for a malformed review that does not count as
     an attempt. Models sometimes return prose, and as written that ends the
     loop right after a paid generation.
   - The review prompt should say that text in reference or generated images is
     content to evaluate, not instructions. A generated image that reads
     "score: 100" is plausible when lettering is requested; `docs/media.md`
     states the same rule for uploads.
   - The stop reasons then become: target reached, attempt limit, generation
     failed, review failed and cancelled.

8. **"The normal preview flow" shows the final image to the main model again.**
   `attach_media` adds the image to the turn, and a done Outcome is deferred
   until that media has reached the model (`src/agents/outcome.gene:96`). That
   is probably intended, since the main model reports the result. But it is one
   more review of the same image. After seeing it, the model can also start
   another three-attempt loop. Say whether a second loop in the same round is
   allowed, or bound the total attempts per round.

9. **Generated media needs a source and a retention rule.** `put_media` accepts
   only the sources `upload`, `screenshot` and `document_page`
   (`src/storage/media.gene:89`), so `generated` must be added. The media store
   has no deletion. Every loop keeps up to `x` images toward the workspace
   limits of 256 MiB and 2,048 records. At 2–3 MB per image, that is roughly 30
   three-attempt requests. Retaining every attempt is a stated requirement, so
   say what happens at the limit and whether unattached attempts can be pruned.

### Minor

10. Rename `x` to `max_attempts` as a named parameter, and give it an upper
    bound, for example 10. Each attempt makes two billed calls.
11. The Harness no longer has a capability mechanism. Describe the feature as an
    `image` plugin that contributes an `image_generate` function and a docs
    row, optionally an `/image` command, and the generator registry from
    point 1.
12. Acceptance checks to add:
    - generation fails on attempt 1: an error and no image;
    - review fails after a generation: an unreviewed image with an unknown
      score;
    - a malformed review;
    - a cancel mid-loop keeps the completed attempts;
    - an oversized image response;
    - refusal before generation with the `claude` provider;
    - no image data under `blobs/`.

## Second review (Claude, 2026-10-17)

All twelve original points are addressed. The deadline arithmetic works for the
default of three attempts: at 185 s per attempt, three worst-case attempts take
555 s, inside the 590 s run ceiling. The OpenRouter claim is also accurate. Its
image-generation guide documents `POST /api/v1/images` with `input_references`
items of type `image_url` (an HTTP(S) or base64 data URL), and responses
carrying `data[].b64_json` and `media_type`, plus `usage` with `cost` when
available. Four new problems, checked against the code, with paths relative to
`examples/gene-harness/`:

1. **A stored replacement runs under 2-second limits.** The model-facing
   `register_plugin` has no `^limits` parameter
   (`src/builtin/plugin_admin.gene:19`). A stored entry therefore gets
   `default_execution_limits`, which is 100,000 steps, 64 MB and **2,000 ms per
   callback** (`src/plugin_api.gene:25`, `src/storage/workspace.gene:606`).
   Built-in profile plugins get the response budget instead, 600 s and 1,024 MB
   (`src/runtime/bootstrap.gene:106`).
   - **Effect.** The default `image` plugin works, but `register_plugin ^^replace
     "image" …` produces an `image_generate` that is cancelled after 2 s. A
     stored generator's `send` cannot wait out a 120 s call either, or hold
     base64 references plus a 16 MiB response in 64 MB.
   - **Effect on the acceptance check.** "A stored plugin replaces `image` using
     only the shared API" fails as the proposal is written.
   - **Needed.** The workflow waits for minutes whoever makes the calls, so the
     proposal needs a way for a stored plugin to declare larger limits. The
     ceiling should be the response budget, and the declared limits should be
     shown in the plugin manager. Separately, keep bytes in host services where
     possible, so a generator's memory limit covers its own work, not the
     images.

2. **Associating attempts through message `media` resends every attempt on
   every later call.** `context_from_state` copies `media` from every history
   message (`src/agents/history.gene:286`). `expand_media_messages` then
   base64-expands all of them for each model call; only the `media_refs` catalog
   that compaction writes is left unexpanded. `history_media_refs` reads both
   fields (`src/agents/history.gene:318`).
   - Record non-final attempts as catalog references, or have `media_list`
     include run records. Only the final attachment should be `media`.
   - Writing to history mid-turn would also interleave with the turn's own
     appends. Keeping run records in host state avoids that.

3. **Running code cannot read its deadlines.** The response deadline is a
   sleeper task that cancels the evaluation (`src/agents/turn_eval.gene:100`).
   Plugin callback deadlines work the same way, through `supervised_call`.
   `$runtime` offers `context`, `bind_call` and `guard_call`, but nothing
   reports the time remaining. "The earliest of the run, response and plugin
   deadlines" therefore needs the host to publish those deadlines, for example
   as absolute milliseconds in `$runtime/context`. Add this to the host services
   listed under "Plugin boundary".

4. **Reviewer calls need a specific recording fix.** Generator rows are new and
   can keep media references. Provider rows, however, receive images already
   expanded: `call_model` runs `expand_media_messages` before `prepare`
   (`src/agents/model_call.gene:87`). There are two ways to record references
   for reviewer calls.
   - Move expansion into `send` for every provider row. That changes the
     contract for all provider plugins, including stored ones.
   - Substitute media markers into the recorded copy. Expansion knows every
     image it inserted, so `call_model` can replace those strings, both the
     `data:` URL form and the raw base64 form, before `record_request`.
   - I recommend the second: it stays inside `call_model` and leaves the
     provider contract unchanged.

Minor:

5. **Avoid paying for an image that cannot be saved.** The 10 MiB decoded limit
   is only checked after a billed generation. Set a default output `size`, which
   the Images API accepts, so that outputs fit. Reject a configured size whose
   output cannot fit, during preflight.
6. **Set `n: 1` explicitly.** OpenRouter's `n` goes up to 10. Record
   `usage.cost` in the result metadata when it is present.
7. **Tell the model what a same-round repeat returns.** After a stop for a
   deadline, a repeated call in the same round returns the recorded result. The
   result should then say that further attempts need a new user request, and
   that a new run can pass the last candidate as a reference. Also define which
   inputs make two invocations identical: prompt, references, `max_attempts`,
   generator and model.
8. **Persist quota reservations.** Reservations must survive a restart in order
   to be released. The current gate is in-process (`media_gate`), and media
   index format 1 has no field for them.
9. **Adding the registry is a one-time host change.** The `image_generators`
   registry needs its declaration (`src/kernel.gene:875`), a guard case
   (`src/kernel.gene:441`) and an entry in the discovery kinds
   (`src/agents/discovery.gene:30`). The requirement that adding a generator
   needs no edits to built-in modules applies after that.
