# Design-quality improvement backlog

Priority-ordered work queue for the improvement loop (`iterate.sh`).
Metrics come from `tools/score_design.py`; progress is tracked in
`results/LEDGER.md`. Composite score (lower is better), in cents:

    capex_cents
  + 50000  * drop_street_crossings
  + 20000  * drop_drop_crossings
  + 100000 * (terminals_under_4 + terminals_over_12)
  + 500000 * rings
  + 1000000 * qa_errors

summed over the parcel district and every scenario in `scenarios/`.

Ground rules: every iteration must keep all QA checks green on the
district (including the >=95% utilization floor), stay deterministic
(stable tie-breaks, no unordered iteration), and re-bless goldens only
for deliberate, reviewed output changes (`BLESS=1`).

## P0 — drop geometry (dominates the penalty budget)

1. ~~**Drop street-crossing constraint in terminal packing and premises
   reassignment.**~~ DONE iter 001 (20,028 -> 7,498 district crossings;
   total score -680M). Engine now carries the scorer's exact integer
   orientation predicate + a 128 m edge grid (`CountDropCrossings` in
   graph.carbon); packing ranks every tree node by (crossings, worst
   drop) and — crucially — prices the BATCH SIZE: the road graph is a
   lattice of parcel lot lines, so a k-customer terminal carries ~k^2/4
   unavoidable crossings; each catalog size is scored at
   (50000*crossings + hardware + 100000*under-4)/customers and the
   cheapest wins. MergeTerminals target-ranking is crossing-aware too.
   MaxTerminals raised 2048 -> 4096 (the cap silently unserved 41
   premises -> QA caught it).
1b. ~~**Batch composition (greedy splintering).**~~ DONE iter 003 via
   candidate (a): `PackTerminals` now runs an exact DP (shortest path
   over DFS positions, arcs = catalog-size batches + 1-premises fallback
   + priced skip) minimizing the SUM of scorer-priced batch costs
   (50000/crossing + hardware + 100000 under-4 + $1.50/m drop cable).
   District: crossings 7,498 -> 5,422, drop-drop 1,856 -> 1,300, capex
   -4.4M, district score -94.5M; every scenario improved or held.
   NOTE: terminals_under_4 ROSE 828 -> 1,076 — the DP deliberately buys
   a 2-port (+100k) whenever it avoids >=2 street crossings. Remaining
   levers on crossings are candidates (b)/(c) below.
1c. ~~**DFS-order interleaving is still the constraint.**~~ RESOLVED
   iter 004 by removing the sequence entirely: PackTerminals is now a
   node-centric set-cover greedy (moves = scorer-priced new-batch at any
   in-reach node, or attach-grow of the terminal already there), run
   BEFORE distribution routing; the trench is then routed TO the
   terminal nodes. Negative result recorded on the way: ordering the DP
   sequence by "home node" (fewest crossings, then most-popular
   zero-crossing anchor) made the total WORSE (+2.8M district) — the
   consecutive-batch constraint, not the order, was binding. District
   crossings 5,422 -> 2,229, under-4 1,076 -> 526, capex -268M (trench
   190,299 m -> 134,276 m: the tree now targets ~1,700 terminal nodes
   instead of ~3,000 snap nodes).
2. **Retire the remaining under-4 strays (526 district).** These are
   geometry-forced: strays whose neighbours' spare ports sit across
   uncrossable edges, plus the utilization floor eating spare-port slack
   (terminal_ports sits exactly at 95.0% after forced repair — ANY
   change that frees installed ports buys headroom for priced dissolves
   currently blocked). Candidates: cross-cluster dissolve targets
   (needs per-cluster fiber bookkeeping), or a swap pass (2 strays merge
   at a middle node neither currently hosts).
3. **Drop 2-opt / local-search reassignment to uncross drops.** Down to
   669 drop-drop crossings after iter 004 (1,300 -> 669 as a free
   side-effect of node-centric packing). When two drops properly cross,
   swapping their terminal assignments never lengthens the total by more
   than the crossing detour; iterate pairwise swaps (grid-hashed
   candidates, deterministic order) until fixpoint, respecting port
   capacity and the 150 m rule. ProperCross/the edge grid are reusable.
