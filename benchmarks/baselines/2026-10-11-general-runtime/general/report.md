# Gene / Python general-purpose benchmark

5000 input items per batch; 6 measured fresh processes per executable.
One excluded warmup process per executable; each kernel calibrates before timing.
Ratio = Gene median / Python median; greater than 1 means Gene took longer.

| Workload | Gene ms/batch | Python ms/batch | Ratio |
| --- | ---: | ---: | ---: |
| integer_loop | 0.927 | 0.185 | 5.014 |
| closure_dispatch | 2.875 | 0.402 | 7.157 |
| records | 4.363 | 0.908 | 4.807 |
| text_index | 15.422 | 1.701 | 9.064 |
| json_roundtrip | 2.719 | 2.84 | 0.957 |
| event_replay | 4.781 | 0.638 | 7.49 |

Baseline / current Gene ratio: greater than 1 means current Gene is faster.

| Workload | Baseline ms/batch | Current ms/batch | Speedup |
| --- | ---: | ---: | ---: |
| integer_loop | 2.844 | 0.927 | 3.068 |
| closure_dispatch | 7.289 | 2.875 | 2.535 |
| records | 10.531 | 4.363 | 2.414 |
| text_index | 28.188 | 15.422 | 1.828 |
| json_roundtrip | 6.18 | 2.719 | 2.273 |
| event_replay | 11.984 | 4.781 | 2.507 |

Process wall times include startup, input construction, calibration and reporting; they are not kernel speed ratios.