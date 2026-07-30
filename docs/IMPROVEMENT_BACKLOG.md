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
1b. **Batch composition is now the binding constraint on the remaining
   7,498 crossings AND the 828 under-4 terminals.** Batches are
   consecutive runs of the distribution-tree DFS order, which interleaves
   opposite lot rows and jumps across intersections, so packing often
   faces "12 with many crossings vs 2 with none" and the priced choice
   splinters into 2-ports (terminals_under_4 rose 310 -> 828, +52M).
   Fix candidates, in order of expected value: (a) DP over the DFS order
   (item 8) with the iter-001 batch cost — optimal consecutive partition
   instead of greedy; (b) order premises within a node run by lot-row
   side so runs stop interleaving; (c) post-pack premises<->terminal swap
   pass reusing CountDropCrossings.
2. **Terminal min-size 4 rule — retire 2-port strays.** 828 under-4
   terminals after iter 001 (was 310). MergeTerminals cannot consolidate
   them: neighbors are exactly-full 4/4s with no spare ports under their
   chosen size. Needs swap-based repacking (move a member out of a full
   terminal to make room for a stray's 2) or the item-1b DP, which
   sizes batches 4+ whenever geometry allows.
3. **Drop 2-opt / local-search reassignment to uncross drops.** Down to
   1,856 drop-drop crossings after iter 001 (was 6,154) as a free
   side-effect of shorter drops (mean 59.5 m -> 37.4 m). When two drops
   properly cross, swapping their terminal assignments never lengthens
   the total by more than the crossing detour; iterate pairwise swaps
   (grid-hashed candidates, deterministic order) until fixpoint,
   respecting port capacity and the 150 m rule. ProperCross/the edge
   grid from iter 001 are reusable here.

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
8. **Exact terminal packing per serving area (DP over the DFS order).**
   Premises arrive tree-ordered along the distribution DFS; optimal
   partition into runs of 4..12 with a placement-cost term is a small
   shortest-path DP over that order — replaces the greedy batch split and
   guarantees no under/oversized terminal where feasible.

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
