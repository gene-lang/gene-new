# Gene / Python general-purpose benchmark

5000 input items per batch; 6 measured fresh processes per executable.
One excluded warmup process per executable; each kernel calibrates before timing.
Ratio = Gene median / Python median; greater than 1 means Gene took longer.

| Workload | Gene ms/batch | Python ms/batch | Ratio |
| --- | ---: | ---: | ---: |
| integer_loop | 4.367 | 0.283 | 15.442 |
| closure_dispatch | 11.344 | 0.618 | 18.357 |
| records | 15.906 | 1.373 | 11.583 |
| text_index | 42.688 | 2.582 | 16.534 |
| json_roundtrip | 9.188 | 4.258 | 2.158 |
| event_replay | 18.281 | 1.002 | 18.244 |

Baseline / current Gene ratio: greater than 1 means current Gene is faster.

| Workload | Baseline ms/batch | Current ms/batch | Speedup |
| --- | ---: | ---: | ---: |
| integer_loop | 7.609 | 4.367 | 1.742 |
| closure_dispatch | 15.094 | 11.344 | 1.331 |
| records | 21.656 | 15.906 | 1.361 |
| text_index | 59.188 | 42.688 | 1.387 |
| json_roundtrip | 12.281 | 9.188 | 1.337 |
| event_replay | 21.938 | 18.281 | 1.2 |

Process wall times include startup, input construction, calibration and reporting; they are not kernel speed ratios.