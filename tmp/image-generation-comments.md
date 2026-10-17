# Image generation review history

The [current proposal](image-generation.md) is authoritative. These reviews
and dispositions preserve the decisions and earlier alternatives, including
format support that was later removed from the PNG-only MVP.

## Review disposition

Claude's integration, prompt-context, revision, parsing, media and acceptance
comments are incorporated in the linked proposal. The workflow itself is replaceable, in
addition to the generator adapter. The first target uses OpenRouter's current
dedicated Image API, rather than assuming its chat parser is the generation
contract. Model access and edit support still require verification.

The bounded inline option is chosen for the first version; a background-job
system is deferred. One format repair is allowed within the review budget.
All review comments below are retained unchanged for context; the current
proposal governs where they differ.

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

The third review's five points are incorporated. Shared callback budgets will
inherit the configured host budget, including module configuration; the
current fixed ceiling is documented until that change lands. The proposal
adds background validation, endpoint-based capability/routing checks, raster
format and dimension rules, and per-image review detail. Review-specific
reasoning about the earlier limits claim stays in this disposition rather
than the plugin contract.

The fourth review's three points are incorporated: operator progress, measured
image properties and explicit routing controls. Image inspection belongs in
shared `genex/` functionality. The alpha rule also distinguishes format
metadata from actual transparent pixels: WebP's lossless header flag is only
a hint, and transparent requests need bounded alpha validation rather than a
vision-model guess. Routing uses the API's `provider_tag` identifiers in
`provider.only`, with an explicit fallback policy.

Owner decision after the fifth review: MVP output is PNG only, with no format
input. Other output formats are deferred. This resolves the WebP-decoder scope
question. The transparency check explicitly adds the `genex/raster` dependency
and selects its v2 `decode_png` worker only for transparent requests, with
the existing 2048-pixel axis limit. Early exit applies to scanning the fully
decoded RGBA buffer, not to decoding itself. The PNG-only specification also
rejects non-PNG responses and avoids promising that default-sized output will
always fit the byte limits. The review history is archived separately so the
main document remains the current specification.

The sixth review's optional timeout suggestion is adopted: `decode_png` takes
an optional `^timeout_ms`, preserving its 30-second default, and the image host
passes the remaining generation-phase time. The enclosing deadline still
enforces cancellation. A decoder timeout uses `generation_failed`; enclosing
run cancellation takes precedence. PNG remains the only MVP output format.

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

## Third review (Claude, 2026-10-17)

**Point 1 of the second review was wrong, and the disposition is correct.**
`descriptor_entry_options` passes stored-entry limits only as `init_limits`
(`src/storage/workspace.gene:510`). `cordis_adapter.gene:368` then defaults the
callback `limits` to `response_execution_limits`, which is 600 s and 1,024 MB.
The 2 s / 64 MB values bound only descriptor evaluation. The new acceptance
check, a stored callback that runs longer than two seconds, is the right way to
keep this from being misread again.

The rest of the revision holds up. The run catalog keeps intermediate attempts
out of message `media`. Deadlines are now host data that callers cannot extend.
Reviewer recording rewrites only the copy that is stored, using an inventory
from expansion; every current image source goes through the media store,
including computer screenshots (`src/builtin/computer.gene:65`), so the
inventory covers them all. Durable reservations, with recovery for a crash
between the media commit and the checkpoint, close the remaining storage gap. I
found nothing blocking. Minor points:

1. **Raising the budget does not reach stored callbacks.** Profile plugins get
   the configured `response_budget` (`src/profiles/profile.gene:43`,
   `src/runtime/bootstrap.gene:106`). Stored entries pass no `limits`, so they
   get the constant `response_execution_limits()` of 600 s, whatever
   `response_budget` says. "A deployment needing longer work must increase
   compatible budgets" therefore works for the built-in `image` plugin. A
   stored replacement or generator would stay at 600 s. Either state that limit,
   or have stored entries inherit the configured response budget. The planned
   effective-limit reporting would show the difference either way.
2. **Transparency has no input.** The text tells the caller to honor
   "transparency requirements in the prompt", but the inputs table has no
   `background` setting. OpenRouter's Image API accepts `background` with the
   values `auto`, `transparent` and `opaque`, and `transparent` requires png or
   webp. Add the setting and validate it against `output_format`, or say that
   transparent output is out of scope for the first version.
3. **OpenRouter publishes the capability data.** Each endpoint record lists
   `supported_parameters`; per the guide, "an absent key means the parameter is
   unsupported by that endpoint". The adapter's `capabilities` can use this for
   `input_references`, `size` and `output_format`, rather than reporting
   `unknown`. Two related rules:
   - Reject `output_format "svg"`. The guide lists it for vectorization models,
     and it is not a raster format the media store accepts.
   - Send only `size`. An explicit pixel size combined with a mismatched
     `resolution` or `aspect_ratio` is a 400 error.
4. **Use high detail for reviewer images.** `expand_media_messages` hardcodes
   `^detail "auto"` (`src/agents/media_input.gene`). For OpenAI-family
   reviewers, request `high` for the candidate image, since checking lettering
   and fine details depends on it. Anthropic ignores the field.