3b. **Street-crossing floor analysis (iter 004 evidence).** 2,229
   district crossings remain; the all-zero-crossing grouping bound says
   only ~3,027 of 6,719 premises fit in all-zero groups of 4..12, so a
   floor well above zero is real — but the greedy's per-move pricing
   (marginal, not global) and the merge repair still leave gap vs the
   ~1,550 the pure greedy simulation reached before utilization repair.
   The binding tension is now utilization-floor vs crossings: forced
   dissolves at the floor buy crossings (measure: engine hits 95.0%
   exactly).

## P1 — trench topology

4. ~~**Ring elimination on the used trench.**~~ DONE iter 002 (866 -> 0
   rings, district capex -160.8M, total score -593.8M). New stage 9
   `DeloopTrench` (stages.carbon): minimum-trench-cost spanning forest of
   the used trench graph (Prim on the existing heap; unique keys
   cost*65536+edge_id), then distribution AND feeder fibers re-routed on
   the forest's unique paths (same snap-node-units sizing semantics),
   term_path_len/fdh_route_len refreshed, trench kept only where cable
   runs. Trench 224,864 m -> 190,299 m (pruning removed more than the
   866 cycle edges: dead alternate branches lost their fibers too).
   QA green, determinism verified byte-identical.
5. **Cross-cluster trench sharing in distribution routing.** Distribution
   Dijkstra should discount already-open trench (opened by any serving
   area or by feeder) the way feeder routing already does, so different
   serving areas share a street instead of opening parallel routes.
   NOTE after iter 002: the forest re-route already collapses duplicate
   corridors post-hoc (sharing_x100 = 113 on the district); remaining
   value is in choosing BETTER corridors during routing, not in dedup.
6. **Feeder/distribution duplicate-route audit.** Report and then shrink
   corridors where feeder and distribution (or two distribution clusters)
   run on parallel nearby edges when one shared trench would do;
   `sharing_ratio` (cable_route_m / trench_m) should rise as duplicates
   collapse. Largely subsumed by iter 002's forest re-route.
6b. ~~**Terminal-off-trench modeling gap (discovered iter 002).**~~
   FIXED iter 004: terminals are packed first, the distribution tree's
   demand nodes ARE the terminal nodes (unit-weighted), and DeloopTrench
   phase 2 re-anchors fibers at term_node (post-merge assignment) — so
   kept trench always reaches every terminal, and the tree shrank to
   boot (fewer, consolidated demand nodes).

## P2 — clustering and packing optimality

7. **Local search (swap/relocate) for serving-area clustering.** After
   greedy seeding, hill-climb: move a boundary premises to the adjacent
   area (or swap two) when it reduces total graph distance without
   breaking FDH capacity; deterministic scan order, fixpoint-bounded.
8. ~~**Exact terminal packing per serving area (DP over the DFS order).**~~
   DONE iter 003, then SUPERSEDED iter 004: the DP's consecutive-batch
   constraint was the binding limit, so the node-centric set-cover greedy
   replaced it (see 1c). District runtime dropped 24 s -> ~11 s. A
   possible future upgrade: replace the greedy's marginal per-move pricing
   with a proper set-cover LP-rounding or swap-based local search.

## P3 — harness and tuning

9. **Overrides section in the interchange** so Python-side optimization
   can pin decisions (fixed terminal nodes, forbidden edges, forced
   serving-area membership) and the engine respects them — enables
   outer-loop search without touching the Carbon inner loop.
10. **Scenario-specific tuning.** Small fixtures fail the utilization
    floor because the smallest FDH cabinet (144) and OLT card sizes dwarf
    tiny demand (see s01/s06 qa FAILs) — decide whether the floor should
    scale with catalog granularity at small N, or whether the catalog
    needs smaller entries; keep the district's floor untouched either
    way. Then tighten room assertions for targets already met.
