# Iteration 006 — growth-aware priced merge: targets may step up the catalog to absorb under-4 strays

golden: BLESSED

| fixture | score | capex_cents | qa_errors | drop_street_crossings | drop_drop_crossings | terminals_under_4 | terminals_over_12 | rings | terminal_count | drop_mean_m | drop_max_m |
|---|---|---|---|---|---|---|---|---|---|---|---|
| parcels | 973132730 | 796452730 | 0 | 2238 | 684 | 511 | 0 | 0 | 1753 | 28.86 | 150 |
| s01_single_street | 3989500 | 1989500 | 2 | 0 | 0 | 0 | 0 | 0 | 6 | 19.0 | 19 |
| s02_parallel_streets | 6146150 | 3146150 | 3 | 0 | 0 | 0 | 0 | 0 | 7 | 26.25 | 105 |
| s03_grid5 | 15494100 | 14494100 | 1 | 0 | 0 | 0 | 0 | 0 | 36 | 22.72 | 108 |
| s04_culdesac | 5966450 | 2966450 | 3 | 0 | 0 | 0 | 0 | 0 | 8 | 20.0 | 46 |
| s05_two_islands | 7935450 | 4935450 | 3 | 0 | 0 | 0 | 0 | 0 | 12 | 22.86 | 46 |
| s06_mdu_block | 2954600 | 954600 | 2 | 0 | 0 | 0 | 0 | 0 | 2 | 34.0 | 47 |
| **total** | 1015618980 | 824938980 | 14 | 2238 | 684 | 511 | 0 | 0 | 1824 | | |

**Composite total: 1015618980** (delta vs iter_005: -1210950)
