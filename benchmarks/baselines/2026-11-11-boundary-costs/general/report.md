# Gene / Python general-purpose benchmark

5000 input items per batch; 5 measured fresh processes per executable.
One excluded warmup process per executable; each kernel calibrates before timing.
Ratio = Gene median / Python median; greater than 1 means Gene took longer.

| Workload | Gene ms/batch | Python ms/batch | Ratio |
| --- | ---: | ---: | ---: |
| integer_loop | 0.383 | 0.181 | 2.109 |
| closure_dispatch | 1.703 | 0.394 | 4.321 |
| records | 1.719 | 0.88 | 1.952 |
| text_index | 6.375 | 1.668 | 3.822 |
| json_roundtrip | 1.445 | 2.738 | 0.528 |
| event_replay | 1.828 | 0.634 | 2.883 |

Baseline / current Gene ratio: greater than 1 means current Gene is faster.

| Workload | Baseline ms/batch | Current ms/batch | Speedup |
| --- | ---: | ---: | ---: |
| integer_loop | 0.363 | 0.383 | 0.949 |
| closure_dispatch | 1.672 | 1.703 | 0.982 |
| records | 1.797 | 1.719 | 1.045 |
| text_index | 6.5 | 6.375 | 1.02 |
| json_roundtrip | 1.438 | 1.445 | 0.995 |
| event_replay | 1.797 | 1.828 | 0.983 |

Process wall times include startup, input construction, calibration and reporting; they are not kernel speed ratios.