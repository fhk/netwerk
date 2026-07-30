# Iteration 003 — optimal batch partition: DP over DFS order replaces greedy packing

golden: BLESSED

| fixture | score | capex_cents | qa_errors | drop_street_crossings | drop_drop_crossings | terminals_under_4 | terminals_over_12 | rings | terminal_count | drop_mean_m | drop_max_m |
|---|---|---|---|---|---|---|---|---|---|---|---|
| parcels | 1521740560 | 1117040560 | 0 | 5422 | 1300 | 1076 | 0 | 0 | 2151 | 31.84 | 150 |
| s01_single_street | 4126300 | 2126300 | 2 | 0 | 0 | 0 | 0 | 0 | 6 | 19.0 | 19 |
| s02_parallel_streets | 6529100 | 3529100 | 3 | 0 | 0 | 0 | 0 | 0 | 10 | 19.0 | 19 |
| s03_grid5 | 17343200 | 16043200 | 1 | 2 | 0 | 2 | 0 | 0 | 38 | 24.72 | 140 |
| s04_culdesac | 6101150 | 3101150 | 3 | 0 | 0 | 0 | 0 | 0 | 9 | 18.65 | 19 |
| s05_two_islands | 8627100 | 5627100 | 3 | 0 | 0 | 0 | 0 | 0 | 12 | 22.86 | 46 |
| s06_mdu_block | 3386750 | 1386750 | 2 | 0 | 0 | 0 | 0 | 0 | 1 | 62.5 | 106 |
| **total** | 1567854160 | 1148854160 | 14 | 5424 | 1300 | 1078 | 0 | 0 | 2227 | | |

**Composite total: 1567854160** (delta vs iter_002: -95971300)
