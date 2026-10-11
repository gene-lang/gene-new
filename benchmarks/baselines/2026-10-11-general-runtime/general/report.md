# Gene / Python general-purpose benchmark

5000 input items per batch; 6 measured fresh processes per executable.
One excluded warmup process per executable; each kernel calibrates before timing.
Ratio = Gene median / Python median; greater than 1 means Gene took longer.

| Workload | Gene ms/batch | Python ms/batch | Ratio |
| --- | ---: | ---: | ---: |
| integer_loop | 0.905 | 0.186 | 4.855 |
| closure_dispatch | 2.906 | 0.402 | 7.232 |
| records | 4.461 | 0.898 | 4.968 |
| text_index | 15.766 | 1.702 | 9.265 |
| json_roundtrip | 2.691 | 2.824 | 0.953 |
| event_replay | 5.211 | 0.642 | 8.117 |

Baseline / current Gene ratio: greater than 1 means current Gene is faster.

| Workload | Baseline ms/batch | Current ms/batch | Speedup |
| --- | ---: | ---: | ---: |
| integer_loop | 2.883 | 0.905 | 3.184 |
| closure_dispatch | 7.422 | 2.906 | 2.554 |
| records | 10.609 | 4.461 | 2.378 |
| text_index | 28.344 | 15.766 | 1.798 |
| json_roundtrip | 6.234 | 2.691 | 2.316 |
| event_replay | 11.953 | 5.211 | 2.294 |

Process wall times include startup, input construction, calibration and reporting; they are not kernel speed ratios.