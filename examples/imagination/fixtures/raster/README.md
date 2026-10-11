# Prompt-only raster acceptance fixtures

These painting programs and PNGs were produced by Imagination's existing multimodal loop using `gpt-6.1-sol`, low reasoning effort, on 2026-10-11. No reference image or generative image service was supplied. Each saved edit repainted the complete program in a fresh native process; the model received the actual output PNGs.

| Subject | Edits / decision calls | Result |
| --- | --- | --- |
| Red sphere on warm cream ground | 3 / 4 | Complete; all hard and soft requirements passed |
| Red apple on blue-gray table | 4 / 5 | Complete on hard requirements; optional refined finish remained partial |

The sphere request specified upper-left light, a bright soft highlight, a dark lower-right edge and a soft cast shadow. The apple request additionally specified an organic lobed silhouette, a short curved brown stem and a green leaf. Both requested multiple brush/gradient refinement passes and no lettering. Visual inspection confirms recognizable stylized form and lighting; these are not photorealism demonstrations.

The apple shown here is the run after fixing unsupported structural-goal validation. An earlier exploratory apple run exposed that issue and is not used as acceptance evidence.

`*.gene` is the authoritative editable program. `*.png` is reference output under the tested macOS arm64 / Cairo 1.18.4 / libpng 1.6.56 / zlib 1.2.12 build. Other native profiles must certify their own bytes. Exact replay of all four apple edits reproduced program, pixel and PNG digests.

| Fixture | Program SHA-256 | PNG SHA-256 |
| --- | --- | --- |
| sphere | b0d6a3eaf1b28bdfd8d84ec8181a7d6904e008da0882f4ac1536942e08309028 | 275dc8ae1083566b75e06d81494a89cead66560445d313d10aa70b669cc32585 |
| apple | d4ed67532dcb94e2fb2c2de05a565c5d01b3e8277a0a33b0dfc73ffffa0b0421 | d9b3532f1254f1e391fff3b861d6d79c002146d5167fcc7dd3d284db155b3a8b |

Local acceptance histories, prompts, replies, image-submission receipts and test logs are under `tmp/imagination-raster/` in the development workspace. They are not required to use these standalone fixture programs.
