# Iteration 001 — crossing-aware terminal placement: exact scorer predicate + edge grid + priced batch sizes

golden: BLESSED

| fixture | score | capex_cents | qa_errors | drop_street_crossings | drop_drop_crossings | terminals_under_4 | terminals_over_12 | rings | terminal_count | drop_mean_m | drop_max_m |
|---|---|---|---|---|---|---|---|---|---|---|---|
| parcels | 2210103805 | 1282283805 | 0 | 7498 | 1856 | 828 | 0 | 866 | 1909 | 37.37 | 150 |
| s01_single_street | 4203900 | 2203900 | 2 | 0 | 0 | 0 | 0 | 0 | 2 | 46.67 | 75 |
| s02_parallel_streets | 6627100 | 3627100 | 3 | 0 | 0 | 0 | 0 | 0 | 4 | 41.0 | 75 |
| s03_grid5 | 18071900 | 16421900 | 1 | 1 | 5 | 5 | 0 | 0 | 20 | 45.48 | 150 |
| s04_culdesac | 6381600 | 3261600 | 3 | 0 | 1 | 1 | 0 | 0 | 5 | 49.23 | 135 |
| s05_two_islands | 8883100 | 5883100 | 3 | 0 | 0 | 0 | 0 | 0 | 6 | 57.14 | 105 |
| s06_mdu_block | 3386750 | 1386750 | 2 | 0 | 0 | 0 | 0 | 0 | 1 | 62.5 | 106 |
| **total** | 2257658155 | 1315068155 | 14 | 7499 | 1862 | 834 | 0 | 866 | 1947 | | |

**Composite total: 2257658155** (delta vs iter_000: -679999200)
