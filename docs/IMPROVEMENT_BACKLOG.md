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
1c. **DFS-order interleaving is still the constraint** (was candidate
   (b)): batches are consecutive runs of the distribution-tree DFS
   order, which interleaves opposite lot rows and jumps across
   intersections, so even the optimal partition pays crossings the
   ORDER forces. Order premises within a node run by lot-row side (e.g.
   sort by side of the frontage edge, then along it) so runs stop
   interleaving; the DP then partitions a cleaner sequence. Evidence:
   5,422 crossings remain with an optimal partition, so ~all of them
   are order-forced or geometry-forced.
2. **Terminal min-size 4 rule — retire 2-port strays.** 1,076 under-4
   terminals after iter 003 (deliberate DP trades: 2-port vs >=2
   crossings). A post-pack premises<->terminal swap pass (candidate (c),
   reusing CountDropCrossings) could dissolve strays without re-adding
   crossings where geometry allows; MergeTerminals alone cannot —
   neighbors close exactly full.
3. **Drop 2-opt / local-search reassignment to uncross drops.** Down to
   1,300 drop-drop crossings after iter 003 (6,154 -> 1,856 -> 1,300)
   as a free side-effect of shorter/cleaner drops (mean 31.8 m). When
   two drops properly cross, swapping their terminal assignments never
   lengthens the total by more than the crossing detour; iterate
   pairwise swaps (grid-hashed candidates, deterministic order) until
   fixpoint, respecting port capacity and the 150 m rule. ProperCross/
   the edge grid from iter 001 are reusable here.

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
6b. **Terminal-off-trench modeling gap (discovered iter 002).** Fibers
   are sized by premises snap-node units, not by terminal location; after
   forest pruning a terminal can sit on a node whose branch carries no
   fiber (its customers' snap nodes route elsewhere). No scorer/QA rule
   measures trench-to-terminal continuity today; if one is ever added
   (tighten-only), fiber accounting should walk from term_node instead of
   snap nodes.

## P2 — clustering and packing optimality

7. **Local search (swap/relocate) for serving-area clustering.** After
   greedy seeding, hill-climb: move a boundary premises to the adjacent
   area (or swap two) when it reduces total graph distance without
   breaking FDH capacity; deterministic scan order, fixpoint-bounded.
8. ~~**Exact terminal packing per serving area (DP over the DFS order).**~~
   DONE iter 003 (see item 1b): shortest-path DP over DFS positions with
   scorer-priced batch arcs replaced the greedy batch split. District
   runtime 15 s -> 24 s (the DP evaluates every start position instead of
   ~1/7th of them); fine for now, and the batch-cost table is the natural
   place to bolt on smarter candidate node ranking later.

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
