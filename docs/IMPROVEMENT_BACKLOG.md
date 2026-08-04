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
2. **Retire the remaining under-4 strays (213 district after iter 010;
   was 526).** Iter 010's exact re-assignment dissolved 274 of them for
   free by making the serving areas contiguous — appendix A E1's "81
   have a spare-port host within 150 m only in another serving area" was
   an under-count of the seam damage, and the seam is now largely gone,
   so re-measure before building cross-cluster bookkeeping. These are
   geometry-forced: strays whose neighbours' spare ports sit across
   uncrossable edges, plus the utilization floor eating spare-port slack
   (terminal_ports sits exactly at 95.0% after forced repair — ANY
   change that frees installed ports buys headroom for priced dissolves
   currently blocked). Candidates: cross-cluster dissolve targets
   (needs per-cluster fiber bookkeeping), or a swap pass (2 strays merge
   at a middle node neither currently hosts).
3. ~~**Drop 2-opt / local-search reassignment to uncross drops.**~~ DONE
   iter 009, total score -23,634,550 (1,001,173,710 -> 977,539,160), all
   of it on the district and roughly TWICE research.md 5.2's 8-13M band.
   New stage 9b `UncrossDrops` (stages.carbon), run once from `RunDesign`
   after the sweep decision: scan all drop pairs in ascending premises id,
   and for each PROPER crossing price the full scorer delta of swapping
   the two terminal assignments — drop cable, both re-routed drops'
   street crossings via `CountDropCrossings`, and every drop-drop pair
   containing either premises — accepting only a strictly negative delta
   with both new drops inside 150 m and the optical route budget. 4 scans
   to fixpoint, 388 swaps. District: drop-drop 692 -> 147, street
   crossings 2,252 -> 2,027 (the swap that shortens a drop usually
   un-crosses a street too), drop cable 194,816 -> 184,919 m, capex
   -1,484,550. Terminals, under-4 (487), trench, rings, sharing and every
   utilization family are IDENTICAL by construction — the swap preserves
   each terminal's port count, so this is the one pass that cannot spend
   budget elsewhere. Determinism verified byte-identical.

   **The v1 restriction research.md asked for was the binding constraint,
   and it was unnecessary.** Section 5.2 says to allow only same-serving-
   area swaps in v1 because cross-area moves "need the per-cluster fiber
   bookkeeping that does not exist yet" (item 2). Measured with the
   restriction in place: only 55 of 692 crossings cleared, and 579 of the
   residual 637 were cross-area pairs — i.e. 84% of the prize sat behind
   the restriction. It does not apply to SWAPS: item 2's bookkeeping
   problem belongs to the one-way move (dissolve), which changes
   `cluster_units` and everything derived from it. An equal-unit exchange
   leaves `cluster_units`, `cluster_prems`, `cluster_take_units`, the
   cabinet size and each cluster's per-(cluster, node) fiber demand
   invariant, so the pass may rewrite `prem_cluster` freely. Lifting the
   restriction took the gain from ~1.3M to 23.6M. Generalizable lesson:
   before accepting a "needs prerequisite X" caveat, check whether the
   move class is balanced — exchanges are far cheaper to make safe than
   one-way moves.

   Two implementation notes worth keeping:
   (a) The pass runs ONCE, after the two-sweep decision, not inside
       `DesignSweep`. It is the only stage that rewrites `prem_cluster`,
       which both sweeps inherit; running it inside a sweep would break
       the invariant that the pi=0 fallback re-run reproduces sweep 1
       bit-for-bit. Reported `sweep_score` is therefore pre-uncrossing on
       both sides — a fair comparison, just not the final number.
   (b) The uncrossing lemma alone is not a licence to swap: a shorter
       drop can cross a street the longer one avoided (50,000) and either
       new drop can cross a THIRD drop (20,000), so all three terms are
       priced. 147 crossings survive that pricing, 90 of them cross-area
       — those are genuinely priced out or blocked by the 150 m / route
       rules, not blocked by scope. The remaining 147 x 20,000 = 2.94M is
       the ceiling on any further uncrossing work; the min-cost-flow
       Tier-2 solve of 5.2 should be sized against that, not against 692.
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
5. ~~**Cross-cluster trench sharing in distribution routing.**~~ DONE
   iter 005, implemented globally rather than per-Dijkstra: DeloopTrench
   phase 1 now builds ONE Steiner tree (shortest-path heuristic,
   incremental multi-source Dijkstra in trench cents; tree nodes are
   0-cost sources, tree edges relax at 0) over the FULL road graph with
   required = CO + FDHs + live terminal nodes, replacing the spanning
   forest that was restricted to already-opened trench. District trench
   134,276 m -> 123,125 m, capex -51.96M cents; cable got CHEAPER too
   (consolidation into fewer, larger shared cables); s03_grid5 -20,700.
   Phases 2-4 (fiber re-route, path refresh, prune) unchanged.
   WATCH: worst CO->premises route is now 18,060 m of the 20,000 m
   optical budget — further trench consolidation may need a
   length-capped Steiner variant before it trips route_length_budget.
