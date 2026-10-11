# Gene / Python general-purpose benchmark

5000 input items per batch; 3 measured fresh processes per executable.
One excluded warmup process per executable; each kernel calibrates before timing.
Ratio = Gene median / Python median; greater than 1 means Gene took longer.

| Workload | Gene ms/batch | Python ms/batch | Ratio |
| --- | ---: | ---: | ---: |
| integer_loop | 0.945 | 0.184 | 5.125 |
| closure_dispatch | 2.992 | 0.398 | 7.527 |
| records | 4.461 | 0.906 | 4.926 |
| text_index | 15.563 | 1.683 | 9.247 |
| json_roundtrip | 2.703 | 2.816 | 0.96 |
| event_replay | 4.688 | 0.632 | 7.412 |

Baseline / current Gene ratio: greater than 1 means current Gene is faster.

| Workload | Baseline ms/batch | Current ms/batch | Speedup |
| --- | ---: | ---: | ---: |
| integer_loop | 2.828 | 0.945 | 2.992 |
| closure_dispatch | 7.297 | 2.992 | 2.439 |
| records | 10.344 | 4.461 | 2.319 |
| text_index | 28.625 | 15.563 | 1.839 |
| json_roundtrip | 6.156 | 2.703 | 2.277 |
| event_replay | 11.875 | 4.688 | 2.533 |

Process wall times include startup, input construction, calibration and reporting; they are not kernel speed ratios.