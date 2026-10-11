# Gene / Python general-purpose benchmark

5000 input items per batch; 6 measured fresh processes per executable.
One excluded warmup process per executable; each kernel calibrates before timing.
Ratio = Gene median / Python median; greater than 1 means Gene took longer.

| Workload | Gene ms/batch | Python ms/batch | Ratio |
| --- | ---: | ---: | ---: |
| integer_loop | 0.939 | 0.186 | 5.045 |
| closure_dispatch | 2.965 | 0.403 | 7.349 |
| records | 4.465 | 0.916 | 4.876 |
| text_index | 15.984 | 1.709 | 9.351 |
| json_roundtrip | 2.754 | 2.84 | 0.97 |
| event_replay | 4.828 | 0.649 | 7.441 |

Baseline / current Gene ratio: greater than 1 means current Gene is faster.

| Workload | Baseline ms/batch | Current ms/batch | Speedup |
| --- | ---: | ---: | ---: |
| integer_loop | 2.887 | 0.939 | 3.073 |
| closure_dispatch | 7.469 | 2.965 | 2.519 |
| records | 10.641 | 4.465 | 2.383 |
| text_index | 28.625 | 15.984 | 1.791 |
| json_roundtrip | 6.227 | 2.754 | 2.261 |
| event_replay | 12.047 | 4.828 | 2.495 |

Process wall times include startup, input construction, calibration and reporting; they are not kernel speed ratios.