# Gene / Python general-purpose benchmark

5000 input items per batch; 5 measured fresh processes per executable.
One excluded warmup process per executable; each kernel calibrates before timing.
Ratio = Gene median / Python median; greater than 1 means Gene took longer.

| Workload | Gene ms/batch | Python ms/batch | Ratio |
| --- | ---: | ---: | ---: |
| integer_loop | 0.797 | 0.183 | 4.35 |
| closure_dispatch | 2.773 | 0.4 | 6.936 |
| records | 3.734 | 0.886 | 4.213 |
| text_index | 12.125 | 1.679 | 7.222 |
| json_roundtrip | 2.5 | 2.779 | 0.9 |
| event_replay | 3.625 | 0.643 | 5.641 |

Baseline / current Gene ratio: greater than 1 means current Gene is faster.

| Workload | Baseline ms/batch | Current ms/batch | Speedup |
| --- | ---: | ---: | ---: |
| integer_loop | 0.781 | 0.797 | 0.98 |
| closure_dispatch | 2.711 | 2.773 | 0.977 |
| records | 3.781 | 3.734 | 1.013 |
| text_index | 13.313 | 12.125 | 1.098 |
| json_roundtrip | 2.57 | 2.5 | 1.028 |
| event_replay | 4.031 | 3.625 | 1.112 |

Process wall times include startup, input construction, calibration and reporting; they are not kernel speed ratios.