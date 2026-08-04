# Iteration 011 — key-path local search on the trench tree: strictly-cheaper path exchange to fixpoint

golden: BLESSED

| fixture | score | capex_cents | qa_errors | drop_street_crossings | drop_drop_crossings | terminals_under_4 | terminals_over_12 | rings | terminal_count | drop_mean_m | drop_max_m |
|---|---|---|---|---|---|---|---|---|---|---|---|
| parcels | 847190105 | 749000105 | 0 | 1509 | 72 | 213 | 0 | 0 | 1530 | 25.55 | 149 |
| s01_single_street | 1889500 | 1889500 | 0 | 0 | 0 | 0 | 0 | 0 | 6 | 19.0 | 19 |
| s02_parallel_streets | 4112150 | 3112150 | 1 | 0 | 0 | 0 | 0 | 0 | 7 | 26.25 | 105 |
| s03_grid5 | 15518600 | 14518600 | 1 | 0 | 0 | 0 | 0 | 0 | 36 | 22.72 | 108 |
| s04_culdesac | 3932450 | 2932450 | 1 | 0 | 0 | 0 | 0 | 0 | 8 | 20.0 | 46 |
| s05_two_islands | 5911950 | 4911950 | 1 | 0 | 0 | 0 | 0 | 0 | 12 | 22.86 | 46 |
| s06_mdu_block | 978100 | 978100 | 0 | 0 | 0 | 0 | 0 | 0 | 2 | 34.0 | 47 |
| **total** | 879532855 | 777342855 | 4 | 1509 | 72 | 213 | 0 | 0 | 1601 | | |

**Composite total: 879532855** (delta vs iter_010: -14811785)
