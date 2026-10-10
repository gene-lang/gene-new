# Gene / Python general-purpose benchmark

5000 input items per batch; 3 measured fresh processes per executable.
One excluded warmup process per executable; each kernel calibrates before timing.
Ratio = Gene median / Python median; greater than 1 means Gene took longer.

| Workload | Gene ms/batch | Python ms/batch | Ratio |
| --- | ---: | ---: | ---: |
| integer_loop | 4.438 | 0.28 | 15.863 |
| closure_dispatch | 11.094 | 0.614 | 18.072 |
| records | 15.781 | 1.364 | 11.568 |
| text_index | 42.75 | 2.572 | 16.621 |
| json_roundtrip | 9.234 | 4.256 | 2.17 |
| event_replay | 18.281 | 1.004 | 18.212 |

Baseline / current Gene ratio: greater than 1 means current Gene is faster.

| Workload | Baseline ms/batch | Current ms/batch | Speedup |
| --- | ---: | ---: | ---: |
| integer_loop | 7.594 | 4.438 | 1.711 |
| closure_dispatch | 15.188 | 11.094 | 1.369 |
| records | 21.688 | 15.781 | 1.374 |
| text_index | 59.125 | 42.75 | 1.383 |
| json_roundtrip | 12.219 | 9.234 | 1.323 |
| event_replay | 21.813 | 18.281 | 1.193 |

Process wall times include startup, input construction, calibration and reporting; they are not kernel speed ratios.