5b. ~~**Trench price inside the terminal-packing move cost (ConFL).**~~
   DONE iter 008, total score -4,985,230 (1,006,158,940 ->
   1,001,173,710); all of it on the district. research.md 5.1b / appendix
   A ranked item 3: `TrenchCostPerM` appeared exactly ONCE in the engine
   (DeloopTrench's Dijkstra) and never in `PackTerminals`, `TryDissolve`
   or `MergeTerminals`, so the stage choosing which ~1,700 nodes the
   trench must reach could not see the cost of reaching them. Implemented
   as the cheap two-sweep Gauss-Seidel version (`src/pipeline.carbon`):
   run the pipeline, price the routed trench with one multi-source
   Dijkstra in `ModeTrenchMarginal` (open trench free, unopened at full
   civil cost) into `node_pi`, re-run packing/merge with `pi_v` in ALL
   FOUR move-price expressions, keep the better-scoring sweep. District:
   capex 797,136,190 -> 793,690,960, trench 123,045 -> 122,256 m,
   terminals 1,753 -> 1,732, under-4 511 -> 487; street crossings +14 and
   drop-drop +8 (the price buys corridor reuse and pays a little geometry
   for it). Scenarios byte-identical (their sweeps tie, so sweep 1 is
   kept). QA green, 95.0% terminal-port utilization held.

   **MEASURED COEFFICIENT** (the point of the experiment — three other
   research.md techniques are budgeted against it). District `pi_v` over
   all 15,668 road nodes, which here are all terminal candidates (every
   node is within 150 m of a premises): min 0, **median 81,000 cents**,
   max 1,669,500, and **9,342 of 15,668 (59.6%) above 50,000**. 81,000
   cents is 18 m of soft trench — which independently reproduces
   appendix A finding D4's ~20 m/terminal (35,387 m of single-serving
   trench over 1,753 terminals, ~90,000 cents) and **refutes section 5's
   flat 210,000 cents/terminal**, which was an arc elasticity across
   iter 004, not a marginal rate. Use ~80-90k, not 210k, when sizing
   §3.3 re-siting and the other pi-dependent techniques.

   Two structural facts learned, both worth carrying forward:
   (a) `pi_v` is ZERO at every terminal the unpriced sweep chose — the
   trench is routed TO the terminals afterwards, so the price can never
   indict the sites it already picked, only the alternatives. That is why
   the two-sweep form is the only cheap way to get information out of it,
   and why the interleaved grow-and-open variant (5.1a) is the real
   prize: it prices sites *while* the corridor is still forming.
   (b) The priced sweep put 100% of its terminals on pi = 0 nodes. The
   price is strong enough (median 81k vs 50k per street crossing) to
   dominate the crossing term, which is exactly why crossings ticked up.
   A damped price (pi_v scaled by a fraction, or amortized over the
   batch's expected size) is the obvious next probe.
6. **Feeder/distribution duplicate-route audit.** Report and then shrink
   corridors where feeder and distribution (or two distribution clusters)
   run on parallel nearby edges when one shared trench would do;
   `sharing_ratio` (cable_route_m / trench_m) should rise as duplicates
   collapse. Largely subsumed by iter 002's forest re-route and iter
   005's global Steiner tree (sharing_x100 113 -> 120 district).
6c. ~~**Steiner tree quality gap — key-path local search.**~~ DONE iter
   011 (research.md 3.2 / 5.5b, appendix A ranked #2). Total
   **-14,811,785** (894,344,640 -> 879,532,855), all of it on the
   district; every scenario byte-identical (their trees are 2-38 key
   paths and already optimal, 0 exchanges each). New stage 9a in
   `stages.carbon`, inserted between `DeloopTrench` phase 1 and the fiber
   re-route: enumerate every key path (maximal tree path whose interior
   is all non-key degree-2 nodes), try them in decreasing (cents, then
   smallest first-edge id) order, and for each one delete it, BFS the two
   components it leaves, and multi-source-Dijkstra the cheapest
   reconnection over the FULL road graph in trench cents. Accept only
   strictly cheaper, re-validate candidates at trial time, repeat to
   fixpoint.

   **MEASURED, with the engine's own isqrt lengths (appendix A D3's
   mandatory haircut):** 4 rounds, 200 exchanges, 2,112 key paths at the
   fixpoint. Tree **119,713 -> 116,666 m (-3,047 m, -2.55%)** and
   **589,959,000 -> 576,436,500 civil cents (-13,522,500, -2.29%)**.
   District capex fell more than that, -14,811,785, because a leaner tree
   also shortens cable (route 144,316 -> 140,191 m). Penalties are
   untouched by construction — crossings 1,509, drop-drop 72, under-4
   213, terminals 1,530, rings 0, all identical to iter 010.

   **This settles appendix A's D2**, which is the reason the item was
   ranked where it was. Section 2's Wong dual ascent certifies at most
   25,552,500 cents of trench slack at the fixed required set; section
   3.2 claimed -15.5M from key-path alone and the reviewer flagged that
   the two cannot both be right. Measured: **-13,522,500, i.e. 52.9% of
   the entire certified slack from one neighbourhood.** Both parties were
   partly wrong in the direction the reviewer predicted — section 3.2's
   -$155,265 was 13% inflated by `round(hypot)` edge lengths (D3 was
   worth exactly what it claimed), and section 2's bound is nonetheless
   too loose to be a useful ceiling, since one Tier-1 local search eats
   half of it and the remaining trench-quality family (key-VERTEX
   elimination, SD reductions, multistart) is untouched. Read 4.22% as
   "at least this much cannot be certified away", never as a distance to
   optimum.

   Three implementation notes worth carrying:
   (a) **The route-length guard cost nothing, and its premise is stale.**
   Appendix A E6/D2 made the `route_length_budget` check mandatory
   because backlog 5 recorded the worst CO->premises route at 18,060 m of
   20,000 m. It is implemented (whole-pass rollback to the phase-1 tree,
   `kp_rollback=1`) and it never fires: the worst route is now **11,718
   m**, 8.3 km of headroom. Iter 010's exact assignment is what did that
   — contiguous serving areas mean nobody is routed across the district
   any more. The WATCH on backlog 5 should be re-read at 11,718, not
   18,060, before anyone builds a length-constrained Steiner variant.
   (b) **The tree invariant is asserted, not assumed.** Removing a path
   and adding a path between exactly two components preserves the tree,
   so rings stay 0 by construction — but a silent ring costs 500,000, so
   `KpTreeOk` BFSes from the CO and checks |E| == |V|-1 plus every
   required node inside, with its own rollback (`kp_rollback=2`). Never
   fired.
   (c) **Second-order effect on the ConFL price.** A leaner tree makes
   reaching a new node dearer: `pi_v` median 85,500 -> 90,000 and nodes
   over 50k 9,413 -> 9,548. Iter 008's measured ~80-90k coefficient still
   holds, at the top of its band.

   Cost: district runtime 18 s -> 36 s (the search runs inside every
   sweep). The hot spot is the two component BFSes plus the O(node_count)
   `DijkstraReset` per trial, not the reconnection itself. A stamped
   Dijkstra reset would roughly halve it. One micro-optimization was
   tried and REVERTED: settling component A's ~5,800 zero-cost sources
   directly instead of pushing them through the heap saved 3 s but
   changed prev-edge tie-breaks into an equal-trench-cost tree with
   17,375 cents more cable. Equal-cost Steiner trees are not equal
   designs — the cable layer breaks the tie, and it is not neutral.

6d. **Next on the Steiner line, in order.** (a) **Key-vertex
   elimination** — research.md 5.5(b) argues it matters more than
   key-path on a lattice, because SPH creates spurious degree-3 Steiner
   vertices where two corridors nearly-but-not-quite coincide; the tree
   still has 2,112 key paths, so the branch structure is rich. Same
   machinery, remove a key VERTEX and re-solve the small Steiner instance
   over its incident key paths' endpoints. (b) **Degree-2 chain
   contraction and the SD test** (5.5a) — exact, and the runtime dividend
   would pay for (a) and for a second Lloyd round (7b) at the same time.
   (c) Multistart SPH from several roots with elite recombination (5.5c);
   deterministic given a fixed root order, but 8x the tree build.
6b. ~~**Terminal-off-trench modeling gap (discovered iter 002).**~~
   FIXED iter 004: terminals are packed first, the distribution tree's
   demand nodes ARE the terminal nodes (unit-weighted), and DeloopTrench
   phase 2 re-anchors fibers at term_node (post-merge assignment) — so
   kept trench always reaches every terminal, and the tree shrank to
   boot (fewer, consolidated demand nodes).

## P2 — clustering and packing optimality

7. ~~**Local search (swap/relocate) for serving-area clustering.**~~
   DONE iter 010, and done exactly rather than by hill-climbing
   (research.md 1.1 item 2 + 1.2, appendix A ranked #5). Total
   **-83,194,520** (977,539,160 -> 894,344,640); district capex
   -$283,945, street crossings 2,027 -> 1,509, drop-drop 147 -> 72,
   under-4 487 -> 213, terminals 1,732 -> 1,530, trench -2,543 m.
   Two stages, and the report prints the decomposition
   (`sweeps: assignment_m:`, unit-weighted premises->cabinet meters):
     - **3c ReassignToFdh** — the ~20-line defect fix. `seed_dist` was
       measured from FARTHEST-POINT seeds; `PlaceFdh` then relocated
       every cabinet to a medoid and never re-assigned, so the design
       optimized its assignment against reference nodes it does not
       build. Refilling the table from `fdh_node` and re-running the
       same greedy is Lloyd's assignment step: **9,824,970 -> 7,685,929
       m (-21.8%)**, district capex -$148,140.
     - **3d TransportRepair** — the greedy is not an *exact* assignment
       step, which is the one thing Lloyd's descent proof requires, and
       measuring 3c alone proved it: id-order "nearest with room" exiled
       premises 6710-6716 into the leftover area 10 km from its cabinet
       and **failed `route_length_budget` (7 violations)**. So 3c must
       NOT ship alone. The repair condenses the residual network onto
       the k<=32 facilities (arc j->j' priced at the cheapest single
       premises that could move, plus a slack node for spare capacity),
       cancels the negative cycle Bellman-Ford finds, and repeats:
       **7,685,929 -> 6,009,457 m (-21.8% more, -38.8% total)** in 1,400
       cycles / 3,206 moves, terminating with `stop=0` — no negative
       cycle left, i.e. an optimality certificate, not a heuristic
       fixpoint. Premises stay single-sourced and a cycle is applied
       only if every area stays within the 432-unit cap and non-empty
       (with u_p > 1 a cycle need not preserve loads).
   Appendix A banked 5-12M cents against a $519,961 addressable
   distribution+feeder pool; the measured 83.2M is 7-16x that, and the
   overrun is NOT cable — cable fell only ~$36k. It is the seam effect
   C2 called unproven: a contiguous assignment lets `PackTerminals`
   choose the natural corner group, so 202 terminals, 518 street
   crossings and 274 under-4 penalties disappear (27.4M of under-4 +
   25.9M of crossings + 1.5M of drop-drop). The lesson is that stage 3's
   real coupling is to the PACKING stage, not to the cable catalog —
   which is why the per-cluster-SPT simulator (C1) under-predicted it.
7b. **Next on this line, in order.** (a) A second Lloyd round —
   re-run `PlaceFdh` on the repaired membership, then 3c+3d again; the
   sites are still the medoids of the OLD partition (research 1.0(ii)
   measured a further -13% of assignment meters for 2 rounds), cost is
   ~1,024 more Dijkstras. (b) `RebalanceClusters` is now provably dead
   weight — it degrades the assignment to defend a cabinet-packing
   objective worth about $700 (15x432+288 = $39,300 vs a balanced
   16x432 = $40,000, and balanced still clears the FDH floor at 97.2%),
   and 3d re-optimizes on top of it anyway; delete it and measure.
   (c) With the assignment exactly optimal at fixed sites, the open
   question moves to the SITES: k as a decision variable (research 1.7,
   but re-run under the 432 cap — appendix A B7).
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

## OPEN QUESTION — is `util_fdh_capacity >= 95%` reachable? (iter 007)

Iteration 007 closed 10 of the 14 standing QA errors by adding catalog
granularity that real vendors actually sell (12/24/48/96-unit FDH
pedestals, 1- and 2-port OLT cards, a 1:2 splitter) and by giving the
splitter bank a minimal-cover remainder fill (26 ports = 16+8+2 exactly,
instead of one 1:32 at 81%). Terminal, splitter and OLT-card utilization
now clear the floor on every fixture.

The remaining 4 errors are all `util_fdh_capacity`, and they look
**structurally unreachable, not merely unoptimized**:

| fixture | units | smallest covering cabinet | utilization |
|---|---|---|---|
| s02_parallel_streets | 40 | 48 | 83.3% |
| s04_culdesac | 40 | 48 | 83.3% |
| s05_two_islands | 35 | 60 (2 areas) | 58.3% |
| s03_grid5 | 155 | 288 | 53.8% |

A serving area buys exactly ONE cabinet, so utilization is
`units / smallest_catalog_size_at_or_above(units)`. Clearing 95% for 40
units needs a 40-42 size; for 155 units a 155-163 size. A catalog that
guarantees 95% for arbitrary demand needs sizes in geometric progression
with ratio <= 1.0526 — roughly 40 sizes between 12 and 432, which is not
real equipment. The parcel district passes at 99.2% only because
clustering is free to *choose* ~432-unit areas; a fixed 40-premises town
has no such freedom.

The other three families are not analogous: they buy N small units and
can always tile demand closely.

Candidate resolutions (needs a decision — do NOT silently relax the
scorer, that is how a campaign starts optimizing its own yardstick):
  (a) Keep the gate; accept 4 permanent scenario errors as an honest
      record of a catalog bound. Costs a fixed 4M in the composite.
  (b) Replace the FDH *gate* with the condition the design actually
      controls: "cabinet is the smallest catalog size covering the
      area's units" (strictly enforced), and keep the percentage as a
      reported-only metric. Arguably TIGHTER — it forbids any oversizing
      beyond the minimum, even at 96% — but it does erase 4M of penalty,
      so the ledger must show the score both ways on the switching
      iteration.
  (c) Make cabinet capacity a clustering objective (size serving areas
      to catalog boundaries). Real, but only helps where cluster count
      is a free variable — i.e. not the small scenarios.

Recommendation: (b) with dual-scoring on the switching iteration, plus
(c) as a separate district-side optimization.
