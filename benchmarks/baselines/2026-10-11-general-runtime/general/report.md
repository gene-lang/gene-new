# Gene / Python general-purpose benchmark

5000 input items per batch; 6 measured fresh processes per executable.
One excluded warmup process per executable; each kernel calibrates before timing.
Ratio = Gene median / Python median; greater than 1 means Gene took longer.

| Workload | Gene ms/batch | Python ms/batch | Ratio |
| --- | ---: | ---: | ---: |
| integer_loop | 0.799 | 0.187 | 4.277 |
| closure_dispatch | 2.781 | 0.407 | 6.839 |
| records | 4.082 | 0.899 | 4.538 |
| text_index | 14.719 | 1.699 | 8.661 |
| json_roundtrip | 2.559 | 2.824 | 0.906 |
| event_replay | 4.512 | 0.648 | 6.967 |

Baseline / current Gene ratio: greater than 1 means current Gene is faster.

| Workload | Baseline ms/batch | Current ms/batch | Speedup |
| --- | ---: | ---: | ---: |
| integer_loop | 2.855 | 0.799 | 3.575 |
| closure_dispatch | 7.5 | 2.781 | 2.697 |
| records | 10.563 | 4.082 | 2.588 |
| text_index | 28.625 | 14.719 | 1.945 |
| json_roundtrip | 6.211 | 2.559 | 2.427 |
| event_replay | 12.0 | 4.512 | 2.66 |

Process wall times include startup, input construction, calibration and reporting; they are not kernel speed ratios.