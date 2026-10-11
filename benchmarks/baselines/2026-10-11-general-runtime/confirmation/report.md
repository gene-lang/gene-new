# Gene / Python general-purpose benchmark

5000 input items per batch; 3 measured fresh processes per executable.
One excluded warmup process per executable; each kernel calibrates before timing.
Ratio = Gene median / Python median; greater than 1 means Gene took longer.

| Workload | Gene ms/batch | Python ms/batch | Ratio |
| --- | ---: | ---: | ---: |
| integer_loop | 0.898 | 0.184 | 4.873 |
| closure_dispatch | 2.852 | 0.405 | 7.049 |
| records | 4.258 | 0.907 | 4.694 |
| text_index | 15.375 | 1.674 | 9.186 |
| json_roundtrip | 2.688 | 2.766 | 0.972 |
| event_replay | 5.031 | 0.639 | 7.876 |

Baseline / current Gene ratio: greater than 1 means current Gene is faster.

| Workload | Baseline ms/batch | Current ms/batch | Speedup |
| --- | ---: | ---: | ---: |
| integer_loop | 2.766 | 0.898 | 3.078 |
| closure_dispatch | 7.156 | 2.852 | 2.51 |
| records | 10.313 | 4.258 | 2.422 |
| text_index | 27.563 | 15.375 | 1.793 |
| json_roundtrip | 5.969 | 2.688 | 2.221 |
| event_replay | 11.781 | 5.031 | 2.342 |

Process wall times include startup, input construction, calibration and reporting; they are not kernel speed ratios.