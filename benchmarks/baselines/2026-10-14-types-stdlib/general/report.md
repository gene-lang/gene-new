# Gene / Python general-purpose benchmark

5000 input items per batch; 5 measured fresh processes per executable.
One excluded warmup process per executable; each kernel calibrates before timing.
Ratio = Gene median / Python median; greater than 1 means Gene took longer.

| Workload | Gene ms/batch | Python ms/batch | Ratio |
| --- | ---: | ---: | ---: |
| integer_loop | 0.777 | 0.183 | 4.245 |
| closure_dispatch | 2.703 | 0.399 | 6.774 |
| records | 3.703 | 0.904 | 4.098 |
| text_index | 12.219 | 1.694 | 7.215 |
| json_roundtrip | 2.5 | 2.784 | 0.898 |
| event_replay | 3.734 | 0.63 | 5.926 |

Baseline / current Gene ratio: greater than 1 means current Gene is faster.

| Workload | Baseline ms/batch | Current ms/batch | Speedup |
| --- | ---: | ---: | ---: |
| integer_loop | 0.785 | 0.777 | 1.01 |
| closure_dispatch | 2.703 | 2.703 | 1.0 |
| records | 4.031 | 3.703 | 1.089 |
| text_index | 14.375 | 12.219 | 1.176 |
| json_roundtrip | 2.578 | 2.5 | 1.031 |
| event_replay | 4.391 | 3.734 | 1.176 |

Process wall times include startup, input construction, calibration and reporting; they are not kernel speed ratios.