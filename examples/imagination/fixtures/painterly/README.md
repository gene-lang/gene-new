# Painterly acceptance examples

Generated and visually checked on 2026-10-11 with the `raster-cairo-linear/v2` profile. The `.gene` files are complete editable programs, including materialized strokes; PNGs are reference output for the tested native build. Other builds must certify their own pixel/PNG identities.

## Reference apple

`reference-apple.gene` uses the previous stage's [apple PNG](../raster/apple.png) as explicit guidance. It contains an 8×8 painted color base, 400 broad strokes and 800 finer strokes. Two `paint-reference` commands created these layers; there was no image-generation call. The sample demonstrates color sampling, contour-guided stroke directions, taper, textured marks and coarse-to-fine refinement. The leaf and silhouette remain approximate.

The source image is retained as reference metadata, but repaint samples only the saved fills/strokes. Standalone CLI render with no reference asset store reproduced PNG SHA-256 `0ce9c338d962c218dc3e933afff445dd0581a9244bf0b2e491cd62199d4aed34`. Program SHA-256 is `da3edbf5dea9842ee5a1e1e7da92aebcbd7f8c622f09725e359971574a92a56c`.

## Swirling landscape

`swirling-landscape.gene` was created from this prompt alone:

> Paint a Van Gogh-inspired landscape: swirling deep blue sky, a luminous yellow sun, golden fields and a dark cypress on the left. Use distinct textured directional brushwork and lively contrasting colors. Establish a colored ground and readable composition before adding stroke fields. Refine through multiple edits. No lettering.

The configured `gpt-6.1-sol` model at low reasoning effort made four painting edits in five decision calls, followed by its completion review. It used explicit shapes, textured strokes and region helpers. Fresh-process exact replay reproduced program, pixel and PNG digests for all four revisions. The result has recognizable requested subjects, a clear warm/cool palette and visible stroke texture. It remains schematic and is not evidence of faithful Van Gogh reproduction or photorealism.

Program SHA-256: `82c375b63629f4edefac838f8ad6f1fc05ca3e8063f37614057afc045c3fbcc7`.

The application suite passes 151 tests (142 previous plus nine painterly/reference tests). All nine new tests also pass with AddressSanitizer and UndefinedBehaviorSanitizer on the v2 native worker. The original v1 sphere still replays unchanged. Local histories and full test/model logs remain under `tmp/imagination-painterly/` in the development workspace.
