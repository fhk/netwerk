# Iteration 009 — priced 2-opt drop uncrossing: load-preserving swaps, cross-area allowed

golden: BLESSED

| fixture | score | capex_cents | qa_errors | drop_street_crossings | drop_drop_crossings | terminals_under_4 | terminals_over_12 | rings | terminal_count | drop_mean_m | drop_max_m |
|---|---|---|---|---|---|---|---|---|---|---|---|
| parcels | 945196410 | 792206410 | 0 | 2027 | 147 | 487 | 0 | 0 | 1732 | 27.52 | 149 |
| s01_single_street | 1889500 | 1889500 | 0 | 0 | 0 | 0 | 0 | 0 | 6 | 19.0 | 19 |
| s02_parallel_streets | 4112150 | 3112150 | 1 | 0 | 0 | 0 | 0 | 0 | 7 | 26.25 | 105 |
| s03_grid5 | 15518600 | 14518600 | 1 | 0 | 0 | 0 | 0 | 0 | 36 | 22.72 | 108 |
| s04_culdesac | 3932450 | 2932450 | 1 | 0 | 0 | 0 | 0 | 0 | 8 | 20.0 | 46 |
| s05_two_islands | 5911950 | 4911950 | 1 | 0 | 0 | 0 | 0 | 0 | 12 | 22.86 | 46 |
| s06_mdu_block | 978100 | 978100 | 0 | 0 | 0 | 0 | 0 | 0 | 2 | 34.0 | 47 |
| **total** | 977539160 | 820549160 | 4 | 2027 | 147 | 487 | 0 | 0 | 1803 | | |

**Composite total: 977539160** (delta vs iter_008: -23634550)
