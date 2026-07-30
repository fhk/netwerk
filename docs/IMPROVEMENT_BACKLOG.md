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

1. **Drop street-crossing constraint in terminal packing and premises
   reassignment.** A drop (premises -> terminal node) may not properly
   intersect any road edge except at its own frontage. Baseline: 20,028
   crossings on the district alone. Candidate-node selection in packing
   (stage 6) and the reassignment passes must reject terminal nodes whose
   drop segment crosses a road edge (same exact integer orientation test
   the scorer uses), falling back to nearest non-crossing node.
2. **Terminal min-size 4 rule — retire 2-port strays.** Every live
   terminal must serve 4..12 customers. Baseline: 310 terminals under 4
   customers (300x terminal_2p in the district BOM). Fold sub-4 remainders
   into neighboring terminals within drop reach during packing instead of
   emitting stray small terminals; drop the 2p/6p sizes from packing
   choices unless a remainder genuinely cannot merge.
3. **Drop 2-opt / local-search reassignment to uncross drops.** Baseline:
   6,154 drop-drop crossings. When two drops properly cross, swapping
   their terminal assignments never lengthens the total by more than the
   crossing detour; iterate pairwise swaps (grid-hashed candidates,
   deterministic order) until fixpoint, respecting port capacity and the
   150 m rule.

## P1 — trench topology

4. **Ring elimination on the used trench.** Baseline: 866 independent
   cycles (E - V + C over trench=1 edges). The converter emits up to 500
   extra street-crossing edges so routes need not detour around a single
   bridge — but routing should not OPEN trench on crossings (or parcel
   loops) that only close cycles. After routing, audit each cycle and
   drop the costliest redundant edge whose removal keeps all served
   premises connected; the rings metric counts USED trench only.
5. **Cross-cluster trench sharing in distribution routing.** Distribution
   Dijkstra should discount already-open trench (opened by any serving
   area or by feeder) the way feeder routing already does, so different
   serving areas share a street instead of opening parallel routes.
6. **Feeder/distribution duplicate-route audit.** Report and then shrink
   corridors where feeder and distribution (or two distribution clusters)
   run on parallel nearby edges when one shared trench would do;
   `sharing_ratio` (cable_route_m / trench_m) should rise as duplicates
   collapse.

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
