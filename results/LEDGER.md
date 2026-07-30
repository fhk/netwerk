# Improvement ledger

Composite score (lower is better) summed over all scenarios and the parcel district.

| iter | title | total_score | capex | street-x | drop-x | term-viol | rings | qa |
|---|---|---|---|---|---|---|---|---|
| 000 | baseline | 2937657355 | 1332357355 | 20070 | 6165 | 315 | 866 | 14 |
| 001 | crossing-aware terminal placement: exact scorer predicate + edge grid + priced batch sizes | 2257658155 | 1315068155 | 7499 | 1862 | 834 | 866 | 14 |
| 002 | trench deloop: min-cost spanning forest + cable re-route (rings 866->0) | 1663825460 | 1154235460 | 7499 | 1862 | 834 | 0 | 14 |
| 003 | optimal batch partition: DP over DFS order replaces greedy packing | 1567854160 | 1148854160 | 5424 | 1300 | 1078 | 0 | 14 |
| 004 | node-centric set-cover packing: terminals first, trench routed to terminals, scorer-priced merge | 1068810835 | 877380835 | 2229 | 669 | 526 | 0 | 14 |
| 005 | global Steiner trench: DeloopTrench grows one tree over the full road graph (CO+FDH+terminals) | 1016829930 | 825399930 | 2229 | 669 | 526 | 0 | 14 |
