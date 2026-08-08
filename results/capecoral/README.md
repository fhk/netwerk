# Cape Coral canal design — the reach campaign

Full-city FTTH design on the Cape Coral canal network: banks resampled every
50 ft, opposite-bank crossings where the along-bank detour exceeds 3x the
straight hop, land links between adjacent canals, address points within
150 m of a node. 84,433 road nodes, 183,225 edges, 106,925 premises,
248 serving areas, 16,756 terminals.

Every QA check passes except `route_length_budget`, the 20 km CO-to-ONT
optical budget. These are the runs against it. Each is ~70-95 minutes.

| run | change | head-ends | over budget | capex | $/passed | trench m |
|---|---|---|---|---|---|---|
| 1 | baseline | 3 | 48,393 | $83,777,418 | $783.51 | 930,989 |
| 2 | head-end siting fixed | 21 | 26,336 | $86,360,473 | $807.67 | 930,989 |
| 3 | + stage 9d reach repair | 21 | 22,657 | $91,503,148 | $855.76 | 999,328 |

Run 1's layers are the ones in `designs/capecoral_canals/`; runs 2 and 3 are
experiments and were not exported.

Capex is not comparable across run 1 and the others by itself: run 2 also
added the OLT chassis ($18,000) and head-end site ($120,000) BOM lines that
were missing entirely, so $2.99M of run 2's increase is honesty rather than
equipment.

## What each run established

**Run 1 → 2, head-end siting.** `SelectCo` scored each area by
`dist(head-end, FDH) - slack`, slack being the budget minus the area's worst
distribution+drop tail. An area whose tail alone exceeds the budget has
negative slack, so its violation stayed large even with a head-end on top of
it; it won the farthest-first argmax every round and siting quit after three
sites. Clamping slack at zero fixed the argmax, and the count fell 45%.

It should have fallen further. `tools/headend_sim.py`, replaying the
corrected greedy on run 1's finished geometry, predicts **42 head-ends and
1,924 residual**. The engine opened 21. The difference is not a bug in the
greedy — it is what the greedy is allowed to see:

> `SelectCo` measures feeder as SHORTEST-PATH distance from a head-end to an
> FDH, but the design routes feeder along the global trench tree built later
> by `DeloopTrench`, which is longer. Siting signs off on a network the
> router then blows past. The simulator saw the true, post-tree tails; the
> engine sees the optimistic pre-tree ones.

**Run 2 → 3, reach repair.** Stage 9d buys trench to buy reach (see
`src/stages.carbon`). It worked as designed — 1,488 accepted moves over 129
rounds — but the trade is poor: **180,746 m of extra trench, $5.14M, to fix
3,679 premises**, about $1,400 each, and it does not reach feasibility. It
also pushed `tail_over` the wrong way, 1,923 → 2,503, because the feeder
scope scores FDH path length only: shortening a feeder can lengthen the
distribution tails hanging off that area, and the scope never sees it.

Since QA is a hard gate, spending toward feasibility is right in principle.
Spending toward *nearly* feasible is not — at this price 9d is only worth
running if the two fixes below land with it.

## What is actually left

1. **Site head-ends against the routes the design will use.** Iterate:
   site, build the tree, measure real feeder and real tails, re-site,
   re-route. One extra round should be enough to close a 21-vs-42 gap.
   Everything needed is already computed, just in the wrong order.

2. **Fix 9d's feeder-scope accounting.** Score a feeder candidate on
   `feeder(c) + tail(c)` against the budget, not on `feeder(c)` alone,
   refreshing `tail(c)` for the clusters inside the disturbed component —
   usually one, so the cost is one extra `ForestBfs` per trial.

3. **Cap serving-area radius.** Ten of the 35 tail-limited areas exceed the
   budget even routed on shortest paths from their FDH. A 432-unit serving
   area on a linear canal network can span more than the whole optical
   budget, and no tree or head-end reaches it. This trades FDH cabinets for
   reach and may pull `util_fdh_capacity` off its 95% floor, so it needs the
   floor decision in `docs/IMPROVEMENT_BACKLOG.md` settled first.

## Reproducing

    ./build.sh
    ./build/netwerk < data/capecoral_canals.txt > report.txt
    ./build/netwerk_export < data/capecoral_canals.txt > geom.txt
    python3 tools/design2geojson.py --interchange data/capecoral_canals.txt \
        --geom geom.txt --meta data/capecoral_canals.txt.meta.json \
        --out designs/capecoral_canals

    python3 tools/budget_report.py --interchange data/capecoral_canals.txt \
        --geom geom.txt              # splits a failure into its three legs
    python3 tools/headend_sim.py --interchange data/capecoral_canals.txt \
        --geom geom.txt              # what siting would cost, in seconds
    python3 tools/check_crossings.py --interchange data/capecoral_canals.txt