5. **Editorial.** The sentence at the end of "Plugin boundary" that cites "the
   second review's mistaken interpretation" belongs in "Review disposition".
   The specification can state the rule without referring to a review.

## Fourth review (Claude, 2026-10-17)

All five third-review points are in, and the new claims check out.
`responses_content` and `chat_messages` already carry `detail`, while
`anthropic_content` drops it (`src/agents/content.gene`). Activation configures
modules with the constant `response_execution_limits`, in the `describe` handler
in `src/kernel.gene`. OpenRouter's per-endpoint `supported_parameters` is
documented as a subset of the model-wide union, fetched from
`/api/v1/images/models/<slug>/endpoints`. Nothing blocking remains. Three small
points:

1. **The run is silent for minutes.** A three-attempt run can block the turn
   for nearly ten minutes with nothing visible. Model code's console output
   already streams to the transcript (`console_output` in
   `src/agents/turn_loop.gene`). Require a progress line when each attempt
   starts and when it finishes, giving the attempt number, status and score.
   Show it only to the operator, with no pixels and nothing added to model
   context. Without this, the user is likely to cancel a run that is working.
2. **The reviewer cannot judge dimensions or alpha from pixels.**
   `inspect_bytes` only sniffs magic bytes
   (`src/genex/documents/src/documents.gene:26`), so nothing knows a candidate's
   actual size or whether it has an alpha channel. Whether a vision model sees
   transparency at all, and against what backdrop, varies by provider.
   - Parse width, height and alpha from the header. For PNG that is IHDR plus
     the color type or a tRNS chunk; for WebP it is the VP8X or VP8L header.
   - Record these values with the candidate.
   - Fail the attempt as `generation_failed` when `transparent` was requested
     and the output has no alpha.
   - Give the reviewer the dimensions and alpha as stated facts, so it does not
     guess them from the image.
3. **Name the routing control.** The guide does not say that routing filters on
   parameter support by default. "Restrict routing and any provider fallback to
   compatible endpoints" should therefore name the mechanism: `provider.only`
   with the compatible provider slugs, and `allow_fallbacks` as needed.

## Fifth review (Claude, 2026-10-17)

The fourth-review changes check out:
- Console output never reaches the model (`examples/gene-harness/docs/design.md:13`), so the operator console is the right channel for progress lines.
- OpenRouter's guide uses `provider_tag` in `provider.only` and `provider.order`, uses `provider_slug` for `provider.options`, and sets `provider_tag` to null when provider-level routing is unavailable. That matches the routing rules.
- `alpha_is_used` in WebP lossless is documented as a hint, as the doc says.

One scoping point remains.

1. **The transparent-pixel scan has no decoder to reuse.**
   - **What exists.** The Harness depends only on `genex/cordis`, `genex/computer` and `genex/documents` (`examples/gene-harness/package.gene`).
     - `genex/documents` sniffs magic bytes only.
     - `genex/archive` has a native zlib/DEFLATE codec, which would let Gene inflate PNG IDAT data, but it needs a native build.
     - `genex/raster` has a libpng `--decode` worker, but it is a separate executable that also requires Cairo.
     - Nothing in the repository decodes WebP pixels, whether VP8L, or VP8 with an `ALPH` chunk.
   - **Consequence.** The preflight rule already handles this safely: missing local inspection support fails preflight. But the acceptance check's "WebP variants" next to "Transparent requests reject … all-opaque output" suggests scanning WebP pixels.
   - **Suggestion.**
     - State that, in the first version, `transparent` requires `png`, and that `webp` plus `transparent` is rejected in preflight until a WebP decoder exists. WebP header inspection still covers dimensions and alpha hints.
     - Name the PNG path: `genex/archive` inflate plus a Gene unfilter, or the raster worker. Either adds a dependency to the Harness package.
     - Stop the scan at the first non-opaque pixel. A correct transparent output then passes after the first rows, and only a failing all-opaque image costs a full scan. That matters on the default debug build, which is roughly 11× slower than release.

Nothing else. Once this is settled, the review history (from "Original review
comments" on) could move to a separate archive file, as was done with
`tmp/macro-comments.md`, so the proposal reads as a specification.

## Sixth review (Claude, 2026-10-17)

The PNG-only revision is consistent, and the raster claims check out against
`src/genex/raster`:
- `--decode` exists only in `native/worker.cpp`, the v2 worker.
- The decoder rejects either axis above 2048 (`native/worker.cpp:313`).
- `default_worker ^version 2` honors `GENE_RASTER_WORKER_V2`.
- `decode_png` runs the worker through `$os/exec`. Inside a scheduled fiber
  that call parks only the fiber, and cancellation kills the worker's process
  group (`docs/stdlib.md:182`). The decode therefore cannot stall the host, and
  the generation-phase deadline can stop it.

Nothing blocking. One optional nit: `decode_png` always uses `checked`'s fixed
30 s timeout. Passing a `^timeout_ms` through from the remaining phase time
would make a slow decode fail with its own timeout before the phase deadline
cancels it. That would give a clearer error, with the same stop reason.
