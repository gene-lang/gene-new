# Gene / Python general-purpose benchmark

5000 input items per batch; 6 measured fresh processes per executable.
One excluded warmup process per executable; each kernel calibrates before timing.
Ratio = Gene median / Python median; greater than 1 means Gene took longer.

| Workload | Gene ms/batch | Python ms/batch | Ratio |
| --- | ---: | ---: | ---: |
| integer_loop | 0.872 | 0.181 | 4.814 |
| closure_dispatch | 2.781 | 0.396 | 7.024 |
| records | 4.086 | 0.883 | 4.63 |
| text_index | 14.469 | 1.661 | 8.708 |
| json_roundtrip | 2.543 | 2.742 | 0.927 |
| event_replay | 4.402 | 0.63 | 6.988 |

Baseline / current Gene ratio: greater than 1 means current Gene is faster.

| Workload | Baseline ms/batch | Current ms/batch | Speedup |
| --- | ---: | ---: | ---: |
| integer_loop | 2.707 | 0.872 | 3.104 |
| closure_dispatch | 6.992 | 2.781 | 2.514 |
| records | 10.078 | 4.086 | 2.467 |
| text_index | 26.75 | 14.469 | 1.849 |
| json_roundtrip | 5.867 | 2.543 | 2.307 |
| event_replay | 11.484 | 4.402 | 2.609 |

Process wall times include startup, input construction, calibration and reporting; they are not kernel speed ratios.