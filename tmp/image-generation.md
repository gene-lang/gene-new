# Image generation with review

Status: implemented PNG-only MVP (2026-10-17). The default workflow and
OpenRouter generator are separate plugins backed by shared host services.
The [usage guide](../examples/gene-harness/docs/image-generation.md) and
[plugin API guide](../examples/gene-harness/docs/plugins.md#image-workflow-and-generator-plugins)
describe the implementation. Transport contracts are tested with fixtures;
no paid OpenRouter generation was performed. The reviews and their dispositions
are preserved in [the review archive](image-generation-comments.md).

## Requirement

Generate an image from a textual prompt and optional reference images. Have the
main model review each result against the request and score it out of 100.
Refine the image while the score is below 85, up to a configurable limit, then
return the last generated image to the user.

**Image generation must be replaceable by a plugin.** Ship a default `image`
plugin for the workflow, with independently selectable generator plugins.
Replacing the workflow or adding a generator must not require editing the turn
loop, conversation UI or built-in provider modules.

The registry, callback guards, discovery entry and host services are shared
Harness infrastructure; later workflow or generator plugins use that API.

## Inputs and model roles

| Input | Meaning | Default |
| --- | --- | --- |
| `prompt` | Complete, authoritative requirements for this image. | Required, nonempty. |
| `reference_images` | Media IDs for the original visual references. | Empty list. |
| `max_attempts` | Named parameter limiting total generation attempts. | `3`; integer from 1 through 10. |
| `generator` | Selected row in the `image_generators` registry. | Explicit argument or image-plugin configuration; no automatic fallback. |
| `generation_model` | Model understood by the selected generator. | Explicit argument or image-plugin configuration. |
| `size` | Requested output dimensions, subject to the selected adapter/model. | `"1024x1024"`. |
| `background` | Background mode: `auto`, `transparent` or `opaque`. | `"auto"`. |

Generated images are always **PNG** in this version; there is no format input.
PNG avoids additional lossy encoding when images are stored and reused, and
supports transparency. Generation/refinement can still alter image quality or
lettering, and the default dimensions do not guarantee a file will fit the
byte limits. Other output formats are a later enhancement.

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
main-model calls, media-ID resolution, image metadata/alpha inspection,
durable attempt/result recording, operator progress, effective execution
limits/deadlines and final attachment publication. The host invokes the
generator and validates/stores its output before returning
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

Keep descriptor and callback budgets distinct. `descriptor_entry_options`
passes stored-entry `limits` as `init_limits`
([workspace.gene](../examples/gene-harness/src/storage/workspace.gene)); the
2-second/64-MiB default bounds descriptor initialization. Live callbacks inherit
the configured host response budget, as profile plugins do. The same policy
applies to Cordis invocation and owned-module configuration in
[cordis_adapter.gene](../examples/gene-harness/src/runtime/cordis_adapter.gene)
and [kernel.gene](../examples/gene-harness/src/kernel.gene).

This applies to stored workflows, generators and reviewers. The standard
configuration gives callbacks 600 seconds/1,024 MiB, narrowed by enclosing
limits. Larger or smaller host budgets must take effect consistently across
built-in and stored implementations; descriptor initialization retains its
independent budget.

Expose the effective callback limits separately from descriptor limits in the
shared host API, plugin inspection and manager UI. A stored descriptor's
`limits` do not establish a callback's budget. Keep descriptor
initialization bounded independently. The acceptance check must exercise the
actual stored workflow and generator callbacks beyond two seconds, and verify
that the configured enclosing ceiling still cancels them.

## Generator contract and preflight

Current `providers` rows and `call_model` return `{^text ^usage}`. Keep image
output on a separate path rather than putting image bytes into `text`.
`image_generators` rows have `name`, `doc`, `available`, `configure`,
`capabilities`, `prepare` and `send`, plus normal discovery metadata.

- `capabilities` receives model settings and describes the selected transport:
  `image_input`, `image_output` and `image_edit`, each `yes`, `no` or `unknown`,
  plus known input-count/size limits and supported output settings. Image
  editing means accepting the previous candidate together with instructions
  for refinement.
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
Every generation requests PNG, and only a valid PNG response is accepted;
any other format is `generation_failed`. Verify the actual bytes and store
the accepted candidate as `image/png`; a PNG MIME label or filename cannot
make another format valid. Do not silently transcode an unsupported response.
Validate `background` against its three allowed values. Persist size and
background with the other resolved settings so they participate in
repeated-call identity.

The calling model must set them consistently with any dimensions or
transparency requirements in the prompt. A request that needs another file
format cannot be met in this version; the function's doc says so, and the
calling model reports it instead of generating. Validate known model/endpoint
support and reject settings known to exceed storage or transport limits before
a billed call. A conservative size reduces the risk of an oversized response,
but dimensions alone cannot guarantee an encoded file size: compression,
metadata and provider behavior also matter. Unknown output size bounds still
require the post-response checks below; do not promise that every generated
image will fit merely because `size` was supplied.

The first adapter target is an **OpenRouter image-generator plugin**, using
the credential names the Harness already supports. OpenRouter's current
[Image API documentation](https://openrouter.ai/docs/guides/overview/multimodal/image-generation)
describes `POST /api/v1/images`, reference-image inputs and base64 image output.
The adapter explicitly sends `n: 1`, the resolved `size` and
`output_format: "png"`. Treat PNG format selection as required: where endpoint
metadata is available, route only to endpoints whose `supported_parameters`
support `output_format` and allow the value `png`. Do not assume that a missing
parameter will honor the requested format. Unknown support follows the
unknown-support policy above, and a non-PNG response still fails the attempt.
Use `size` as the sole dimension control; do not also send `resolution` or
`aspect_ratio`. Send a supported `background` setting; `auto` may be omitted
when an endpoint lacks that parameter, while an explicit `transparent` or
`opaque` requirement must be supported. Preserve returned usage, including
`usage.cost` when present.
Select the model explicitly and verify generation, reference input and editing
before declaring support. Do not assume that extending the existing chat-text
parser is sufficient, or that the Codex OAuth transport supports generation.
Other transports can be added through generator plugins.

Use OpenRouter's model modalities and per-endpoint `supported_parameters` to
populate capabilities and validate reference inputs and output settings. Its
[endpoint capability documentation](https://openrouter.ai/docs/guides/overview/multimodal/image-generation#per-endpoint-records)
distinguishes endpoint support from the model-wide union. An absent key in
available endpoint metadata means unsupported, not `unknown`; unavailable
discovery data remains `unknown`. Account for the documented normalization of
`size` into endpoint dimension controls. When metadata is available, restrict
routing and any provider fallback to compatible endpoints; a model-wide union
must not authorize a parameter combination that no eligible endpoint supports.
Discovery failure follows the explicit-configuration/unknown-support policy
above and must not override any already known incompatibility. Record the
selected routing and capability snapshot with the run.

Where provider-level routing is available, enforce it with `provider.only`,
populated from compatible endpoints' `provider_tag` routing identifiers.
The Image API distinguishes these from `provider_slug`, which keys
provider-specific options. Set
`provider.allow_fallbacks` to `false` by default; enable it only within an
explicit compatible allowlist. If a mixed compatible/incompatible route
cannot be constrained (for example, routing identifiers are unavailable),
reject it before generation. During discovery failure, preserve any configured
allowlist, disable fallbacks and record unknown support rather than claiming
automatic parameter filtering. See the documented
[routing controls](https://openrouter.ai/docs/guides/overview/multimodal/image-generation#provider-routing).

Use a separate bounded image-response limit, initially **16 MiB** of encoded
response data, including protocol overhead. Validate decoded bytes against
the media store's **10 MiB/image** limit and the PNG signature and structure
before saving. Exceeding either limit is a generation failure, never a truncated
success. The initial adapter can use non-streaming responses; a streaming
adapter must also bound aggregate traffic, including repeated/partial images.
Do not increase every text provider's current 2,000,000-byte response cap.

Shared `genex/documents/inspect_bytes` measures `width`, `height` and `has_alpha`
from the actual PNG through its reusable PNG inspector. Read bounded,
validated chunks: IHDR for dimensions and
color type, and tRNS for transparency information. Include these facts in the
media descriptor and attempt record. Reject a malformed PNG as
`generation_failed`; a MIME label alone does not establish image validity. See
the [PNG specification](https://www.w3.org/TR/png-3/).

`has_alpha` reports transparency information in the file (an alpha color type
or a tRNS chunk), not whether any decoded pixel is actually transparent.
Record `has_transparent_pixels` as true, false or unknown, with unknown used
when pixels have not been checked.

For `background = transparent`, use the existing `genex/raster` PNG decoder
through the host media service and the Harness's `genex/raster` dependency. Select
`worker_profile ^version 2` and call `decode_png` with that profile. The default
v1 worker does not support `--decode`. Version 2 uses `raster-worker-v2` or the
configured `GENE_RASTER_WORKER_V2` executable.

Build the worker from the repository root with
`gene run src/genex/raster/tools/build.gene`; its native dependencies are Cairo,
libpng and zlib. Preflight must verify the v2 decoder and its dependencies,
not merely that an executable exists. Check this only for transparent
requests; `auto` and `opaque` generation do not require the worker. The current
decoder accepts at most **2048 pixels on each axis**. Reject transparent
requests whose known normalized dimensions exceed that bound before generation,
and validate the actual candidate dimensions again before decoding. Do not
resize the result to evade that bound. See
[the raster package](../src/genex/raster/README.md) and
[decoder implementation](../src/genex/raster/native/worker.cpp).

`decode_png` fully decodes the image and returns RGBA8 pixels. Scan only the
alpha bytes and stop at the first value below 255. Early exit saves scan work;
it does not avoid decoding or guarantee that transparency appears near the
start of the image. A PNG with no transparency information, an entirely opaque
result or a failed decode is `generation_failed`; do not ask the vision model
to guess. Keep the original provider PNG as the candidate, rather than the
decoder's re-encoded copy. Use a private scratch directory and remove decoded
pixels and scratch PNGs on success, failure and cancellation. Inspection and
worker cancellation remain bounded by the generation phase's remaining time
and memory limits. Add an optional `^timeout_ms` to `decode_png`, retaining its
30-second default for existing callers. The host passes the remaining
generation-phase time explicitly so a slow worker can report its own timeout;
the enclosing phase deadline remains authoritative if cancellation wins the
race. A decode timeout is `generation_failed`, unless the enclosing run was
cancelled. Transparent pixels still do not prove that the requested
background was removed correctly; the review assesses the visual requirements
with these facts available.

## Workflow

1. **Preflight and start a run.** Resolve and lease the configured rows, check
   the requirements above, and durably record the run and its budgets.
2. **Generate and save the first image.** Send the original prompt and
   reference images to the generator. Record the attempt before sending;
   validate its image data and metadata, then save its single candidate
   immediately on completion.
3. **Review it.** Send the original prompt, reference images and actual
   generated image, plus its measured dimensions and alpha facts, to the main
   model. Ask it to assess the image against the requirements and return a
   score, comments and a revision instruction.
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

Supply host-inspected image facts alongside the candidate's pixels, including
actual width/height, alpha information and whether transparent pixels were
verified. Keep requested dimensions separate from measured dimensions. The
reviewer uses these facts for file properties and must not infer dimensions
or transparency from a provider's rendered backdrop. Unknown metadata remains
unknown; a valid review cannot turn it into a measured fact.

Request `high` detail for the candidate image in both the initial review and
any format repair, on reviewer transports that support this hint. References
may use `auto` unless fine reference details also require `high`. Extend the
host's media-expansion path to accept validated per-call/per-image detail
overrides instead of always writing `auto`; keep the hint out of the immutable
media record. The existing Responses/chat content adapters already preserve
the detail field, while the Anthropic adapter omits it. Adapters without this
setting still receive the actual image. Retain applied detail hints in the
recorded request so review inputs remain inspectable.

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

The shared `PluginHost:execution_budget` service publishes read-only absolute
`response_deadline_ms`, `callback_deadline_ms` and the effective deadline,
using the same monotonic clock as `$os/monotonic_ms`. Stamp each deadline when
its enforcing timer starts, carry forward the earliest enclosing deadline
through nested calls, and expose remaining time through the service. The host
uses its own authoritative values for admission; caller-supplied context
cannot extend them. The implementation combines authenticated host scopes
with the read-only `$runtime/execution_budget` snapshot of actual VM limits.
This adds introspection without changing Gene syntax or limit enforcement.
Monotonic deadlines are process-local;
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
`max_attempts`. Longer inline runs require compatible host
response/module/callback budgets and adjusted workflow ceilings. Stored
plugins inherit the configured budget, including increases above 600 seconds.
A host-owned job API is separate work; an
asynchronous job system is not a prerequisite of this first version.

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

Stream concise progress through the existing operator console/transcript sink,
exposed through the shared host API. Emit a line when each attempt starts,
when it moves to review/repair, and when it finishes. Include run/attempt
identity, attempt number out of the limit, status and a validated score when
available; otherwise show pending/unknown. For example: `Image attempt 2/3:
reviewed, score 86/100; target reached.` Keep these lines out of model context
and `append_prompt`, and include no pixels or payloads. Use durable attempt
transitions to drive progress so a replacement plugin uses the same path and
an identical repeat does not announce another generation. The host finalizer
publishes the terminal failure/cancellation status even if evaluation cannot
return. Progress delivery does not create another model call or retry.

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
- inspected dimensions, alpha information and transparent-pixel verification
  for the saved candidate;
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
- The first adapter sends `n: 1`, the size, `output_format: "png"` and
  supported background settings on every generation, with no extra dimension
  controls. Routing excludes endpoints known to lack PNG format selection.
  A non-PNG response, including one mislabeled `image/png`, fails the attempt
  without transcoding. Reject known incompatible settings in preflight;
  retain usage and cost and still validate actual bytes when size was
  configured.
- Endpoint metadata drives capability checks. Missing parameter keys are
  unsupported; unavailable discovery is unknown. Known endpoint restrictions
  also constrain fallbacks. Assert the compatible `provider.only` list and
  explicit fallback policy in outgoing requests. Refuse a known incompatible
  route that cannot be constrained. Handle documented size normalization.
- Measured dimensions and alpha facts survive storage and reach review/repair.
  Cover PNG with an alpha color type, PNG with tRNS, opaque PNG and malformed
  chunks. Transparent requests reject a PNG with no transparency information
  and an all-opaque PNG; unknown metadata is never presented as verified
  transparency. A missing, v1-only or unusable decoder worker fails preflight
  only for transparent requests; `auto` and `opaque` still work without it.
- Transparent requests use the v2 decoder and respect its 2048-pixel axis
  limit at preflight and on the actual output. Scan stops at the first
  non-opaque pixel, handles transparency only in the final pixel, and scans
  the full buffer for an opaque image. Preserve the original PNG bytes and
  clean scratch files after success, failure and cancellation. Verify the
  decoder receives the remaining generation-phase timeout and that a worker
  timeout reports `generation_failed` without losing earlier saved attempts.
- Candidate images reach review and repair with `high` detail where supported.
  Reference overrides also survive expansion; transports without a detail
  option still receive pixels without an unsupported field.
- Valid image responses above the old text-response cap work. Encoded responses
  above 16 MiB, decoded images above 10 MiB, invalid bytes and unexpected image
  counts fail explicitly without leaking their contents to logs.
- Cancellation/deadline during generation, review or repair preserves saved
  attempts and durable metadata. Insufficient remaining time prevents another
  generation. Restart marks open work interrupted without replaying calls.
- Each attempt streams operator-visible start, phase and completion status,
  including the validated score or pending/unknown. Failure and cancellation
  still produce terminal progress. These lines add neither images nor messages
  to model context, and repeated invocations do not duplicate attempt starts.
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
- Lower and higher configured response budgets reach both built-in and stored
  workflows/generators, including their module policies. A raised budget must
  not leave a hidden 600-second ceiling; a lowered budget must still cancel
  work. Inspection reports the effective values and descriptor budgets remain
  independent.
