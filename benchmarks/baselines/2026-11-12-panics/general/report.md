# Gene / Python general-purpose benchmark

5000 input items per batch; 5 measured fresh processes per executable.
One excluded warmup process per executable; each kernel calibrates before timing.
Ratio = Gene median / Python median; greater than 1 means Gene took longer.

| Workload | Gene ms/batch | Python ms/batch | Ratio |
| --- | ---: | ---: | ---: |
| integer_loop | 0.297 | 0.183 | 1.619 |
| closure_dispatch | 1.359 | 0.395 | 3.444 |
| records | 1.469 | 0.89 | 1.65 |
| text_index | 5.281 | 1.668 | 3.166 |
| json_roundtrip | 1.32 | 2.743 | 0.481 |
| event_replay | 1.547 | 0.629 | 2.458 |

Baseline / current Gene ratio: greater than 1 means current Gene is faster.

| Workload | Baseline ms/batch | Current ms/batch | Speedup |
| --- | ---: | ---: | ---: |
| integer_loop | 0.381 | 0.297 | 1.283 |
| closure_dispatch | 1.75 | 1.359 | 1.287 |
| records | 1.766 | 1.469 | 1.202 |
| text_index | 6.438 | 5.281 | 1.219 |
| json_roundtrip | 1.461 | 1.32 | 1.107 |
| event_replay | 1.828 | 1.547 | 1.182 |

Process wall times include startup, input construction, calibration and reporting; they are not kernel speed ratios.