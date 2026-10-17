# Image generation

`image_generate` generates PNG images and asks the main model to review each
candidate. It stops at a score of 85 or after `max_attempts` (default 3, range
1–10). It returns the latest saved image, even when an earlier image scored
higher. Generation and review failures stop the run and retain completed work.

```gene
(image_generate "Create a square logo with the exact label Gene and a transparent background."
  ^generator "openrouter" ^generation_model "YOUR_IMAGE_MODEL"
  ^background "transparent" ^max_attempts 3)
(Outcome ^prompt "Report the image result and its review score.")
```

Supply the complete requirements in `prompt`, including constraints from prior
conversation turns. `reference_images` is an ordered list of image media IDs.
Earlier attachments are available through `media_list`; use their IDs instead
of text descriptions or pasted image data. A reference may be a prior generated
candidate. The default size is `1024x1024`; `background` is `auto`, `opaque` or
`transparent`. Output is always PNG; there is no format selector.

Select a generator and generation model explicitly, or set `generator` and
`generation_model` in the `image` map of workspace `config.gene`. The same map
can set `size`, `background`, `generator_options`, `decoder_worker`, and the
run/generation/review timeouts and persistence margin in milliseconds. Their
defaults are 590000/120000/60000/5000. Both models' declared input limits and the
remaining response budget apply. The main reviewer is pinned to the provider
and settings that produced the current response; Claude CLI cannot review
images. Unknown model support is reported honestly and may fail at the provider.

The baseline includes the `openrouter` image generator, using
`OPENROUTER_API_KEY` or `OPENROUTER_KEY`. It calls OpenRouter's dedicated
[Image API](https://openrouter.ai/docs/guides/overview/multimodal/image-generation),
discovers endpoint capabilities before generation, requests one PNG, and
routes only to endpoints compatible with the requested settings. Configure
`generator_options` as `{^only ["PROVIDER_TAG"] ^allow_fallbacks false}` to
restrict routing further. Fallbacks require an explicit compatible allowlist;
discovery failure disables them and records unknown support. Missing keys in
available endpoint metadata mean unsupported. There is no automatic generator
or model selection, and a model's vision support does not establish image
generation support.

The function publishes final metadata and attaches the saved final image for
the next model turn and the normal preview/download flow. Progress appears
only in the operator console. An unreviewed candidate has an unknown score.
There is one run per user round: identical calls return the recorded result;
different inputs require a new user request. Repeated calls, final previews,
plugin replacement and host restarts cannot reset the attempt counter. A new
user request may use the last image ID as a reference.

Use `(recall "image.RUN_ID")` to inspect the saved run, attempts and reviews.
Intermediate candidates appear in `media_list` without automatically adding
their pixels to model context. Call `media_show` to inspect one explicitly.
Cancellation preserves completed candidates and reviews; restart marks open
work interrupted and never replays paid calls. Generated media obeys the
workspace quota and is not automatically pruned.

Transparent output requires the working genex/raster v2 decoder, selected by
`GENE_RASTER_WORKER_V2` or `image/decoder_worker`. Build it from the repository
root with `gene run src/genex/raster/tools/build.gene` (Cairo, libpng and zlib).
For materialized packages, configure the built executable's absolute path.
It supports at most 2048 pixels per axis. Opaque/auto generation needs no native
decoder. The host checks PNG structure and metadata, and verifies non-opaque
pixels for transparent output. It keeps the provider's original PNG bytes.
The decoder receives the remaining generation-phase timeout and cleans its
scratch files after success, failure or cancellation.

The optional `image` plugin owns prompts and the generate/review loop. Replace,
disable or restore it through the ordinary plugin lifecycle. Its replacement
can import `Plugin`, `PluginHost` and `ImageHost` from `src/plugin_api.gene`,
resolve the `image/runtime` seam, and call `begin`, `generate`, `review` and
`finish`. The host owns individual bounded calls, durable admission, media and
results. Generator plugins independently contribute `image_generators` rows.
Detailed adapter and shared API contracts are in [Harness plugins](plugins.md).
