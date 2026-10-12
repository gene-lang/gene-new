# Gene / Python general-purpose benchmark

5000 input items per batch; 6 measured fresh processes per executable.
One excluded warmup process per executable; each kernel calibrates before timing.
Ratio = Gene median / Python median; greater than 1 means Gene took longer.

| Workload | Gene ms/batch | Python ms/batch | Ratio |
| --- | ---: | ---: | ---: |
| integer_loop | 0.908 | 0.184 | 4.936 |
| closure_dispatch | 2.809 | 0.402 | 6.992 |
| records | 4.215 | 0.882 | 4.776 |
| text_index | 15.25 | 1.681 | 9.073 |
| json_roundtrip | 2.645 | 2.755 | 0.96 |
| event_replay | 4.504 | 0.638 | 7.063 |

Baseline / current Gene ratio: greater than 1 means current Gene is faster.

| Workload | Baseline ms/batch | Current ms/batch | Speedup |
| --- | ---: | ---: | ---: |
| integer_loop | 2.805 | 0.908 | 3.088 |
| closure_dispatch | 7.219 | 2.809 | 2.57 |
| records | 10.344 | 4.215 | 2.454 |
| text_index | 27.656 | 15.25 | 1.814 |
| json_roundtrip | 6.078 | 2.645 | 2.298 |
| event_replay | 11.75 | 4.504 | 2.609 |

Process wall times include startup, input construction, calibration and reporting; they are not kernel speed ratios.