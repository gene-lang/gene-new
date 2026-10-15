# Gene / Python general-purpose benchmark

5000 input items per batch; 5 measured fresh processes per executable.
One excluded warmup process per executable; each kernel calibrates before timing.
Ratio = Gene median / Python median; greater than 1 means Gene took longer.

| Workload | Gene ms/batch | Python ms/batch | Ratio |
| --- | ---: | ---: | ---: |
| integer_loop | 0.785 | 0.183 | 4.285 |
| closure_dispatch | 2.727 | 0.398 | 6.849 |
| records | 3.781 | 0.905 | 4.18 |
| text_index | 12.188 | 1.681 | 7.248 |
| json_roundtrip | 2.492 | 2.773 | 0.899 |
| event_replay | 3.656 | 0.642 | 5.695 |

Baseline / current Gene ratio: greater than 1 means current Gene is faster.

| Workload | Baseline ms/batch | Current ms/batch | Speedup |
| --- | ---: | ---: | ---: |
| integer_loop | 0.789 | 0.785 | 1.005 |
| closure_dispatch | 2.703 | 2.727 | 0.991 |
| records | 3.703 | 3.781 | 0.979 |
| text_index | 13.0 | 12.188 | 1.067 |
| json_roundtrip | 2.523 | 2.492 | 1.013 |
| event_replay | 3.984 | 3.656 | 1.09 |

Process wall times include startup, input construction, calibration and reporting; they are not kernel speed ratios.