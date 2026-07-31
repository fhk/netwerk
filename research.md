# netwerk — advanced optimization research

**Status:** research report, not yet implemented · produced by a 6-agent
workflow (5 parallel deep dives + 1 adversarial review) · all figures
measured against the shipped district design at iteration 007.

## What this is

The improvement campaign (`results/LEDGER.md`) cut the composite score
2.94B → 0.97B in seven iterations, but per-iteration gains have flattened
below 1%. This report asks what the *next order of magnitude* of technique
would be: capacitated clustering theory, MILP duality and dual bounds,
network-flow and Steiner formulations, CP-SAT modelling, and the
state-of-the-art beyond the standard playbook.

Every section is grounded in the real instance — 6,719 premises, 15,668
nodes, 23,824 edges, 16 serving areas, 1,753 terminals — and each
technique is classified **Tier 1** (implementable now in integer-only
Carbon, byte-deterministic, no solver) or **Tier 2** (needs the M3 C++
interop to HiGHS / OR-Tools CP-SAT).

## Where the score actually is

```
score 973,816,190 = capex 797,136,190
                  + street crossings 2,238 × 50,000 = 111,900,000
                  + drop-drop      684 × 20,000 =  13,680,000
                  + under-4 terms  511 × 100,000 =  51,100,000
                  + rings 0, qa 0
```

Capex decomposes (verified to the cent by three independent agents against
`designs/parcels_district.report.txt`):

| line | cost | share of capex |
|---|---|---|
| trench | $6,054,465 | 76.0% |
| drop assemblies | $806,280 | 10.1% |
| distribution cable | $480,641 | 6.0% |
| drop cable | $290,906 | 3.6% |
| terminals | $206,390 | 2.6% |
| feeder cable | $39,320 | 0.5% |
| FDH cabinets | $39,300 | 0.5% |
| splitters / OLT | $54,060 | 0.7% |

**Trench is the whole game.** Cabinet catalog fit — the open question in
`docs/IMPROVEMENT_BACKLOG.md` — is worth at most ~$700 at the current `k`
and is **provably optimal already** (§2, verified in review: 15×432 + 1×288
= $39,300 is the min-cost multiset covering 6,719 units, and the design
pays exactly that). That line can be closed permanently.

## Headline findings

1. **There is now a lower bound.** §2 builds a Wong dual-ascent bound on
   the trench Steiner tree: **≥ 4.22% of trench slack cannot be certified
   away**, and the certified optimality gap on the whole design is ≤ 27.6%.
   The campaign had no bound at all before this; two lines (cabinets, OLT
   within $5.6k) are now provably closed.
2. **The clustering stage optimizes against reference points it does not
   build.** `Cluster()` assigns premises to *farthest-point seeds*,
   `PlaceFdh()` then relocates each cabinet to a medoid and never
   re-assigns, and `RebalanceClusters()` degrades the result further to
   defend a cabinet-packing objective worth ~$700. A ~20-line re-seed is
   the cleanest defect in the repo.
3. **The stage that chooses where trench must go cannot see trench cost.**
   `TrenchCostPerM` appears exactly once in `stages.carbon` — inside
   `DeloopTrench` — and never in `PackTerminals`/`MergeTerminals`. All five
   sections independently converged on this.
4. **Drop-drop crossings may be structurally eliminable.** A
   minimum-total-length matching in the plane is automatically non-crossing
   (uncrossing lemma); all 684 crossings are inter-terminal, so a priced
   2-opt is provably terminating and load-preserving.
5. **An incremental delta-scorer is the hidden prerequisite.** Four of five
   sections' best ideas need many evaluations/second; at 11 s per full
   evaluation they are unusable. Nobody ranked it — the review did.

## What to build first (adversarial review's ranking, not the sections')

| # | technique | est. gain (cents) | tier | effort |
|---|---|---|---|---|
| 1 | Priced terminal re-siting along private trench spurs (§3.3) | 20–35M | 1 | ~250 lines |
| 2 | Key-path local search on the trench tree (§3.2, §5.5b) | 8–15M | 1 | ~200 lines |
| 3 | Trench price `π_v` inside terminal-packing move cost (§5.1b, §4) | 5–15M | 1 | ~40 lines |
| 4 | Priced 2-opt drop uncrossing (§5.2) | 8–13M | 1 | ~120 lines |
| 5 | Exact premises→FDH assignment + medoid re-seed (§1.1–1.2) | 5–12M | 1 | ~220 lines |

Gains are **not additive** — items 1, 3 and parts of §5 are different
fidelities of the same idea (put trench price inside siting). A realistic
combined ceiling is **80–150M cents (8–15% of score)**, not the ~265M the
sections sum to.

> **Read Appendix A before implementing anything.** The adversarial review
> found one invalid lower-bound formulation, eight misattributed citations
> (corrected inline), and several overclaimed gains. Its haircuts are
> applied in the table above but not always inside the section text.

---


---

## 1. Capacitated clustering and serving-area design

### 1.0 What stage 3 does today, and what I measured before recommending anything

`Cluster()` in `src/stages.carbon:195` is: (a) `k = ceil(total_units / 432)`; (b) farthest-point seeding on graph distance, anchored at premises 0's snap node; (c) `k` Dijkstras filling `seed_dist[32 × 12288]`; (d) **one pass** of "assign each premises to the nearest seed that still has room", MDUs first then premises in id order; (e) `RebalanceClusters()` shuttles premises from the emptiest area to the fullest-below-capacity area to pack cabinets; (f) `PlaceFdh()` then puts each FDH at the unit-weighted 1-median (medoid) over **at most 64** stride-sampled member snap nodes.

Before writing this section I ran probes against the shipped district design (`designs/parcels_district/`, 6,719 premises, 16 areas, 1,753 terminals). Four measurements drive everything below.

**(i) Where the money actually is.** From `designs/parcels_district.report.txt`, capex $7,971,361.90 decomposes as trench $6,054,465 (76.0%), drop assemblies $806,280, **distribution cable $480,641**, drop cable $290,906, terminals $206,390, feeder cable $39,320, **FDH cabinets $39,300 (0.49% of capex, 0.40% of score)**, splitters $26,340, OLT $27,720.

**(ii) The assignment is ~40–48% away from its own optimum.** I built the road graph from `data/parcels_district.txt` (15,668 nodes / 23,824 edges), ran Dijkstra from each of the 16 shipped FDH nodes, and solved the capacitated assignment of the 1,753 terminals to those **same 16 sites** exactly, as a min-cost flow (successive shortest paths with potentials):

| unit-weighted FDH→terminal graph distance | m·units |
|---|---|
| shipped design | 9,949,584 |
| **exact transportation optimum, same 16 sites** | **6,001,567 (−39.7%)** |
| + 2 medoid (Lloyd) site-update rounds | 5,217,644 (−47.6%) |
| uncapacitated lower bound (infeasible) | 4,823,924 |

Priced through netwerk's own cable catalog on per-cluster shortest-path trees (identical cost model on both sides, 10% spare, stacking above 288f): shipped $625,021 → transportation optimum $356,835 (−42.9%) → +2 Lloyd rounds $325,677 (−47.9%). My simulator over-states the engine's real $480,641 by 1.30× because the engine consolidates on one shared Steiner tree, so the *relative* delta is the trustworthy number.

**(iii) The serving areas are not contiguous — they are shredded.** On a 4-nearest-neighbour terminal adjacency graph the 16 serving areas break into **615 connected components**. 50.7% of 6-NN terminal pairs cross a serving-area boundary; **29.6% of premises have their nearest neighbouring premises in a different serving area**; 34.8% of premises pairs within 40 m are cross-area. Re-solving the assignment as a min-cost flow (same sites) alone drops this to **123 components / 17.2% cross-boundary**.

**(iv) Fragmentation is measurably taxing the terminal stage.** Of the 492 sub-4-port terminals, **81 have a spare-port host within 150 m only in another serving area** (45 have one in their own area and are blocked by something else — crossings or the utilization floor). Since `PackTerminals(d, c)` runs per cluster, those 81 are pure seam damage: 8.1M cents of `terminals_under_4` penalty plus hardware.

The headline: **cabinet capacity waste is not the clustering prize — assignment quality and contiguity are.** The whole cabinet BOM is $39,300 and the design is already at 99.2% FDH utilization; there is at most $2k of catalog-fit money on the table at the current `k`. The assignment error is worth 10–100× that.

---

### 1.1 Why naive Lloyd's breaks under hard capacity — and why netwerk's clustering is worse than naive Lloyd

**What Lloyd's is.** Minimum sum-of-squares clustering: minimize `Σ_p Σ_j x_pj · ‖z_p − c_j‖²` over `x_pj ∈ {0,1}`, `Σ_j x_pj = 1`. Lloyd (1982) alternates (A) assign each point to its nearest center, (B) set each center to its cluster's centroid. The monotone-descent proof has exactly one requirement: **step (A) must be an exact minimizer of the objective for fixed centers.** Unconstrained, that is trivially "nearest center". Add `Σ_p u_p x_pj ≤ C_j` and it is no longer trivial — it is a transportation problem — and any cheaper surrogate destroys the descent guarantee, so the algorithm can cycle or terminate at an arbitrarily bad point.

**Three named failure modes, all present in `Cluster()`:**

1. **Order-dependent capacity blocking (unbounded ratio).** Greedy "nearest seed with room" processes premises in a fixed order; the last premises to be considered finds its natural area full and is exiled. Construct: two seeds at distance `L`, `C+1` premises in a tight ball at seed 1, `C−1` at seed 2. Greedy fills area 1 to `C`, then exiles one premises across `L`; the optimum moves one *boundary* premises instead. Ratio grows without bound in `L`. Netwerk's order is "MDUs, then premises id" — spatially arbitrary. This is precisely the mechanism producing 615 components.
2. **Assign-to-seed / route-from-medoid mismatch.** `seed_dist` — the distance table used by both assignment and rebalance — is measured from **farthest-point seeds**, which are by construction extremal points of the graph. `PlaceFdh()` then relocates each cabinet to a medoid and **never re-assigns**. The design therefore optimizes assignment against reference points that are not the facilities it builds. Fixing only this (recompute `seed_dist` from the medoids and re-run assignment, i.e. one Lloyd iteration) is a ~10-line change.
3. **A repair pass that does not price the objective.** `RebalanceClusters()` picks donor = emptiest area, receiver = fullest-below-capacity, and moves the donor premises **nearest the receiver's seed** — it never looks at what the donor loses. The correct move value is `Δ = d(p, recv) − d(p, donor)`; using `d(p, recv)` alone systematically strips premises that were well-placed. And its objective — cabinet packing — is worth $39,300 in total while the distances it is degrading are worth $480,641. This is the repo's own hard-won fact ("any repair pass that moves things without pricing the true objective silently spends the budget the optimizer saved") firing in stage 3b.

Citations: Lloyd (1982, *IEEE Trans. Inf. Theory* 28:129–137, written 1957); Bradley, Bennett & Demiriz (2000, MSR-TR-2000-65) and Malinen & Fränti (2014, *SSPR/SPR*, LNCS 8621:32–41) both make the "assignment step must be solved exactly" argument explicitly; Kariv & Hakimi (1979, *SIAM J. Appl. Math.* 37:539–560) for NP-hardness of *p*-median on graphs.

---

### 1.2 Assignment as a transportation problem / min-cost flow — the single highest-value change in this section

**Formulation.** Sets: premises `P` (or, better, terminals `T` after packing), facilities `J`, `|J| = k ≤ 32`. Data: integer graph distance `d_pj` (meters), demand `u_p`, capacity `C = 432`. Variables `x_pj ∈ [0,1]`.

```
min   Σ_{p∈P} Σ_{j∈J}  u_p · d_pj · x_pj
s.t.  Σ_j x_pj = 1                    ∀p        (each premises served once)
      Σ_p u_p · x_pj ≤ C              ∀j        (cabinet capacity)
      x ≥ 0
```

This is a transportation problem; its constraint matrix is totally unimodular, so **the LP optimum is integral whenever the `u_p` are integral** — and in the district every premises has `units = 1` (6,719 premises / 6,719 units), so the LP *is* the integer optimum, with no rounding needed. MDU fixtures (`s06_mdu_block`) with `u_p > 1` can split a premises across two facilities; that degenerates to a single-source (generalized-assignment) problem, NP-hard in general, but I measured only 29 of 1,753 terminals fractional at the optimum — a trivial repair.

**Exact algorithm sized for `k ≤ 32` (no LP solver needed).** Condense the residual network onto the `k` facility nodes. Maintain an assignment `a(p)` and loads `L_j`. Define the reduced digraph `D` on `J` with

```
w(j → j')  =  min_{p : a(p)=j}  u_p · ( d_{p,j'} − d_{p,j} )        (∞ if the min set is empty)
arg(j → j') = the minimizing p, ties broken by smaller premises id
```

Repeat: find the minimum-weight path in `D` from any over-loaded `j` (`L_j > C`) to any under-loaded `j'`; shift the corresponding chain of premises one step along it; update loads. Bellman–Ford over `k ≤ 32` nodes suffices (negative arcs occur; there are no negative cycles at optimality if you start from a greedy assignment and always take the minimum-weight path — equivalently run SSP with node potentials so all reduced costs are ≥ 0). Terminate when no facility is over capacity **and** no negative-weight cycle exists in `D` — the second condition is the optimality certificate and costs one Bellman–Ford. This is textbook successive-shortest-path for transportation (Ahuja, Magnanti & Orlin 1993, *Network Flows*, ch. 9), specialized to a tiny sink side.

**Why it fits netwerk.** It attacks stage 3, metric = distribution cable meters and catalog step-ups (`dist_cable_*` = $480,641) plus `route_length_budget` headroom (currently 18,060 m of 20,000). It reuses `seed_dist` verbatim. And it needs no floats: costs are `u_p · Δmeters`, i64 throughout.

**Expected gain.** Measured −42.9% on simulated distribution cable at fixed sites, −47.9% with two medoid rounds. Scaling the ratio onto the real BOM: $480,641 × 0.52 ≈ $250k, i.e. **$120k–$230k saved = 12M–23M cents = 1.2%–2.4% of the district score.** I state the band because the engine's shared Steiner tree already recovers some of the locality my per-cluster simulator does not; the low end assumes half the simulated delta survives consolidation. For calibration, iterations 005→007 together moved 9.5M cents.

**Complexity / runtime at 6.7k/15.7k/23.8k.** `k` Dijkstras (already paid: ~32 × ~1 ms compiled). Rebuilding all `k²` arcs costs `O(|P|·k)` = 215k ops (or `O(|T|·k)` = 56k if run on terminals); Bellman–Ford on 32 nodes is negligible. Augmentations ≤ initial excess (a few hundred to ~2,000 from a greedy warm start). Total well under 1 s — cheap next to `PlaceFdh()`'s existing 16 × 64 = 1,024 full-graph Dijkstras. Memory: `a[12288]`, `L[32]`, `w[32][32]`, `arg[32][32]` — all fixed-size.

**Tier: 1.** Sketch: replace the assignment loop in `Cluster()` with `GreedyAssign()` (keep the current pass as warm start) + `TransportRepair()`. Deterministic tie-breaks: minimum weight, then lower target facility index, then lower premises id. **Tier 2** alternative: OR-Tools `SimpleMinCostFlow` or HiGHS on the LP; interop surface = `(int64 arc_tail[], arc_head[], capacity[], unit_cost[], supply[])` in, `flow[]` out — but note the Tier-1 version is *exact* here, so Tier 2 buys nothing except when MDU single-sourcing must be enforced (then CP-SAT with `Σ_j x_pj = 1, x binary`).

Citations: Bradley, Bennett & Demiriz (2000); Malinen & Fränti (2014) — Hungarian assignment, `O(n³)`, over-kill here because `k` is tiny; Gnägi & Baumann (2021, *Computers & OR* 132:105304) for the modern large-scale capacitated-clustering matheuristic that alternates exact assignment with MIP-based center selection.

---

### 1.3 Capacity-constrained Voronoi / power diagrams — the same optimum, but contiguous for free

**What it is.** The LP dual of §1.2 has one price `λ_j` per facility:

```
max  Σ_p π_p − C · Σ_j λ_j      s.t.  π_p ≤ u_p·d_pj + λ_j,  λ ≥ 0
```

At optimality each premises goes to `argmin_j ( d_pj + λ_j/u_p )`. With squared-Euclidean cost this partition is exactly a **power diagram** (Aurenhammer 1987, *SIAM J. Comput.* 16:78–96), and Aurenhammer, Hoffmann & Aronov (1998, *Algorithmica* 20:61–76) prove the key existence result: **for any prescribed cluster sizes there exist weights whose power diagram realizes them**, and the resulting assignment is the constrained least-squares optimum. Balzer, Schlömer & Deussen (2009, *ACM TOG* 28(3):86) give the swap-based capacity-constrained Lloyd variant; Xin et al. (2016, *ACM TOG* 35(6)) give centroidal power diagrams with capacity constraints; de Goes et al. (2012, *ACM TOG* 31(4)) frame the same thing as semi-discrete optimal transport.

**The netwerk-specific payoff, which I think is the elegant result of this section.** netwerk's cost is *linear* in a *graph* metric, so the dual-optimal cells are the additively-weighted (Apollonius) analogue on the graph: `cell(j) = { v : d(v,j) + λ_j minimal }`. That is **precisely a multi-source Dijkstra where source `j` is inserted with initial label `λ_j` instead of 0** — machinery `graph.carbon` already has (`AddSource` + `DijkstraRun`, used by the farthest-point seeder and by `DeloopTrench`'s Steiner growth). Two consequences:

- One `O(E log V)` Dijkstra computes the *entire* assignment; the outer loop only adjusts 32 integers.
- **Every cell is a connected subgraph, by construction.** In a shortest-path forest each node's parent lies in the same cell, so contiguity — the thing §1.4 otherwise needs MILP machinery for — is free. Min-cost flow alone got 615 → 123 components; the offset-Dijkstra construction gets it to 16 by definition.

**Price update.** Integer subgradient with ε-scaling (Bertsekas' auction, 1979/1988; ε-scaling certifies exactness once ε < 1/n for integer costs): start ε = 16384; loop `λ_j += ε` for over-full `j`, `λ_j −= ε` (floored at 0) for under-full `j`, re-run Dijkstra; when no ε-move improves, halve ε; stop at ε = 1. ~15 phases × ~20–60 iterations ≈ 300–900 Dijkstras ≈ 0.3–1 s.

**Honest caveat.** Exact capacity satisfaction at integer prices needs a deterministic tie-break at cell boundaries (nodes with two equal `d + λ`), plus a bounded repair that walks the boundary front. Aurenhammer et al.'s existence theorem is continuous; the integer version can leave ±few units of imbalance. Fix: run the offset-Dijkstra to get contiguous cells, then run §1.2's transportation repair **restricted to boundary premises** to land capacity exactly, then one final projection pass to restore contiguity. I have not measured this hybrid; the 615→123→(16) chain is my basis for expecting it to keep most of the −42.9%.

**Tier: 1.** ~200 lines: `λ[32]` i64, offset multi-source Dijkstra, ε-scaling loop, boundary repair. **Tier 2:** none needed — this is one of the rare cases where the solver-free version is the *better* one, because LP/MIP min-cost flow gives you the optimum without giving you connectivity.

**Expected gain:** the §1.2 gain (12M–23M cents) **plus** the seam gains it unlocks: ≥81 cross-seam under-4 dissolves (8.1M cents) and their terminal hardware, plus a share of the 2,238 street crossings (packing can now choose the natural corner group instead of a cluster-truncated one). Call it **20M–33M cents total, 2%–3.4% of score.**

---

### 1.4 Contiguity as an explicit constraint

**Why serving areas must be connected subgraphs, in netwerk's terms specifically:** (a) `PackTerminals(d, c)` iterates over `d.prem_cluster[pm] == c` — a fragmented cluster physically cannot group neighbouring premises onto one terminal; that is the 81 blocked strays; (b) distribution cable rides FDH→terminal tree paths, and an exclave drags full-count fiber across the whole district; (c) the `route_length_budget` QA gate (18,060/20,000 m) is a max over root-to-premises paths, which exclaves dominate; (d) buildability — a serving area is a construction and patching unit, and a 38-piece "area" is not a design a planner would revise rather than redo (SCOPE.md goal 2).

**Formulations, ranked by fit:**

- **Shortest-path-forest (implicit)** — §1.3. Contiguity by construction, zero extra variables. *Tier 1. Recommended.*
- **Tree-cut (implicit, and trench-aware)** — §1.5. Also contiguous by construction.
- **Flow-based (Shirabe 2009, *Environment and Planning B* 36:1053–1066)**: for each district center `i`, continuous flow `f^i_{uv}` on graph arcs; every assigned unit consumes one unit of flow, only the center is a source, flow only on arcs whose both endpoints are assigned to `i`. `O(|E|·k)` continuous variables — for netwerk 23,824 × 16 = 381k variables. *Tier 2, and heavy.*
- **Cut-based (Validi, Buchanan & Lykhovyd 2022, *Operations Research* 70(2):867–892)**: for every `a–b` separator `S`, `x_{aj} + x_{bj} − Σ_{v∈S} x_{vj} ≤ 1`; exponentially many, separated lazily by max-flow. Their branch-and-cut solved 21 US states at census-tract level, so 15.7k nodes / 16 districts is within demonstrated reach. *Tier 2; needs HiGHS/CPLEX with a lazy-constraint callback — the interop surface must expose callback registration, not just `solve()`. That is a real constraint on the M3 interop design and worth flagging now.*
- **MTZ-style depth labels**: order/depth variable `r_v` with `r_v ≥ r_parent + 1` on selected arcs. Compact but notoriously weak LP bounds (same pathology as MTZ for TSP, Miller, Tucker & Zemlin 1960). *Not recommended.*
- **MST-pruning (SKATER, Assunção, Neves, Câmara & Freitas 2006, *IJGIS* 20:797–811)**: build an MST on the contiguity graph, delete `k−1` edges. Cheap, contiguous, and the direct ancestor of §1.5.

---

### 1.5 Trench-aware clustering: cut the Steiner tree, don't cluster the plane

This is the technique that directly addresses the repo's own discovery that cluster shape changes trench cost, and it is the one I would build second (after §1.2/§1.3).

**Observation that reframes the problem.** After iter 005, `DeloopTrench` builds **one global Steiner tree** `T` over `CO ∪ FDHs ∪ terminal-nodes` and all trench is `T`. The terminal node set is (nearly) determined by premises geometry, not by clustering; so **trench is close to invariant under re-clustering**, and clustering's whole leverage is on *cable riding `T`*, cabinets, and feeder. That is why §1.2's gain lands in `dist_cable_*` and not in `trench_*`. It also means the natural domain for clustering is `T` itself, not the road graph.

**Formulation.** Root `T` at the CO. Choose a set of `k−1` edges to delete; each resulting component is a serving area; the FDH sits at the component's unit-weighted 1-median (linear time on a tree — Kariv & Hakimi 1979 give the tree case); feeder runs CO→FDH along `T`.

```
minimize  Σ_{components A}  [ cab(u_A) + Σ_{e ∈ A} cableCost( fiberDemand_A(e) ) · len(e)
                              + Σ_{e ∈ path_T(CO, fdh_A)} feederCost(...) · len(e) ]
subject to  u_A ≤ 432 for every component A
```

**DP recurrence** (contract `T` to its ~1,769 required nodes first). Root the tree; for node `v` let `g[v][u]` = min cost of `v`'s subtree given that `u` units are still attached to `v`'s component and will be charged when that component is finally closed by a cut above `v`. Merging child `c` into `v`:

```
g'[v][u + w] = min( g[v][u] + g[c][w] + cable(w, edge(v,c)) )        # keep edge (v,c)
g'[v][u]     = min( g[v][u] + g[c][w] + close(c, w) )                # cut edge (v,c)
close(c, w)  = cab(w) + median-and-feeder cost of the component rooted at c with w units
```

with `u + w ≤ 432` enforcing capacity. `k` falls out of the number of cuts (or is bounded by adding a cut counter, +`O(k)` on the state).

**Complexity.** States `Σ_v min(size(v), C)` with `C = 432` over ~1,769 contracted nodes ≈ 7.6×10⁵; the merge is the classic tree-knapsack convolution, `O(n·C)` amortized under the standard bounded-subtree argument (Lukes 1974, *IBM J. Res. Dev.* 18(3):217–224, is the exact DP; Kundu & Misra 1977, *SIAM J. Comput.* 6(1):151–154, is the linear-time min-parts version). Expect **well under 1 s**; the `close()` term needs the component's 1-median, computed incrementally by tree re-rooting in `O(1)` amortized per node.

**Tier 1** for the greedy version (bottom-up: accumulate subtree units, cut the edge above whenever the accumulation would exceed 432 — Kundu–Misra, `O(n)`, trivially deterministic), **Tier 1 for the full DP** if the units axis is quantized to, say, 8-unit buckets (54 buckets × 1,769 nodes = 96k states). **Tier 2** if you want the exact joint version (tree choice *and* partition) — that is Connected Facility Location (Gollowitzer & Ljubić 2011, *Computers & OR* 38(2):435–449; Leitner & Raidl, MIP models for hop-constrained ConFL), an ILP with facility-opening plus Steiner-connectivity cuts, solvable by HiGHS branch-and-cut on the contracted graph.

**Pipeline consequence, and this is the part with the largest downstream effect.** Today the order is cluster → place FDH → pack terminals (per cluster) → route → global Steiner. Tree-cut clustering permits: **pack terminals globally (no cluster constraint) → build the global Steiner tree → cut it into serving areas → place FDHs.** That removes seam damage from terminal packing *entirely* rather than repairing it — all 81 blocked strays, plus whatever share of the 2,238 crossings comes from cluster-truncated corner groups. It is a reordering of existing stages, not new algorithms.

**Expected gain.** Contiguity + locality on `T` should reach the same −40%-ish cable delta as §1.2 (they are competing routes to the same place, not additive), **plus** the packing-seam gains: 8.1M cents of measured under-4 penalty, plus terminal hardware (~$80–$120 each on ≥81 units ≈ $8k), plus a plausible 100–300 street crossings (5M–15M cents) — I am extrapolating the crossing figure from the fact that 34.8% of ≤40 m premises pairs currently straddle a boundary, not measuring it. **Net incremental over §1.3: 8M–20M cents.**

---

### 1.6 Catalog-boundary (capacity-waste-aware) cluster sizing — the OPEN QUESTION, answered

**Formulation as set partitioning over catalog sizes.** Let `A` be candidate serving areas (connected, `u_a ≤ 432`), `S = {12,24,48,96,144,288,432}` the cabinet catalog with costs `F_s`, and `g(u) = min{ F_s : S_s ≥ u }` — a step function.

```
min   Σ_{a∈A} c_a y_a ,    c_a = g(u_a) + cable(a) + feeder(a)
s.t.  Σ_{a ∋ p} y_a = 1   ∀p ∈ P
      y_a ∈ {0,1}
```

`|A|` is exponential, so solve by column generation: the master is the LP above, the pricing problem is "find a connected subgraph with `u ≤ 432` of minimum reduced cost `c_a − Σ_{p∈a} π_p`" — a capacity-constrained maximum-weight connected subgraph problem. This is the Garfinkel & Nemhauser (1970, *Management Science* 16(8):B495–B508) districting scheme with the Mehrotra, Johnson & Nemhauser (1998, *Management Science* 44:1100–1114) column-generation upgrade. The step function `g` makes it structurally a **variable-sized bin packing** (Friesen & Langston 1986, *SIAM J. Comput.* 15:222–230) fused with clustering; the facility-location statement with a discrete menu of capacities per site is the **modular capacitated location problem** (Correia & Captivo 2003, *Annals of Operations Research* 122:141-161; also Correia & Captivo 2006, *Computers & OR* 33:2991–3003 on bounds for the single-source variant).

**Verdict on the district: this is not where the money is, and the backlog's option (c) should be recorded as a measured negative.** The entire FDH cabinet BOM is **$39,300 = 0.49% of capex**, and the design already reports `fdh_capacity: 6719/6768 = 99.2%`. The single imperfect area (239 units in a 288 cabinet) could at best be re-shaped to save one catalog step ≈ $300–$600. Capacity-waste-aware clustering **cannot move the district score.** On the four failing scenarios it cannot help either, for the reason the backlog itself states: `s02` has 40 units total, so `k` is forced to 1 and no clustering freedom exists. I concur with the backlog's recommendation (b), dual-scored.

**But the machinery is not wasted — it is the enabling constraint for §1.7.** The moment `k > k_min`, areas stop sitting at 432 and cabinet fit becomes binding on the QA gate. In my `k = 20` run areas ranged 115–436 units; a 115-unit area buys a 144 cabinet at 79.9%. The gate is on the aggregate (`Σ units / Σ installed ≥ 95%`), so the requirement is `Σ_a smallestCover(u_a) ≤ 7,072`. Feasible at `k = 20` — e.g. 14×432 + 6×~112→144 gives 6,912 installed = 97.2% PASS — but *only if the sizes are chosen deliberately*. So the correct statement of the open question's option (c) is: **cluster-size-to-catalog is not a cost lever, it is a feasibility lever for making `k` a free variable.** The step function that actually holds money is not the cabinet catalog but the **cable** catalog on shared trench (12→288f, $0.95→$7.80/m, $480,641 of BOM: 39,285 m of 288f alone is $306,423) and the **terminal** catalog (51.1M cents of under-4 penalty). A 432-unit area needs 476 fibers on its trunk (2 cables); a 288-unit area needs 317 (288+48); a 144-unit area needs 159 (one 288f). That is the mechanism behind §1.7's numbers.

**Tier.** Set-partitioning with column generation is **Tier 2** (needs an LP solver for the master and CP-SAT or a labelling algorithm for pricing; interop surface = LP with dynamic columns, i.e. `addCol()` during solve, plus dual access — again more than a one-shot `solve()`). **Tier 1** version: after §1.3 or §1.5 produces areas, run a *sizing repair* that moves boundary premises to push each `u_a` just over/under the nearest catalog boundary, accepting only moves whose scorer-priced Δ (cabinet step + cable step + feeder) is negative. ~100 lines.

---

### 1.7 Should `k` be a decision variable? — Yes. Measured.

`k = CeilDiv(d.total_units, 432)` = 16 is the *minimum feasible* count; nothing in the objective says minimum is optimal. I swept `k` under one consistent protocol (farthest-point seeding, exact min-cost-flow assignment, 2 medoid update rounds, netwerk's own cable/cabinet catalogs, 10% spare):

| k | dist. cable | feeder cable | cabinets | total | fiber·m |
|---|---|---|---|---|---|
| 16 (today's k) | $325,107 | $33,459 | $40,000 | **$398,566** | 5,131,658 |
| 18 | $297,017 | $37,226 | $42,300 | $376,542 (−5.5%) | 4,533,095 |
| 20 | $270,370 | $39,072 | $43,100 | $352,542 (−11.5%) | 3,832,500 |
| 24 | $248,196 | $42,855 | $47,400 | $338,451 (−15.1%) | 3,369,659 |

(For reference, the shipped design under the same simulator is $625,021 + $33,193 + $39,300 = $697,514.)

**Why the derivative points the "wrong" way relative to textbook facility location.** Normally each extra facility costs a dedicated feeder spur and its trench. In netwerk **trench is already sunk**: the global Steiner tree spans every terminal node regardless of `k`, and an extra FDH adds one required node that is almost certainly already on the tree. So an extra area costs one cabinet ($650–$2,500) plus a few hundred metres of *cheap* feeder cable ($0.95–$4.70/m riding existing trench), and saves *expensive* trunk distribution cable by dropping catalog steps. My sweep does not model trench at all, which is exactly the assumption that needs validating in the engine — **flag: verify `trench_m` is invariant under `k` before banking these numbers.**

**Formulation.** Make `k` implicit by charging the cabinet: this is the modular capacitated facility location objective `min Σ_j Σ_s F_s z_js + Σ transport` with `Σ_s z_js ≤ 1` and `Σ_p u_p x_pj ≤ Σ_s S_s z_js`. The regionalization analogue where the region count is endogenous is **max-p-regions** (Duque, Anselin & Rey 2012, *Journal of Regional Science* 52(3):397–419).

**Constraints bounding `k` upward:** `MaxClusters() = 32` (a fixed-array constant, `model.carbon:168`); splitter-bank and OLT rounding per FDH (each area rounds its splitter bank up — today 11 splitters/area, 172 PON ports total, so ~$27k of splitter+OLT cost grows sublinearly but grows); and the `util_fdh_capacity` aggregate gate (§1.6). There is an interior optimum; the sweep suggests it is around 20–24 for this district, with returns flattening after 20.

**Tier 1 implementation.** The engine runs the district in 11 s, so an outer sweep of `k ∈ [k_min, 32]` is ~3 minutes — fine for an offline calibration run, too slow per-design. Cheap in-engine version: after the Steiner tree exists, evaluate the surrogate `Σ_a [cab(u_a) + Σ_e cableCost(demand_a(e))·len(e)]` for each `k` using the §1.5 tree-cut greedy (which is `O(n)` per `k`), pick the argmin, then solve once at that `k`. Total added runtime: 17 × `O(n)` ≈ milliseconds.

**Expected gain.** Taking the simulator's −11.5% at `k = 20` and applying it to the post-§1.2 cable BOM (~$250k) gives ~$29k; applying the full spread from *today's* baseline (§1.2 + `k`-raise: $697,514 → $352,542, −49.5%) onto the actual $480,641 + $39,320 + $39,300 = $559,261 of `k`-sensitive BOM gives **$150k–$275k = 15M–27.5M cents**, of which §1.2/§1.3 already claims the larger share. **Incremental value of `k` alone, on top of a fixed assignment: 3M–6M cents (0.3%–0.6% of score)** — real but second-order, and it carries the QA-gate risk of §1.6.

---

### 1.8 Local search that prices the true objective

**Move set** (all capacity-repaired, all on boundary elements only):

1. **Relocate** premises `p` from area `A` to adjacent area `B` (feasible iff `u_B + u_p ≤ 432`).
2. **Swap** `p ∈ A` with `q ∈ B` where `u_p = u_q` — capacity-neutral, so always feasible; this is the move Osman & Christofides (1994, *ITOR* 1:317–336) use for the capacitated clustering problem, hybridized SA/TS.
3. **Vertex substitution** of the FDH site within an area — Teitz & Bart (1968, *Operations Research* 16(5):955–961), with Resende & Werneck's (2007, *Annals of OR* 150:205–230) incremental-evaluation implementation which is up to three orders of magnitude faster than naive re-evaluation and matters a lot here, because a naive Teitz–Bart would multiply `PlaceFdh()`'s already-dominant 1,024 Dijkstras.
4. **Split / merge** an area — changes `k`, ties to §1.7. This is the shaking step of a VNS (Mladenović & Hansen 1997, *Computers & OR* 24:1097–1100; Hansen & Mladenović 1997, *Location Science* 5:207–226, specifically for *p*-median).

**Pricing.** The repo's scar tissue is unambiguous, so the move value must be the scorer's:

```
Δ = Δ_cable(catalog-priced along the tree paths terminal→FDH_A and terminal→FDH_B)
  + Δ_cabinet(g(u_A − u_p) − g(u_A) + g(u_B + u_p) − g(u_B))
  + Δ_feeder + Δ_terminal_penalty + 1e6 · Δ_qa
```

`Δ_cable` is the honest cost: you must walk both tree paths and re-price every edge whose fiber count crosses a catalog step. Path depth on this district is a few hundred edges, so a move evaluation is ~10³ integer ops. Restricting candidates to boundary premises (measured: ~30% of premises have a cross-area 4-NN today; after §1.3 it should be ~5–10%, i.e. 300–700 candidates) gives ~10⁷ ops per sweep — sub-second.

**Honest expectation.** After §1.2/§1.3 the assignment is *exactly optimal for the given sites*, so relocate/swap will find almost nothing; the residual gap is in (a) site choice and (b) catalog non-linearity, which the transportation LP does not see because it prices linear fiber-meters, not step-function cable. So local search should be aimed narrowly at **catalog-step boundaries and site substitution**, not at general rebalancing. Expected **2M–5M cents**, low confidence — this is an extrapolation from the general 3–8% improvement local search gives over a good constructive heuristic in the capacitated *p*-median literature (Lorena & Senne 2003, *Networks and Spatial Economics* 3:407-419; Gnägi & Baumann 2021), not a netwerk measurement. **Tier 1** for moves 1–3 (Resende–Werneck style bookkeeping); **Tier 2** for a proper large-neighbourhood version (fix 80% of the assignment, re-solve the rest as a MIP — Gnägi & Baumann's matheuristic pattern; interop surface = a plain `solve(A, b, c, vartypes)` MIP call, no callbacks).

---

### 1.9 Seeding: measured to be nearly irrelevant here — do not spend effort on it

k-means++ (Arthur & Vassilvitskii 2007, *SODA*, 1027–1035) samples center `i+1` with probability `∝ D(p)²`, giving `Θ(log k)`-competitive expected cost. Netwerk uses deterministic farthest-point/maxmin seeding (Gonzalez 1985, *TCS* 38:293–306), which is the derandomized cousin.

**Measured:** with the exact assignment step and 2 medoid rounds in place, farthest-point seeds land at **$398,566** and the engine's own medoid sites land at **$399,792** — 0.3% apart. Without the medoid rounds, farthest-point seeds cost $730,459. **The site-update loop, not the seed, is the whole story.** This matches Fränti & Sieranoja (2019, *Pattern Recognition* 93:95–112), who found initialization matters mostly when the subsequent optimization is weak.

Two further reasons to skip k-means++ specifically: it is randomized, which fights NFR-3's byte-determinism gate (the deterministic `argmax D²` variant simply *is* farthest-point); and its guarantee is for the unconstrained MSSC objective, which is not netwerk's objective. **Recommendation: leave seeding alone; fix the two real defects instead — the seed-vs-medoid reference mismatch (§1.1 item 2) and `PlaceFdh()`'s candidate cap** (it collects only the *first 256 distinct snap nodes in premises-id order*, then strides to ≤64, `stages.carbon:368–404`; on a fragmented area that subset is spatially arbitrary and the 1-median is searched over <15% of the area's nodes).

---

### 1.10 Graph metric vs Euclidean — already right, but the *right* graph metric is the tree

Netwerk already clusters on graph distance (`seed_dist[32 × 12288]`, `k` Dijkstras). Keep it: on a parcel-lot-line lattice with generated street crossings, Euclidean distance systematically under-states cost across uncrossable boundaries — the same geometry that forces `~k²/4` drop crossings per terminal.

One refinement: once `DeloopTrench` has built the global Steiner tree `T`, **cable rides `T`, not the shortest path**, so the metric that prices assignment is `d_T(·,·)` — which is cheaper to compute than `d_G` (one tree walk, no heap) and is the metric §1.5 partitions in. Today's `seed_dist` is `d_G`, computed *before* `T` exists, which is a chicken-and-egg the pipeline resolves in the wrong order. The `k`-Dijkstra table stays useful as the initial estimate for the first pass.

---

### Ranking by expected score reduction per unit of implementation effort

Score baseline: district 973,816,190 cents. "Gain" is in cents; effort is my estimate of Carbon lines + risk.

| # | Technique | Tier | Expected gain (cents) | % of score | Effort | Gain/effort | Confidence |
|---|---|---|---|---|---|---|---|
| 1 | **Re-seed `seed_dist` from the medoids and re-run assignment** (one Lloyd iteration; fixes the assign-to-seed/route-from-medoid mismatch) | 1 | 3M–8M | 0.3–0.8% | ~20 lines | **very high** | high — it is a strict subset of #2's measured gain |
| 2 | **Exact assignment as a transportation problem** (SSP min-cost flow condensed on `k ≤ 32` facilities), replacing greedy first-fit + `RebalanceClusters` | 1 | 12M–23M | 1.2–2.4% | ~250 lines | **very high** | high — exact optimum measured (−42.9% simulated cable, −39.7% fiber-metres) |
| 3 | **Offset multi-source Dijkstra (additively-weighted graph Voronoi / power-diagram dual)** — same optimum, contiguity free, unlocks cross-seam terminal packing | 1 | 20M–33M (supersedes #2, not additive) | 2.0–3.4% | ~200 lines + ε-scaling loop | **high** | medium-high — 615→123 components measured for #2; →16 is by construction, but the integer price loop is unmeasured |
| 4 | **Pack terminals globally, then cut the Steiner tree into serving areas** (pipeline reorder + Kundu–Misra greedy cut) | 1 | 8M–20M incremental over #3 | 0.8–2.0% | ~300 lines + stage reorder | medium-high | medium — 81 blocked strays measured; crossing share extrapolated |
| 5 | **Make `k` a decision variable** (sweep `k ∈ [k_min, 32]` on the tree-cut surrogate) | 1 | 3M–6M incremental | 0.3–0.6% | ~80 lines | medium-high | medium — sweep measured, but assumes trench is `k`-invariant (must verify) |
| 6 | **Fix `PlaceFdh` candidate selection** (drop the first-256-by-id bias; use unit-weighted stratified candidates + Resende–Werneck incremental Teitz–Bart) | 1 | 2M–5M | 0.2–0.5% | ~150 lines | medium | medium |
| 7 | **Full tree-cut DP** (Lukes-style, exact capacitated tree partition with catalog-priced cuts) | 1 (bucketed) / 2 (exact) | 2M–5M over #4's greedy | 0.2–0.5% | ~400 lines | medium-low | medium |
| 8 | **Catalog-boundary sizing repair** (push `u_a` onto catalog windows) | 1 | ~0 alone; **required** to keep the QA gate green if #5 ships | 0% direct | ~100 lines | n/a (enabler) | high — measured: cabinets are 0.49% of capex, FDH util already 99.2% |
| 9 | **Boundary relocate/swap local search priced by the scorer** | 1 | 2M–5M | 0.2–0.5% | ~250 lines | low-medium | low — extrapolated from CPMP literature, not measured here |
| 10 | **Set-partitioning / column generation over catalog-sized areas** | 2 | 1M–4M | 0.1–0.4% | large (LP master + pricing + interop with dual access) | **low** | low |
| 11 | **Cut-based contiguity MILP (Validi et al.)** | 2 | ~0 beyond #3 | 0% | large (needs lazy-cut callbacks in the interop surface) | **lowest** | high that it is redundant given #3 |
| 12 | **k-means++ / D² seeding** | 1 | ~0 | 0% | small | **zero** | high — measured 0.3% difference vs farthest-point once #2 is in place |

**Recommended sequence:** #1 (one afternoon, banks part of #2's gain immediately and de-risks it) → #2 → #3 (which subsumes #2's contiguity problem) → #4 → #5 paired with #8. Items #10–#12 should be recorded as measured or argued negatives rather than queued.

**Two caveats I want on the record.** (a) All cable-cost deltas come from my own per-cluster shortest-path-tree simulator, which reproduces netwerk's catalog and spare rules but over-states the engine's actual distribution-cable BOM by 1.30× because the engine consolidates on a shared Steiner tree; I quote *ratios*, scaled onto the real BOM, and banded downward. (b) The `k`-sweep assumes trench length is invariant in `k` — structurally justified (the Steiner tree spans all terminal nodes regardless) but unverified in the engine, and it is the one assumption that could invert the sign of #5.

**Sources:** [Bradley, Bennett & Demiriz 2000](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/tr-2000-65.pdf) · [Malinen & Fränti 2014](https://link.springer.com/chapter/10.1007/978-3-662-44415-3_4) · [Gnägi & Baumann 2021](https://www.sciencedirect.com/science/article/pii/S0305054821000952) · [Aurenhammer 1987](https://www.cs.jhu.edu/~misha/Spring16/Aurenhammer87.pdf) · [Aurenhammer, Hoffmann & Aronov 1998](https://link.springer.com/article/10.1007/PL00009187) · [Balzer, Schlömer & Deussen 2009](https://kops.uni-konstanz.de/bitstream/123456789/5934/1/Balzer_etal_2009_CCPDAVoLM.pdf) · [Xin et al. 2016](https://dl.acm.org/doi/10.1145/2980179.2982428) · [Arthur & Vassilvitskii 2007](https://www.semanticscholar.org/paper/k-means++:-the-advantages-of-careful-seeding-Arthur-Vassilvitskii/ab25e57c716c34c02fe8f78738ffbd44fe7732fa) · [Fränti & Sieranoja 2019](https://cs.uef.fi/sipu/pub/KM-Init-PR-2019.pdf) · [Teitz & Bart 1968](https://pubsonline.informs.org/doi/10.1287/opre.16.5.955) · [Resende & Werneck 2007](https://link.springer.com/article/10.1007/s10479-006-0154-0) · [Mladenović & Hansen 1997](https://www.scirp.org/reference/referencespapers?referenceid=1247853) · [Osman & Christofides 1994](https://www.sciencedirect.com/science/article/abs/pii/0969601694900329) · [Kariv & Hakimi 1979](https://epubs.siam.org/doi/10.1137/0137041) · [Shirabe 2009](https://journals.sagepub.com/doi/10.1068/b34104) · [Validi, Buchanan & Lykhovyd 2022](https://pubsonline.informs.org/doi/abs/10.1287/opre.2021.2141) · [Assunção et al. 2006](http://www.dpi.inpe.br/gilberto/papers/assuncao_neves_camara_ijgis.pdf) · [Duque, Anselin & Rey 2012](https://ideas.repec.org/a/bla/jregsc/v52y2012i3p397-419.html) · [Garfinkel & Nemhauser 1970](https://doi.org/10.1287/mnsc.16.8.b495) · [Hess et al. 1965](https://pubsonline.informs.org/doi/abs/10.1287/opre.13.6.998) · [Lukes 1974](http://bitsavers.informatik.uni-stuttgart.de/pdf/ibm/IBM_Journal_of_Research_and_Development/183/ibmrd1803D.pdf) · [Kundu & Misra 1977](https://epubs.siam.org/doi/10.1137/0206012) · [Friesen & Langston 1986](https://www.semanticscholar.org/paper/Variable-Sized-Bin-Packing-Friesen-Langston/049c673efc63c50ec8bd2f05e724d8e497d3035b) · [Correia & Captivo](https://www.sciencedirect.com/science/article/abs/pii/S0305054805000869) · [Gollowitzer & Ljubić 2011](https://www.sciencedirect.com/science/article/pii/S0305054810001334) · [Chardy, Costa, Faye & Trampont 2012](https://www.sciencedirect.com/science/article/abs/pii/S0377221712003748) · [Bertsekas auction](https://www.mit.edu/~dimitrib/Auction_Trans.pdf)


---

## 2. MILP duality, Lagrangian relaxation and dual bounds for FDH/hub selection

### 2.0 Headline: I computed netwerk's first lower bounds, and they redirect the campaign

Before any technique discussion, here are numbers this section actually produced by running dual ascent on `data/parcels_district.txt` plus the shipped design in `designs/parcels_district/`. Scripts are in `/tmp/claude-0/-home-user-netwerk/c96678cd-ce3d-5748-99b6-67ac7c297bd3/scratchpad/` (`wong.py`, `wong2.py`, `rcfix.py`, `primal.py`, `terms_lb.py`, `uncond.py`, `lb2.py`). No repo file was modified.

**Result 1 — the trench is already within 4.22% of its conditional optimum.** Wong's dual-ascent on the bidirected-cut (Steiner arborescence) relaxation, with required set = {CO} ∪ {16 FDH nodes} ∪ {1,688 distinct terminal nodes} = 1,702 nodes, root = CO, arc cost = `edge_len × TrenchCostPerM(surface)`:

```
design trench      605,446,500 cents  (123,045 m = 118,117 soft + 4,928 asphalt)
dual bound (DA)    579,894,000 cents  (117,541 m on the meter-denominated run)
certified slack     25,552,500 cents  = 4.22%  ( 4.47% in meters )
runtime             0.9 s, pure Python, 24,555 ascent iterations, single thread
stability           identical to 3 significant figures across 5 terminal orders and 3 roots
```

The global Steiner trench built in iteration 005 is therefore **at most $255,525 above the cheapest possible trench for the terminal set it was given**. Backlog item 6c ("key-path improvement, typically 1–3% trench") now has a hard ceiling, and it is small.

**Result 2 — an independent SPH on the dual-ascent saturation graph already banks a third of that.** Running Takahashi–Matsuyama on the subgraph of arcs the ascent saturated: 602,466,000 cents / 122,364 m, i.e. −2,980,500 cents (−0.49% trench, −0.31% score) versus the engine. On the full graph my SPH gets 603,232,500 / 122,539 m. So the engine's tree is ~0.4% worse than a plain re-run of the same heuristic with a different insertion order — noise-level, but free once DA exists.

**Result 3 — the FDH cabinet decision is *provably optimal* and worth nothing.** Minimum-cost multiset of catalog cabinets covering 6,719 units (a relaxation of "one cabinet per serving area") = 3,930,000 cents, by DP. The design pays exactly 3,930,000. Zero slack. FDH cabinets are 0.40% of capex; feeder cable is 0.49%. **The stage this section is named after carries ~6.7M cents of directly attributable cost out of a 973.8M score.** I say this plainly because it is the most useful thing I can tell the campaign: the CFLP/Lagrangian toolbox should not be pointed at FDH siting. It should be pointed one level down, at terminal siting, where the identical mathematics governs 226.4M cents.

**Result 4 — the full separable bound.** Because the objective is a sum of terms over disjoint resources and the penalty terms are non-negative, independently valid lower bounds on each term sum to a valid global lower bound:

| term | design (cents) | valid LB (cents) | slack | basis |
|---|---|---|---|---|
| trench | 605,446,500 | 579,894,000 | 25,552,500 | Wong DA, conditional on required-node set |
| penalties (street-x, drop-x, under-4) | 176,680,000 | 0 | 176,680,000 | **no bound exists today** |
| drop assemblies | 80,628,000 | 80,628,000 | 0 | 6,719 × $120, a constant |
| distribution + feeder cable | 51,996,140 | 11,166,395 | 40,829,745 | 117,541 m × 95 c/m (cheapest 12f) |
| drop cable | 29,090,550 | 10,399,050 | 18,691,500 | Σ dist(premises, nearest node) × 150 c/m |
| terminals | 20,639,000 | 14,000,000 | 6,639,000 | ⌈6719/12⌉ × $250, min-cost cover DP |
| FDH cabinets | 3,930,000 | 3,930,000 | 0 | min-cost cover DP — **tight** |
| OLT cards + optics | 2,772,000 | 2,209,500 | 562,500 | ⌈4368/32⌉ = 137 PON ports |
| splitters | 2,634,000 | 2,460,000 | 174,000 | min-cost cover of 4,368 take-ports |
| **total** | **973,816,190** | **704,686,945** | **269,129,245** | **certified gap ≤ 27.63%** |

**Result 5 — the unconditional bound is currently weak, and that is a finding.** Relaxing terminal placement entirely (group-Steiner: for each premises a super-node reachable by 0/drop-cost arcs from every graph node within 150 m; 6,719 groups, 1,267,450 membership arcs, mean group size 188.6) and running the same ascent gives only 204,911,850 cents for trench + drop-cable against 634,537,050 realised — a 67.7% gap, 73 s. The ascent degenerates because groups overlap massively: W(z_p) instantly swallows other active group terminals and Wong's root-component test deactivates them without raising anything. Adding a Duin–Volgenant–Voß-style constant offset M to the membership arcs recovered exactly p·M and nothing more. **Conclusion: the unconditional bound needs a group-aware relaxation and is Tier 2.** Summed with the other terms, the fully unconditional certificate today is score ≥ 319,305,745 (gap ≤ 67.2%) — honest, valid, and not yet useful.

**What this reframes.** 65.6% of the certified gap is the penalty budget, on which netwerk has *no* bound at all. 9.5% is trench. The seven iterations of the campaign spent most of their effort on the 9.5%.

---

### 2.1 What netwerk's facility-location layer actually is: SSCFLP is the wrong model, ConFL is the right one

**The single-source capacitated facility location problem (SSCFLP).** Sets: customers *I*, candidate sites *J*. Data: demand `d_i`, capacity `s_j`, opening cost `f_j`, assignment cost `c_ij`. Variables `y_j ∈ {0,1}` (open), `x_ij ∈ {0,1}` (i homed to j).

```
min   Σ_j f_j y_j + Σ_i Σ_j c_ij x_ij
s.t.  Σ_j x_ij = 1                    ∀i          (assignment)
      Σ_i d_i x_ij ≤ s_j y_j          ∀j          (capacity, "aggregated")
      x_ij ≤ y_j                      ∀i,j        (VUB, "disaggregated")
      x ∈ {0,1}^{IxJ},  y ∈ {0,1}^J
```

CFLP is the same with `x_ij ∈ [0,1]` (splittable demand).

**Strong vs weak.** The classical weak (Balinski 1965) form drops the `x_ij ≤ y_j` VUBs, which are redundant for integral `x,y` but not for the LP. Without them, `y_j` is only forced up to `(Σ_i d_i x_ij)/s_j`, so a facility serving one unit of a 432-unit cabinet pays 1/432 of its opening cost; the LP "opens" every site at a nominal fraction and the facility-cost term collapses. With the VUBs the LP must pay `f_j` in full for any customer routed to `j`. Cornuéjols, Sridharan & Thizy (1991) map the full dominance lattice of relaxations obtained by relaxing demand, capacity, non-negativity or integrality, completely or in Lagrangian fashion; Krarup & Pruzan (1983) is the canonical survey of the uncapacitated case.

**Why this barely matters for netwerk's FDH layer, quantitatively.** Capacity is uniform (`s_j = 432`) and cabinet cost is essentially linear in size. The aggregated LP already forces `Σ_j y_j ≥ 6719/432 = 15.55`, so the facility-cost term is bounded below by 15.55 × $2,500 = $38,877 against a design paying $40,000 — the aggregated/disaggregated distinction is worth 2.8% of 0.40% of capex. Meanwhile the assignment term `Σ_i min_j c_ij` is *near zero* for netwerk, because there are 15,668 candidate nodes and every premises has one metres away. The CFLP model prices "homing premises i to cabinet j" as an independent per-customer distance. In netwerk that distance is not paid: **trench is shared**. Feeder cable is $39,320 of a $7.97M build, and its route is 100% inside a tree that distribution also uses (sharing ratio 1.20).

**The correct model is Connected Facility Location (ConFL) / Steiner tree-star.** Add `z_e ∈ {0,1}` for road edges and a connectivity requirement linking every open facility to the root:

```
min   Σ_e t_e z_e  +  Σ_j f_j y_j  +  Σ_i Σ_j a_ij x_ij
s.t.  Σ_j x_ij = 1                              ∀i
      Σ_i u_i x_ij ≤ 432 y_j                    ∀j
      x_ij ≤ y_j                                ∀i,j
      z(δ(S)) ≥ y_j          ∀ S ⊆ V \ {r},  ∀ j ∈ S ∩ J     (connectivity cuts)
      z ∈ {0,1}^E, x,y ∈ {0,1}
```

`t_e` is netwerk's trench cost (`edge_len × 4500` or `× 15000`). Gollowitzer & Ljubić (2011, *Computers & OR* 38:435–449) give the first systematic theoretical + computational comparison of ConFL MIP models, establishing that cut-based formulations dominate flow-based ones in LP strength; Leitner & Raidl and the "3-architecture connected facility location" line target exactly urban access-network design. Approximation-side: Karger & Minkoff (2000, "maybecast") gave the first constant factor; Swamy & Kumar (2004, *Algorithmica* 40:245–269) a primal-dual 8.55-approximation for ConFL and 4.55 for rent-or-buy. netwerk is actually a **three-level** ConFL (CO → FDH → terminal → premises) with a shared tree at both upper levels.

*Tier:* the ConFL formulation as a MIP is Tier 2 (HiGHS/CP-SAT, exponential cut families needing separation). **But its dual — the connectivity cuts' dual variables — is exactly what dual ascent computes without any solver, and that is Tier 1.** That is the whole argument of §2.2.

*Expected gain from modelling the FDH layer better:* near zero on capex. 16 cabinets are already optimal; feeder cable is $39k. The only real lever is that FDH placement perturbs the *distribution* tree, and Result 1 says that tree is within 4.22% of optimal for its current demand nodes. **Honest verdict: do not build a CFLP for FDH siting.**

---

### 2.2 Dual ascent — the Tier-1 workhorse, and the one that already paid

This is the critical technique in this section: it produces near-LP-quality bounds in near-linear time with pure integer arithmetic, no LP solver, no floating point, no allocation. It is directly implementable in Carbon.

#### 2.2.1 Erlenkotter's DUALOC (the facility-location ancestor)

For UFLP, the LP dual condenses (substituting `w_ij = max(0, v_i − c_ij)`) to:

```
max   Σ_i v_i
s.t.  Σ_i max(0, v_i − c_ij) ≤ f_j     ∀j
```

Ascent (Erlenkotter 1978, *Operations Research* 26(6):992–1009): initialise `v_i = min_j c_ij`. Define facility slack `s_j = f_j − Σ_i max(0, v_i − c_ij)`. Sweep customers in fixed order; raise `v_i` to
`min( next larger c_ij above v_i , v_i + min{ s_j : j with c_ij ≤ v_i } )`,
updating slacks. Repeat sweeps until no `v_i` moves. Then **dual adjustment** (DUALADJ) lowers a `v_i` that is blocking, allowing others to rise, and re-ascends. Complementary slackness (`s_j = 0` ⇒ open j) reads off a primal solution; if primal cost equals `Σ v_i`, optimality is proven with no branching — Erlenkotter reported exactly this on all Kuehn–Hamburger instances, under 0.1 s on an IBM 360/91, at up to 100 sites. Körkel (1989, *EJOR* 39:157–173) strengthened the adjustment step for large instances. Bilde & Krarup (1977) gave the same ascent independently.

Everything here is `min`, `max`, `+`, `−` on integers. Cents in, cents out. Determinism is trivial (fixed sweep order, ties by index).

*Sizing for netwerk (Tier 1):* if the FDH candidate set is capped at |J| = 256 nodes, the `c_ij` matrix is 6,719 × 256 = 1.72M i32 = 6.9 MB — a fixed-size array is fine — but it needs 256 Dijkstras (~0.5–1 ms each on 15.7k/23.8k) ≈ 0.2 s, plus ~5 ascent sweeps at 1.7M ops each. Total well under 1 s. The current engine caps candidates at 64 per area with a stride sample; DUALOC over a 256-node global candidate set would be strictly better *and* certified. **But per §2.1 the prize is ~$6.7k. Do not do this for FDHs.** Build DUALOC for the *terminal* layer instead (§2.4).

#### 2.2.2 Wong's dual ascent for the Steiner arborescence — the one that matters

Directed cut (bidirected) formulation, root `r`, terminals `T`; `δ⁻(W)` = arcs entering `W`; a *Steiner cut* is `W ⊆ V \ {r}` with `W ∩ T ≠ ∅`:

```
(CUT)   min Σ_a c_a x_a   s.t.  x(δ⁻(W)) ≥ 1  ∀ Steiner cuts W;  x ∈ {0,1}^A
(CUT-D) max Σ_W β_W       s.t.  Σ_{W : a ∈ δ⁻(W)} β_W ≤ c_a  ∀a;  β ≥ 0
```

Reduced cost `c̃_a = c_a − Σ_{W : a ∈ δ⁻(W)} β_W`; the **saturation graph** `G_S` is the subgraph of arcs with `c̃_a = 0`. For terminal `k`, `W(k) = { i : ∃ path i→k in G_S }`; `k` is *active* if `r ∉ W(k)`; `W(k)` is a **root component** if `k` is the only active terminal in it.

**The loop (Wong 1984, *Mathematical Programming* 28:271–287):**

```
c̃ ← c ; LB ← 0 ; active ← T \ {r}
while active ≠ ∅:
    pick k ∈ active                       (priority: smallest |δ⁻(W(k))|)
    W ← backward BFS from k over saturated arcs only
    if r ∈ W:                    active ← active \ {k}; continue     # k is connected
    if W contains another active terminal:  active ← active \ {k}; continue  # not a root component
    Δ ← min { c̃_a : a ∈ δ⁻(W) }
    LB ← LB + Δ ;   c̃_a ← c̃_a − Δ  for all a ∈ δ⁻(W)
```

Every iterate is dual-feasible (Δ is the exact slack of the binding cut arc), so **`LB` is a valid lower bound at every step, including if you stop early** — a property worth a lot for a byte-deterministic engine with a runtime budget. Complexity `O(|A| · min(|T||V|, |A|))` worst case (Wong 1984; Leitner, Ljubić, Luipersbeck & Sinnl generalise it to the asymmetric prize-collecting case and re-prove the same bound). The ascent generalises both Chu–Liu–Edmonds and the Bilde–Krarup–Erlenkotter plant-location ascent — it is literally the same algorithm family as §2.2.1.

Two implementation facts, both from Pajor, Uchoa & Werneck (*Math. Prog. Computation* 2018, arXiv:1412.2787) and confirmed in my run:

- **Track components implicitly.** Recompute `W(k)` by BFS on `G_S` each iteration rather than maintaining component sets. Explicit tracking costs Θ(|T||V|) memory (1,702 × 15,668 here) and updates a large number of components per saturation. My Carbon-shaped Python does implicit BFS and runs the whole district in 0.9 s.
- **Selection order barely matters for bound quality but matters for speed.** I measured 579,750,000 (node-id order) vs 579,894,000 (best of 5 shuffles and 3 roots) — 0.025% spread. Pajor et al. report the same insensitivity. **This is excellent news for determinism:** fix the order to ascending terminal node id and the bound is byte-stable with no quality cost.

**Measured on netwerk (Result 1):** 24,555 ascent iterations, 0.9 s in Python; 4.22% gap in cents, 4.47% in meters. Since dual-ascent bounds on sparse graph instances are themselves typically 1–3% below the bidirected-cut LP optimum (Polzin & Vahdati Daneshmand, *Discrete Applied Math* 112:263–300, 2001, and the DIMACS-11 results in Leitner et al. — I am extrapolating the specific 1–3% figure from those papers' general behaviour, not quoting a netwerk-specific number), **the true achievable trench saving is likely 1–2%, i.e. 6–12M cents ($60k–120k), not the 25.5M ceiling.**

#### 2.2.3 Tier-1 Carbon implementation sketch

```
// state, all fixed-size, all integer
var red:   array(i64, 2*MaxEdges())     // reduced costs, cents
var mark:  array(i32, MaxNodes())       // BFS stamp
var Wbuf:  array(i32, MaxNodes())       // component node list
var active: array(bool, MaxNodes())
var lb: i64 = 0
// priority queue: reuse the existing binary heap with unique integer keys
//   key = last_component_size * 65536 + terminal_index      (deterministic ties)
```

- Arcs: reuse the existing CSR adjacency; store both directions with the same `edge_cost_cents(e)`.
- Backward BFS over `red[a] == 0` arcs, stamped by an incrementing `i32` counter (no clearing).
- Two passes over `W`'s incoming arcs per iteration: one to find `Δ`, one to decrement.
- `lb` must be `i64` (579.9M fits i32 but partial sums during a multi-scenario roll-up will not).
- Bound: ~250 lines. No allocation, no floats, no I/O.

**Where it plugs in:** a new stage 11 `DualBound` after `DeloopTrench`, emitting `dual_bound_trench_cents` into the report and into `tools/score_design.py`'s JSON, so `results/LEDGER.md` grows a `gap_to_bound` column. That single column is, in my judgement, worth more than the next three heuristic iterations, because it tells the campaign when a lever is exhausted. It is exhausted now for trench routing.

#### 2.2.4 Reduced-cost fixing — measured, and it fails here

Standard test (Duin 1993; Polzin & Daneshmand 2001; Test 1 of Leitner et al.): with `d̃` = shortest-path distances under reduced costs, arc `(i,j)` can be deleted if

```
LB + d̃(r, i) + c̃_ij + min_{t ∈ T\{r}} d̃(j, t)  >  UB
```

**Measured on netwerk: 0 of 23,824 edges eliminated** (`rcfix.py`). The reason is structural and worth recording: with 1,702 required nodes in a 15,668-node graph, `d̃(r,i) ≈ 0` and `d̃(j,t) ≈ 0` almost everywhere, and the largest single arc cost is ~3M cents against a gap of 25.7M. Reduced-cost fixing needs `gap < per-item cost`, and netwerk's trench items are 300–1,000× smaller than the gap. Leitner et al. report ≈99% arc fixing on benchmark Steiner instances — those have few terminals and large edge costs. **Do not port reduced-cost fixing for trench.** It *will* work on the FDH/terminal *siting* variables, where a single item (a cabinet plus its feeder path) is worth tens of millions of cents — comparable to the gap.

---

### 2.3 Lagrangian relaxation of the assignment constraints, subgradient, and the volume algorithm

**Formulation.** Dualise `Σ_j x_ij = 1` with free multipliers `λ_i`:

```
L(λ) = Σ_i λ_i + min { Σ_j f_j y_j + Σ_i Σ_j (c_ij − λ_i) x_ij }
       s.t.  Σ_i d_i x_ij ≤ s_j y_j,  x_ij ≤ y_j,  x,y ∈ {0,1}
```

This **separates completely by facility**: for each `j`, solve a 0-1 knapsack
`κ_j(λ) = min { Σ_i (c_ij − λ_i) x_ij : Σ_i d_i x_ij ≤ s_j , x ∈ {0,1}^I }`
(only items with `c_ij − λ_i < 0` are candidates), then `y_j = 1` iff `f_j + κ_j(λ) < 0`. The Lagrangian dual is `z_LD = max_λ L(λ)`, and because the subproblem does not have the integrality property, `z_LD ≥ z_LP` — Cornuéjols, Sridharan & Thizy (1991) formalise which relaxations dominate which; the practical folklore, confirmed there, is that CFLP Lagrangian bounds run roughly a third of the LP gap. Guignard & Opaswongkarn (1990, *EJOR* 46:73–83) is the dedicated Lagrangian *dual ascent* treatment for capacitated plant location: add valid inequalities so the relaxed problem splits into a transportation problem plus a knapsack, then ascend the multipliers rather than subgradient them.

**Subgradient (Held–Karp style).** Subgradient `g_i^k = 1 − Σ_j x_ij^k`; step

```
λ_i^{k+1} = λ_i^k + t_k · g_i^k ,     t_k = α_k (UB − L(λ^k)) / ‖g^k‖²
```

with `α_k` halved after a fixed number of non-improving iterations (Held, Wolfe & Crowder 1974, *Math. Prog.* 6:62–88; the construction traces to Held & Karp 1970/71 for TSP/1-trees). Beasley (1993, "Lagrangian relaxation", in Reeves ed., *Modern Heuristic Techniques*) is the standard implementation cookbook.

**The determinism problem, and its solution.** `t_k` is a ratio — floating point in every textbook. Netwerk forbids floats. Fix: keep `λ` in **millicents** (i.e. scale cents by 1000), compute `t_k` by integer division with a fixed rounding rule (`(α_num · (UB − L) · 1000) / (α_den · ‖g‖²)`, truncating toward zero), and halve `α` on a fixed counter rather than on a float threshold. All arithmetic stays in `i64`. This is byte-deterministic and I have seen no argument that the bound degrades materially from the rounding — though I am extrapolating; nobody publishes integer-scaled subgradient for CFLP that I found.

**Netwerk's gift: the subproblem is a *sort*, not a knapsack.** The parcel district has `units = 1` for all 6,719 premises. With uniform unit demand and capacity `s_j`, the knapsack `κ_j(λ)` collapses to "take the `s_j` most negative values of `(c_ij − λ_i)`" — an `O(|I_j|)` partial selection. At the terminal layer (`s_j = 12`) it is a 12-element bounded min-heap per node. This makes the whole Lagrangian machinery an integer, allocation-free, deterministic loop. That is a genuinely strong Tier-1 fit and I have not seen it exploited in the FTTH literature.

**Volume algorithm (Barahona & Anbil 2000, *Math. Prog.* 87:385–399).** Pure subgradient gives dual values but no primal. The volume algorithm maintains a running convex combination `x̄ ← α x^k + (1−α) x̄` of subproblem solutions, uses `1 − Σ_j x̄_ij` as the direction, and converges to an approximate primal LP solution as well as the dual bound. Barahona & Anbil report success precisely on set partitioning, set covering and plant location — netwerk's three structures. For netwerk the primal `x̄` is the payoff: fractional `x̄_ip` values tell you *which premises-to-terminal assignments the LP is uncertain about*, which is exactly the guidance a rounding/repair pass needs (§2.6). `α` in integer form: `x̄ ← (α_num·x^k + (α_den−α_num)·x̄)/α_den` on a scaled integer grid.

*Expected gain, honestly:* applied to **FDH assignment**, ~0 (see §2.1). Applied to **terminal assignment** (§2.4), this is the only route I can see to a lower bound on the 176.7M penalty budget, which is 65.6% of the certified gap. *Complexity:* per subgradient iteration, `O(Σ_v |cover(v)|)` = 1.27M integer ops on the district; 200–500 iterations ⇒ 0.25–0.6 G-ops ⇒ roughly 1–3 s in Carbon. That is 10–25% of the current 11 s pipeline — significant but affordable, and it can be run only in a `--bound` mode outside the golden path. *Tier:* **Tier 1** for the district's unit-demand case; Tier 2 if MDU weights make the subproblem a real knapsack (then use CP-SAT or a DP over `s_j ≤ 432`, which is also Tier-1-able as an `O(|I_j| · 432)` integer DP).

---

### 2.4 The redirect: run the whole toolbox at the TERMINAL layer, not the FDH layer

This is the most actionable recommendation in my section, so I state it as a formulation.

**Terminal siting is a modular-capacity single-source CFLP on netwerk's real data.**

```
I = 6,719 premises.   J = graph nodes v with ≥1 premises within 150 m  (≈ all 15,668;
     mean |cover(v)| = 1,267,450 / 15,668 ≈ 81 premises per node — measured).
Variables:  y_v^k ∈ {0,1}  = "a terminal of catalog size k ∈ {2,4,6,8,12} sits at v"
            x_iv  ∈ {0,1}  = "premises i drops to the terminal at v"

min  Σ_v Σ_k TerminalCost(k) · y_v^k                            hardware
   + Σ_v 100000 · [terminal at v serves 1..3 premises]          under-4 penalty
   + Σ_i Σ_v ( 150·drop_m(i,v) + 50000·streetx(i,v) ) x_iv      drop cable + street crossings
   + Σ_{(i,v),(j,w) crossing pairs} 20000 · (drop-drop term)    drop-drop crossings
s.t. Σ_v x_iv = 1                      ∀i
     Σ_i x_iv ≤ Σ_k k · y_v^k          ∀v
     Σ_k y_v^k ≤ 1                     ∀v
     x_iv = 0 whenever drop_m(i,v) > 150
```

The step-function facility cost (`TerminalCost(k)` plus the 100,000 under-4 cliff) makes this a **modular capacitated location problem** — Correia & Captivo (2003, *Annals of OR* 122:141–161) give the Lagrangian heuristic for exactly this structure, where capacity is chosen from a finite discrete set. Everything above except the drop-drop pairing term is already computable by existing netwerk code: `DistM`, `CountDropCrossings` with the exact integer orientation predicate, and the 128 m edge grid.

**Money at stake, from the shipped design:**

```
street crossings   2,238 × 50,000  = 111,900,000
under-4 terminals    511 × 100,000 =  51,100,000
drop cable        193,937 m × 150  =  29,090,550
terminal hardware                  =  20,639,000
drop-drop            684 × 20,000  =  13,680,000
                                     -----------
                                     226,409,550 cents = 23.2% of the score
```

versus the FDH layer's ~6.7M. **Same mathematics, 34× the money.**

**The Lagrangian bound on this is Tier 1 and cheap.** Dualise `Σ_v x_iv = 1` with `λ_i`. The subproblem separates by node `v`:

```
for each v:  sort cover(v) by (c_iv − λ_i) ascending
             for k in {2,4,6,8,12}:
                 val(k) = TerminalCost(k) + [k<4 ⇒ 100000] + Σ of the k smallest (c_iv − λ_i)
             κ_v = min(0, min_k val(k))         # 0 = don't open
L(λ) = Σ_i λ_i + Σ_v κ_v
```

That is `O(Σ_v |cover(v)| log 12)` ≈ 1.3M integer operations per iteration; a 12-element bounded max-heap makes the "k smallest" incremental across `k`. The drop-drop crossing term does not separate — **drop it from the relaxation** (it is non-negative, so `L(λ)` remains a valid lower bound on the full objective; you simply forfeit 13.7M of tightness).

This produces, for the first time, **a valid lower bound on 212.7M cents of penalty-plus-drop cost**, and answers backlog item 3b's open question ("is a crossing floor well above zero real?") with a number instead of a simulation. It also, via the volume algorithm's `x̄`, tells you *which* premises the LP wants to move — the guided-rounding input for the swap pass in backlog item 3.

*Expected gain:* the bound itself is worth 0 score. But the plausible outcome is one of two, both valuable: (a) the bound comes in near 200M, proving the packing is nearly optimal and closing three backlog items as exhausted; or (b) it comes in near 120M, in which case there is ~90M cents (9% of score) of certified, addressable slack in terminal packing — an order of magnitude more than anything left in trench. I cannot predict which; that is the point of computing it.

*Tier:* **Tier 1** for the bound and the volume primal. Tier 2 for an exact solve (CP-SAT is a good fit: 6,719 exactly-one constraints, ~1.27M assignment literals, step-cost facilities — this is squarely in CP-SAT's comfort zone with a good search hint from the incumbent).

---

### 2.5 Semi-Lagrangian relaxation — closes the duality gap, at a price

Standard Lagrangian dualisation of an equality leaves a gap. **Semi-Lagrangian relaxation (SLR)** (Beltran, Tadonki & Vial 2006, *Computational Optimization and Applications* 35:239–260, for p-median; extended to UFLP by Beltran-Royo, Vial & Alonso-Ayuso) splits the equality and dualises only one side:

```
Σ_v x_iv = 1     →     Σ_v x_iv ≤ 1   (kept in the subproblem)
                        Σ_v x_iv ≥ 1   (dualised with λ ≥ 0)

L_S(λ) = Σ_i λ_i + min { Σ_v f_v y_v + Σ_{i,v} (c_iv − λ_i) x_iv :
                          Σ_v x_iv ≤ 1,  capacity,  x,y ∈ {0,1} }
```

`L_S(λ)` is non-decreasing in `λ`, and **for `λ` large enough `L_S(λ) = z*` — the duality gap closes exactly.** The subproblem is an instance of the *same* problem restricted to "profitable" customers (those with `λ_i > min_v c_iv`), which is small when `λ` is small and grows toward the full problem as `λ` grows. The practical method is to ascend `λ` until either the gap closes or the subproblem gets too hard, taking the best bound reached.

**Fit for netwerk.** The terminal formulation of §2.4 is exactly the covering/median shape SLR was built for, and the "profitable customers only" subproblem is precisely what netwerk's node-centric set-cover greedy already computes — the existing `PackTerminals` is a *warm start for the SLR subproblem*, not a competitor. That is an unusually clean fit.

**Cost.** The SLR subproblem is an ILP, not a sort. Early iterations are tiny; late ones approach the original problem. This is **Tier 2** — the interop surface must expose a 0-1 ILP with exactly-one/≤-one constraints and integer objective, warm-startable from an incumbent (CP-SAT `AddHint`, or HiGHS MIP with a `MipStart`). *Expected gain:* SLR is a bound-tightening device, not a cost-reducer; its value is turning "≥ 120M" into "= 173M, proven", which converts an open backlog item into a closed one. Rank it low on score-per-effort, high on decision value once Tier 2 exists.

---

### 2.6 Benders decomposition — real for the assignment layer, awkward for the tree

**Classical Benders for CFLP.** Project out `x`: for fixed `y`, the subproblem is a transportation LP whose dual `(u, w)` yields optimality cuts

```
η  ≥  Σ_i u_i(y)  −  Σ_j w_j(y) · s_j · y_j
```

and the master is `min Σ_j f_j y_j + η` over `y ∈ {0,1}^J` plus accumulated cuts. Naively this converges glacially because the subproblem dual is massively degenerate and most cuts are weak.

**Accelerations, in the order they matter:**

1. **Magnanti & Wong (1981, *Operations Research* 29:464–484) Pareto-optimal cuts.** Among the alternative optimal duals, pick the one maximising the cut's value at a *core point* `y⁰` (a point in the relative interior of the convex hull of the master's feasible set). This requires a second LP per iteration.
2. **Papadakos (2008, *Operations Research Letters*) — "practical enhancements to the Magnanti–Wong method".** Drop the constraint tying the MW subproblem to the current `y`; solve the MW problem *only* at the core point. This removes the second LP's dependence on the master iterate and is both faster and produces Pareto-optimal cuts.
3. **Fischetti, Ljubić & Sinnl (2017, *Management Science* 63(7):2146–2162), "Redesigning Benders decomposition for large-scale facility location".** Reformulate cut separation as a *normalised* LP inside a single branch-and-cut tree (cuts separated at fractional nodes, not in an outer loop), which solved a large set of previously unsolved UFL benchmarks and gave dramatic speedups on separable-quadratic allocation costs. This is the current state of the art and the right target if Tier 2 ever wants exact FDH/terminal siting.

**Fit for netwerk, honestly.** Benders works for CFLP because the `y`-fixed subproblem is an LP with a closed-form dual. netwerk's `y`-fixed subproblem contains the **shared Steiner tree**, which is not an LP — you would have to replace it with a multicommodity-flow relaxation of the tree (one commodity per terminal, arc capacities `≤ z_e`), whose LP dual is then Benders-able but whose size is |T| × |A| = 1,702 × 47,648 ≈ 81M flow variables. That is not going to happen on a laptop. The tractable split is:

- **Master:** `y` = terminal/FDH siting binaries.
- **Subproblem:** premises→terminal assignment LP (a transportation problem — genuinely an LP, genuinely dual-nice).
- **Tree cost:** *not* in the Benders subproblem; handled by the DA bound of §2.2 as a separate additive term (valid, by the separability argument of Result 4).

*Tier:* **Tier 2**, needs an LP solver for the subproblem duals and a MIP for the master. Interop must expose: build/solve an LP with warm start and *dual value extraction* (HiGHS `getSolution` including row duals), plus a MIP with a lazy-constraint callback (HiGHS lacks a general callback; CP-SAT has one but is not an LP-dual engine — this is a real interop-design constraint worth recording now). *Expected gain:* only meaningful if it produces an exact terminal-siting solve on a sub-district; on the full 6,719-premises instance I would not bet on closure. Low score-per-effort.

---

### 2.7 Column generation / branch-and-price over serving-area patterns

This is the technique the prompt correctly flags as "extremely natural here", because a serving area's true cost *is* its Steiner tree, and a pattern-based master is the only formulation that can price it correctly.

**Master (set partitioning over serving-area patterns).** Let `Ω` be the set of feasible serving areas; each `ω ∈ Ω` is a subset `S_ω ⊆ I` with `Σ_{i∈S_ω} u_i ≤ 432`, an FDH node, a terminal layout, and a distribution tree. Let `γ_ω` be its **true cost** — cabinet + splitters + terminals + drops + crossing penalties + the Steiner tree from its FDH to its terminals. `a_iω = 1` iff `i ∈ S_ω`.

```
(M)   min  Σ_ω γ_ω θ_ω
      s.t. Σ_ω a_iω θ_ω = 1   ∀i ∈ I        [duals π_i]
           Σ_ω θ_ω ≤ K                       [dual μ ≤ 0]   (K = MaxClusters() = 32)
           θ_ω ∈ {0,1}
```

**Pricing subproblem:** find `ω` minimising `γ_ω − Σ_{i∈S_ω} π_i − μ`. Structurally this is a **capacity-constrained prize-collecting Steiner tree** rooted at a candidate FDH node: choose a connected subtree and a set of premises to "collect" (prize `π_i`) subject to `Σ u_i ≤ 432`. NP-hard, but it is exactly the APCSTP that dual ascent + branch-and-bound handles well (Ljubić et al. 2006, *Mathematical Programming* 105:427–449, "An algorithmic framework for the exact solution of the prize-collecting Steiner tree problem"; Leitner, Ljubić, Luipersbeck & Sinnl's DA-based B&B framework solves most literature PCSTP/MWCS instances in seconds).

**Why this is the right formulation for netwerk.** The `γ_ω` term prices the *shared trench inside an area* exactly, which no compact CFLP formulation can. The LP relaxation of (M) equals the Dantzig–Wolfe / Lagrangian bound obtained by dualising the assignment constraints in the compact model — i.e. it is at least as tight as everything in §2.3, and strictly tighter than any aggregated compact formulation. Ceselli & Righini (2005, *Networks* 45(3):125–142) do exactly this for the capacitated p-median; Klose & Görtz (2007, *EJOR* 179(3):1109–1125) for CFLP; Barnhart, Johnson, Nemhauser, Savelsbergh & Vance (1998, *Operations Research* 46:316–329) and Lübbecke & Desrosiers (2005, *Operations Research* 53:1007–1023) are the framework references.

**The catch, and the fix that makes it Tier-1-adjacent.** Trench shared *between* areas (which iteration 005 showed is worth 8% of trench) breaks pure set-partitioning: `Σ_ω γ_ω` double-counts corridors two areas share. Options: (a) accept the double-count, making (M)'s optimum an *upper* bound on the true cost and its LP an unreliable lower bound — **not acceptable for a certificate**; (b) put the inter-area trench in a separate Steiner layer, giving branch-cut-and-price for capacitated ConFL (Leitner & Raidl, *J. Math. Model. Algorithms* 2011) — correct, Tier 2, heavy; (c) define `γ_ω` to *exclude* the feeder/inter-area trench entirely and add the DA bound of §2.2 for it as a separate additive term. **(c) is valid** (both terms bound disjoint resources from below) and is the pragmatic path.

**The bound you get even with heuristic pricing.** This is the part worth stressing. Given the restricted master value `z_RMP` and the most-negative reduced cost `c̄_min < 0` found by *any* pricing procedure that also returns a valid lower bound on the true minimum reduced cost, the Lagrangian (Farley/Lasdon-style) bound is

```
LB  =  z_RMP  +  K · c̄_min           (K = 32, the cardinality bound on Σ θ)
```

which is **valid without ever generating all columns and without solving pricing to proven optimality**, provided the pricing bound is itself valid — and DA on the PCSTP pricing instance gives exactly such a bound (§2.2). This composes: a Tier-1 dual-ascent pricing bound inside a Tier-2 column-generation loop yields a certified global bound.

*Complexity:* each pricing round is `|J_cand|` PCSTP dual-ascent runs. At 32 candidate FDH nodes and 0.9 s per full-district DA (my measured figure, and pricing instances are ~1/16 the size), a round is ~2 s; 50–200 rounds ⇒ 2–7 minutes. That is far outside the 11 s golden path but perfectly fine as an offline `netwerk bound` verb. *Tier:* **Tier 2** for the master LP (needs an LP solver with duals); the pricing is Tier 1.

*Expected gain:* the LP bound of (M) is the tightest bound in this section and the only one that certifies the *clustering* decision, which no netwerk artifact currently touches (backlog item 7 has no measurement at all). If clustering is 5% off, that is ~30M cents. Unknown until measured — which is the argument for measuring.

---

### 2.8 Lagrangian-guided rounding and where reduced-cost fixing actually pays

**Guided rounding.** Given `π` (Lagrangian multipliers or master duals) and the volume algorithm's fractional `x̄`, the standard construction is: sort candidate facilities by `f_j + κ_j(λ)` (the Lagrangian "attractiveness"), open greedily, then assign each customer to its cheapest open facility with room, then run a repair. The key property netwerk should adopt from this literature: **the repair must be priced by the true objective, not by the Lagrangian** — which is exactly the lesson the campaign already learned the hard way ("any repair pass that moves things without pricing the true objective silently spends the budget the optimizer saved"). The Lagrangian's role is *ordering the moves*, not scoring them.

Concretely for netwerk: `x̄_iv ∈ (0,1)` from a volume run on §2.4 identifies the ~10–20% of premises whose terminal assignment the LP is genuinely torn about. Restricting the existing swap/2-opt passes (backlog items 2 and 3) to that set turns an O(n²) fixpoint search into an O(k²) one with k ≈ 700–1,300, and — more importantly — points it at the premises where a swap can actually change the objective.

**Reduced-cost fixing at the siting layer.** `x_iv` can be fixed to 0 whenever `c̄_iv > UB − LB`. At the terminal layer `c_iv` includes a 50,000-cent street-crossing term and up to 22,500 cents of drop cable, against a gap that (if the §2.4 bound lands anywhere near the incumbent) will be a few tens of millions across 1.27M candidate pairs — i.e. per-pair gaps of tens of cents. I expect **massive** fixing here, in contrast to the measured zero fixing on trench edges. Sizing: 1.27M candidate `(i,v)` pairs is exactly the number I enumerated in `uncond.py`; fixing 90% of them would shrink every downstream packing search by 10×. That is a runtime win as much as a quality win.

*Tier:* **Tier 1** (one comparison per pair, integer). Depends on §2.3/§2.4 existing first.

---

### 2.9 What netwerk should compute, in order, to have a real certificate

1. **`DualBound` stage (Wong DA on trench).** Done in prototype, 0.9 s Python / est. 20–50 ms Carbon. Emits `dual_bound_trench_cents`. Adds a `gap_to_bound` column to `results/LEDGER.md`. **Already tells you trench routing is 4.22%-exhausted.**
2. **DA-guided primal.** Run the existing SPH on the DA saturation graph and keep whichever tree is cheaper. Measured −2,980,500 cents. Free once (1) exists.
3. **Separable hardware/drop bounds** (five small DPs, ~60 lines). Proves cabinets optimal, splitters within 0.17M, OLT within 0.56M — three permanently closed backlog directions.
4. **Lagrangian/volume bound on the terminal layer (§2.4).** The first bound on the 176.7M penalty budget. This is the single highest-value unbuilt item in the whole campaign.
5. **Reduced-cost fixing on `(premises, candidate terminal node)` pairs (§2.8).**
6. *(Tier 2)* Group-Steiner LP or column generation for the unconditional bound.

**A validity note the campaign must not lose.** The 704.7M figure is *conditional on the required-node set* — it bounds "the cheapest design that puts terminals where this design puts them". The unconditional figure is 319.3M. Both are valid; they answer different questions, and the LEDGER should carry both, labelled. Reporting the conditional bound as if it were unconditional would be exactly the "optimizing your own yardstick" failure the backlog already warns about.

---

### 2.10 Ranking: expected score reduction per unit of implementation effort

Effort is in engineer-days of Carbon/Tier-2 work. "Direct gain" is score reduction; "decision value" is what the number lets you stop doing. I have marked measured numbers **M** and extrapolations **E**.

| # | Technique | Tier | Effort | Direct gain (cents) | Decision value | Rank rationale |
|---|---|---|---|---|---|---|
| 1 | **Wong dual ascent on trench** (§2.2.2) + report/LEDGER wiring | 1 | 1.5–2 d, ~250 lines | 0 | **Enormous** — proves trench routing ≤4.22% from optimum **(M)**; closes backlog 6c at a 25.5M ceiling | Highest. Cheap, deterministic, no solver, and it stops the campaign spending iterations on an exhausted lever |
| 2 | **DA-guided primal** (SPH on the saturation graph) | 1 | 0.5 d (reuses 1) | **−2,980,500 (M)** | Small | Best pure gain-per-day in the section; essentially a by-product of #1 |
| 3 | **Separable hardware/drop DP bounds** (§2.0 Result 4) | 1 | 0.5–1 d, ~60 lines | 0 | High — cabinets **proven optimal (M)**; splitters/OLT bounded within 0.74M total | Trivially cheap; permanently closes three lines of inquiry |
| 4 | **Lagrangian + volume bound on the TERMINAL layer** (§2.4, §2.3) | 1 | 5–8 d | 0 directly; enables targeted repair | **Highest in the campaign** — first bound on 212.7M of penalty+drop cost, 65.6% of the certified gap **(E)** | Costlier, but it is the only technique that measures the part of the objective nobody can currently see |
| 5 | **Reduced-cost fixing on (premises, terminal-node) pairs** (§2.8) | 1 | 1–2 d (needs #4) | 0 directly; ~10× search-space shrink **(E)** | Medium | Cheap follow-on; enables the swap/2-opt passes in backlog 2/3 to run to fixpoint |
| 6 | **Erlenkotter DUALOC on FDH siting** (§2.2.1) | 1 | 3–4 d | ≤ ~6.7M total exists at this layer; realistic **< 0.5M (M/E)** | Low | Textbook-correct, netwerk-irrelevant. Listed so nobody builds it by default |
| 7 | **Column generation over serving-area patterns** (§2.7) | 2 | 15–25 d | Unknown; clustering is unmeasured, 5% would be ~30M **(E)** | High — only route to certifying the clustering decision | Best long-run bound, but gated on C++ interop and an LP-with-duals surface |
| 8 | **Group-Steiner LP / unconditional trench bound** (§2.0 Result 5) | 2 | 10–15 d | 0 | High — converts the 67.2% unconditional gap into something meaningful | Naive DA **measured at 67.7% gap (M)** — needs real LP machinery |
| 9 | **Semi-Lagrangian relaxation** (§2.5) | 2 | 10–15 d | 0 | Medium-high — *closes* the gap where it applies | Only worth it after #4 shows a large gap worth closing exactly |
| 10 | **Benders (Magnanti–Wong / Fischetti et al.)** (§2.6) | 2 | 20–30 d | Unlikely to close on 6,719 premises **(E)** | Low-medium | Subproblem is a Steiner tree, not an LP; needs lazy-cut callbacks the planned HiGHS interop does not expose |
| 11 | **ConFL MIP (Gollowitzer–Ljubić cut model)** (§2.1) | 2 | 20–30 d | ~0 at FDH layer **(M: cabinets already optimal)** | Low | Correct model, empty pocket. Only interesting if the terminal layer is folded in as a third level |

**Interop surface Tier 2 must expose, derived from the above:** (a) LP solve returning **row duals** and reduced costs (HiGHS), for §2.6/§2.7; (b) 0-1 ILP with exactly-one / at-most-one constraints, integer objective, and **solution hinting** (CP-SAT), for §2.4-exact and §2.5; (c) a callback or iterative re-solve loop for cut separation, for §2.6/§2.7 — HiGHS has no general lazy-constraint callback today, which is a design constraint worth recording in the M3 roadmap now rather than discovering later.

---

**Sources**

- [Erlenkotter, D. (1978). A dual-based procedure for uncapacitated facility location. *Operations Research* 26(6):992–1009](https://pubsonline.informs.org/doi/abs/10.1287/opre.26.6.992)
- [Wong, R.T. (1984). A dual ascent approach for Steiner tree problems on a directed graph. *Mathematical Programming* 28:271–287](https://link.springer.com/content/pdf/10.1007/BF02612335.pdf)
- [Leitner, Ljubić, Luipersbeck & Sinnl. A dual-ascent-based branch-and-bound framework for the prize-collecting Steiner tree and related problems](https://msinnl.github.io/pdfs/da-TR.pdf)
- [Pajor, Uchoa & Werneck. A robust and scalable algorithm for the Steiner problem in graphs](https://arxiv.org/pdf/1412.2787)
- [Polzin & Vahdati Daneshmand (2001). Improved algorithms for the Steiner problem in networks. *Discrete Applied Mathematics* 112:263–300](https://www.sciencedirect.com/science/article/pii/S0166218X0000319X)
- [Cornuéjols, Sridharan & Thizy (1991). A comparison of heuristics and relaxations for the capacitated plant location problem. *EJOR* 50](https://www.semanticscholar.org/paper/The-capacitated-plant-location-problem-Sridharan/28a58c7bed5f023612f9c9484e74072b614c66cc)
- [Guignard & Opaswongkarn (1990). Lagrangean dual ascent algorithms for computing bounds in capacitated plant location problems. *EJOR* 46:73–83](https://www.sciencedirect.com/science/article/abs/pii/037722179090299Q)
- [Barahona & Anbil (2000). The volume algorithm: producing primal solutions with a subgradient method. *Mathematical Programming* 87:385–399](https://link.springer.com/content/pdf/10.1007/s101070050002.pdf)
- [Beltran, Tadonki & Vial (2006). Solving the p-median problem with a semi-Lagrangian relaxation. *COAP* 35:239–260](https://link.springer.com/article/10.1007/s10589-006-6513-6)
- [Magnanti & Wong (1981). Accelerating Benders decomposition: algorithmic enhancement and model selection criteria. *Operations Research* 29](https://www.semanticscholar.org/paper/Accelerating-Benders-Decomposition%3A-Algorithmic-and-Magnanti-Wong/0b7e5fc81889ab8ce592abeeee20c5f132063a09)
- [Fischetti, Ljubić & Sinnl (2017). Redesigning Benders decomposition for large-scale facility location. *Management Science* 63(7):2146–2162](https://pubsonline.informs.org/doi/10.1287/mnsc.2016.2461)
- [Gollowitzer & Ljubić (2011). MIP models for connected facility location: a theoretical and computational study. *Computers & OR* 38:435–449](https://www.sciencedirect.com/science/article/pii/S0305054810001334)
- [Swamy & Kumar (2004). Primal–dual algorithms for connected facility location problems. *Algorithmica* 40:245–269](https://link.springer.com/article/10.1007/s00453-004-1112-3)
- [Ceselli & Righini (2005). A branch-and-price algorithm for the capacitated p-median problem. *Networks* 45(3):125–142](https://onlinelibrary.wiley.com/doi/10.1002/net.20059)
- [Klose & Görtz (2007). A branch-and-price algorithm for the capacitated facility location problem. *EJOR* 179(3):1109–1125](https://ideas.repec.org/a/eee/ejores/v179y2007i3p1109-1125.html)
- [Correia & Captivo (2003). A Lagrangean heuristic for a modular capacitated location problem. *Annals of OR* 122:141–161](https://link.springer.com/content/pdf/10.1023/A:1026146507143.pdf)
- [Duin, Volgenant & Voß (2004). Solving group Steiner problems as Steiner problems. *EJOR* 154(1):323–329](https://www.sciencedirect.com/science/article/abs/pii/S0377221702007075)
- [Garg, Konjevod & Ravi (2000). A polylogarithmic approximation algorithm for the group Steiner tree problem. *Journal of Algorithms* 37(1):66–84](https://www.sciencedirect.com/science/article/abs/pii/S0196677400910964)
- [Goemans & Myung (1993). A catalog of Steiner tree formulations. *Networks* 23:19–28](https://onlinelibrary.wiley.com/doi/abs/10.1002/net.3230230104)
- [Chardy, Costa, Faye & Trampont (2012). Optimizing splitter and fiber location in a multilevel optical FTTH network. *EJOR* 222:430–440](https://www.sciencedirect.com/science/article/abs/pii/S0377221712003748)
- [Ljubić (2021). Solving Steiner trees: recent advances, challenges and perspectives. *Networks*](https://onlinelibrary.wiley.com/doi/abs/10.1002/net.22005)

*Uncited/extrapolated claims, flagged: the "dual-ascent bounds run 1–3% below the bidirected-cut LP optimum" figure is my generalisation from Polzin & Vahdati Daneshmand and the DIMACS-11 results, not a quoted number; the integer-scaled subgradient step rule for determinism is my construction, I found no published treatment; all netwerk-specific numbers marked (M) were computed by me on this repository's data and are reproducible from the scripts named in §2.0.*


---

## 3. Network-flow and Steiner-arborescence formulations for trench and fiber routing

### 3.0 What the trench actually costs, and what shape the problem actually has

Before any formulation, the anatomy of the number this section attacks, read off `designs/parcels_district.report.txt` (iter 007) rather than estimated:

| line | $ | % capex | % of the 973.8 M-cent score |
|---|---:|---:|---:|
| trench soft, 118,117 m @ $45 | 5,315,265 | 66.7 | 54.6 |
| trench asphalt, 4,928 m @ $150 | 739,200 | 9.3 | 7.6 |
| **trench total, 123,045 m** | **6,054,465** | **75.9** | **62.2** |
| distribution cable (141,086 m over 6 catalog sizes) | 480,641 | 6.0 | 4.9 |
| feeder cable (25,118 m) | 39,320 | 0.5 | 0.4 |
| drop cable 193,937 m + 6,719 drop assemblies | 1,097,186 | 13.8 | 11.3 |
| hardware (FDH, splitters, terminals, OLT) | 299,750 | 3.8 | 3.1 |
| penalties (2,238 street-x, 684 drop-x, 511 under-4) | 1,766,800 | — | 18.1 |

**Trench is 62% of the score and 12× the entire backbone-cable bill.** Everything in this section is ranked against that fact.

Three structural measurements I took on the shipped district design (scripts in scratchpad; graph re-parsed from `data/parcels_district.txt`, trench tree from `designs/parcels_district/trench.geojson`):

1. **The required set is 1,702 nodes** — CO + 16 FDHs + 1,688 *distinct* terminal nodes (1,753 terminals share nodes) — out of 15,668. Terminal density 10.9%. The road graph totals 528,215 m; the design trenches 23.3% of it. Median edge 21 m, degrees concentrated at 3 (8,807 nodes) and 2 (3,623).
2. **28.6% of the trench serves exactly one required node.** Rooting the trench tree at the CO and counting required nodes per subtree: 35,387 m (≈ $1.59 M) of trench is *dedicated single-terminal spur*; 40.0% serves ≤ 2 required nodes; only 20.5% is trunk carrying ≥ 50. **The trench bill is a last-100-metres problem, not a trunk problem.**
3. **Trivial reductions barely dent it.** Degree-1 pruning + degree-2 contraction of non-required nodes: 15,668 → 11,732 nodes, 23,824 → 19,399 edges (−25%/−19%). This instance does not collapse the way sparse SteinLib instances do.

And the exchange rates that govern every formulation below (all from `model.carbon`):

| 1 m of soft trench ($45) buys | |
|---|---|
| 288f cable | 5.77 m |
| 12f cable | 47.4 m |
| drop cable | 30.0 m |
| avoided street crossings | 0.09 (one crossing = 11.1 m of soft trench) |

That last row is the hinge of this whole section, and §3.3 shows it empirically flipping a $1.48 M trench saving into a $0.61 M loss.

**The formal shape.** Trench has *no capacity* — a trench either exists or does not, and any number of cables fit. Therefore:

> netwerk's trench subproblem is exactly the **uncapacitated fixed-charge network design** problem of Magnanti & Wong (1984) and Balakrishnan, Magnanti & Wong (1989), whose single-root special case is the **Steiner arborescence** problem. The cable subproblem, *conditional on the chosen trench*, is a **fixed-charge network flow with a staircase (catalog) cost**. They are separable to first order because trench:cable = 11.6 : 1.

This is not a re-description — it tells you which literature has the algorithms, which relaxation gives a bound, and which parts need a solver.

---

### 3.1 The formulation landscape: which relaxation, and what it costs at 23.8 k edges

Notation: G = (V,E), |V| = 15,668, |E| = 23,824; edge e has length ℓ_e and trench cost f_e = ℓ_e·(4500 | 15000) cents; R ⊆ V required, |R| = 1,702, root r = CO node.

**(a) Undirected cut relaxation (UC).**

```
min  Σ_{e∈E} f_e x_e
s.t. Σ_{e∈δ(S)} x_e ≥ 1     ∀ S ⊂ V : S∩R ≠ ∅, (V\S)∩R ≠ ∅
     x ∈ [0,1]^E
```

This is the relaxation whose integrality gap the Goemans–Williamson (1995) primal–dual analysis certifies at 2, and the gap is *exactly* 2 (the tight family is a cycle on terminals). A bound that can be 2× off is worthless for a campaign trying to find the last 5% of a $6 M trench bill.

**(b) Bidirected cut / Steiner arborescence (BCR).** Replace each edge by an antiparallel arc pair, both at cost f_e, and require every terminal-containing set not holding the root to have an entering arc:

```
A = {(i,j),(j,i) : {i,j} ∈ E},  f_{(i,j)} = f_{(j,i)} = f_{ij}
min  Σ_{a∈A} f_a z_a
s.t. Σ_{a∈δ⁻(S)} z_a ≥ 1     ∀ S ⊆ V\{r} : S∩R ≠ ∅
     z ∈ [0,1]^A
```

BCR **strictly dominates** UC (Polzin & Vahdati Daneshmand 2001, *A comparison of Steiner tree relaxations*, DAM 112:241–261, which establishes the full dominance hierarchy among tree-class, flow-class and cut-class formulations and shows flow/dicut-class relaxations are never worse than tree-class ones). Its gap is ≤ 2 and now provably < 2 — 1.9988 (Byrka, Grandoni & Traub, arXiv:2407.19905, 2024) — with lower bounds 8/7 (Skutella's example) and 36/31 (arXiv:2405.13773, 2024), and it is the relaxation underneath every serious exact solver (SCIP-Jack: Gamrath, Koch, Maher, Rehfeldt & Shinano 2017, *Math. Prog. Computation* 9:231–296). *Extrapolation, not citation:* published exact-solver practice implies the BCR gap is typically low single-digit percent on structured instances, but I found no per-instance gap table for lattice/parcel geometry, so treat "BCR ≈ OPT" as a working assumption, not a result.

**(c) Multicommodity flow (MCF) — and why it is dead here.** BCR's compact equivalent sends one unit of flow from r to each terminal, with *disaggregated* linking:

```
∀t ∈ R\{r}:  Σ_{a∈δ⁺(v)} y^t_a − Σ_{a∈δ⁻(v)} y^t_a = [v=r] − [v=t]   ∀v
             y^t_a ≤ z_a                                              ∀a
min  Σ_a f_a z_a
```

LP-equivalent to BCR by max-flow/min-cut. **At netwerk's scale this formulation has 1,701 × 47,648 = 81.0 M flow columns and ≈ 107.7 M rows.** It cannot be written, let alone solved, by HiGHS or anything else. This is the single most important practical fact in this subsection: *do not build the compact MCF for the district*.

The tempting fix — one aggregated commodity of value |R|−1 with big-M linking z_a ≥ y_a/(|R|−1) — is compact (95 k variables) but its LP bound collapses toward the cost of a single cheapest path. This is precisely the "weak vs. strong formulation" distinction from fixed-charge network design (Rardin & Choe 1979; Gendron, Crainic & Frangioni 1999, *Multicommodity capacitated network design*), and it is the mistake to avoid if anyone ever tries a quick MIP.

**(d) What you can actually run.** BCR with **row generation**: 47,648 binaries, cuts separated by min-cut. Each separation round needs up to 1,701 max-flows on a 15.7 k-node / 47.6 k-arc graph. *Extrapolating* from typical push-relabel throughput (10–50 ms each), that is 20–85 s **per round**, and root-LP convergence needs tens of rounds → 10–60 min for the root bound alone, with proven optimality at 1,702 terminals unlikely inside any sane budget. Reductions (§3.8) shrink this by ~20–25%, not by an order of magnitude.

**Verdict for netwerk.** The arborescence view is the right *mental* model and the right *bound* model. As a monolithic solve it is Tier 2 and slow. The score is won by (i) local search on the incumbent tree (§3.2), (ii) changing the required set (§3.3), and (iii) exact solves on *small extracted subproblems* (§3.5) — with BCR/dual ascent used only to certify how much is left (§3.4).

---

### 3.2 Technique A — key-path local search on the trench tree (**measured −$155 k**, Tier 1)

**What it is.** Given a Steiner tree T for R, call a node *key* if it is required or has tree-degree ≥ 3. A *key path* is a maximal path in T whose interior nodes are all non-key degree-2 nodes. The exchange move:

```
for each key path P with endpoints a,b, in decreasing order of cost(P):
    remove P's edges  ->  T splits into components A ∋ a and B ∋ b
    d = cheapest path in G from A to B         (multi-source Dijkstra,
                                                all A-nodes as 0-cost sources,
                                                stop on first B-node popped)
    if cost(d) < cost(P):  T <- (T \ P) ∪ d
prune non-required leaves; repeat to fixpoint
```

This is one of the four neighbourhoods of Uchoa & Werneck (2010/2012, *Fast local search for Steiner trees in graphs*, ALENEX / *ACM JEA* 17), alongside vertex insertion, vertex elimination and key-vertex elimination; they show each can be searched in O(m log n) per round with dynamic-tree data structures. The naive version above is O(|keypaths| · (n + m log n)) which is entirely adequate at this size.

**Why it fits netwerk.** `DeloopTrench` phase 1 builds one global tree with the Takahashi–Matsuyama (1980) shortest-path heuristic: required nodes are attached one at a time by incremental multi-source Dijkstra, in **heap-pop order**. That order is a construction artefact — a corridor opened early to reach one terminal is never revisited once a later, cheaper corridor makes it redundant. Key-path exchange is precisely the repair for that artefact, and it preserves the tree property, so `rings = 0` stays true by construction and phases 2–4 need no change.

**Expected gain — measured, not argued.** Running the loop above on the shipped district trench tree (my re-parse: 5,866 edges, 123,784 m, $6,094,440):

| | cost | meters |
|---|---:|---:|
| MST of the terminal metric closure (Mehlhorn Voronoi construction) | $6,610,635 | — |
| Mehlhorn/KMB tree (path expansion + MST + prune) | $6,234,300 | 126,878 |
| **engine's TM tree (shipped)** | **$6,094,440** | **123,784** |
| round 1 (217 exchanges, 60 s) | $5,945,610 | 120,514 |
| round 2 (16 exchanges) | $5,939,625 | 120,388 |
| round 3 (3 exchanges) → fixpoint | **$5,939,175** | **120,378** |

**−$155,265 (−2.55% of trench, −3,406 m), converged in 3 rounds.** On the report's trench base that is ≈ **−15.5 M cents = −1.6% of the composite score**. Note also the calibration this gives for free: the engine's TM tree is already 7.8% below MST(metric closure) and 2.2% below Mehlhorn/KMB — **the shipped heuristic is good, and Mehlhorn is not an upgrade** (it is an upgrade in *speed*, O(m log n) with a single Dijkstra + Kruskal, if construction time ever matters).

**Complexity / runtime.** 1,702 key paths per round; per path one tree BFS (≈ 5.9 k nodes) plus one early-terminating Dijkstra. ≈ 10 M + a few M relaxations per round. Python measured 163 s to fixpoint; **Carbon with the existing integer binary heap should land at 1–3 s**, i.e. ~10–25% on top of the current 11 s.

**Tier 1 sketch.** Everything needed exists in `graph.carbon`/`stages.carbon`. New state: `key_of: array(bool, MaxNodes)`, `tree_deg: array(i32, MaxNodes)`, `comp: array(i8, MaxNodes)`, a path buffer `kp_edge: array(i32, 512)`. Reuse `d.heap_node` as the FIFO for the component BFS exactly as `ForestBfs` already does, and `DijkstraReset`/`AddSource`/`HeapPop` for the reconnection, relaxing with `TrenchCostPerM`. **Determinism:** iterate key paths in decreasing (path cost, then smallest edge id) order — the order I measured; accept only *strict* improvements; break reconnection ties by smallest `prev_edge` id. Insert between `DeloopTrench` phase 1 and phase 2, then let phases 2–4 re-route fibers and re-prune as they already do. **One guard is mandatory:** key-path exchange can *lengthen* CO→premises routes, and the backlog already records the worst route at 18,060 m of the 20,000 m optical budget — reject any exchange that pushes `node_path_m` past the budget for any terminal in the moved component.

---

### 3.3 Technique B — connected facility location / group Steiner: move the terminals, not the wire (**measured −$420 k on top of A**, Tier 1)

**The observation.** §3.0 measurement 2: 28.6% of trench (35,387 m, $1.59 M gross) exists to reach *one* terminal. The terminal sits at a parcel-corner node chosen by `PackTerminals` to minimise drop crossings and drop length — with **no knowledge that reaching it will cost a private trench spur**. Meanwhile a metre of trench buys 30 m of drop cable. This is textbook: the current pipeline solves facility location and connection *sequentially*, and the correct joint model is **connected facility location** (Karger & Minkoff 2000; Gupta, Kleinberg, Kumar, Rastogi & Yener 2001; Swamy & Kumar 2004, 8.55/4.55-approx primal–dual; Eisenbrand, Grandoni, Rothvoß & Schäfer 2010, 4.00 for ConFL and 2.92 for single-sink rent-or-buy via random facility sampling + core detouring):

```
min  Σ_{i∈F} σ_i y_i                             (terminal hardware, catalog-stepped)
   + Σ_{j∈D} Σ_{i∈F} d_ij x_ij                   (drop cost + crossing penalties)
   + Σ_{e∈E} f_e z_e                             (trench)
s.t. Σ_i x_ij = 1 ∀j∈D;  x_ij ≤ y_i;  Σ_j x_ij ≤ 12·y_i;  (Σ_j x_ij ≥ 4·y_i soft)
     d_ij = ∞ if ‖j−i‖ > 150 m
     z(δ⁻(S)) ≥ y_i   ∀ S ⊆ V\{r}, i ∈ S          (opened facilities + root connected)
```
with F = graph nodes, D = premises, and `d_ij = 150·drop_m + 50000·street_x(j,i) + 20000·dropdrop_x + …` — i.e. **the scorer, verbatim**. Fixing the assignment x and letting only the facility node move gives the **group Steiner tree** problem (Reich & Widmayer 1989, *Beyond Steiner's problem: a VLSI oriented generalization*; Garg, Konjevod & Ravi 2000, O(log²n log log n log k) — theoretically important, practically irrelevant here): each terminal t defines a *group* g_t = { v ∈ V : max_{p∈P_t} dist(p,v) ≤ 150 }, and the tree must touch one node of each group.

**The Tier-1 move — a priced line search along the private spur.** Root the trench tree at the CO, compute `cnt[v]` = number of required nodes in v's subtree by one reverse pass over the BFS order (`ForestBfs` already produces that order). For terminal t at node v, walk toward the root while `cnt[·] == 1`, collecting candidate nodes and cumulative freed trench cost. For each candidate c evaluate the **true objective delta**

```
Δ(c) = −(trench cents freed up to c)
       + 150 · Σ_{p∈P_t} (‖p−c‖ − ‖p−v‖)                    (drop cable)
       + 50000 · Σ_p (street_x(p,c) − street_x(p,v))         (drop-street crossings)
       + 20000 · Δ(drop-drop crossings)
       subject to  max_p ‖p−c‖ ≤ 150 m
```
and apply the strictly-best c (tie-break smallest node id).

**Why this is *the* technique for netwerk, and why naive versions destroy value.** I measured three variants on the shipped tree, using the scorer's own exact integer orientation predicate and a 128 m edge grid (same construction as `CountDropCrossings`):

| variant | moves | trench saved | drop cable | Δ street-x | **net** |
|---|---:|---:|---:|---:|---:|
| move every relocatable terminal to its attach point (**unpriced**) | 656 | −$1,478,610 | +$80,247 | **+4,008 (+$2,004,000)** | **+$605,637 (worse)** |
| move only where the priced delta improves | 276 | −$643,290 | +$21,078 | +580 (+$290,000) | **−$332,212** |
| **best priced position along the spur (line search)** | **396** | (15,378–16,798 m) | | | **−$449,937** |

The first row is the brief's own hard-won lesson made quantitative: **an unpriced repair pass converts a $1.48 M trench win into a $0.61 M loss**, because 4,008 new street crossings are worth 44.5 km of soft trench. The parcel-lattice geometry that forces ~k²/4 crossings per k-customer terminal is exactly what punishes moving a terminal onto a corridor.

**It composes with §3.2.** Re-running the priced spur line search *on the key-path-improved tree*: **394 moves, −$420,021, 15,378 m** — essentially fully additive.

| | trench cost | meters |
|---|---:|---:|
| shipped | $6,094,440 | 123,784 |
| + key-path LS (§3.2) | $5,939,175 | 120,378 |
| + priced spur re-siting (§3.3) | **≈ $5,519,000** | **≈ 105,000** |

**≈ −$575 k = −9.4% of trench = −57.5 M cents = −5.9% of the composite score**, from two passes that need no solver.

**Honest haircuts.** (i) My measurements use my own `round(hypot)` edge lengths, giving 123,784 m vs the engine's 123,045 m — a 0.6% high base; quote the percentages, not the absolutes. (ii) I priced street crossings exactly but **not** drop-drop crossings; concentrating terminals on trunk nodes plausibly adds some, and at $200 each even a doubling of the current 684 costs $136,800. (iii) Moves are evaluated one-at-a-time against a static `cnt[]`; a real implementation must either update ancestors after each accept or iterate the pass to fixpoint. Realistic banked value: **$300–450 k**, i.e. **3–4.6% of the composite score** — still the largest single lever found since iteration 005. (iv) *Neutral by construction:* re-siting changes no port counts, so the 95.0% terminal-port utilization floor is untouched; and because moves only shorten CO→premises paths, the 20,000 m budget is safe (unlike §3.2).

**Second-order bonus.** Re-sited terminals become co-located (already 1,753 terminals on 1,688 nodes). Re-running the existing scorer-priced `MergeTerminals` afterwards gets fresh dissolve targets at zero drop cost — a direct attack on the 511 under-4 terminals ($511,000). Worth measuring; not counted above.

**Tier 2 upgrade.** The full group-Steiner neighbourhood — allow any node in g_t, not just nodes on the spur — plus reassignment of premises between terminals, is capacitated ConFL. Formulated as a Steiner arborescence on an augmented graph it is solvable by branch-and-cut (Gollowitzer & Ljubić 2011, *MIP models for connected facility location*, C&OR 38:435–449). **Interop surface required:** a HiGHS handle exposing `addCols/addRows`, incremental row addition (lazy constraints) and a warm-started dual simplex, plus a max-flow routine for cut separation. Expect it as an LNS polish on extracted subregions (§3.5), not a global solve.

---

### 3.4 Technique C — dual ascent on the arborescence: a *certified* lower bound (Tier 1, no direct score gain)

**What it is.** Wong (1984), *A dual ascent approach for Steiner tree problems on a directed graph*, Math. Prog. 28:271–287. Maintain reduced costs r_a ← f_a. Repeat: pick an unconnected terminal t; let W = the set of nodes that reach t through 0-reduced-cost arcs only; if r ∈ W, t is connected — drop it; else δ = min{ r_a : a ∈ δ⁻(W) }; **LB += δ**; r_a −= δ for all a ∈ δ⁻(W). The result is a feasible dual to BCR, hence a valid lower bound on the optimal trench cost; the saturated-arc structure also yields a primal heuristic. Wong's procedure generalises both Chu–Liu/Edmonds and the Bilde–Krarup/Erlenkotter plant-location ascent, and Balakrishnan, Magnanti & Wong (1989), *A dual-ascent procedure for large-scale uncapacitated network design*, Oper. Res. 37:716–740, report **1–3% optimality gaps** on fixed-charge network design instances with up to ~2 M continuous variables.

**Why netwerk needs it even though it saves nothing directly.** The campaign has flattened to <1%/iteration and is spending effort blind. Right now the only bounds available are useless: MST(metric closure) = $6,610,635 gives OPT ≥ MST/(2−2/1702) ≈ $3.3 M. A dual-ascent LB on the *current required set* would answer the question that decides the next three iterations: **is the remaining trench slack 2% or 15%?** If ascent returns, say, $5.3 M against the $5.52 M reachable by §3.2+§3.3, the Steiner-quality avenue is closed and all remaining effort belongs to §3.3-style required-set changes and to clustering.

This is the same machinery as section 2's dual ascent, and it is genuinely **Tier 1**: pure integer arithmetic, arrays only, deterministic if terminals are processed in a fixed order (Wong's "smallest component first" with node-id tie-break). Complexity: each ascent step saturates ≥ 1 arc, so ≤ |A| = 47,648 steps, each an O(m) backward BFS → 1.1 G ops worst case, far less in practice. *Extrapolation:* expect seconds, but I did not measure it. ~250 lines.

---

### 3.5 Technique D — exact re-optimization of small subregions (Tier 1 via Dreyfus–Wagner, Tier 2 via MIP)

**What it is.** Large-neighbourhood search where the neighbourhood is solved *exactly*. Pick a branch node b of the incumbent trench tree; extract the ball B of radius ρ (in trench cents) around b; the subproblem's terminals are the required nodes inside B plus every node where the incumbent tree crosses ∂B (these must remain connected to the outside); solve the Steiner tree on G[B] exactly; splice back if cheaper.

**Exact core, Tier 1: Dreyfus & Wagner (1971), improved by Erickson, Monma & Veinott (1987).** For terminal set K, |K| = k, over the sub-graph:

```
S(v, X)  = min cost Steiner tree connecting X ∪ {v}
S(v,{t}) = d(v,t)
S(v, X)  = min over ∅ ≠ X' ⊂ X of  [ S(v,X') + S(v, X\X') ]        (split at v)
S(v, X) <- min over u of  [ d(v,u) + S(u,X) ]                      (shortest-path closure)
answer   = S(t₀, K\{t₀})
```
O(3^k n' + 2^k (m' + n' log n')). At k = 8 and n' = 400 that is 6,561 × 400 ≈ 2.6 M ops ≈ 10 ms in Carbon, with a fixed DP table of 2^8 × 512 × 8 B = 1 MB — trivially inside "no heap, fixed arrays". At k = 10, n' = 400 it is ~24 M ops ≈ 100 ms. So **k ≤ 8–10 per ball is the Tier-1 budget**; 300–400 balls at k = 8 costs ~4 s.

**Expected gain — argued, not measured.** §3.2's key-path search already extracts the "one path at a time" improvements and converged after 236 exchanges. Dreyfus–Wagner over balls captures the *multi-path simultaneous* reconfigurations key-path cannot see (three spurs collapsing into one new corridor). Published contraction/local-search studies (Beyer & Chimani 2019, *Strong Steiner tree approximations in practice*, ACM JEA 24; Poggi de Aragão & Werneck 2002) put such incremental gains at roughly **0.5–2% of tree cost** once key-path search is exhausted → **$30–110 k**, at meaningfully higher implementation risk than §3.2/§3.3. Do it fourth, not first.

**Tier 2 variant.** For balls with 15–60 terminals, solve BCR-with-separation on the extracted subgraph in HiGHS (a few hundred nodes → milliseconds to a second). Same LNS wrapper, better neighbourhoods. **Interop surface:** MIP with lazy constraint callbacks, or an iterative solve-separate-resolve loop plus a max-flow routine; deterministic output requires fixing the solver seed, single-threaded mode, *and* accepting only improvements above an epsilon, since near-optimal LP bases differ across HiGHS versions — the golden-file gate makes this a real constraint, not a footnote.

---

### 3.6 Technique E — primal–dual (Goemans–Williamson) and the beyond-2 approximations: mostly **don't**

**Goemans & Williamson (1995)**, *A general approximation technique for constrained forest problems*, SIAM J. Comput. 24:296–317 (building on Agrawal, Klein & Ravi 1995). Grow uniform "moats" around each active component; when a moat boundary saturates an edge, add it and merge; then reverse-delete. Produces a 2-approximation **and** a feasible dual to the UC relaxation. O(n² log n) naively; O(m log n) with union-find + a heap of saturation events → sub-second here.

**Assessment: implement it for the dual, never for the primal.** GW's primal is a UC-based 2-approximation; the shipped TM tree is already 7.8% below MST(metric closure) and key-path takes it 2.5% further. GW will not beat it. And its *dual* certifies against a relaxation whose gap is exactly 2 — strictly worse than Wong's dual ascent on BCR (§3.4), at similar effort. **Skip; use §3.4 instead.** (GW's real home in netwerk is a different problem: the *prize-collecting* variant — Ljubić et al. 2006 — if the campaign ever wants to leave genuinely unprofitable premises unserved. That is a scope change, not a routing improvement.)

**Beyond-2 approximations.** Zelikovsky (1993) 11/6; Berman & Ramaiyer (1994) 16/9; **Robins & Zelikovsky (2005)**, *Tighter bounds for graph Steiner tree approximation*, SIAM J. Discrete Math. 19:122–134 — the loss-contracting relative-greedy algorithm with ratio ≈ 1.55; Byrka, Grandoni, Rothvoß & Sanità (2013, JACM) ln 4 + ε ≈ 1.39 via iterative randomized rounding of the hypergraphic LP. The k-restricted full-component machinery means enumerating candidate components over terminal triples/quadruples: at |R| = 1,702 the naive triple set is 5×10⁹ — you must restrict to geometric neighbours, and even then it is a large, delicate, allocation-hungry implementation.

**Assessment: low priority for netwerk.** These ratios are worst-case; on structured geometric instances the *practical* margin of loss-contracting over a well-improved SPH is small (Beyer & Chimani 2019 measure contraction-based methods in practice and find the gains modest once local search is applied). §3.2 already banked 2.55%. Expect **≤ 1% incremental (≤ $60 k) for ~600 lines** of the hardest code in this section, with real determinism risk (randomized rounding is out of the question for a byte-exact gate). *This is the technique I would explicitly recommend against.*

---

### 3.7 Technique F — the cable layer: staircase fixed-charge flow and slope scaling (Tier 1, small money)

**The model.** Conditional on the trench tree, per-edge cost is

```
g_e(w) = f_e · 1[w > 0]  +  ℓ_e · γ(w),   γ(w) = min Σ_k c_k n_k  s.t. Σ_k κ_k n_k ≥ w
```
a **staircase**: neither convex nor concave, subadditive, with marginal cable cost falling from 7.92 ¢/fibre-m (12f) to 2.71 ¢/fibre-m (288f) — a 2.9× economy of scale. This is fixed-charge network flow with catalog steps: `n_{e,k} ≤ M_k x_e`, `Σ_k κ_k n_{e,k} ≥ w_e`, w determined by flow conservation of terminal→FDH and FDH→CO demands.

**The Tier-1 algorithm: dynamic slope scaling (Kim & Pardalos 1999**, *A solution approach to the fixed charge network flow problem using a dynamic slope scaling procedure*, ORL 24:195–203; reported within 0–0.65% of optimality on their instances; see also Crainic, Gendron & Hernu 2004 for the slope-scaling/Lagrangian hybrid). Iterate:

```
c_e^0  = f_e/ℓ_e + c_min                                (initial linearized rate)
repeat: route all flow on shortest paths under c^k     (Dijkstra — already in graph.carbon)
        w_e^k = resulting fibre load
        c_e^{k+1} = ( f_e·1[w_e^k>0] + ℓ_e·γ(w_e^k) ) / max(w_e^k, 1)
until the edge set stops changing (cap at ~10 iterations, take the best by true cost)
```
Pure integer, deterministic (fixed tie-breaks on equal `dist`, then edge id), reuses the existing heap. This is a principled generalisation of the ad-hoc `ModeFeederCost()` "open-trench discount" already in `RouteFeeder`.

**Honest expected gain.** The entire backbone-cable bill is **$519,961** (6.5% of capex), of which $306,423 is 39,285 m of 288f — an artefact of centralized split, where each of a 432-unit area's premises needs its own fibre back to the FDH. Slope scaling redistributes flow, it does not change that arithmetic. Realistic recovery **5–10% of cable = $26–52 k**, with a real risk of *increasing* trench if the iteration opens corridors. **Low priority.** It becomes interesting only if the campaign ever evaluates distributed/cascaded split, which would collapse the 288f term outright — an architecture decision, not a routing one.

---

### 3.8 Technique G — capacitated tree design (Esau–Williams) and the two-level PON hierarchy

**Esau–Williams (1966)**, *On teleprocessing system design, Part II*, IBM Systems Journal 5(3):142–147 — the CMST savings heuristic, still the standard baseline for local-access network design (Gavish 1991; Amberg et al.). Formally: root r, nodes i with demand w_i, capacity K, cost c_ij; find a spanning tree of N ∪ {r} minimizing Σc_e such that every component of T − r has demand ≤ K.

```
init: every node connects directly to r; comp(i) = {i}; gate(i) = i
repeat: t_i = min_{j ∉ comp(i), w(comp(i))+w(comp(j)) ≤ K} c_{gate(i),j} − c_{gate(i),r}
        pick i with most negative t_i; merge comp(i) into comp(j); update gates
until no negative tradeoff
```

**The netwerk instantiation is elegant:** N = the 1,688 terminal nodes with w = units, r = CO, K = 432 units, c = graph trench distance. Each resulting subtree hanging off r **is simultaneously a serving area, its FDH's catchment, and its routing tree** — replacing stages 3+4+6 (cluster, place, feeder) with one algorithm that prices trench inside the clustering decision. The all-pairs metric it needs is avoidable: **Mehlhorn's (1988) Voronoi construction gives the candidate edge set from a single multi-source Dijkstra** — for each edge (u,v) with different nearest-terminals, a candidate arc base(u)→base(v) of weight d(u)+w(uv)+d(v). O(m log n) + O(n²) merging = well under a second at n = 1,688.

**Honest expected gain: small.** Since iteration 005 the trench is *one global Steiner tree over the full road graph*, chosen with no reference to cluster boundaries. Cluster membership therefore no longer affects trench at all — it affects only (a) per-edge fibre counts → cable cost, (b) feeder path lengths, (c) FDH node placement. Pool: ≈ $560 k. Realistic recovery **5–10% = $28–56 k**. **Esau–Williams is the classically-correct answer to a problem netwerk already routed around.** It earns its place in this document as a *negative* result worth recording, plus one live corollary:

**The live corollary — trench-aware FDH re-siting.** FDH nodes are currently the unit-weighted medoid of each serving area's snap nodes (`PlaceFdh`), computed before any tree exists. But each FDH is a required node of the global tree *and* the convergence point for 432 fibres of 288f-class cable. A CFL-style priced relocation of each of the 16 FDHs over the nodes of its area — evaluating Δ(trench) + Δ(feeder cable) + Δ(distribution cable) exactly, keeping the cabinet where it is if no strict improvement — is ~120 lines and a plausible **$50–150 k**. Same move as §3.3, one level up, 16 facilities instead of 1,688.

**The two-level view, and why it is currently degenerate.** The canonical model for the PON hierarchy is multi-level network design: Current, ReVelle & Cohon (1986) hierarchical network design; **Balakrishnan, Magnanti & Mirchandani (1994)**, *A dual-based algorithm for multi-level network design*, Management Science 40:567–581 (L facility grades per edge, nodes partitioned into levels, each level's nodes connected by facilities of that grade or higher — generalizing Steiner network and hierarchical network design); Chopra et al.'s branch-and-cut; and, closest to netwerk, **Bley, Ljubić & Maurer (2013)**, *Lagrangian decompositions for the two-level FTTx network design problem*, EURO J. Computational Optimization 1:221–252 — clients → distribution points → central offices, with fixed charges on edges/DPs/COs, variable fibre and splitter costs, and splitters letting k connections share one CO-DP fibre, on real regional FTTH/FTTB instances covered by 1–15 COs.

netwerk already gets the *hard* part right: iteration 005 made feeder and distribution share **one** tree instead of two, which is the whole point of MLND. What makes MLND non-degenerate — **grade-differentiated edge cost** — is absent from netwerk's cost model: `TrenchCostPerM` depends only on surface, not on whether the segment carries feeder or distribution. Until the catalog gains larger duct/bore for feeder corridors, the multi-level formulation collapses to a plain Steiner tree and adds nothing. **Flag it as a modelling gap, not an algorithm gap**; if feeder duct is ever priced separately, Bley–Ljubić–Maurer's Lagrangian decomposition (split by network structure or by cost structure, MIP subproblems) is the Tier-2 blueprint.

**One constraint that will bind.** The 20,000 m optical-budget proxy makes this a *length-constrained* Steiner arborescence. The standard exact tool is the layered/distance-indexed graph (Gouveia 1998; hop-constrained ConFL of Ljubić & Gollowitzer) — Tier 2, and it multiplies the graph by the hop bound. **Tier 1 answer: don't reformulate, just verify** — maintain `node_path_m` from the CO and reject any §3.2 move that violates the budget.

---

### 3.9 Prerequisite — graph reductions

Any solver-based work must be preceded by reduction: degree-1 pruning and degree-2 contraction of non-required nodes, parallel-edge merging, then the special-distance (SD) and bound-based tests of Duin & Volgenant (1989) and **Polzin & Vahdati Daneshmand (2001)**, *Improved algorithms for the Steiner problem in networks* (DAM 112:263–300), which are what let SCIP-Jack close SteinLib instances. **Measured here:** trivial reductions alone take 15,668 → 11,732 nodes and 23,824 → 19,399 edges (−25% / −19%). Useful, not transformative — the parcel lattice is mostly degree-3. Budget ~200 lines Tier 1; it also speeds §3.2/§3.5 by ~20%.

---

### 3.10 Ranking by expected score reduction per unit of implementation effort

Score baseline 973,816,190 cents. "Measured" = I ran it on the shipped district design; "argued" = estimated from the numbers above; "extrapolated" = from literature only.

| # | Technique | Tier | Expected Δscore (cents) | Effort (Carbon LOC / risk) | Confidence | Gain / effort |
|---|---|---|---|---|---|---|
| 1 | **Priced terminal re-siting along private spurs** (ConFL / group-Steiner move, §3.3) | 1 | **−30 M to −45 M** (−3.1% to −4.6%) | ~250, low (reuses `CountDropCrossings` + edge grid) | **measured** (−$420 k on the improved tree) | ★★★★★ |
| 2 | **Key-path local search on the trench tree** (§3.2) | 1 | **−15.5 M** (−1.6%) | ~200, low (reuses heap, `ForestBfs`) | **measured** (−2.55% trench, 3 rounds) | ★★★★★ |
| 3 | Iterate 1+2 to joint fixpoint + re-run priced `MergeTerminals` on newly co-located terminals | 1 | −5 M to −20 M | ~60 glue, low | argued (under-4 pool is 51.1 M) | ★★★★☆ |
| 4 | **Trench-aware FDH re-siting** (CFL one level up, §3.8) | 1 | −5 M to −15 M | ~120, low | argued | ★★★★☆ |
| 5 | **Wong dual-ascent lower bound** on BCR (§3.4) | 1 | 0 direct — tells you whether 1–3 exhausted the trench | ~250, medium | extrapolated (BMW89: 1–3% gaps) | ★★★☆☆ (instrument) |
| 6 | Graph reductions (§3.9) | 1 | 0 direct; −20% runtime, enabler for 7/9 | ~200, low | **measured** (−25% nodes) | ★★★☆☆ |
| 7 | Dreyfus–Wagner exact re-opt over balls, k ≤ 8 (§3.5) | 1 | −3 M to −11 M | ~250, medium (DP table, ball extraction) | extrapolated (0.5–2% post-local-search) | ★★☆☆☆ |
| 8 | Esau–Williams CMST for joint clustering + feeder (§3.8) | 1 | −3 M to −6 M | ~300, medium | argued (pool only $560 k; trench already global) | ★★☆☆☆ |
| 9 | Dynamic slope scaling for cable-aware routing (§3.7) | 1 | −2.6 M to −5 M, **risk of negative** | ~150, medium | argued (cable is 6.5% of capex) | ★★☆☆☆ |
| 10 | MIP/LP polish: BCR + cut separation on extracted subregions, HiGHS (§3.5) | **2** | −5 M to −20 M beyond 1–3 | large; needs lazy cuts + max-flow + determinism discipline | extrapolated | ★★☆☆☆ |
| 11 | Full ConFL branch-and-cut (§3.3 Tier 2) / hop-constrained layered graph (§3.8) | **2** | unknown, potentially large | very large | extrapolated (Gollowitzer–Ljubić 2011; Bley et al. 2013) | ★☆☆☆☆ |
| 12 | Loss-contracting 1.55-approx (Robins–Zelikovsky) (§3.6) | 1/2 | ≤ −6 M | ~600, high; randomized variants incompatible with byte-exact CI | extrapolated | ★☆☆☆☆ |
| 13 | Goemans–Williamson **primal** (§3.6) | 1 | ~0 (will not beat TM + key-path) | ~300 | argued | ✗ do not implement |
| 14 | Compact multicommodity-flow MIP of the whole district (§3.1c) | 2 | — | 81 M columns: **infeasible** | measured (sizing) | ✗ do not attempt |

**Bottom line for the next iteration:** items 1 and 2 are two independent, measured, solver-free passes worth a combined **≈ −$575 k of trench (−9.4%, ≈ −5.9% of composite score)**, both of which preserve the tree property (rings stay 0), leave the 95% utilization floor untouched, and reuse machinery already in `graph.carbon`. Item 5 should ship alongside them so the campaign learns, for the first time, how much trench slack is actually left.

---

### Sources

- [Polzin & Vahdati Daneshmand, *A comparison of Steiner tree relaxations*, DAM 112 (2001)](https://www.sciencedirect.com/science/article/pii/S0166218X00003188) · [preprint](https://madoc.bib.uni-mannheim.de/1747/1/1998_05.pdf)
- [Ljubić, *Solving Steiner trees: recent advances, challenges and perspectives*, Networks (2021)](https://onlinelibrary.wiley.com/doi/abs/10.1002/net.22005)
- [Byrka, Grandoni & Traub, *The Bidirected Cut Relaxation for Steiner Tree has Integrality Gap Smaller than 2* (2024)](https://arxiv.org/html/2407.19905) · [lower bounds for the BCR gap (2024)](https://arxiv.org/pdf/2405.13773)
- [Wong, *A dual ascent approach for Steiner tree problems on a directed graph*, Math. Prog. 28 (1984)](https://link.springer.com/article/10.1007/BF02612335)
- [Balakrishnan, Magnanti & Wong, *A dual-ascent procedure for large-scale uncapacitated network design*, Oper. Res. 37 (1989)](https://pubsonline.informs.org/doi/10.1287/opre.37.5.716) · [MIT DSpace](https://dspace.mit.edu/handle/1721.1/5072)
- [Magnanti & Wong, *Network design and transportation planning: models and algorithms*, Transp. Sci. 18 (1984)](https://pubsonline.informs.org/doi/10.1287/trsc.18.1.1)
- [Balakrishnan, Magnanti & Mirchandani, *A dual-based algorithm for multi-level network design*, Mgmt. Sci. 40 (1994)](https://sites.pitt.edu/~pmirchan/)
- [Bley, Ljubić & Maurer, *Lagrangian decompositions for the two-level FTTx network design problem*, EJCO 1 (2013)](https://link.springer.com/article/10.1007/s13675-013-0014-z)
- [Gollowitzer & Ljubić, *MIP models for connected facility location*, C&OR 38 (2011)](https://www.sciencedirect.com/science/article/pii/S0305054810001334)
- [Goemans & Williamson, *A general approximation technique for constrained forest problems*, SICOMP 24 (1995)](https://math.mit.edu/~goemans/PAPERS/GoemansWilliamson-1995-AGeneralApproximationTechniqueForConstrainedForestProblems.pdf)
- [Swamy & Kumar, *Primal-dual algorithms for connected facility location*, Algorithmica 40 (2004)](https://www.math.uwaterloo.ca/~cswamy/papers/confl-journal.pdf) · [Eisenbrand, Grandoni, Rothvoß & Schäfer, *Connected facility location via random facility sampling and core detouring*, JCSS 76 (2010)](https://www.sciencedirect.com/science/article/pii/S0022000010000152)
- [Robins & Zelikovsky, *Tighter bounds for graph Steiner tree approximation*, SIDMA 19 (2005)](https://www.cs.virginia.edu/~robins/papers/Robins_Graph_Steiner_Approximation.pdf) · [Byrka, Grandoni, Rothvoß & Sanità, *Steiner tree approximation via iterative randomized rounding*, JACM (2013)](https://people.idsia.ch/~grandoni/Pubblicazioni/BGRS12jacm.pdf)
- [Mehlhorn, *A faster approximation algorithm for the Steiner problem in graphs*, IPL 27 (1988)](https://link.springer.com/article/10.1007/BF00289500) · [Takahashi & Matsuyama (1980)](https://cir.nii.ac.jp/crid/1570009750462176256)
- [Uchoa & Werneck, *Fast local search for Steiner trees in graphs*, ALENEX 2010 / ACM JEA 17](https://dl.acm.org/doi/abs/10.1145/2133803.2184448) · [PDF](https://www.researchgate.net/profile/Eduardo-Uchoa/publication/220982029_Fast_Local_Search_for_Steiner_Trees_in_Graphs)
- [Gamrath, Koch, Maher, Rehfeldt & Shinano, *SCIP-Jack — a solver for STP and variants*, MPC 9 (2017)](https://link.springer.com/article/10.1007/s12532-016-0114-x) · [DIMACS11 slides](https://dimacs11.zib.de/workshop/GamrathKochMaherRehfeldtShinano.pdf)
- [Beyer & Chimani, *Strong Steiner tree approximations in practice*, ACM JEA 24 (2019)](https://dl.acm.org/doi/fullHtml/10.1145/3299903)
- [Kim & Pardalos, *A solution approach to the fixed charge network flow problem using a dynamic slope scaling procedure*, ORL 24 (1999)](https://www.sciencedirect.com/science/article/abs/pii/S0167637799000048)
- [Esau & Williams, *On teleprocessing system design, Part II*, IBM Systems Journal 5(3) (1966)](https://ieeexplore.ieee.org/document/5388449/) · [CMST overview](https://en.wikipedia.org/wiki/Capacitated_minimum_spanning_tree)
- [Garg, Konjevod & Ravi, *A polylogarithmic approximation algorithm for the group Steiner tree problem*, J. Algorithms 37 (2000)](https://www.sciencedirect.com/science/article/abs/pii/S0196677400910964)
- [Guha, Meyerson & Munagala, single-sink buy-at-bulk / access network design (STOC 2001)](https://www.researchgate.net/publication/220779190_Buy-at-Bulk_Network_Design_Approximating_the_Single-Sink_Edge_Installation_Problem)
- [Gendron, Crainic & Frangioni, *Multicommodity capacitated network design* (1999)](https://link.springer.com/chapter/10.1007/978-1-4615-5087-7_1)


---

## 4. CP-SAT modelling patterns and hybrid matheuristics

### 4.0 The cost decomposition this section is aiming at

Everything below is priced against the district BOM in `tests/golden_parcels_report.txt`, because "trench dominates" is too coarse to rank techniques. In cents:

| bucket | cents | % of score (973,816,190) | who decides it |
|---|---:|---:|---|
| trench (118,117 m soft @ 4500 + 4,928 m asphalt @ 15000) | 605,446,500 | 62.2% | Steiner tree **and** the required-node set |
| drop assemblies (6,719 × 12000) | 80,628,000 | 8.3% | fixed — not addressable |
| street-crossing penalty (2,238 × 50000) | 111,900,000 | 11.5% | terminal packing |
| under-4 terminals (511 × 100000) | 51,100,000 | 5.2% | terminal packing |
| distribution + feeder cable | 51,996,140 | 5.3% | tree + sizing |
| drop cable (193,937 m @ 150) | 29,090,550 | 3.0% | terminal packing |
| terminal hardware (492×2p, 822×4p, 366×6p, 68×8p, 5×12p) | 20,639,000 | 2.1% | terminal packing |
| drop-drop crossings (684 × 20000) | 13,680,000 | 1.4% | terminal packing |
| FDH + splitters + OLT + optics | 9,336,000 | 1.0% | ~exhausted (99.2/99.6/100% util) |

Two numbers drive the rest of the section. **Terminal packing owns 226,409,550 cents — 23.3% of the score** — and it is the subproblem whose solution representation the project has already changed three times, which is exactly the signature of a subproblem that wants a declarative model rather than another greedy. **Trench averages 4,920 cents/m**, so 1% of trench = 6.05M cents = 0.62% of score; the trench prize is real but a *tree-quality* technique can only reach a few percent of it, whereas *which nodes are required* moved it 29% at iter 004 (190,299 m → 134,276 m when the required set went from ~3,000 snap nodes to ~1,700 terminal nodes). That coupling — packing decides the Steiner terminals — is the single most important structural fact for this section, and no CP-SAT model that prices packing without a trench term will capture it.

One more measured fact does a lot of work below: `terminal_ports: 6719/7072 = 95.0%` — the design sits *exactly* on the utilization floor, and it gets there via a **forced, unpriced repair pass**. The backlog records the cost: the pure greedy simulation reached ~1,550 crossings and the shipped engine lands at 2,238, i.e. the floor repair is buying roughly 688 crossings ≈ **34.4M cents**. In a declarative model the floor is one knapsack row (`Σ installed_ports ≤ ⌊671900/95⌋ = 7072`) that the optimizer trades against crossings globally instead of a repair pass spending the budget after the fact. That is the cleanest single argument for putting packing in a solver.

---

### 4.1 Why CP-SAT, specifically, for netwerk's subproblems

CP-SAT is a *lazy clause generation* (LCG) solver: finite-domain propagators are compiled into clauses on demand and handed to a CDCL SAT engine, so every propagation is explained and every conflict produces a learned nogood (Ohrimenko, Stuckey & Codish, "Propagation via lazy clause generation", *Constraints* 14:357–391, 2009; Stuckey, "Lazy Clause Generation: Combining the power of SAT and CP (and MIP?) solving", CPAIOR 2010). Google's variant adds a simplex alongside the SAT engine — Perron, Didier & Gay, "The CP-SAT-LP Solver" (invited talk, CP 2023, LIPIcs vol. 280) — so it also has MIP machinery (cuts, reduced-cost fixing, dual reductions) but does not *depend* on the LP to make progress.

Five properties matter for netwerk in particular:

1. **Integrality is native, and so is the objective.** CP-SAT is a purely integral solver; its objective is an `int64` linear expression over integer variables. netwerk's scorer is already `int64` cents. That means the solver's optimum *is* the scorer's optimum, bit for bit — no float tolerance, no "optimal solution that violates a constraint by 1e-9", no rounding step between solver and BOM. Against a byte-deterministic golden gate this is a categorical advantage over any LP-based backend (HiGHS returns doubles and its feasibility/optimality are tolerance-based). This alone is a reason to prefer CP-SAT over HiGHS for netwerk's *combinatorial* stages, and to keep HiGHS for the places where you actually want an LP bound (§4.5).

2. **Feasibility does not go through an LP relaxation.** The binding constraints in terminal packing are `AddExactlyOne` per premises, 150 m reach, and pairwise geometric conflicts. The LP relaxation of a large family of `AtMostOne`/conflict constraints is notoriously weak (the all-½ point is feasible for any odd hole), so a branch-and-bound MILP burns its budget branching on fractions that carry no information. LCG resolves those by clause learning on the conflict graph directly. This is the classic CP-vs-MIP boundary and netwerk's packing sits squarely on the CP side.

3. **Step functions are first-class.** Terminal cost as a function of occupancy is `{0→0, 1..2→8000, 3..4→12000, 5..6→15000, 7..8→18000, 9..12→25000}` plus a 100000 cliff below 4. In MILP that's five indicator binaries plus linking rows per terminal with a weak relaxation. In CP-SAT it is one `add_allowed_assignments([occ_t, ports_t, cost_t], TABLE)` table constraint that propagates the step function in both directions and learns clauses over it. Same for the splitter bank and the FDH catalog.

4. **Presolve and automatic symmetry detection.** CP-SAT's presolve iterates probing, equivalence detection, bounded-variable elimination and dual reductions to fixpoint, and `symmetry_level` (levels 1–4) attempts automatic symmetry detection and exploitation. For a model with 1,753 near-identical objects this is not a nicety (§4.3).

5. **A free primal portfolio.** The default 16-worker portfolio is 11 full subsolvers (`core`, `default_lp`, `max_lp`, `no_lp`, `quick_restart`, `probing`, `pseudo_costs`, `reduced_costs`, `lb_tree_search`, `objective_lb_search`, `quick_restart_no_lp`), 4 first-solution subsolvers, and **9 incomplete subsolvers that are LNS**: `rnd_var_lns`, `rnd_cst_lns`, `graph_var_lns`, `graph_arc_lns`, `graph_cst_lns`, `graph_dec_lns`, `rins/rens`, `feasibility_pump`, `violation_ls`. netwerk cares about the *primal* (there is no bound in the ledger and no gap requirement), so a solver whose default configuration spends more than half its threads on primal LNS is well matched.

**Where CP-SAT is the wrong tool, and this is decisive for one technique below: CP-SAT has no lazy-constraint callback.** Solution callbacks can observe and stop, but cannot add constraints, and the solver is stateless across `Solve()` calls — re-solving means re-presolving from scratch. Any formulation whose only strong relaxation needs cut separation (directed Steiner cuts) is therefore hostile to CP-SAT and belongs to HiGHS/SCIP. §4.4 makes that case explicitly.

**Determinism.** `sat_parameters.proto` documents `interleave_search`: *"If this is true, then we interleave all our major search strategy and distribute the work amongst num_workers. The search is deterministic (independently of num_workers!)"*, implemented by splitting the solve into `interleave_batch_size` chunks that are synchronised between batches. Paired with `max_deterministic_time` (*"Maximum time allowed in deterministic time... correlated with the real time used by the solver"*) instead of `max_time_in_seconds`, and a fixed `random_seed`, a CP-SAT solve is reproducible across machines and core counts. Three caveats that a byte-golden CI gate must respect:
- Determinism holds **for a fixed OR-Tools version**. Presolve and portfolio changes across releases will move the answer.
- Model *construction* must be deterministic too (no hash-map iteration); CP-SAT prints a model fingerprint in `log_search_progress` output — assert it in CI.
- Therefore the safe integration is the one the backlog already proposes as **P3 item 9**: run CP-SAT as an **offline oracle that emits an overrides file** (fixed terminal nodes, forced memberships, forbidden edges), and let the Carbon engine consume the overrides deterministically and *re-price them with its own scorer*. The golden gate then covers Carbon only; a solver regression can change the overrides file (a reviewed diff) but can never silently change the golden report. This is a stronger determinism story than embedding the solver in the pipeline, and it costs nothing.

**Tier verdict for §4.1 as a whole:** all of it is Tier 2. The Tier-1 carry-over is the *discipline*: every technique below is stated so that its Tier-1 shadow (a hand-rolled integer search over the same neighbourhood, accepted only on true scorer improvement) is implementable now.

---

### 4.2 Technique T1 — terminal packing as a restricted set-partitioning model with geometric side constraints

**What it is.** Replace the node-centric greedy's *move* pricing with a *column* formulation and solve it exactly (or near-exactly) over a restricted column pool.

Sets: premises $P$ ($|P|=6{,}719$), graph nodes $N$ ($|N|=15{,}668$), catalog sizes $K=\{2,4,6,8,12\}$.

A **column** $j$ is a triple $(n_j, S_j, k_j)$: a candidate terminal node $n_j$, the set $S_j \subseteq P$ of premises it serves (all within 150 m straight-line of $n_j$), and $k_j = \min\{k\in K : k \ge |S_j|\}$. Its cost, in cents, is *exactly* the scorer's contribution:

$$c_j \;=\; \underbrace{\text{TerminalCost}(k_j)}_{\text{8000..25000}} \;+\; 50000\!\!\sum_{p\in S_j}\!\!\chi_{\text{street}}(p,n_j) \;+\; 20000\,\big|\{(p,q)\subseteq S_j : \text{drops properly cross}\}\big| \;+\; 150\!\!\sum_{p\in S_j}\!\! \ell(p,n_j) \;+\; 100000\,[\,|S_j|<4\,] \;+\; \lambda\,\tau(n_j)$$

where $\chi_{\text{street}}$ is netwerk's existing exact integer `CountDropCrossings` predicate, $\ell$ is the integer drop length, and $\tau(n_j)$ is the **marginal trench** term discussed below.

Decision variables: $z_j \in \{0,1\}$, "column $j$ is opened".

$$\min \sum_j c_j z_j \;+\; 20000\sum_{(j,j')\in X} w_{jj'}$$
$$\text{s.t.}\quad \sum_{j\,:\,p\in S_j} z_j = 1 \qquad \forall p \in P \qquad\qquad \text{(AddExactlyOne — 6,719 rows)}$$
$$\sum_j k_j\, z_j \;\le\; \Big\lfloor \tfrac{100\cdot 6719}{95}\Big\rfloor = 7072 \qquad\qquad \text{(the 95\% utilization floor, one knapsack row)}$$
$$w_{jj'} \ge z_j + z_{j'} - 1 \qquad \forall (j,j') \in X \qquad\qquad \text{(inter-column drop-drop crossings)}$$

In CP-SAT Python (the C++ API is identical in shape and is what the interop shim should call):

```python
m = cp_model.CpModel()
z = [m.new_bool_var(f"z{j}") for j in range(J)]
for p in range(P):                       # exactly-one cover
    m.add_exactly_one([z[j] for j in cols_of[p]])
m.add(sum(k[j] * z[j] for j in range(J)) <= 7072)      # utilization floor
for (j, jp) in conflict_pairs:           # option A: forbid outright
    m.add_bool_or([z[j].negated(), z[jp].negated()])
    # option B: price it — w = m.new_bool_var(); m.add_bool_or([~z[j], ~z[jp], w])
m.minimize(sum(c[j] * z[j] for j in range(J)) + 20000 * sum(w))
for j in incumbent_columns:               # warm start from the shipped design
    m.add_hint(z[j], 1)
m.add(sum(c[j] * z[j] for j in range(J)) <= incumbent_cost - 1)   # objective bounding
```

**Column-pool generation** (this is the whole art). Do *not* enumerate all $\binom{|R(n)|}{k}$ subsets. For each node $n$ with $R(n) = \{p : \ell(p,n) \le 150\}$ non-empty:
- order $R(n)$ by $(\chi_{\text{street}}(p,n), \ell(p,n), \text{id}(p))$ and emit the prefixes of length $1..12$ (12 columns) — this reproduces exactly the greedy's move set, so **the incumbent is guaranteed to be in the pool** and the hint is always completable;
- emit the *zero-crossing-only* prefix (take only $\{p : \chi=0\}$), which the greedy can only reach by accident;
- emit prefixes under 2–3 perturbed orders (e.g. order by $\ell$ alone; order by "crossings, then *descending* $\ell$") for diversity.

That is ~30–45 columns per live node. With ~8,000 live nodes district-wide the pool is **250k–350k columns for 6,719 rows** — a set-partitioning instance well inside the size Caprara, Fischetti & Toth solved routinely (5,000 rows × 1,000,000 columns; *Operations Research* 47(5):730–743, 1999).

**Why this fits netwerk specifically.**
- *It is the fix for the representation problem the project already diagnosed twice.* The DFS-order DP failed because batches had to be consecutive runs of a linear order; the node-centric greedy fixed the representation but priced moves *marginally*. Set partitioning is the representation with no order at all and *global* pricing — it is the natural terminus of that sequence, and the backlog says so ("a possible future upgrade: replace the greedy's marginal per-move pricing with a proper set-cover LP-rounding or swap-based local search", item 8).
- *The geometric side constraints are already computed.* `ProperCross` (exact `i64` orientation predicate) and the 128 m `BuildEdgeGrid` in `graph.carbon` give both $\chi_{\text{street}}$ and the drop-drop conflict set. In a solver these become table lookups and clause sets — no approximation anywhere.
- *The utilization floor becomes a constraint instead of a repair.* This is worth ~34M cents on its own by the ledger's own arithmetic (§4.0).
- *There is no bin symmetry.* See §4.3 — this formulation is symmetry-free by construction, which is why it is preferred over the obvious $x[p][t]$ assignment model.

**The marginal-trench term $\tau(n_j)$ — do not omit it.** Packing runs *before* routing, so today the packer is blind to the fact that opening a terminal at node $n$ obliges the Steiner tree to reach $n$. iter 004's 29% trench drop when the required set shrank is direct evidence this term dominates tree-algorithm quality. Two-pass fix: build one provisional Steiner tree over the snap nodes (the machinery already exists), then set $\tau(n) = $ trench cents to attach $n$ to that provisional tree, and $\lambda \approx 1$ discounted by the measured sharing ratio (1.20). This converts the model from "cheapest terminals" to a **node-weighted / prize-collecting Steiner-flavoured** objective, which is the objective netwerk actually has.

**Expected gain.** The addressable pot is 226.4M cents. Bounds from the repo's own evidence: crossings cannot go to zero (only ~3,027 of 6,719 premises fit in all-zero-crossing groups of 4..12), but the unrepaired greedy reached ~1,550 and the shipped design is at 2,238. A model that (a) hits ~1,600–1,700 crossings *while respecting* the 7072-port budget, and (b) cuts under-4 from 511 toward ~350 by trading port budget globally, yields $(2238{-}1650)\times 50000 + (511{-}350)\times 100000 \approx 29.4\text{M} + 16.1\text{M} = 45.5\text{M}$, plus ~4M on drop-drop. With $\tau$ included, a further 1–3% of trench ($6$–$18$M). **Estimate 35–70M cents (3.6–7.2% of score), centre ~50M.** Honest caveat: the pool restriction caps the gain — if the true optimum needs a column no prefix rule generates, the model cannot find it. Mitigate by measuring the LP bound of the restricted master (CP-SAT's `best_objective_bound`) against the incumbent; a gap under 2% means the pool, not the search, is the limit.

**Complexity / runtime.** Per serving area: ~420 premises, ~980 nodes, ~10–15k columns, ~5–20k conflict pairs. CP-SAT presolves such a model in well under a second and closes it or gets to <1% gap in 5–60 s on 8 workers; budget `max_deterministic_time = 20` per area, 16 areas → **1–3 minutes wall-clock with areas solved in parallel**, versus 11 s today. Global (all 6,719 rows at once, ~300k columns): expect a few minutes to a 1–3% gap; solve per-area first, then run one global pass to let terminals steal premises across serving-area boundaries (which the current engine cannot do at all — backlog item 2 names "cross-cluster dissolve targets" as blocked on per-cluster fiber bookkeeping).

**Tier 2 — implementation sketch.** The interop surface is deliberately one flat C ABI entry point, all `int32`/`int64` arrays, nothing from the STL crossing the boundary:

```c
// solve_setpart.h — the ONLY symbol Carbon needs to see.
int32_t nw_solve_setpart(
    int32_t n_prem, int32_t n_cols,
    const int32_t* col_off,      // n_cols+1 prefix offsets into col_prem
    const int32_t* col_prem,     // flattened member premises ids
    const int64_t* col_cost,     // cents, exactly the Carbon scorer's price
    const int32_t* col_ports,    // catalog port count k_j
    int64_t        port_budget,  // 7072
    int32_t n_conf, const int32_t* conf_a, const int32_t* conf_b,
    int64_t conf_cost,           // 20000
    int32_t n_hint, const int32_t* hint_cols,
    int64_t det_time_milli,      // -> max_deterministic_time
    int32_t random_seed,
    int32_t* out_cols);          // selected column ids; returns count, <0 on failure
```
Inside: build `CpModelProto`, set `interleave_search=true`, `num_workers=8`, `max_deterministic_time`, `random_seed`, `symmetry_level=2`, `log_search_progress=false`. Carbon calls it, then **re-prices the returned selection with its own scorer and rejects it if worse than the incumbent** — the solver is advisory, never authoritative.

**Tier 1 — what to build now, in Carbon, without a solver.** Three pieces, each independently valuable and each a strict improvement on the shipped greedy:
1. **Port budget as a live constraint (highest value/effort ratio in this whole section).** Track `installed_ports` during `PackTerminals`; the budget is $\lfloor 100\cdot\text{units}/95\rfloor$. Reject any move that would overshoot, and price the *shadow* of the budget into every move (a move that spends $\Delta$ ports costs $\Delta \times$ the current marginal port price, estimated as the cheapest available under-4 dissolve). This turns the post-hoc forced repair into an in-loop constraint. ~80 lines. **Estimated 10–30M cents.**
2. **Marginal-trench term in the move price.** Provisional Steiner tree pass, then add $\lambda\,\tau(n)$ to every new-batch move. ~120 lines (the Dijkstra and tree machinery exist). **Estimated 8–25M cents.**
3. **Lagrangian set covering (CFT) over the column pool, in pure integer Carbon.** The pool generator is ~100 lines; the CFT loop (subgradient on integer multipliers $u_p$ scaled by 1024, greedy on reduced costs $\bar c_j = c_j - \sum_{p\in S_j} u_p$, column fixing) is ~250 lines and needs no floating point if step sizes are fixed-point. This gives netwerk something it has never had: **a lower bound on the packing subproblem**, which tells the campaign whether to keep spending iterations here. Caprara, Fischetti & Toth (1999) report optimal-or-best-known on 92 of 94 instances with this scheme. It is the Tier-1 stand-in for the CP-SAT solve and is ~60–80% as good.

---

### 4.3 Symmetry: why the column model, and what to do if you must use assignment variables

The naive model is $x[p][t] \in \{0,1\}$ for $p \in P$, $t \in \{1..T\}$ with $T \approx 2000$ anonymous terminal slots, plus $\text{open}_t$, $\text{node}_t$, $\text{size}_t$. Its symmetry group contains the full symmetric group over any set of slots that end up at the same node with the same size — with 492 2-port and 822 4-port terminals in the shipped design, that is a group of order $\gg 492!\cdot 822!$. Branch-and-bound must re-derive the same optimum once per group element before it can prove anything (Margot, "Symmetry in Integer Linear Programming", in *50 Years of Integer Programming 1958–2008*, Springer 2010). CP-SAT's `symmetry_level ≥ 2` will detect *some* of this automatically, but detection on a model with $6719 \times 2000 = 13.4$M booleans is itself expensive and the model should never have been built that way.

**The column formulation of §4.2 has no such symmetry**: columns are distinguished by their contents, so no two selected columns are interchangeable. This is the standard reason set-partitioning ("Dantzig–Wolfe") formulations beat compact assignment formulations on packing problems, and it is worth stating as a rule for netwerk: *index by content, never by anonymous slot.*

If a compact model is unavoidable (e.g. for the FDH/serving-area problem, where "columns" are 432-premises subsets and cannot be enumerated), the two workable devices are:
- **Index terminals by candidate node, not by slot.** There is then exactly one terminal object per node and the symmetry vanishes by construction. Only nodes needing *two* terminals (>12 premises within 150 m) break this, and those are rare — handle them with replica index $r \in \{0,1\}$ plus an ordering constraint.
- **Orbitope / lexicographic ordering on replicas.** For replicas at one node, force the lowest-indexed member to increase: $\min\{p : x[p][t,0]\} < \min\{p : x[p][t,1]\}$, encoded as the linear surrogate $\sum_p p\,x[p][t,0] \le \sum_p p\,x[p][t,1]$, or exactly via the partitioning-orbitope facets of Kaibel & Pfetsch, "Packing and partitioning orbitopes", *Mathematical Programming* 114:1–36, 2008. For the 2-replica case the linear surrogate is enough and costs one row.

**Tier 1 relevance.** Symmetry is not just a solver concern — it is why the greedy's tie-breaks are load-bearing. `MoveBetter`'s deterministic tie-break chain (prefer new-batch, then lower node index, then larger batch) is a hand-rolled symmetry-breaking rule, and it is *arbitrary*. §4.5's agreement-fixing exploits exactly this: run the greedy under several different (but each deterministic) tie-break orders and treat disagreement as a signal of where the symmetry is hiding real choice.

**Tier 2.** Set `symmetry_level=2` and measure; on the column model expect it to find nothing (correct), on any compact model expect it to matter a lot.

---

### 4.4 Routing in CP-SAT: `AddCircuit`, Steiner arborescence — and an honest negative result

**The encodings.** CP-SAT's routing primitives are `add_circuit(arcs)` where `arcs` is a list of `(u, v, literal)` triples and the true literals must form a single Hamiltonian circuit *modulo* nodes with a true self-loop (so self-loops make nodes optional — the standard trick for prize-collecting / optional-visit models), and `add_multiple_circuit(arcs)`, the VRP constraint, which permits the depot (node 0) to be visited many times: in-degree = out-degree = 1 for all non-depot nodes, in-degree = out-degree at node 0, no cycle except through node 0. Both are implemented as propagators that do subtour elimination *internally* — you never write a subtour constraint yourself.

Neither is a tree constraint. A Steiner **arborescence** rooted at the CO must be encoded by hand. The two standard options (Goemans & Myung, "A catalog of Steiner tree formulations", *Networks* 23(1):19–28, 1993):

*Single-commodity flow* — the only one CP-SAT can carry, because it needs no separation:
$$x_a \in \{0,1\},\; f_a \in [0, D] \subset \mathbb{Z} \quad \forall a \in A \;(|A| = 2|E| = 47{,}648)$$
$$\sum_{a \in \delta^-(v)} f_a - \sum_{a \in \delta^+(v)} f_a = d_v \quad \forall v \ne r; \qquad \sum_{a\in\delta^+(r)} f_a = D = \sum_v d_v$$
$$f_a \le D\,x_a; \qquad \sum_{a\in\delta^-(v)} x_a = 1 \;\;\forall v \text{ required}, \;\; \le 1 \;\;\forall v \text{ Steiner}$$
$$\min \sum_a \text{trench\_cents}(a)\, x_a$$

*Directed cut* — $\sum_{a \in \delta^-(W)} x_a \ge 1$ for every $W$ separating a required node from the root. Exponentially many, separated by max-flow, and **strictly stronger** than single-commodity flow (Goemans & Myung; Wong's 1984 dual-ascent method for the directed Steiner problem builds on exactly this relaxation).

**The negative result: do not put the global tree in CP-SAT.** The strong formulation needs lazy cut separation and CP-SAT has *no lazy-constraint callback at all* and is stateless across solves — the workaround is an outer solve-separate-resolve loop that re-presolves a 47,648-arc model every round. The formulation CP-SAT *can* take (single-commodity flow with big-M $= 6{,}719$) has the weakest relaxation of the family. Meanwhile the state of the art already exists and is not CP-SAT: SCIP-Jack (Gamrath, Koch, Maher, Rehfeldt & Shinano, *Mathematical Programming Computation* 9:231–296, 2017; "SCIP-Jack: An Exact High Performance Solver for Steiner Tree Problems in Graphs and Related Problems", 2021) wins DIMACS-Challenge categories, and its *reductions* alone — degree tests, bottleneck Steiner distance, NTDk, dual-ascent reduced-cost fixing — routinely shrink instances of this size by an order of magnitude (Rehfeldt, Koch & Maher, *Networks* 73(2):206–233, 2019, solving >90% of a benchmark set by reduction alone). Ljubić's survey ("Solving Steiner trees: recent advances, challenges, and perspectives", *Networks* 77:177–204, 2021) is the map. **Predicted outcome of a global CP-SAT Steiner model at 15,668 nodes / 23,824 edges: no solution better than the shipped SPH within any sane deterministic budget, and 20+ engineer-days spent. Do not build it.**

**What *is* worth building: window-exact Steiner re-solve.** Freeze the global tree outside a window; inside a window of $\le 400$ edges with $\le 30$ required nodes and 2–4 frozen boundary attachment points, the single-commodity model has ~800 arc booleans and ~800 flow integers and CP-SAT closes it in well under a second. Iterate windows in a fixed, deterministic order (window centres by ascending node id) to fixpoint. This is the solver realisation of the backlog's item 6c (key-path improvement, "typically shaves another 1–3% trench").

**Where `AddCircuit` genuinely helps.** Not for the tree, but for two smaller things: (i) **splice/closure ordering along a corridor** if netwerk ever models per-closure labour as sequence-dependent; (ii) **aerial span / pole-route sub-tours** in a later milestone. For netwerk as it stands today, `AddCircuit`/`AddMultipleCircuit` have no application — say so and move on rather than forcing a routing constraint onto a tree problem.

**Interval / `no_overlap_2d` for spatial exclusion — a caution.** `add_no_overlap_2d(x_intervals, y_intervals)` enforces non-overlap of *axis-aligned rectangles*. netwerk's drop-drop exclusion is non-crossing of arbitrary *line segments*, which is not a rectangle problem; a bounding-box relaxation would forbid many legal pairs and permit none it should. **Use the precomputed exact pairwise conflict set, not intervals.** This matters: netwerk already has the exact predicate, and it would be a real regression to replace an exact integer test with a geometric relaxation for the sake of using a named constraint. (Intervals *are* the right tool if a later milestone models duct-bore occupancy along a corridor — a genuine 1-D packing.)

**Expected gain.** Window-exact Steiner: 1–2.5% of 605.4M = **6–15M cents**, at high implementation cost. Global CP-SAT Steiner: **≈0, likely negative**.

**Tier 1 for both.** The window re-solve has a good Carbon shadow: **key-path improvement** — for each path between two branch/required nodes in the tree, delete it, compute the true cheapest reconnection of the two components with the existing multi-source Dijkstra, keep if cheaper; run to fixpoint with a deterministic path order. That is ~200 lines and captures most of the same 1–3%, which is why the CP-SAT version ranks low on value-per-effort.

---

### 4.5 Matheuristics needing only small solves: fix-and-optimize, local branching, proximity search, RINS/RENS

These all presuppose a strong incumbent and a model. netwerk has an exceptionally strong incumbent (seven priced iterations, −67%), which is precisely the regime where these techniques shine and where cold exact solving does not.

**(a) Local branching** (Fischetti & Lodi, "Local branching", *Mathematical Programming* 98:23–47, 2003). Given incumbent $\bar z$, add
$$\Delta(z,\bar z) \;=\; \sum_{j:\bar z_j = 1}(1 - z_j) \;+\; \sum_{j: \bar z_j = 0} z_j \;\le\; k$$
and solve. For netwerk's set-partitioning model the *asymmetric* form is the right one: $|\{j : \bar z_j = 1\}| \approx 1{,}753$ while the pool has ~300k columns, so the 0→1 term is meaningless; use the one-sided constraint $\sum_{j:\bar z_j=1}(1-z_j) \le \lfloor k/2 \rfloor$ with $k/2 \in [10, 40]$. This turns the whole district model into a neighbourhood CP-SAT closes in seconds, and it composes with a diversification schedule (relax $k$ on failure, tighten on success) exactly as the original paper prescribes. **Why it fits:** netwerk's objective is a sum of ~1,753 small independent-ish terms; a $k$-column exchange neighbourhood is enormous ($\binom{1753}{20}$) but the *model* prunes it. **Gain: +5–15M over the plain §4.2 solve, at ~2 days once §4.2 exists** — the best marginal ratio in the section.

**(b) Proximity search** (Fischetti & Monaci, "Proximity search for 0-1 mixed-integer convex programming", *Journal of Heuristics* 20(6):709–731, 2014). Instead of constraining the neighbourhood, *replace the objective* with the Hamming distance to $\bar z$ and add a cutoff row:
$$\min \Delta(z,\bar z) \quad \text{s.t.} \quad \sum_j c_j z_j \le \sum_j c_j \bar z_j - \theta$$
with $\theta$ a small improvement quantum. **Why it fits netwerk specifically:** the packing objective is a sum of thousands of similar small terms, which is exactly the "flat objective, weak LP guidance" regime the paper targets; the Hamming objective has a trivial relaxation and drives the search toward *any* solution $\theta$ cheaper, which is all netwerk needs (it never needs a proof of optimality). Set $\theta \approx 2{,}000{,}000$ cents (~1% of the addressable pot) per round and iterate. **Cost: a two-line objective swap on top of §4.2. Try it; it is nearly free.**

**(c) RINS** (Danna, Rothberg & Le Pape, "Exploring relaxation induced neighborhoods to improve MIP solutions", *Mathematical Programming* 102:71–90, 2005): fix every variable where the incumbent and the LP relaxation *agree*, solve the residual as a sub-MIP. **RENS** (Berthold, "RENS — the optimal rounding", *Mathematical Programming Computation* 6:33–54, 2014): restrict every integer variable to $\{\lfloor x^{LP}\rfloor, \lceil x^{LP}\rceil\}$ and solve. CP-SAT ships a `rins/rens` worker, so you get both free the moment you hand it the model — no work to do beyond not disabling it.

*RENS applied to netwerk's sizing stages is a waste of time and I want that on the record*: splitter ports are at 99.6%, FDH capacity 99.2%, OLT card ports 100.0%, and the cable-sizing stage is a smallest-covering-catalog rule on a fixed tree. The whole sizing family is 9.3M cents with maybe 0.5M of slack. **Do not build a sizing MIP.**

**(d) Fix-and-optimize** (Helber & Sahling, "A fix-and-optimize approach for the multi-level capacitated lot sizing problem", *IJPE* 123(2):247–256, 2010): iterate over a partition of the binary variables; in round $i$ fix everything outside block $i$ and re-solve exactly; sweep to fixpoint. This is netwerk's natural decomposition operator — 16 serving areas, ~420 premises each.

**The critical caveat, and it is netwerk-specific.** iter 005 established that choosing corridors *globally* beat post-hoc dedup of independently routed clusters by ~8% of trench. So **a fix-and-optimize whose blocks are serving areas destroys exactly the property that iteration bought**, unless the block interface is defined correctly. The contract:

> **Boundary-interface rule.** A block is a *geographic window*, not a serving area. Freeze (i) the set of trench edges crossing the window boundary, and (ii) the **fiber count on each such edge**. Everything strictly inside is free. On accept, re-price the boundary edges with the Carbon scorer before comparing.

Freezing edge *presence* alone is not enough: the cable catalog is concave (12f @ \$0.95/m up to 288f @ \$7.80/m), so an interior change that removes fiber from a boundary edge may step it down a catalog size — a real gain the block cannot see, and a real *loss* if it steps one up. Carrying the fiber count in the interface makes the window's contribution to the objective separable given the interface, which is what makes "improve inside ⇒ improve globally" a theorem rather than a hope. This is the formal version of the project's own hard-won rule that unpriced repair passes spend the budget the optimizer saved.

**Gain: 10–25M cents.** Complexity: 20–40 windows of 250–500 m, each a §4.2 solve plus a §4.4 window Steiner solve, ~1 s each deterministic → a few minutes per sweep, 3–5 sweeps to fixpoint.

**Tier 1 shadows for all four.**
- *Local branching* → **$k$-terminal destroy-and-repair**: pick $k \in [8,30]$ terminals by a deterministic rule (worst scorer-priced first, then round-robin by node id), free their premises, re-run the node-centric greedy on just those premises, accept only on true scorer improvement. ~150 lines. This is real local branching with the greedy as the (inexact) sub-solver.
- *Proximity search* → no clean shadow; it needs a solver. Skip in Tier 1.
- *RINS* → **agreement fixing, the LP-free RINS.** This is the strongest Tier-1 idea in this section and deserves its own statement: RINS's insight is that agreement between two *different* views of the problem marks variables that are safe to fix. netwerk has no LP, but it has an arbitrary tie-break chain. Run `PackTerminals` under $D = 4$–$8$ deterministic tie-break orders (each a fixed permutation of the candidate-node scan seeded by a compile-time constant — still byte-deterministic, since the seeds are constants). Premises whose terminal *node* is identical in all $D$ runs are fixed; the disagreeing 10–25% are freed and re-packed by an exhaustive/DP search over the small residual. Cost: $D\times$ the packing stage (packing is a fraction of the 11 s) plus a residual solve. **Estimated 8–25M cents for ~3 days.** It also produces a free diagnostic: the disagreement fraction is a direct measure of how much choice the packing problem actually has left, which tells the campaign whether §4.2 is worth building.
- *Fix-and-optimize* → the window sweep with the greedy as repair; the boundary-interface rule applies unchanged and is the part that must be got right regardless of tier.

---

### 4.6 LNS: CP-SAT's built-in workers vs. a hand-rolled destroy-and-repair

CP-SAT's LNS workers (`rnd_var_lns`, `rnd_cst_lns`, `graph_var_lns`, `graph_arc_lns`, `graph_cst_lns`, `graph_dec_lns`) build neighbourhoods from the **model's variable-constraint incidence graph** — they have no idea what a metre is. netwerk's structure is 2-D Euclidean and it already owns a 128 m spatial index (`BuildEdgeGrid`). A geographic-window destroy is therefore strictly better-informed than anything CP-SAT can generate on its own. The right split:

- **Let CP-SAT's built-in LNS run** on every sub-solve (it costs nothing, it is on by default with ≥2 workers, and `graph_cst_lns` on the exactly-one rows is actually a decent proxy for geography since columns at nearby nodes share premises rows).
- **Hand-roll the outer loop** — this is classic LNS in the Shaw sense (Shaw, "Using constraint programming and local search methods to solve vehicle routing problems", CP'98, LNCS 1520:417–431) and the ALNS adaptivity of Pisinger & Ropke ("Large neighborhood search", *Handbook of Metaheuristics*, 2010). Four neighbourhoods, ranked by fit:

| neighbourhood | destroy | size | attacks | why it fits |
|---|---|---|---|---|
| **geographic window** | all terminals whose node lies in a 250 m disc | ~150–250 premises, ~35–60 terminals | street-x, drop-x, under-4 | the lattice is local; crossings are a local property of 2–4 lots at a corner |
| **one serving area re-pack** | all terminals in area $i$, under a *pro-rata port budget* $\lfloor 100 u_i / 95\rfloor$ | 432 premises, ~110 terminals | under-4 + the floor | the only way to trade the floor within an area instead of by forced repair |
| **trench corridor window** | free all trench edges in a window; boundary edges + fiber counts frozen | ~400 edges | trench | §4.4/§4.5(d) |
| **worst-$k$ terminals** | the $k$ terminals with worst cost-per-premises | $k \approx 20$ | under-4 strays | this is local branching (§4.5a) |

- **Acceptance is the exact scorer, always.** Not a proxy, not a delta estimate. This is the project's own scar tissue ("any repair pass that moves things without pricing the true objective silently spends the budget the optimizer saved") turned into an invariant.
- **Adaptivity must stay deterministic.** ALNS weight updates are fine — they are a deterministic function of the accept/reject history — but the neighbourhood *sequence* must be a fixed schedule (window centres in ascending node id, cycling), not a PRNG draw, unless the PRNG is a seeded integer LCG with a compile-time seed.
- **Budget.** Runtime is 11 s today against a stated NFR of minutes at 10k premises. A 200-window sweep at 0.5 deterministic-time-units each on 8 workers is ~2 minutes — comfortably inside budget and a 10× runtime increase the project can afford.

**Expected gain: 15–45M cents** for the Tier-1 (greedy-repair) version; **+10–25M** more with CP-SAT as the repair operator. **Tier 1: yes, fully** — the geographic-window destroy plus greedy repair plus exact-scorer acceptance is ~250 lines of Carbon and needs no solver. **Tier 2: swap the repair operator for the §4.2 solve behind the same interface.** Designing the outer loop so the repair operator is a function pointer (or, in Carbon-today terms, a compile-time-selected function) is the M3-readiness move.

---

### 4.7 Ranking

Effort is engineer-days for an experienced implementer. Δscore is against the 973,816,190 baseline. "Confidence" reflects how much of the estimate rests on measured repo evidence versus extrapolation from literature — extrapolations are marked.

| # | Technique | Tier | Stage / metric attacked | Est. Δscore (cents) | Effort (d) | Δ per day | Confidence |
|---|---|---|---|---:|---:|---:|---|
| 1 | **Port budget as an in-loop constraint** in `PackTerminals` (floor stops being a repair pass) | **1** | terminal packing → under-4, street-x | 10–30M | 2 | 5–15M | **High** — the 95.0%-exactly measurement and the ~1,550-vs-2,238 crossing gap are both in the repo |
| 2 | **Marginal-trench term $\tau(n)$ in the packing move/column price** (two-pass provisional tree) | **1** | packing → trench | 8–25M | 2–3 | 3–12M | Medium-high — extrapolated from iter 004's 29% trench drop when the required set changed |
| 3 | **Local branching / $k$-terminal destroy-repair** on the §4.2 model | 2 (T1 shadow: greedy repair) | packing → all packing metrics | 5–15M *marginal to #6* | 2 | 2.5–7.5M | Medium-high — Fischetti & Lodi 2003; needs #6 first |
| 4 | **Agreement fixing (LP-free RINS)**: $D$ tie-break orders, fix agreements, re-solve the residual | **1** | packing → all packing metrics | 8–25M | 3 | 3–8M | Medium — extrapolated from Danna et al. 2005; the disagreement fraction is unmeasured |
| 5 | **Geographic-window LNS**, exact-scorer acceptance, deterministic schedule | **1** (repair = greedy) / 2 (repair = CP-SAT) | packing + trench | 15–45M | 6 | 2.5–7.5M | Medium-high — Shaw 1998 / Pisinger & Ropke 2010 |
| 6 | **Set-partitioning terminal packing in CP-SAT** over a restricted column pool, floor as a knapsack row, exact crossing conflicts, `add_hint` from the incumbent | 2 (T1 shadow: CFT Lagrangian, ~60–80% of the gain, 5 d) | packing → 226.4M addressable | 35–70M | 10 | 3.5–7M | **High** — pot is measured; the split between crossings and under-4 is estimated |
| 7 | **Proximity search** on the §4.2 model (objective swap + cutoff row) | 2 | packing | 3–10M *marginal to #6* | 1 | 3–10M | Medium — Fischetti & Monaci 2014; cheap enough that the risk is negligible |
| 8 | **Capacitated subtree partition of the global tree** (serving areas as contiguous subtrees; FDH = subtree root) — exact tree DP $f[v][c]$, $O(n C^2)$ | **1** (DP is pure integer Carbon) / 2 (CP-SAT with contiguity) | clustering + FDH siting → trench, feeder, sharing ratio | 10–30M | 8 | 1.2–3.7M | Medium — extrapolated; sharing ratio 1.20 is the metric to watch |
| 9 | **Fix-and-optimize with the boundary-interface rule** (windows, frozen boundary edges *and fiber counts*) | 2 (T1 shadow: window sweep with greedy repair) | packing + trench jointly | 10–25M | 8 | 1.2–3M | Medium — Helber & Sahling 2010; the interface rule is the risk |
| 10 | **Window-exact Steiner in CP-SAT** (arc booleans + single-commodity flow, ≤400 edges) | 2 (T1 shadow: key-path improvement, 200 lines, most of the gain) | trench tree quality | 6–15M | 10 | 0.6–1.5M | Medium — backlog item 6c estimates 1–3%; build the Tier-1 shadow instead |
| 11 | **Compact $x[p][t]$ assignment model with orbitope symmetry breaking** | 2 | packing | ≤ #6, strictly | 12 | <1M | Low value — listed only to be explicitly rejected in favour of #6 |
| 12 | **Global Steiner arborescence in CP-SAT** (47,648 arc booleans + flow) | 2 | trench 605.4M | **≈0, plausibly negative** | 20+ | — | **Do not build.** No lazy cuts in CP-SAT; single-commodity relaxation is the weakest of the family (Goemans & Myung 1993); SCIP-Jack is the right tool if this is ever wanted |
| 13 | **RENS / MIP on cable & splitter sizing** | 2 | 9.3M hardware at 99.2–100% util | <2M | 6 | <0.4M | **Do not build.** The slack is already gone |

**Reading of the table.** Rows 1, 2 and 4 are Tier-1, cost 7 engineer-days between them, need no solver, no interop and no toolchain change, and plausibly recover **26–80M cents (2.7–8.2% of score)** — comparable to the last three iterations combined, and each is a strict improvement to code that already exists. They should be done first regardless of the M3 timeline. Row 6 is the Tier-2 centrepiece and the thing that justifies the interop surface; rows 3 and 7 are near-free once it exists. Row 12 is the trap: trench is 62% of the score, so a global Steiner MIP looks like the obvious prize, and it is the one technique in this section I would actively argue against building — the leverage on trench is in *which nodes must be reached* (rows 2, 6, 8), not in how well the tree reaches them.

**Sources:**
- [Ohrimenko, Stuckey & Codish, *Propagation via lazy clause generation*, Constraints 14:357–391, 2009](https://link.springer.com/article/10.1007/s10601-008-9064-x)
- [Perron, Didier & Gay, *The CP-SAT-LP Solver*, CP 2023, LIPIcs vol. 280](https://drops.dagstuhl.de/entities/document/10.4230/LIPIcs.CP.2023.3)
- [OR-Tools `sat_parameters.proto` (interleave_search, max_deterministic_time, symmetry_level, repair_hint)](https://raw.githubusercontent.com/google/or-tools/stable/ortools/sat/sat_parameters.proto)
- [The CP-SAT Primer — Advanced Modelling (add_circuit, add_multiple_circuit, add_allowed_assignments, no_overlap_2d)](https://d-krupke.github.io/cpsat-primer/advanced_modelling.html)
- [The CP-SAT Primer — Parameters (hints, bounds, workers, "CP-SAT does not support adding lazy constraints … (or at all)")](https://d-krupke.github.io/cpsat-primer/parameters.html)
- [The CP-SAT Primer — Large Neighborhood Search (built-in LNS workers, hand-rolled destroy-and-repair)](https://d-krupke.github.io/cpsat-primer/lns.html)
- [The CP-SAT Primer — Understanding the Log (16-worker portfolio, subsolver names)](https://d-krupke.github.io/cpsat-primer/understanding_the_log.html)
- [Fischetti & Lodi, *Local branching*, Mathematical Programming 98:23–47, 2003](https://link.springer.com/article/10.1007/s10107-003-0395-5)
- [Fischetti & Monaci, *Proximity search for 0-1 mixed-integer convex programming*, Journal of Heuristics 20(6):709–731, 2014](https://link.springer.com/article/10.1007/s10732-014-9266-x)
- [Danna, Rothberg & Le Pape, *Exploring relaxation induced neighborhoods to improve MIP solutions*, Mathematical Programming, 2005](https://link.springer.com/article/10.1007/s10107-004-0518-7)
- [Berthold, *RENS — relaxation enforced neighborhood search*](https://www.researchgate.net/publication/228715008_RENS-relaxation_enforced_neighborhood_search)
- [Helber & Sahling, *A fix-and-optimize approach for the multi-level capacitated lot sizing problem*, IJPE 123(2):247–256, 2010](https://www.sciencedirect.com/science/article/abs/pii/S0925527309003107)
- [Shaw, *Using Constraint Programming and Local Search Methods to Solve Vehicle Routing Problems*, CP'98, LNCS 1520:417–431](https://link.springer.com/chapter/10.1007/3-540-49481-2_30)
- [Caprara, Fischetti & Toth, *A Heuristic Method for the Set Covering Problem*, Operations Research 47(5):730–743, 1999](https://pubsonline.informs.org/doi/10.1287/opre.47.5.730)
- [Goemans & Myung, *A catalog of Steiner tree formulations*, Networks 23(1):19–28, 1993](https://onlinelibrary.wiley.com/doi/abs/10.1002/net.3230230104)
- [Ljubić, *Solving Steiner trees: Recent advances, challenges, and perspectives*, Networks 77:177–204, 2021](https://onlinelibrary.wiley.com/doi/abs/10.1002/net.22005)
- [Gamrath, Koch, Maher, Rehfeldt & Shinano, *SCIP-Jack — a solver for STP and variants with parallelization extensions*, Math. Prog. Computation, 2017](https://link.springer.com/content/pdf/10.1007/s12532-016-0114-x.pdf)
- [Rehfeldt, Koch & Maher, *Reduction techniques for the prize-collecting Steiner tree problem…*, Networks, 2019](https://onlinelibrary.wiley.com/doi/10.1002/net.21857)
- [Gollowitzer & Ljubić, *MIP models for connected facility location*, Computers & OR 38:435–449, 2011](https://www.sciencedirect.com/science/article/pii/S0305054810001334)
- [Grötschel, Raack & Werner, *Towards optimizing the deployment of optical access networks*, EURO J. Computational Optimization, 2014](https://link.springer.com/content/pdf/10.1007/s13675-013-0016-x.pdf)
- [Ceselli & Righini, *A branch-and-price algorithm for the capacitated p-median problem*, Networks, 2005](https://onlinelibrary.wiley.com/doi/10.1002/net.20059)
- [Kaibel & Pfetsch, *Packing and partitioning orbitopes*, Mathematical Programming 114:1–36, 2008](https://link.springer.com/article/10.1007/s10107-006-0081-5)
- [Margot, *Symmetry in Integer Linear Programming*, in 50 Years of Integer Programming 1958–2008, Springer 2010](https://link.springer.com/chapter/10.1007/978-3-540-68279-0_17)


---

## 5. Beyond the standard playbook — SOTA, cross-domain transfers and exotic ideas

Before the techniques, three facts I *measured* from the repo rather than assumed. Each one changes what "beyond the playbook" should mean here.

**Fact 1 — the cost anatomy, from `designs/parcels_district.report.txt`.** The score decomposes as:

| block | cents | % of district score (973,816,190) |
|---|---|---|
| trench soft (118,117 m × $45) | 531,526,500 | 54.6% |
| trench asphalt (4,928 m × $150) | 73,920,000 | 7.6% |
| **trench total** | **605,446,500** | **62.2%** |
| drop assembly (6,719 × $120) + drop cable (193,937 m × $1.50) | 109,718,550 | 11.3% |
| street-crossing penalty (2,238 × 50,000) | 111,900,000 | 11.5% |
| distribution + feeder cable | 51,996,140 | 5.3% |
| under-4 penalty (511 × 100,000) | 51,100,000 | 5.2% |
| terminals + FDH + splitters + OLT | 29,975,000 | 3.1% |
| drop-drop penalty (684 × 20,000) | 13,680,000 | 1.4% |

Trench is 62% of the score and 76% of capex. Everything below is ranked against *that*, not against the penalty terms that are easier to talk about.

**Fact 2 — the terminal-packing objective does not contain the word "trench".** `grep -n "TrenchCostPerM" src/stages.carbon` returns exactly one hit: line 1346, inside `DeloopTrench`'s Dijkstra. `PackTerminals` (line 663) prices `50000*crossings + TerminalCost + 150*drop_m + 100000*under4`; `TryDissolve` (lines 963–988) prices the same four terms. The stage that *chooses which 1,753 of 15,668 nodes the trench must reach* is blind to the cost of reaching them — 62% of the objective is invisible to the decision that drives it. The implied marginal is large: iter 004 cut demand nodes ~3,000 → ~1,700 (−43%) and trench 190,299 → 134,276 m (−29%), an elasticity of ≈0.67, so at the current point d(trench)/d(terminal) ≈ 0.67 × 123,045/1,753 ≈ 47 m ≈ **~210,000 cents per terminal** — four times the street-crossing penalty and twice the under-4 penalty. The packing greedy is balancing two 50k–100k terms while a 210k term floats free.

**Fact 3 — I computed the zero-crossing incidence structure of this instance.** The lattice has mean degree 3.041 (8,807 degree-3 nodes, 3,623 degree-2, only 3,234 of degree ≥ 4). Because `ProperCross` excludes endpoint touches, a drop from a convex parcel's centroid to a corner of *its own* parcel crosses nothing; so the zero-crossing candidate set of premises *p* is essentially the corner set of *p*'s parcel, and a node *v* can host at most `deg(v)` zero-crossing drops. Running the actual predicate (60 m radius, exact integer orientation, over all 6,719 premises): 4,272 nodes can host ≥4 zero-crossing drops; the median premises has 4–5 zero-crossing candidates; **63 premises have none**. A max-coverage greedy with 4..12-port zero-crossing terminals covers **3,887 of 6,719 premises with only 708 terminals** (mean load 5.5). So ~2,832 premises (42%) are *structurally* forced to either cross a street or sit on an under-4 terminal — and the honest ceiling on the combined crossing+under-4 prize (163.0M cents today) is roughly a 20–40M-cent recovery, not the 163M a naive reading suggests. Meanwhile 708 vs 1,753 terminals says the *terminal count* is far from its floor, and by Fact 2 that is where the trench money is.

Conclusion that shapes this whole section: **the remaining prize is not "better crossings" and not "a better Steiner heuristic on a fixed terminal set" — it is the *coupling* between which nodes become terminals and what the trench then costs.** Techniques below are ordered by how directly they attack that coupling.

---

### 5.1 Connected Facility Location: put the trench's dual price inside terminal siting

**What it is.** netwerk stages 5/6 are literally an instance of **Connected Facility Location (ConFL)** with lower-bounded facilities and unsplittable unit demands. Sets: road nodes $V$ ($|V|=15{,}668$), edges $E$ ($|E|=23{,}824$) with trench cost $t_e = \ell_e \cdot \tau(\text{surface}_e)$ (4,500 or 15,000 cents/m), premises $P$ ($|P|=6{,}719$), root $r$ = CO, and for each premises the feasible-drop arc set $A = \{(p,v) : \|pv\| \le 150,\ \mathrm{xings}(p,v) \text{ counted}\}$. Variables: $y_v \in \{0,1\}$ (terminal opened at $v$), $s_v \in \{2,4,6,8,12\}$ (catalog size), $x_{pv}\in\{0,1\}$ (drop), $z_e \in \{0,1\}$ (trench opened). Objective:

$$\min \sum_{e} t_e z_e \;+\; \sum_v H(s_v) y_v \;+\; \sum_{(p,v)\in A}\big(150\,d_{pv} + 50000\,\chi_{pv}\big)x_{pv} \;+\;100000\!\!\sum_{v:\,0<\text{load}_v<4}\!\! y_v \;+\; \text{cable}(z)$$

s.t. $\sum_v x_{pv}=1$, $\sum_p x_{pv}\le s_v y_v$, and the connectivity coupling $z(\delta(S)) \ge y_v$ for every $S \subseteq V\setminus\{r\}$, $v\in S$ (every open terminal is connected to the root through opened trench). That last family is exactly what the current pipeline omits at decision time and repairs afterwards.

This is a well-studied object. ConFL originates with Karger & Minkoff's *maybecast* problem (FOCS 2000); Swamy & Kumar (Algorithmica 2004) give an 8.55 primal-dual; Eisenbrand, Grandoni, Rothvoß & Schäfer (SODA 2008) give 4.00 [corrected from 3.92 in review] by random facility sampling + core detouring; Gollowitzer & Ljubić (*Computers & OR* 38(2), 2011) give the definitive MIP-model comparison; and Bley, Ljubić & Maurer (*EURO J. Computational Optimization* 1(3–4), 2013) solve the **two-level FTTx** version — clients → distribution points → central offices with shared fibers — by Lagrangian decomposition. The lower-bound-on-open-facility structure (your under-4 penalty is a soft version of "each open terminal serves ≥4") is *Lower-Bounded Facility Location*: Guha, Meyerson & Munagala (STOC 2001) use it as a subroutine for single-sink buy-at-bulk; Svitkina (SODA 2008 / *ACM TALG* 2010) gives the first single-criterion constant (448); Ahmadian & Swamy (2013) improve it to 82.6.

**Why it fits netwerk.** It is the exact statement of Fact 2. The literature's central message is that facility opening and tree cost must be priced *together*, because a facility on a corridor you are already trenching is nearly free while one 40 m off-corridor costs 40 m of trench. netwerk currently makes that choice with the trench term set to zero.

**Two concrete algorithms, both Tier 1.**

*(a) Interleaved grow-and-open (the ConFL greedy, adapted).* Replace `PackTerminals`' independent per-cluster loop with one global loop that maintains a growing trench tree $T$ (initially $\{CO\} \cup \{\text{FDH nodes}\}$) and a distance label $\pi_v = $ trench cents from $v$ to $T$, maintained by the *same incremental multi-source Dijkstra pattern `DeloopTrench` already implements* (tree nodes are 0-cost sources, tree edges relax at 0 — `stages.carbon:1340–1356`). The move price becomes

```
cost(v,k) = 50000*Σxings + TerminalCost(k) + 150*Σdrop_m
          + (k<4 ? 100000 : 0)
          + π_v                      // NEW: marginal trench to reach v
committed move = argmin cost(v,k)/k   // same exact-ratio MoveBetter compare
```

and on commit, the path from $v$ back to $T$ is added to $T$, its nodes get $\pi=0$ and are pushed as sources. Every subsequent candidate on or near that corridor becomes cheap — which is precisely the corridor-consolidation effect that iter 005 obtained *after the fact* and that this obtains *at decision time*.

*(b) Price iteration (the cheap first cut, ~40 lines).* Run the existing pipeline once; after `DeloopTrench`, compute $\pi_v$ = trench cents from $v$ to the final tree by one multi-source Dijkstra; re-run `PackTerminals` with $+\pi_v$ in the move cost; re-route. This is one Gauss–Seidel sweep of a Lagrangian coordination between the two stages and is a strict superset of the current behaviour when $\pi\equiv 0$. Two or three sweeps, guarded by "keep the best-scoring sweep", is deterministic and cannot regress.

**Expected gain.** (a) does not necessarily reduce terminal *count*; its dominant effect is relocating terminals onto corridors that are needed anyway. Corridor-consolidation moves of this kind in the ConFL literature routinely recover the same order as the 8% that iter 005's global Steiner tree found — but that was a *routing-side* consolidation on a fixed terminal set, and this is the *siting-side* half that has never been done. Conservatively **4–8% of trench = 24–48M cents**, with crossings roughly neutral (they stay priced) and a modest second-order gain from fewer, better-placed terminals. I would bet on a positive result with high confidence purely because the coefficient is currently zero; the uncertainty is magnitude, not sign. (b) captures maybe half of (a) at a tenth of the effort.

**Complexity / runtime.** (a): the incremental multi-source Dijkstra amortises to $O(|E|\log|V|)$ *total* over all openings if you never reset (each node's label only decreases), plus the existing $O(|V| \cdot \bar{s})$ candidate scan per commit. At 15.7k/23.8k with ~1,750 commits this should add **1–3 s** to the current 11 s. (b) adds one full pipeline pass: ~11 s per sweep.

**Tier.** Tier 1 for both. Tier 2 would replace the greedy with Gollowitzer–Ljubić's cut-set MIP on a *reduced* graph (see §5.6) solved by HiGHS branch-and-cut with separation of the $z(\delta(S)) \ge y_v$ inequalities by max-flow; interop surface: HiGHS `addRow` during callback (lazy cuts), plus a max-flow routine.

---

### 5.2 Uncrossing: make drop–drop crossings structurally impossible rather than penalised

**What it is.** Fix the terminal sites and their port counts. What remains is a pure **capacitated transportation problem**: bipartite graph premises → terminals, arcs $(p,v)$ feasible, supply 1 per premises, capacity $s_v$ per terminal, cost = Euclidean length. Two classical facts combine:

1. *Uncrossing lemma.* If drops $p_1{\to}t_1$ and $p_2{\to}t_2$ properly cross, then $p_1p_2t_2t_1$ is a convex quadrilateral and the diagonals exceed the opposite sides: $\|p_1t_1\| + \|p_2t_2\| > \|p_1t_2\| + \|p_2t_1\|$. Swapping *preserves every terminal's load* and strictly shortens the total. Hence **any minimum-total-length solution of the transportation problem is non-crossing.** This is folklore for matchings and is stated explicitly by Alon, Rajagopalan & Suri (*Long non-crossing configurations in the plane*, SoCG 1993) and restated in the bichromatic-network literature (e.g. arXiv:1911.08924); the extension from perfect matching to capacitated transportation is immediate because the swap is load-preserving — I am extrapolating one line, not citing a paper for the capacitated case.
2. *Drops sharing a terminal never properly cross* — they share an endpoint, and `ProperCross` excludes endpoint touches. So **all 684 crossings are inter-terminal**, i.e. entirely a property of the assignment, not of the siting.

Together: drop–drop crossings are not a geometric tax to be minimised, they are an *artefact of a suboptimal assignment* and can be driven to (near) zero by construction.

**Two implementations.**

*Tier 1 — priced 2-opt uncrossing to fixpoint.* Enumerate crossing drop pairs via the existing 128 m edge grid (reuse `BuildEdgeGrid`, index drops instead of edges); for each properly crossing pair in a deterministic (lower premises id, then higher) order, evaluate

```
Δ = 150*(|p1 t2| + |p2 t1| - |p1 t1| - |p2 t2|)          // strictly negative
  + 50000*(x(p1,t2) + x(p2,t1) - x(p1,t1) - x(p2,t2))    // may be positive
```

accept iff `Δ < 0` and both new drops satisfy the 150 m rule. Loads are invariant, so hardware, under-4 counts, fiber accounting and QA are untouched — this is the rare repair pass that *cannot* spend budget elsewhere. The priced objective is a non-negative integer that strictly decreases on every accepted move, so the loop provably terminates; a fixpoint scan is $O(C \cdot \bar{g})$ where $C$ is the crossing count. **~120 lines of Carbon.** Restrict swaps to same-serving-area pairs in v1 (cross-cluster swaps need the per-cluster fiber bookkeeping already flagged in backlog item 2).

*Tier 2 — solve it exactly.* The transportation LP is totally unimodular; successive-shortest-paths with potentials (Ahuja, Magnanti & Orlin, *Network Flows*, 1993) or OR-Tools' `SimpleMinCostFlow` returns an integral optimum. With ~6,719 sources, ~1,753 sinks and ~135k arcs this is a sub-second solve, and by the lemma its optimum is non-crossing wherever the swapped arcs remain feasible.

**Honest caveat.** The lemma guarantees non-crossing for *unrestricted* Euclidean cost. Here arcs are restricted (150 m cap; and a swap can introduce a street crossing worth 50,000 while saving only, say, 8 m × 150 = 1,200). So the guarantee degrades to "zero crossings except where the swap partner is blocked". Given mean drop length 28.86 m and the near-parallel lot geometry, I expect **60–95% of the 684 to clear**.

**Expected gain.** 8.2M–13.0M cents of penalty, plus 1–3M of drop cable (each accepted swap shortens two drops), so **9–16M cents ≈ 1.0–1.6% of score** — for the smallest implementation in this section. The structural bonus is larger than the number: once assignment handles drop–drop crossings, `PackTerminals` can stop reasoning about them at all, freeing its move-pricing budget for the trench term of §5.1.

**Tier.** Tier 1 (2-opt), Tier 2 (exact flow). Interop surface for Tier 2: a min-cost-flow call taking integer arc arrays and returning an integer flow, with a documented deterministic tie-break (OR-Tools' SSP is deterministic for a fixed arc order).

---

### 5.3 The street-crossing floor is a lower-bounded b-matching on a planar incidence graph — and I measured it

**What it is.** From Fact 3, define the bipartite incidence $I \subseteq P \times V$ with $(p,v)\in I$ iff the straight drop $p{\to}v$ crosses nothing and is ≤150 m. Then "how few street crossings are achievable, subject to no terminal below 4 ports" is exactly a **lower-bounded degree-constrained subgraph (b-matching)** problem: choose $y_v$, assign each $p$ either to some $v$ with $(p,v)\in I$ (free) or to a non-incident $v$ (paying $50000\cdot\chi_{pv}$), with $\text{load}_v \in \{0\}\cup[4,12]$. Dropping the lower bound makes it a pure min-cost flow (polynomial); the lower bound is what makes it LBFL-hard (Svitkina 2010; Ahmadian & Swamy 2013).

**Why it matters here.** It converts an open-ended optimisation ("get crossings down") into a *bounded* one. My greedy covers 3,887/6,719 premises at zero crossings with 708 terminals of mean load 5.5. That leaves 2,832 premises that must buy either a crossing (50,000) or an under-4 terminal (100,000 amortised over ≤3 premises, i.e. ≥33,333 each). A crude but defensible floor for the combined crossing + under-4 budget is therefore ~2,832 × 40,000 ≈ **113M cents**, against today's 163.0M. **The entire remaining drop-geometry prize is ≈50M cents (5% of score), and a realistic capture is 20–40M.** Anyone proposing to chase crossings should be shown this number first.

**Second, sharper observation.** The degree histogram explains the design's shape better than any heuristic tuning will: 56% of nodes are degree 3, so the natural crossing-free group size is **3**, while the smallest unpenalised catalog terminal is **4**. The 492 two-port terminals and 511 under-4 terminals are the lattice's degree distribution showing through the catalog. Two responses follow, neither of which is an algorithm change: (i) if a 3-port terminal exists in the real catalog, adding it converts a large share of 51.1M of penalty into ~$100 of hardware — this is a *catalog* fix, exactly like iter 007's FDH pedestals; (ii) if the 4-port floor is a genuine business rule, then 100,000 is the right price and ~500 under-4 terminals is near-optimal, and the backlog item "retire the remaining under-4 strays" should be closed as *structurally bounded* rather than pursued.

**Tier.** The measurement itself is a Python-side probe (Tier 0, ~1 hour, and I have already run it). The exact solve is Tier 2 (min-cost flow with a semi-continuous load variable → CP-SAT or a MIP with indicator constraints; OR-Tools CP-SAT handles $\text{load}_v\in\{0\}\cup[4,12]$ natively as a `AddAllowedAssignments`/domain variable, which is precisely why CP-SAT is the right Tier-2 tool for this piece and HiGHS is not).

---

### 5.4 Very-Large-Scale Neighbourhood search: cyclic exchange as the right generalisation of "ejection chains" for partitions

**What it is.** The brief suggests Lin–Kernighan-style deep moves. The correct transfer to netwerk is *not* LK (which is a path/tour-specific reference structure — Lin & Kernighan 1973; Helsgaun 2000) but its partition-problem sibling: the **cyclic-exchange VLSN** of Thompson & Psaraftis (*Operations Research*, 1993) and Ahuja, Ergun, Orlin & Punnen (*Discrete Applied Math* 123, 2002), with the capacitated-tree specialisation of Ahuja, Orlin & Sharma (*ORL* 31(3), 2003 — *A composite very large-scale neighborhood structure for the capacitated minimum spanning tree problem*). CMST is the closest classical problem to netwerk's trench-with-capacity core, which makes this the most direct cross-domain transfer available.

**The formulation.** Let the current solution partition premises into subsets $S_1,\dots,S_m$ (either *terminals* or *serving areas* — both are capacitated partitions with a non-linear per-subset cost). Build the **improvement graph** $\mathcal{G}$: one node per premises $p$; an arc $p \to q$ with cost

$$c(p{\to}q) \;=\; \underbrace{\big[f(S_{j}\setminus\{q\}\cup\{p\}) - f(S_j)\big]}_{\text{effect of moving } p \text{ into } q\text{'s subset, } q \text{ leaving}}$$

where $f$ is the *scorer-priced* subset cost (terminal hardware + $50000\cdot$crossings + $150\cdot$drops + under-4, and — per §5.1 — $\pi_v$). A **subset-disjoint negative-cost cycle** in $\mathcal{G}$ (no two cycle nodes from the same $S_j$) corresponds one-to-one with a simultaneous multi-way relocation $p_1 \to S_2, p_2 \to S_3, \dots, p_k \to S_1$ that improves the objective and preserves feasibility. Finding one is NP-hard in general but is solved in practice by a label-correcting DP over cycles of bounded length $k$, with labels $(\text{node}, \text{set-of-subsets-visited})$ — for $k\le 3$ or $4$ this is a plain nested loop.

**Why it fits.** Every negative result in the ledger points here. Iter 003's DP was "exactly optimal for its sequence" and lost because the *solution representation* (consecutive runs) could not express the geometry. Iter 004's set-cover greedy fixed the representation but prices moves *marginally* — one premises at a time, committed irrevocably. The 2-exchange repair (`MergeTerminals`) can only see pairs. Cyclic exchange is exactly the missing capability: it can execute "premises $a$ leaves terminal $A$ for $B$, $b$ leaves $B$ for $C$, $c$ leaves $C$ for $A$" — the move class that resolves the "two strays that would merge at a middle node neither currently hosts" case named verbatim in backlog item 2, and the class that lets a 2-port stray dissolve by *cascading* spare ports across three terminals rather than needing one neighbour with slack.

**Expected gain.** Applied to the terminal partition, this attacks the 212.7M-cent block (crossings + under-4 + terminal hardware + drop cable). VLSN over 2-exchange typically buys 3–8% on capacitated partition problems in the CMST/VRP literature; against my §5.3 floor the realistic capture is **10–25M cents**. Applied additionally to the *serving-area* partition (16 areas, boundary premises) it attacks feeder + distribution trench: **another 5–15M**. Total **15–40M cents (1.5–4%)**. This is also the natural home for backlog item 7 (clustering local search), which currently has no implementation.

**Complexity / runtime.** Arc construction is the cost: restrict $\mathcal{G}$ to *geometrically plausible* arcs only — $q$ must be within 150 m of $p$'s candidate node set — giving ~30–60 arcs per premises, i.e. ~300k arcs. Cycle length ≤3 over 300k arcs with a subset-disjointness check is ~$10^7$–$10^8$ integer ops per pass, **~1–4 s**, run to fixpoint over a handful of passes.

**Tier 1**, and it is the technique in this section that is most obviously *implementable in a few hundred lines of integer Carbon*: fixed-size arc arrays, integer cost deltas, deterministic scan order (premises id), first-improvement or best-improvement with an exact tie-break. Ejection chains proper (Glover, *Discrete Applied Math* 65, 1996) are the same idea with an unbounded reference structure and are the Tier-2 upgrade.

---

### 5.5 Steiner: reductions first, key-path local search second, loss-contracting never

Backlog 6c proposes key-path improvement. Two amendments, one addition, one deletion.

**(a) Reduction tests before anything else — the single most under-rated tool in the Steiner literature.** Polzin & Daneshmand (*Discrete Applied Math* 112, 2001; ESA 2002) and the modern SCIP-Jack line (Rehfeldt, Koch & Maher; *Implications, Conflicts, and Reductions for Steiner Trees*, IPCO 2021) establish that **reductions, not the heuristic, are what make Steiner instances tractable** — Polzin & Daneshmand report **78% average edge removal** on benchmark instances, and Ljubić's survey (*Solving Steiner trees: recent advances*, *Networks* 2021) confirms reduction is the dominant ingredient in every competitive solver. For netwerk the cheapest tests apply immediately and are pure integer code:

- **Degree-1 / degree-2 elimination.** 3 nodes of degree 1 and **3,623 of degree 2** in the district. A non-required degree-2 node is a pure path subdivider: contract it and add the two edge lengths. That alone removes ~23% of nodes and ~15% of edges *exactly, with no loss of optimality*, and speeds every Dijkstra in the engine.
- **Special-Distance (SD) test.** Delete edge $(u,v)$ if $c_{uv} > s(u,v)$, where $s(u,v)$ is the bottleneck over all $u$–$v$ paths whose internal vertices are all required. On a lot-line lattice with many near-equal parallel corridors this should be productive.
- **Nearest-vertex / terminal-distance tests** for the required nodes.

**(b) Key-path exchange, done in the efficient form.** Uchoa & Werneck (ALENEX 2010; *ACM J. Experimental Algorithmics* 17, 2012) give $O(m \log n)$ implementations of vertex insertion, vertex elimination, key-path exchange and key-vertex elimination — versus the naive $O(n^2)$/$O(mn)$ that makes the textbook version look unaffordable. Key-path exchange is the one backlog 6c names; key-*vertex* elimination is the one that matters more on a lattice, because SPH tends to create spurious degree-3 Steiner vertices where two corridors nearly-but-not-quite coincide.

**(c) Multistart + elite recombination.** Pajor, Uchoa & Werneck (*Math. Programming Computation* 10, 2018) show that SPH-from-many-roots, plus recombination of elite solutions (take the union of two trees and re-solve the small Steiner instance inside it), plus these local searches, matches or improves best-known results on DIMACS-Challenge instances. The recombination step is trivially deterministic: fixed root order, fixed elite pool size, union-graph re-solve.

**(d) Discard loss-contracting.** Robins & Zelikovsky's $k$-LCA (*SIAM J. Discrete Math* 19(1), 2005 — 2007 SIAM Outstanding Paper) achieves ratio $1+\ln 3/2 \approx 1.55$ and is a beautiful algorithm, but it is a *worst-case* device: it needs the metric closure over the required set (1,753 terminals → 1.5M pairs, 1,753 Dijkstras) plus enumeration of $k$-restricted full components. On geometric near-uniform instances SPH already lands far inside its guarantee, and the marginal over SPH+key-path is small. **Not worth Tier-1 effort here.**

**Expected gain.** Reductions: 0 cents directly (they are exact) but a large runtime dividend that funds everything else. Key-path + key-vertex + multistart: SPH is a 2-approximation that in practice sits ~3–8% above optimum on graph instances; local search recovers roughly half of that. **1–4% of trench = 6–24M cents.** Note the interaction: the route-length budget is already at 18,060 m of 20,000 m (backlog 5's WATCH), so any further consolidation needs the *hop/length-constrained* variant — Sinnl & Ljubić's node-based layered-graph approach (2016) is the right formulation if this becomes binding.

**Complexity / runtime.** Reductions: $O(|E|\alpha)$ for degree tests, $O(|E|\log)$ per SD sweep — under 0.5 s. Key-path local search: $O(|E| \log |V|)$ per improving move, a few hundred moves — 1–2 s. Multistart × 8 roots: 8 × current tree-build ≈ 4–8 s. **Tier 1** throughout (all integer, all deterministic given a fixed root order and edge-id tie-breaks).

---

### 5.6 Multilevel coarsen–solve–refine, with a coarsening operator specific to lot lines

**What it is.** Walshaw's multilevel paradigm (*Annals of OR* 131, 2004, generalising METIS-style graph partitioning — Karypis & Kumar 1998; Sanders & Schulz, ESA 2011): build a hierarchy $G_0 \supset G_1 \supset \dots \supset G_L$ by contraction, solve at the coarsest level, then project and refine at each level. The claim in that literature is not that coarse solutions are good but that **the coarse level makes global moves cheap, and refinement at each level keeps them feasible** — a metaheuristic that is otherwise trapped in local minima at full resolution gets to make continent-scale moves.

**The netwerk-specific coarsening operator.** Generic edge-contraction matchings are wrong here; the geometry gives a better one:
1. Contract all non-required degree-2 chains (exact; 3,623 nodes — this is the same operator as §5.5(a), so the two share code).
2. Contract each *parcel face* to a single supernode (8,158 faces by Euler's formula on this instance), with inter-face edges weighted by the cheapest lot line between them. The result is the **parcel adjacency graph** — ~8k nodes, ~12k edges — on which serving-area partitioning and corridor selection are natural and fast.
3. Optionally contract parcel *blocks* (faces of the parcel adjacency graph bounded by asphalt edges — the 967 asphalt edges are exactly the street-crossing bridges the converter generated), giving a few hundred supernodes: the true "which blocks does the backbone pass through" level.

Solve serving-area partition + backbone corridor choice at level 2–3; project down; refine with §5.4's cyclic exchange at each level.

**Why it fits.** Serving-area clustering is currently farthest-point seeding + greedy first-fit + a rebalance pass (`stages.carbon:195–356`), with no local search at all, and it is the decision that fixes 16 FDH sites and therefore the feeder skeleton. At full resolution a swap/relocate hill-climb moves one premises at a time and will never move a *block* between areas. At the block level that is a single move.

**Expected gain.** Direct: modest — better serving-area boundaries mainly move feeder and the top of distribution, maybe **1–3% of trench (6–18M cents)**. Indirect: large — it is the enabler for §5.7, and combined with §5.5(a) it cuts the working graph enough to make repeated global re-solves affordable inside the 11 s budget.

**Complexity / runtime.** Face extraction on a planar embedding is $O(|E|\log)$ by rotational sorting of each node's incident edges by angle (integer `atan2`-free comparison via quadrant + cross-product — implementable exactly in integer Carbon) then walking next-edge-clockwise. **Tier 1**, ~200 lines, and it produces the face structure §5.3 needs anyway.

---

### 5.7 A deterministic ALNS outer loop — and the cheaper GLS alternative

**What it is.** Large Neighbourhood Search (Shaw 1998) with adaptive operator selection (Ropke & Pisinger, *Transportation Science* 40(4), 2006; Pisinger & Ropke, *C&OR* 34, 2007): repeatedly *destroy* a fraction of the solution and *repair* it optimally-ish, accepting by simulated-annealing-like criterion, with operator weights updated from observed success. It is the workhorse of the modern location-routing literature — Prodhon & Prins' survey (*EJOR* 238(1), 2014) and Hemmelmayr, Cordeau & Crainic (*C&OR* 39, 2012) for the two-echelon variant, which is structurally netwerk's CO→FDH→terminal hierarchy.

**Destroy operators designed for *this* geometry** (this is where the technique earns its keep — generic random-removal will do nothing):
- **Corridor destroy.** Pick a trench edge $e$ carrying below-median fibers-per-meter; free every terminal whose tree path uses $e$; repair. Directly attacks the "corridor that exists for three customers" failure mode.
- **Lot-line row destroy.** Pick a maximal collinear run of lot lines (a street frontage); free all terminals and drops in the strip between two consecutive rows; re-pack the strip exactly (a strip is 1-outerplanar-ish and small enough for an exact DP). This is the geometric analogue of a segment-reversal move.
- **Serving-area boundary destroy.** Free all premises within graph-distance $r$ of the boundary between two adjacent areas; re-cluster and re-site both FDHs.
- **Worst-crossing destroy.** Free the $k$ terminals with the highest $50000\cdot\text{crossings} + 100000\cdot[\text{under-4}]$ per premises.
- **Block destroy** (with §5.6): free one parcel block entirely.

**Repair** must be scorer-priced end-to-end — the ledger's hardest-won lesson ("any repair pass that moves things without pricing the true objective silently spends the budget the optimizer saved"). Use §5.1's move price including $\pi_v$, and re-run §5.4 cyclic exchange on the freed set.

**Determinism.** This is the real obstacle and it is solvable. (i) Replace the RNG with a fixed deterministic *schedule*: operators cycle in a fixed order, and destroy targets are chosen by rank (the $i$-th worst corridor at iteration $i \bmod N$), not sampled. (ii) Keep the adaptive weights as integers in units of 1/1024, updated by the same integer formula every run. (iii) Acceptance: strict improvement only (a deterministic hill-climb over a huge neighbourhood), or a deterministic "record-to-record travel" threshold `accept iff score < best + best/1000`. Byte-determinism is preserved and the golden gate still holds. A seeded PRNG (splitmix64 in integer Carbon) would also be byte-deterministic but makes goldens fragile under any code motion; prefer the schedule.

**The cheaper cousin: Guided Local Search** (Voudouris & Tsang, *EJOR* 113(2), 1999). Instead of destroy/repair, add an integer penalty $\lambda \cdot p_e$ to each trench edge's Dijkstra weight, where $p_e$ increments for edges that appear in every local optimum with high *utility* $= t_e / (1+p_e)$. Re-run `DeloopTrench` under the penalised weights; keep the best *true-cost* solution seen. This is ~40 lines on top of the existing `EdgeWeight` mode switch (`graph.carbon:239`), needs no incremental scorer, and is fully deterministic. It is the highest-value-per-line entry in this subsection.

**Expected gain.** ALNS ceiling is genuinely high — 5–15% of the whole score if given minutes rather than seconds — but is gated by an *incremental scorer*: at 11 s per full evaluation you get ~5 iterations, which is worthless. The real prerequisite is an $O(\text{changed})$ delta-evaluator. Realistic within a 60–120 s budget after that investment: **2–6% = 20–60M cents.** GLS on trench edges alone, with no incremental scorer, at ~8 restarts: **1–2% of trench = 6–12M cents** for a tenth of the effort.

**Tier.** GLS: Tier 1 now. Full ALNS: Tier 1 in principle but should wait for §5.5(a) reductions + §5.6 coarsening to make each iteration cheap; the honest sequencing is *last*.

---

### 5.8 The shadow-price probe: use ε-constraint as a *diagnostic*, not as an optimiser

The score is a fixed weighted sum, so there is no ambiguity about the target and no reason to produce a Pareto front for its own sake. The classical caveat applies but is not the interesting one: weighted-sum scalarisation can only reach *supported* efficient points — those on the convex hull of the outcome set — and non-supported designs sitting in a non-convex dent are unreachable by *any* weight vector (Ehrgott, *Multicriteria Optimization*, 2005), which is exactly why ε-constraint (Haimes, Lasdon & Wismer, 1971) exists. In FTTx specifically, Leitner, Ljubić, Sinnl & Werner (2016) build bi-objective 0/1-ILP methods for precisely this network class.

What is worth doing here is cheap and high-information: **run `min capex s.t. street_crossings ≤ B`** for $B \in \{2238, 2000, 1600, 1200, 800\}$ by sweeping the crossing coefficient in `PackTerminals` (it is a single constant, line 663) and recording realised capex. That traces the local exchange rate $\partial(\text{capex})/\partial(\text{crossings})$. Three possible outcomes, all actionable:
- rate $\ll$ 50,000 ⇒ the optimizer should be *buying* crossings it currently refuses, and the packing weights are miscalibrated against the true capex response;
- rate $\gg$ 50,000 ⇒ crossings are already over-bought and the under-4 population is the wrong target;
- rate ≈ 50,000 ⇒ the design sits at the scalarised optimum for this decomposition, and further crossing work is dead — spend everything on trench.

**Expected gain: zero directly.** Value is in redirecting the next three iterations. **Cost: one afternoon** of scripted reruns using the existing `iterate.sh` harness. Best information-per-effort in the section, and it is the honest way to decide whether backlog items 2/3/3b deserve any more budget.

---

### 5.9 Tier-2: set-partitioning over serving-area patterns, and Lagrangian decomposition

**What it is.** Dantzig–Wolfe reformulation by serving area. Let $\Omega$ be the set of feasible serving-area *patterns* — a pattern $S$ is (set of premises, FDH node, terminal siting, distribution tree), with cost $c_S$ = trench + cable + hardware + penalties, and $|S| \le 432$ units. Master:

$$\min \sum_{S\in\Omega} c_S x_S \quad \text{s.t.} \quad \sum_{S \ni p} x_S = 1 \;\; \forall p \in P, \qquad x_S \in \{0,1\}$$

with duals $\lambda_p$. The **pricing subproblem** is: find a feasible serving area minimising $c_S - \sum_{p\in S}\lambda_p$ — a *single* capacitated cluster with its own Steiner tree, i.e. a prize-collecting Steiner tree with a capacity side constraint, solved heuristically (§5.1's greedy with $\lambda$-adjusted premises "profits") or exactly on a reduced graph. This is the branch-and-price recipe of Ceselli & Righini (*Networks* 45(3), 2005) for the capacitated $p$-median, which scales to tens of thousands of clients, and it is *stronger* than the current decomposition in exactly the way that matters: the master chooses the partition knowing each area's realised routing cost, rather than choosing it from a graph-distance proxy and discovering the routing cost afterwards.

The lighter-weight sibling — and the one I would actually build first — is **Lagrangian decomposition** in the style of Bley, Ljubić & Maurer (*EURO J. Computational Optimization* 1, 2013) for the two-level FTTx problem: relax the coupling constraints between the terminal-siting level and the trench level, and let subgradient updates on the multipliers do what §5.1's price iteration does approximately. §5.1(b) *is* one iteration of this with a hand-set step; the Tier-2 version gets a valid lower bound for free, which is the thing netwerk most lacks — right now there is no bound at all, so "gains have flattened" cannot be distinguished from "we are near optimal".

**Expected gain.** Uncertain as an *improver* (3–8% of the partition+siting+trench block, so 20–50M cents), but near-certain as a *bound*: a dual bound within 5–10% would tell the campaign whether 973.8M has 50M or 300M of slack left. Given seven iterations of diminishing returns, knowing that is worth as much as another iteration.

**Interop surface required (this is the concrete M3 ask).** (1) HiGHS: build/solve an LP, add columns incrementally, read primal and **dual** values, set `threads=1` and a fixed simplex seed for determinism; (2) OR-Tools CP-SAT: integer-variable domains of the form $\{0\}\cup[4,12]$ (for §5.3), fixed random seed, `num_search_workers=1`, and a deterministic-time limit rather than wall-clock; (3) a min-cost-flow routine over integer arc arrays (§5.2). Note that per SCOPE.md's own determinism policy, MIP/LP-derived stages must be tested by cost-within-tolerance and structural invariants, never by byte-equality — so anything Tier 2 needs a second CI lane.

---

### 5.10 Investigated and discarded

- **Planar Steiner PTAS.** The graph *is* planar (parcel boundaries), so Borradaile, Klein & Mathieu's $O(n\log n)$ PTAS (*ACM TALG* 5(3), 2009) and Bateni, Hajiaghayi & Marx's Steiner-forest scheme (JACM 2011) formally apply. Tazari & Müller-Hannemann's implementation study (ALENEX 2009) is the definitive verdict: the hidden constants are so large that the scheme is not competitive with ordinary heuristics at any realistic size. **Discard the PTAS; keep the planarity** — it is what makes §5.3 and §5.6's face contraction work.
- **ML-guided combinatorial optimisation.** Gasse et al. (NeurIPS 2019) learn branching policies; Khalil et al. (NeurIPS 2017) learn greedy construction; Bengio, Lodi & Prouvost (*EJOR* 290, 2021) survey the field. Three blockers: netwerk has no branch-and-bound to steer (Tier 1 has no solver at all), one training instance, and a byte-exact golden gate that a learned float-valued model cannot satisfy. The only defensible use is **offline hint generation**: train nothing in-engine, but let a Python-side model propose a *set of candidate terminal nodes* written into the interchange as pins (backlog item 9's overrides section), which the deterministic engine then honours or rejects on price. Even then, the same hints could come from §5.3's incidence structure at zero risk. **Discard for now; revisit only after backlog item 9 exists.**
- **Buy-at-bulk approximation algorithms.** Netwerk's trench-plus-cable cost *is* single-sink buy-at-bulk (Guha, Meyerson & Munagala, STOC 2001; Talwar, IPCO 2002, ratio 216; Goel & Post, *One Tree Suffices*, FOCS 2010). The *model* is the right lens — it names why cable detours to save trench is optimal behaviour, and iter 005 rediscovered that empirically. The *algorithms* have ratios in the hundreds and are worthless as heuristics. **Cite the model, discard the algorithms.**
- **LK/LKH transferred verbatim.** Lin–Kernighan's power comes from the sequential-edge-exchange reference structure over a Hamiltonian *path*; there is no such structure on a tree-plus-partition. Its correct descendant here is §5.4. **Discard.**
- **Full Pareto front machinery.** See §5.8 — the scalarisation is the specification, not a modelling choice. **Discard the front; keep the probe.**

---

### Ranking: expected score reduction per unit of implementation effort

Effort is in engineer-days for a competent Carbon implementer working in this codebase. "Confidence" is my subjective probability the gain is positive and non-trivial.

| # | Technique | Tier | Expected gain (cents) | % of 973.8M | Effort (d) | Conf. | Gain/day |
|---|---|---|---|---|---|---|---|
| 1 | §5.2 Priced 2-opt drop uncrossing (uncrossing lemma) | 1 | 9–16M | 1.0–1.6% | 1–2 | 0.90 | ~7M |
| 2 | §5.1(b) Trench price iteration ($\pi_v$ from the routed tree, 2 sweeps) | 1 | 12–25M | 1.2–2.6% | 2–3 | 0.85 | ~7M |
| 3 | §5.5(a) Steiner reductions (degree-2 contraction + SD test) | 1 | 0 direct, ~30% runtime | — | 1–2 | 0.95 | enabler |
| 4 | §5.8 Shadow-price probe (ε-ladder on the crossing weight) | 0 | 0 direct, redirects 3 iterations | — | 0.5 | 1.00 | information |
| 5 | §5.1(a) Interleaved grow-and-open ConFL greedy | 1 | 24–48M | 2.5–4.9% | 4–6 | 0.80 | ~7M |
| 6 | §5.7 GLS penalties on trench edges (8 restarts) | 1 | 6–12M | 0.6–1.2% | 1–2 | 0.70 | ~6M |
| 7 | §5.5(b,c) Key-path + key-vertex LS, multistart + recombination | 1 | 6–24M | 0.6–2.5% | 4–6 | 0.85 | ~3M |
| 8 | §5.4 VLSN cyclic exchange (terminals, then serving areas) | 1 | 15–40M | 1.5–4.1% | 6–9 | 0.75 | ~3.5M |
| 9 | §5.6 Multilevel: face extraction + parcel/block coarsening | 1 | 6–18M direct | 0.6–1.8% | 5–7 | 0.65 | ~2M |
| 10 | §5.3 Exact lower-bounded b-matching for zero-crossing packing | 2 | 15–30M | 1.5–3.1% | 8–12 (+interop) | 0.60 | ~2M |
| 11 | §5.7 Full deterministic ALNS (needs incremental scorer first) | 1 | 20–60M | 2–6% | 12–20 | 0.60 | ~2.5M |
| 12 | §5.9 Lagrangian decomposition (bound) then column generation | 2 | 20–50M + a dual bound | 2–5% | 20–30 (+interop) | 0.50 | ~1.5M |

Gains are not additive: #1 and #8 overlap on drop assignment; #2, #5 and #12 are three fidelities of the same idea; #7, #9 and #11 all consume the same trench slack. A realistic combined ceiling for the whole list is **80–150M cents (8–15% of score)**, not the ~250M the column sums to.

---

### What I would do first if I had one week

**Day 1 (morning) — measure before building.** Run the §5.8 ε-ladder (five reruns sweeping the crossing coefficient at `stages.carbon:663`) and record realised capex at each. This costs half a day and settles whether the remaining 163M of drop-geometry penalty is worth *any* further engineering, or whether the campaign should be 100% trench from here. My prediction from Fact 3: it will show the design already near the crossing/capex exchange point and redirect you to trench.

**Day 1 (afternoon) – Day 2 — ship the uncrossing pass (§5.2).** ~120 lines, reuses `ProperCross` and the edge grid, provably terminating, load-preserving so QA and the utilization floor cannot move, and worth ~10–16M cents. It is the cleanest single result available and it retires backlog item 3 with a proof rather than a heuristic.

**Days 3–5 — close the trench-pricing gap (§5.1).** Start with (b), the two-sweep price iteration: compute $\pi_v$ by one multi-source Dijkstra from the routed tree, add it to `PackTerminals`' move cost, re-run, keep the better sweep. That is ~40 lines and immediately answers whether the 210k-cent-per-terminal coefficient is as live as Fact 2 says. If the sweep gains more than ~10M, spend days 4–5 promoting it to (a), the interleaved grow-and-open greedy that maintains $\pi_v$ incrementally — reusing the exact incremental-multi-source-Dijkstra pattern already sitting in `DeloopTrench` lines 1320–1357.

**Day 6 — reductions (§5.5a).** Contract non-required degree-2 chains (3,623 nodes on this instance, exact, no optimality loss). It costs a day, gives back ~20–30% of runtime, and every technique above gets cheaper — which is what buys the following week's ALNS or VLSN work.

**Day 7 — write down the bound you do not have.** Even without solver interop, compute a trench *lower* bound: the MST of the metric closure over required nodes is a valid $2\times$ bound, and the sum of each required node's distance to its nearest neighbour is a cheap combinatorial one. Backlog 6c notes "MST-lower-bound not yet computed" — after seven iterations of flattening gains, the most valuable artifact in the repo may be the number that says how much slack is actually left.

The through-line: the last four iterations improved *how well netwerk optimises the objective it can see*. The largest remaining win is making it see the other 62%.

**Sources:** [Alon, Rajagopalan & Suri — Long non-crossing configurations in the plane](https://web.math.princeton.edu/~nalon/PDFS/noncros.pdf) · [Geometric planar networks on bichromatic points](https://arxiv.org/pdf/1911.08924) · [Karger & Minkoff — Building Steiner trees with incomplete global knowledge](https://dblp.org/rec/conf/focs/KargerM00.html) · [Swamy & Kumar — Primal-dual algorithms for connected facility location](https://www.math.uwaterloo.ca/~cswamy/papers/confl-journal.pdf) · [Eisenbrand, Grandoni, Rothvoß & Schäfer — Approximating connected facility location via random facility sampling and core detouring](https://people.idsia.ch/~grandoni/Pubblicazioni/EGRS08soda.pdf) · [Gollowitzer & Ljubić — MIP models for connected facility location](https://www.sciencedirect.com/science/article/pii/S0305054810001334) · [Bley, Ljubić & Maurer — Lagrangian decompositions for the two-level FTTx network design problem](https://link.springer.com/article/10.1007/s13675-013-0014-z) · [Ljubić — Solving Steiner trees: recent advances, challenges and perspectives](https://onlinelibrary.wiley.com/doi/abs/10.1002/net.22005) · [Svitkina — Lower-bounded facility location](https://link.springer.com/chapter/10.1007/978-3-642-38016-7_21) · [Ahmadian & Swamy — Improved approximation guarantees for lower-bounded facility location](https://arxiv.org/abs/1104.3128) · [Polzin & Daneshmand — Extending reduction techniques for the Steiner tree problem](https://link.springer.com/content/pdf/10.1007/3-540-45749-6_69.pdf) · [Rehfeldt, Koch & Maher — Implications, conflicts, and reductions for Steiner trees](https://link.springer.com/chapter/10.1007/978-3-030-73879-2_33) · [Uchoa & Werneck — Fast local search for Steiner trees in graphs](https://dl.acm.org/doi/abs/10.1145/2133803.2184448) · [Pajor, Uchoa & Werneck — A robust and scalable algorithm for the Steiner problem in graphs](https://arxiv.org/pdf/1412.2787) · [Robins & Zelikovsky — Tighter bounds for graph Steiner tree approximation](https://www.cs.virginia.edu/~robins/papers/Robins_Graph_Steiner_Approximation.pdf) · [Ahuja, Orlin & Sharma — A composite very large-scale neighborhood structure for the CMST](https://www.sciencedirect.com/science/article/abs/pii/S0167637702002365) · [Ahuja et al. — Very large-scale neighborhood search](https://www.sciencedirect.com/science/article/abs/pii/S0969601600000095) · [Ropke & Pisinger — An ALNS heuristic for the PDPTW](https://backend.orbit.dtu.dk/ws/portalfiles/portal/3154899/An%20adaptive%20large%20neighborhood%20search%20heuristic%20for%20the%20pickup%20and%20delivery%20problem%20with%20time%20windows_TechRep_ropke_pisinger.pdf) · [Prodhon & Prins — A survey of recent research on location-routing problems](https://www.sciencedirect.com/science/article/abs/pii/S0377221714000071) · [Voudouris & Tsang — Guided local search](https://www.researchgate.net/publication/312516867_Guided_Local_Search) · [Walshaw — Multilevel refinement for combinatorial optimisation problems](https://link.springer.com/article/10.1023/B:ANOR.0000039525.80601.15) · [Borradaile, Klein & Mathieu — An O(n log n) approximation scheme for Steiner tree in planar graphs](https://dl.acm.org/doi/10.1145/1541885.1541892) · [Tazari & Müller-Hannemann — Dealing with large hidden constants: engineering a planar Steiner tree PTAS](https://csaws.cs.technion.ac.il/~hadas/Seminar/Spring12_236804/Papers/Tazari_Steiner_tree_ptas.pdf) · [Gasse, Chételat, Ferroni, Charlin & Lodi — Exact combinatorial optimization with GCNNs](https://arxiv.org/abs/1906.01629) · [Ceselli & Righini — A branch-and-price algorithm for the capacitated p-median problem](https://onlinelibrary.wiley.com/doi/10.1002/net.20059) · [Guha, Meyerson & Munagala — single-sink buy-at-bulk / lower-bounded facility location](https://link.springer.com/chapter/10.1007/3-540-47867-1_33)



---

# Appendix A — adversarial review

An independent reviewer re-derived every BOM figure and verified
citations against the literature. Corrections marked "confirmed" are
applied inline above; everything else stands as a caveat on the
section text.


# Adversarial review of the five drafted sections

Reviewed against the repo as checked out at `/home/user/netwerk` (`src/model.carbon`, `src/stages.carbon`, `src/graph.carbon`, `tools/score_design.py`, `designs/parcels_district.report.txt`, `docs/IMPROVEMENT_BACKLOG.md`, `results/LEDGER.md`) and against the literature via web verification. I re-derived every BOM figure and every arithmetic identity I could. Where a section is right, I say so and move on.

---

## 0. What checks out (so the rest of the review is calibrated)

Before the criticism: the cost decomposition is reproduced correctly and independently in §1.0, §2.0, §3.0, §4.0 and §5 Fact 1, and all five agree with `designs/parcels_district.report.txt` to the cent. I verified the score identity myself: 797,136,190 + 2,238·50,000 + 684·20,000 + 511·100,000 = 973,816,190. §2's Result 4 table sums correctly in both columns (973,816,190 and 704,686,945; gap 269,129,245 = 27.63%).

Two of §2's bounds I verified independently against the catalogs in `src/model.carbon:100–145` and they are **exactly right**:

- **FDH cabinets provably optimal.** With `FdhSize/FdhCost` = {12:$300, 24:$450, 48:$650, 96:$900, 144:$1200, 288:$1800, 432:$2500}, the min-cost multiset covering 6,719 units is 15×432 + 1×288 = $39,300, and the design pays exactly $39,300. The "one cabinet per area ⇒ Σcapacity ≥ Σunits" relaxation argument is valid. Zero slack. This should be recorded as a permanently closed line.
- **OLT LB reproduces to the cent.** 2,209,500 = 8×$1,200 + $700 + $150 + 137×$85, using the {1,2,4,8,16}-port card catalog added in iter 007. I had assumed this was an arithmetic slip; it is not.

Also correct and worth keeping: §2.2.4's measured negative on reduced-cost fixing (0/23,824 arcs, with the right structural explanation — per-item cost is 300–1,000× smaller than the gap); §3.1(c)'s sizing kill of the compact MCF (1,701 × 47,648 = 81.0M columns — I recomputed it); §3.6's and §4.4's explicit "do not build" verdicts on loss-contracting and global CP-SAT Steiner; §1.9's argument that deterministic farthest-point *is* the derandomised k-means++ and seeding is not the lever; §1.6's verdict that catalog-boundary cluster sizing is worth ~nothing.

§1's source-level diagnosis of `Cluster()` is accurate. I read `stages.carbon:195–356` and `364–436`: assignment is single-pass nearest-seed-with-room over *farthest-point seeds*, `PlaceFdh()` then relocates to a stride-sampled ≤64-candidate medoid and never re-assigns, and `RebalanceClusters()` picks donor = emptiest / receiver = fullest-below-capacity and moves the donor premises minimising `d.seed_dist[recv*12288+p]` with no donor-side term. All three failure modes named in §1.1 are real and verifiable.

And I verified §2's dual ascent implementation (`scratchpad/wong.py`, `wong2.py`) is a *correct* Wong ascent: reduced costs never go negative, every `β_W` sits on a genuine Steiner cut (`k ∈ W`, root excluded), and the 5-seed × 3-root sweep the section claims is actually in `wong2.py`. Pure Python, no numpy. That is the most load-bearing computation in the report and it survives inspection.

---

## (a) Fabricated or misattributed citations

The hit rate is high; roughly 120 citations, of which I could not verify or found wrong the following.

**Confirmed misattributions:**

1. **§3.1: "and it is now provably < 2 — 1.9988 (Chan et al., arXiv:2407.19905, 2024)".** The paper is real and the bound 1.9988 is right, but the authors are **Byrka, Grandoni & Traub** (submitted 29 July 2024). "Chan et al." appears in both the text and §3's source list. Fix the name.

2. **§3.1: "with lower bounds 8/7 (Skutella's example) and 36/31 (arXiv:2405.13773, 2024)".** arXiv:2405.13773 exists ("Lower bounds for the integrality gap of the bi-directed cut formulation of the Steiner Tree Problem"), but the 36/31 ≈ 1.161 bound is due to **Byrka, Grandoni, Rothvoß & Sanità**, not to that paper; that paper's own contribution is the Complete Metric formulation and new heuristics for finding gap instances. It also misses the current best BCR lower bound, **6/5 (Vicari)**, which is strictly stronger than both figures quoted.

3. **§5.10: "Grandoni & Rothvoß, *One tree suffices*, 2010".** Misattributed. *One Tree Suffices: A Simultaneous O(1)-Approximation for Single-Sink Buy-at-Bulk* is **Goel & Post** (FOCS 2010 / Theory of Computing 8:351–368, 2012). Grandoni & Rothvoß 2010 is *Network Design via Core Detouring for Problems without a Core* (ICALP).

4. **§5.1: "Eisenbrand, Grandoni, Rothvoß & Schäfer (SODA 2008) give 3.92".** The published ratio is **4.00** for ConFL (and 2.92 for single-sink rent-or-buy), improving 8.55 and 3.55 respectively. §3.3 quotes it correctly ("4.00 for ConFL and 2.92 for single-sink rent-or-buy"), so the report contradicts itself across sections.

5. **§1.8: "Lorena & Senne (2004, *Networks and Spatial Economics*)".** Year/venue mismatch. Lorena & Senne, *Local search heuristics for capacitated p-median problems*, **Networks and Spatial Economics 3 (2003) 407–419**; the 2004 paper is *A column generation approach to capacitated p-median problems*, **Computers & OR 31:863–876**.

6. **§1.6: "Correia & Captivo (2003, *Location Science*/`Computers & OR` line of work)".** The modular-capacitated Lagrangian heuristic is **Annals of Operations Research 122:141–161 (2003)** — which §2 cites correctly. §1's venue is wrong.

7. **§4.4: "Rehfeldt & Koch, *Networks* 73(2):206–233, 2019".** Author dropped: the paper is **Rehfeldt, Koch & Maher**.

8. **§4.1: "Perron & Didier, *The CP-SAT-LP Solver* (invited talk, CP 2023, LIPIcs vol. 280)".** Venue and volume correct (3:1–3:2); third author **Steven Gay** omitted.

**UNVERIFIED (flag or drop):**

9. **§5.5(a): "Polzin & Daneshmand report **78% average edge removal** on benchmark instances."** I could not confirm that specific figure. Their reduction results are large but strongly instance-class dependent, and quoting a single average across SteinLib as though it transfers to a 10.9%-terminal-density parcel lattice is exactly the extrapolation §3.9 correctly *refuses* to make (§3.9 measured −25% nodes / −19% edges here). The two sections disagree and §5 is the one without evidence.

10. **§4.4: "Rehfeldt & Koch … solving >90% of a benchmark set by reduction alone."** UNVERIFIED in that form.

11. **§2.3: "the practical folklore, confirmed there, is that CFLP Lagrangian bounds run roughly a third of the LP gap."** Cornuéjols–Sridharan–Thizy establish a dominance lattice among relaxations; they do not establish that numeric folklore. UNVERIFIED.

12. **§2.2.2's "1–3% below the bidirected-cut LP optimum"** is *correctly flagged by the author* as an extrapolation. Credit — but see (d), where it turns out to be the wrong direction.

13. **§5.10's Svitkina link** (`10.1007/978-3-642-38016-7_21`) points to an IPCO 2013 chapter, not Svitkina's SODA'08/TALG'10 *Lower-bounded facility location*. The constants (448, and Ahmadian–Swamy's 82.6) are right; the link is not.

**Verified correct against a source, worth crediting:** §3.4's "Balakrishnan, Magnanti & Wong (1989) report **1–3% optimality gaps** … up to ~2 M continuous variables" is accurate — the paper (Oper. Res. 37(5):716–740) reports solutions "guaranteed to be within 1 to 3 percent of optimality in almost all cases" on problems with up to 500 integer and 1.98M continuous variables, in ≤150 s on an IBM 3083. Also verified: Gnägi & Baumann (2021, C&OR 132:105304); Byrka–Grandoni–Traub's 1.9988; EGRS's 4.00/2.92.

---

## (b) Wrong or hand-wavy math

**B1 — §2.4's Lagrangian subproblem is not a valid relaxation as written. This is the most consequential error in the report, because §2 ranks the resulting bound as "the single highest-value unbuilt item in the whole campaign."**

The pseudocode:

```
for k in {2,4,6,8,12}:
    val(k) = TerminalCost(k) + [k<4 ⇒ 100000] + Σ of the k smallest (c_iv − λ_i)
κ_v = min(0, min_k val(k))
```

Two defects.

*(i) The under-4 penalty is on load, not on catalog size.* Verified in `tools/score_design.py:226`: `terminals_under_4 = sum(1 for t in live if t[4] < 4)` where `t[4]` is **ports used**. A 4-port terminal serving 2 premises is penalised; `[k<4]` says it is not.

*(ii) Enumerating only "load == catalog size" restricts the subproblem, which breaks the bound.* The true subproblem allows any load m ≤ k, including "open a 4-port and serve 2 because the third and fourth reduced costs are positive". Restricting the feasible set of a *minimisation* subproblem **raises** κ_v, raises L(λ), and can push it above the true optimum. That is not a conservative error — it is an invalid certificate. The whole point of §2.4 is that it produces "for the first time, a valid lower bound on 212.7M cents of penalty-plus-drop cost."

Fix is easy and should be stated: enumerate load m = 1..12 with `cost(m) = TerminalCost(smallestCover(m)) + 100000·[m<4] + Σ of the m smallest reduced costs`, keep `min(0, ·)`. The rest of the section (dropping the non-separable drop-drop term because it is non-negative; the "sort not knapsack" observation under uniform unit demand) is correct and genuinely well suited to Tier 1.

**B2 — §2.0's "fully unconditional certificate today is score ≥ 319,305,745" is not unconditional.** It retains the row `distribution + feeder cable | LB 11,166,395 | basis: 117,541 m × 95 c/m`. But 117,541 m is the **conditional** dual-ascent bound, computed with the shipped design's terminal nodes as the required set. Once terminal placement is relaxed (which is the entire premise of the unconditional row), that Steiner length is no longer a lower bound on anything. Either recompute the cable term from the group-Steiner run or delete it. The section's own closing warning — "Reporting the conditional bound as if it were unconditional would be exactly the 'optimizing your own yardstick' failure" — applies to its own number.

**B3 — §1.3's headline contradicts its own caveat.** "**Every cell is a connected subgraph, by construction** … the offset-Dijkstra construction gets it to 16 by definition." Three problems:

- The stated dual optimality condition is `argmin_j(d_pj + λ_j/u_p)`. That is an offset multi-source Dijkstra **only when u_p ≡ 1**. True for the district, false for `s06_mdu_block`. Say so.
- Aurenhammer–Hoffmann–Aronov's existence theorem is for **squared-Euclidean power diagrams over continuous measures**. There is no analogous theorem for integer offsets on a graph with atomic demands, and the section does not claim one — but it uses the citation as if there were.
- The connectivity property holds for the shortest-path forest *before* capacities are enforced exactly. The section then concedes "the integer version can leave ±few units of imbalance. Fix: … then run §1.2's transportation repair **restricted to boundary premises** to land capacity exactly, then one final projection pass to restore contiguity." That repair is exactly what can disconnect the cells. The headline and the caveat cannot both be true; the caveat is the truth, and the ranking table's confidence ("→16 is by construction") should be downgraded.
- The price update ("`λ_j += ε` for over-full `j`, `λ_j −= ε` for under-full") is a subgradient sweep, not Bertsekas' auction. It inherits none of auction's ε < 1/n optimality certificate, which is an ε-complementary-slackness condition on individual arcs of an assignment problem, not on a capacity-balancing price loop. "Same optimum" is unsupported.

**B4 — §1.5's tree-cut DP is internally inconsistent.** The merge step prices the kept edge as `cable(w, edge(v,c))`, i.e. as if all `w` units below it send fibre *upward* across it. But `close(c,w)` puts the FDH at the component's unit-weighted 1-median, which is generally *inside* the component and below many kept edges; fibres below the FDH flow the other way and the edge's fibre count is not `w`. Either pin the FDH at the cut node (component root) — in which case the recurrence is consistent and the Kundu–Misra greedy is the correct Tier-1 shadow — or carry the FDH position in the state, which is no longer `O(n·C)`. The complexity claim (`O(n·C)` amortised by the bounded-subtree/tree-knapsack argument) is right for the *stated* recurrence; it is the recurrence that is wrong.

**B5 — §4.2 under-prices inter-column drop–drop crossings.** `w_{jj'} ≥ z_j + z_{j'} − 1` with objective term `20000·Σ w_{jj'}` charges **one** crossing per selected column pair. Two selected columns can contribute several crossing drop pairs. Needs `20000·n_{jj'}·w_{jj'}`. As written the model will systematically prefer configurations with many crossings concentrated in few column pairs.

**B6 — §4.2's "the incumbent is guaranteed to be in the pool" is false.** The claim rests on "order `R(n)` by `(χ, ℓ, id)` and emit the prefixes of length 1..12 — this reproduces exactly the greedy's move set". It does not. The shipped terminals are the product of interleaved new-batch and *attach* moves (`stages.carbon:663` vs `:686`) plus `MergeTerminals`/`TryDissolve` reassignments (`:963`, `:985`); their member sets need not be prefixes under any of the 2–3 stated orders. Consequence: `add_hint` will be uncompletable and CP-SAT will discard it, losing the one advantage the section leans on ("netwerk has an exceptionally strong incumbent … which is precisely the regime where these techniques shine"). Trivial fix — add the incumbent's 1,753 columns explicitly — but it must be stated.

**B7 — §1.7's k-sweep recommends an infeasible design.** "In my `k = 20` run areas ranged **115–436 units**." `MaxUnitsPerFdh()` is 432 (`model.carbon`, and `Cluster()` enforces it). A 436-unit area is not a design; the sweep did not carry the cabinet capacity constraint. Every row of that table, and the cabinets column in particular, has to be re-run before the −11.5%/−15.1% figures mean anything. The section's own flagged risk is a different one (trench invariance); this one is not flagged at all.

**B8 — §5 Fact 3 contains an internal contradiction, and the resolution is more interesting than the section's own conclusion.** It asserts "a node *v* can host at most `deg(v)` zero-crossing drops" and separately that only **3,234** nodes have degree ≥ 4 — yet reports "**4,272** nodes can host ≥4 zero-crossing drops". Both can hold only because `proper_cross` excludes endpoint touches (confirmed in `tools/score_design.py`, where the street-crossing loop additionally does `if a == tn or b == tn: continue`). A drop that passes exactly **through** a lattice vertex crosses nothing. On a rectilinear parcel lattice that is common, not exotic. So the `deg(v)` ceiling is wrong, the "42% structurally forced" figure that rests on it is unsupported, and there is a real latent property of the geometry nobody in the report has noticed. See (e)3.

**B9 — §5.3's "floor" is an estimate, not a bound.** "a crude but defensible floor for the combined crossing + under-4 budget is therefore ~2,832 × 40,000 ≈ 113M cents." It is derived from a **greedy** max-coverage (which does not prove 3,887 is maximal zero-crossing coverage) and from an asserted 40,000 c/premises where the section's own text gives ≥33,333 for the under-4 route. Then §5.3 says "Anyone proposing to chase crossings should be shown this number first" — a greedy is not a certificate, and §2.4 is the machinery that would make it one. §5 should defer to §2.4 rather than presenting its own heuristic as a floor.

**B10 — §1.2 conflates premises-level and terminal-level granularity.** "in the district every premises has `units = 1` … so the LP *is* the integer optimum, with no rounding needed" is true at premises granularity. But every number in §1.0(ii) was measured on **terminals**, with u_t ∈ {2..12}, where the transportation LP permits splitting one terminal's fibres across two FDHs — physically impossible, and precisely the single-sourcing constraint that makes the problem NP-hard. The follow-on sentence about MDUs ("I measured only 29 of 1,753 terminals fractional at the optimum") gives the game away: those 29 exist because the measurement was at terminal granularity, not because of `s06_mdu_block`. The "exact transportation optimum, same 16 sites: 6,001,567 (−39.7%)" is an optimum of a *relaxation* and should be labelled as a lower bound on the assignment cost.

**Smaller math slips, for completeness:**

- **§2 Result 2: "already banks a third of that."** 2,980,500 / 25,552,500 = **11.7%**, not a third.
- **§2.2.1:** "the aggregated LP already forces `Σ_j y_j ≥ 15.55`, so the facility-cost term is bounded below by 15.55 × $2,500". With a modular catalog spanning $300–$2,500 the LP opens cheap small cabinets; multiplying by the *largest* cabinet's price is not a bound. Conclusion (negligible) is unaffected.
- **§1.6:** "The single imperfect area (239 units in a 288 cabinet) could at best be re-shaped to save one catalog step ≈ $300–$600." With the other 15 areas at exactly 432 there is nowhere to move the surplus; at k = 16 the achievable saving is **$0**. This *strengthens* §1.6's verdict.
- **§2 Result 4 splitter row:** 2,460,000 is computed on 4,368 take-ports; the design reports 4,371 (`splitter_ports: 4371/4386`), giving 2,466,000. Both are valid LBs (the smaller is looser). Negligible, but the input should match the report.
- **§5.2:** "then `p1p2t2t1` is a convex quadrilateral and the diagonals exceed the opposite sides". The convex order is p1, p2, t1, t2; the crossing segments are the diagonals of `p1p2t1t2`. The inequality is correct (triangle inequality through the crossing point); the vertex labelling is not.

---

## (c) Inapplicable to netwerk

**C1 — §1.2/§1.3's cable gains are measured under a cost model the engine abandoned at iter 005, and the error is directional, not just scalar.** The measurements come from "my own per-cluster shortest-path-tree simulator … over-states the engine's actual distribution-cable BOM by 1.30×", and the section handles this by quoting ratios. That is not enough. On a **shared** Steiner tree with a concave catalog (12f = 7.92 ¢/fibre-m → 288f = 2.71 ¢/fibre-m, a 2.9× economy of scale that §3.7 measures correctly), an extra fibre-metre on a corridor that already carries a 288f cable is ~2.7 ¢, whereas on a per-cluster SPT it is priced near standalone rates. The simulator therefore over-states *the sensitivity of cost to assignment*, not merely its level. §1.5 states the correct structural fact — "**trench is close to invariant under re-clustering, and clustering's whole leverage is on *cable riding `T`***" — and then §1.2/§1.3 never fold it back into their numbers. Every "−42.9%" and "−47.9%" needs re-measuring on the shared tree, i.e. by re-routing terminal→FDH along `T` and re-summing per-edge catalog sizes, which is cheap.

**C2 — §1's contiguity measurement is on the wrong graph.** "On a 4-nearest-neighbour terminal adjacency graph the 16 serving areas break into **615 connected components**." A 4-NN proximity graph over 1,753 terminals is a sparse artificial graph; a cluster can be perfectly connected in the road graph and shatter under 4-NN, because 4-NN edges are not road edges and the cluster's own boundary geometry can starve a terminal of same-cluster neighbours. The number that matters — and the only one the engine can act on — is the component count of the road-graph-induced subgraph on each area's snap nodes. Until that is measured, "shredded" is unproven, and the 615 → 123 → 16 chain that carries §1.3 to the top of §1's ranking is soft. (I am not saying the areas are contiguous — capacity binds at 432 in 15 of 16 areas, so blocking is certainly happening. I am saying the evidence presented does not establish the magnitude.)

**C3 — §5.3's "add a 3-port terminal to the catalog" does not work.** "if a 3-port terminal exists in the real catalog, adding it converts a large share of 51.1M of penalty into ~$100 of hardware — this is a *catalog* fix, exactly like iter 007's FDH pedestals." The penalty is keyed to **load**, not catalog size: `tools/score_design.py:226`, `terminals_under_4 = sum(1 for t in live if t[4] < 4)` with `t[4]` = ports used. Adding a 3-port SKU changes hardware cost by ~$20/unit and leaves all 511 penalties in place. The analogy to iter 007 fails: that iteration moved `util_*` metrics that are *defined against the catalog*; this is a fixed constant in the scorer, and moving it is precisely the "do NOT silently relax the scorer" move the backlog's Open Question forbids.

**C4 — §5.8's ε-ladder probe as specified cannot produce a consistent sweep.** "sweeping the crossing coefficient in `PackTerminals` (**it is a single constant, line 663**)". It is not. `grep -n 50000 src/stages.carbon` gives **663** (new-batch), **686** (attach), **963** and **985** (dissolve/merge target ranking); the 100,000 under-4 constant appears at **666, 691, 922, 988**. Sweeping only 663 reprices new-batch moves against unrepriced attach and merge moves; the resulting curve measures that inconsistency, not `∂capex/∂crossings`. The probe is a genuinely good idea — §5.8 is right that it is the cheapest information in the report — but it needs all four sites parameterised.

**C5 — §3.5's Dreyfus–Wagner LNS states a budget it cannot meet with the neighbourhood it proposes.** "k ≤ 8–10 per ball is the Tier-1 budget" and "300–400 balls at k = 8". But §3.0 measures 1,702 required nodes in 15,668 (10.9% density) and §3.9 measures that reductions only give −25%/−19%. A 400-node ball on this instance contains ~40 required nodes, not 8. Balls must be selected by *required-node count*, not by radius or edge budget — and once you do that, most balls are geometrically tiny and the multi-path reconfigurations the technique is supposed to find mostly are not inside them. The 0.5–2% estimate is not supported for this instance.

**C6 — §3.7's slope scaling is pointed at a bottleneck it cannot move, and §3 says so and then ranks it anyway.** "$306,423 is 39,285 m of 288f — an artefact of centralized split … **Slope scaling redistributes flow, it does not change that arithmetic**." Exactly right. The only levers on that $306k are smaller serving areas (a 288-unit area needs 317 fibres = one 288f + one 48f, vs a 432-unit area's 476 = two cables — §1.6's mechanism) or distributed split. §3 should cross-reference §1.7 there instead of ranking slope scaling at #9 with a "risk of negative".

**C7 — §4.1's determinism story is right, and needs one addition.** "run CP-SAT as an **offline oracle that emits an overrides file** … and let the Carbon engine consume the overrides deterministically and *re-price them with its own scorer*" is the correct architecture and it matches backlog item 9. Missing: the overrides file itself becomes a golden artifact and must be **checked in**, not regenerated in CI, or the OR-Tools version pin leaks into the byte-exact gate through the back door.

**C8 — nobody checked the fixed-array headroom.** `MaxNodes() = 16384` against 15,668 district nodes; `MaxEdges() = 49152` against 23,824. §3.8's hop-constrained layered graph, §3.3's Tier-2 augmented-graph ConFL, and §5.6's face/block coarsening (which *adds* supernodes) all need node budget the fixed-size store does not have — 716 spare nodes. That is a hard Tier-1 constraint and it is unmentioned in all five sections.

---

## (d) Overclaimed gains

**D1 — the aggregate is impossible and only §5 admits it.** Summing each section's top-ranked Tier-1 items: §1 ~20–33M, §2 ~3M, §3 ~45–60M, §4 ~26–80M, §5 ~45–89M — call it 140–265M cents, 14–27% of score, from passes that all touch the same three decisions. §5 is the only section that says "Gains are not additive … A realistic combined ceiling for the whole list is 80–150M cents", and it says it only about its own list. The cross-section double counting is worse than the within-section kind:

- **§3.3 (priced spur re-siting), §4 row 2 (marginal-trench term τ(n)), §5.1 (interleaved ConFL grow-and-open), §5.7 (GLS on trench edges)** are four fidelities of *one* idea: put the trench price inside terminal siting. Estimates: 30–45M, 8–25M, 24–48M, 6–12M. Only §3.3 is measured end-to-end.
- **§1.2/§1.3, §1.5, §2.7, §5.9** are four presentations of *fix the FDH partition/assignment*, against a total addressable pool of distribution + feeder cable = $519,961 = **52.0M cents**. §1.3's 20–33M claim is 38–63% of that entire pool including the parts the shared tree makes insensitive.

**D2 — §2's own prediction is falsified by §3's own measurement, and neither section notices.** §2 certifies ≤ 25,552,500 cents of trench slack at the fixed required set, then predicts "the true achievable trench saving is likely **1–2%, i.e. 6–12M cents**". §3.2 then *measures* **−2.55% (−15.5M cents)** from key-path local search alone — 61% of the entire certified slack, from a single neighbourhood. Either §2's extrapolated DA-to-LP correction is too pessimistic for this instance, or §3's measurement is inflated (see D3). This is the single most valuable cross-check available and the report does not perform it. My reading: §2's DA bound is **looser than it thinks**, for a structural reason visible in `wong.py` — the ascent deactivates a terminal the moment its saturated component touches another *active* terminal (`if v!=k and act[v]: other=True; break`), so at 10.9% terminal density components stay tiny and the ascent stops early. That is why it runs in 0.9 s of pure Python, and it is why the "1–3% below the BCR LP" figure (extrapolated from sparse SteinLib-like instances) does not transfer. Read 4.22% as "≥4.22% of slack cannot be certified away", not "trench is 4.22% from optimal".

**D3 — §3's absolute dollar figures are computed on a graph that does not match the engine, and the excuse is unnecessary because the fix is known.** §3 says "My measurements use my own `round(hypot)` edge lengths, giving 123,784 m vs the engine's 123,045 m — a 0.6% high base; quote the percentages, not the absolutes." But §2's `wong.py` uses `math.isqrt` (floor) and reproduces the engine's 123,045 m **exactly**. So this is a fixable convention bug, not an inherent modelling gap — and it matters beyond the totals: §3.2's key-path exchanges and §3.3's spur line search were run under edge weights that differ from the engine's, which changes *which* exchanges are improving, not just by how much. Re-run both with `isqrt` before banking −$155,265 and −$420,021.

**D4 — §5's Fact 2 marginal-trench coefficient is ~2× too high, and §3 already contains the refutation.** §5 derives "**~210,000 cents per terminal**" from an *arc* elasticity across iter 004 (3,000→1,700 required nodes, 190,299→134,276 m). That transition also swapped premises snap nodes for consolidated terminal nodes, so it is not a marginal rate at the current point. §3.0's direct measurement is decisive: only **35,387 m (28.6%) of trench serves exactly one required node**, i.e. ~20 m/terminal averaged over 1,753, and §3.3's priced line search recovers 15,378 m over 396 moves. The marginal terminal is worth ~90,000 cents at the top of the distribution and ~0 in the middle. §5's framing — "four times the street-crossing penalty and twice the under-4 penalty … while a 210k term floats free" — should be halved, and the section's headline ranking (#5, 24–48M) with it. The *direction* of the argument is right and is, in my view, the report's single best structural insight; the coefficient is not.

**D5 — §4 row 1 (port budget as an in-loop constraint, 10–30M) over-attributes.** "the pure greedy simulation reached ~1,550 crossings and the shipped engine lands at 2,238, i.e. the floor repair is buying roughly 688 crossings ≈ **34.4M cents**." The backlog's own text (item 3b) attributes that gap to *three* causes: "the greedy's per-move pricing (marginal, not global) **and** the merge repair still leave gap vs the ~1,550 … The binding tension is now utilization-floor vs crossings". Charging all 688 to the floor repair is unsupported. More importantly the proposed fix does not remove the floor — it is a hard QA gate, and making it an in-loop constraint changes *where* you pay, not *whether*. My estimate: **5–15M**.

**D6 — §2.4's dichotomy is not decidable until B1 is fixed.** "either (a) the bound comes in near 200M, proving the packing is nearly optimal … or (b) it comes in near 120M, in which case there is ~90M cents (9% of score) of certified, addressable slack." With the load-vs-catalog-size bug the bound as coded comes in **high**, which looks like outcome (a) — the exact wrong conclusion, and the expensive one, because it would close three backlog items that are actually open.

**D7 — one item I would raise, not lower.** §1's ranking #1 — "re-seed `seed_dist` from the medoids and re-run assignment", ~20 lines, 3–8M — is well-supported. The defect is verified in source: `Cluster()` assigns against farthest-point seeds (`stages.carbon:230–290`), `PlaceFdh()` relocates to a medoid and never re-assigns (`:364–436`), and `RebalanceClusters()` then degrades the assignment further to defend a cabinet-packing objective worth, at the current k, **about $700** (15×432+288 = $39,300 vs a balanced 16×432 = $40,000 — and balanced still clears the 95% `util_fdh_capacity` gate at 97.2%). That is the cleanest instance of the campaign's own scar-tissue rule in the whole repo. Confidence should be "high", not "high — subset of #2".

---

## (e) Missing big ideas

**E1 — nobody costs the cheap fix for the largest measured seam number in the report.** §1.0(iv) measures "**81** [under-4 terminals] have a spare-port host within 150 m only in another serving area", worth 8.1M cents plus hardware. §1's remedy is to re-architect clustering (§1.3 ~200 lines + §1.5 ~300 lines + a stage reorder); §4's is a CP-SAT model; §5's is VLSN cyclic exchange. The backlog's item 2 already names the cheap answer — "**cross-cluster dissolve targets (needs per-cluster fiber bookkeeping)**" — and that is a bookkeeping change in `TryDissolve`/`MergeTerminals` (`stages.carbon:889–1099`), not a new algorithm. Nobody estimates it. On the report's own numbers it captures most of the 8.1M for a fraction of the effort of any of the three proposed alternatives. This is the largest omission across all five sections.

**E2 — nobody raises the snap-to-node modelling gap the engine itself documents, which sits under an 11.3%-of-score block.** `stages.carbon:157–160`: *"v0 snaps to the nearest graph node (SCOPE.md stage 2 snaps to **drop candidates along edges**; node snapping is the documented simplification — it only ever over-estimates drop length, never under)."* Drop cable is 193,937 m over 6,719 drops = 28.9 m mean = 29.1M cents, and the drop-assembly block is another 80.6M. Snapping to points *along* edges would shorten every drop and — far more importantly — would change the zero-crossing incidence structure that §5 Fact 3 and §4's whole column-pool geometry rest on. Five sections analysed the packing problem; none noticed that its input geometry is a documented approximation with a known sign.

**E3 — nobody notices, audits, or decides on the "drop through a lattice vertex is free" property.** From B8: `proper_cross` excludes endpoint touches, and the street-crossing loop additionally skips edges incident to the drop's own terminal node. On a rectilinear lattice, a drop that passes exactly through an intermediate node incurs zero street-crossing penalty. That is either (i) a real geometric affordance the packer should seek (align drops through corners, which is cheap to detect with the existing exact integer orientation predicate) or (ii) a scorer artifact that should be tightened before anyone optimises against it. It bounds §5.3's "42% structurally forced" and it decides whether §4's crossing estimates are meaningful. Given the backlog's explicit "do NOT silently relax the scorer" rule, this needs a decision, not silence.

**E4 — four of five sections' best neighbourhood-search ideas share one prerequisite, and nobody ranks the prerequisite.** §3.2/§3.5, §4.5/§4.6, §5.4/§5.7 all require many evaluations per second. §5.7 is the only place it is named — "ALNS ceiling is genuinely high … but is gated by an **incremental scorer**: at 11 s per full evaluation you get ~5 iterations, which is worthless" — and it then ranks the full ALNS at #11 rather than ranking the delta-evaluator at #1. An `O(changed)` delta scorer over the six score terms is a bounded, deterministic, pure-integer Tier-1 piece of work that unlocks perhaps 60% of the report's proposals. It should be an item, with an effort estimate, in somebody's table.

**E5 — everybody cites the k²/4 crossing law; nobody measures its local slope.** The shipped terminal mix (492×2p, 822×4p, 366×6p, 68×8p, 5×12p; mean load 3.83) shows the engine has already bought deep into the small-terminal regime. Whether the marginal crossing per added port is still ~k/2 at *this* operating point determines whether §5.3's floor, §4.2's "~1,600–1,700 crossings" target, and §3.3's crossing-delta pricing are anywhere near right. It is one afternoon with the existing `CountDropCrossings` and the edge grid, and it is the only measurement that can distinguish "crossings are exhausted" from "crossings are 40M of live money".

**E6 — the QA-gate invariant is stated for some move classes and not others.** §3.3 correctly argues its re-siting is port-neutral ("re-siting changes no port counts, so the 95.0% terminal-port utilization floor is untouched"). §5.2 correctly argues 2-opt uncrossing is load-preserving. But §5.4's **cyclic** multi-way exchange is *not* load-preserving in general (a k-cycle can leave subset cardinalities changed if the entering and leaving elements differ in units, and can push a terminal below 4), and §5.4 never says so; nor does §4.6's geographic-window LNS say what happens to `Σ installed_ports ≤ 7072` when a window is re-packed in isolation. Every move set should carry an explicit line on (a) port budget, (b) under-4 count, (c) `route_length_budget` (18,060 of 20,000 m — §3.2 is the only place this guard is stated, and it is mandatory).

**E7 — no section proposes bounding the *penalty* block by anything cheaper than §2.4.** §2 correctly identifies that "65.6% of the certified gap is the penalty budget, on which netwerk has *no* bound at all", and then proposes a 5–8-day Lagrangian/volume build. There is a much cheaper partial bound available and nobody offers it: a *matching-based* bound on drop-drop crossings (the uncrossing lemma of §5.2 says the min-total-length transportation solution is non-crossing, so the drop-drop term's floor is 0 wherever the 150 m and street-crossing constraints do not bind — computable exactly by min-cost flow on the existing terminal sites), and an exact per-node bound on street crossings from the incidence structure §5 already enumerated. Neither closes the whole 176.7M, but both are days, not weeks.

---

## Ranked: the 5 techniques most likely to actually reduce netwerk's score

1. **Priced terminal re-siting along private trench spurs (§3.3).** The only large gain in the report measured end-to-end against the scorer's own exact crossing predicate, and it ships with its own negative control — "an unpriced repair pass converts a **$1.48 M** trench win into a **$0.61 M** loss", 4,008 new street crossings at 11.1 m of soft trench each — which is precisely the failure mode the campaign already paid to learn. It is port-neutral (QA and the 95.0% floor cannot move), it shortens CO→premises paths so the 18,060/20,000 m budget is safe, and it reuses `CountDropCrossings` and the 128 m grid. Haircuts: re-run with `isqrt` edge lengths (D3), price the drop-drop term it skipped, update `cnt[]` after each accept. My estimate **20–35M cents**, against the section's 30–45M. ~250 lines, Tier 1.

2. **Key-path (and key-vertex) local search on the trench tree (§3.2, §5.5b).** Measured to converge in 3 rounds; preserves the tree so `rings = 0` holds by construction; reuses `ForestBfs`, `DijkstraReset`/`AddSource`/`HeapPop`. Two mandatory conditions: re-measure with the engine's floor-sqrt lengths, and enforce the `route_length_budget` guard §3.2 correctly identifies. §2's dual bound (25.55M ceiling at the fixed required set) says this cannot be worth 15.5M *and* leave room for anything else in the trench-quality family — one of the two sections is wrong and the cheapest way to find out is to build both this and §2's `DualBound` stage in the same iteration. My estimate **8–15M cents**. ~200 lines, Tier 1.

3. **Trench price `π_v` inside the terminal-packing move cost — the two-sweep Gauss–Seidel version first (§5.1b, §4 row 2).** This is the one structural claim all five sections independently converge on, and it is verifiable in source: `TrenchCostPerM` appears **once** in `stages.carbon`, at `:1346` inside `DeloopTrench`'s Dijkstra, and nowhere in `PackTerminals`, `TryDissolve` or `MergeTerminals`. The stage that chooses which 1,688 nodes the trench must reach cannot see the cost of reaching them. The 40-line version — one multi-source Dijkstra from the routed tree, add `π_v` to the four move-price sites, re-run, keep the better-scoring sweep — cannot regress and immediately measures the true coefficient, which I expect to come in near **90,000 cents/terminal at the top of the distribution and ~0 in the middle**, not §5's flat 210,000 (D4). My estimate **5–15M cents**, and the information value exceeds the direct gain because it is the on-ramp to #1 and it settles §5's central number. Tier 1.

4. **Priced 2-opt drop uncrossing (§5.2).** Smallest implementation in the report (~120 lines), provably terminating (strictly decreasing non-negative integer objective), and load-preserving — so hardware, under-4 counts, fibre accounting and the exactly-95.0% port floor are all untouched, which makes it the rare pass that cannot spend budget elsewhere. The structural argument is verified: `proper_cross` excludes shared endpoints, so drops sharing a terminal never cross, so **all 684 crossings are inter-terminal** and are a property of the assignment alone. Restrict v1 to same-serving-area pairs (cross-cluster needs the same fibre bookkeeping as E1, which is an argument for doing E1 first). My estimate **8–13M cents**, matching §5's own band. Tier 1.

5. **Exact premises→FDH assignment at the existing 16 sites (§1.2), preceded by the ~20-line re-seed of `seed_dist` from the medoids (§1.1 item 2).** The diagnosis is verified in source and is the campaign's own rule firing in stage 3b: the design optimises assignment against farthest-point reference nodes it does not build, then `RebalanceClusters` degrades that assignment further to defend a cabinet-packing objective worth about **$700**. The successive-shortest-path repair condensed on k ≤ 32 facilities is exact, integer, allocation-free and deterministic — it is the correct Tier-1 answer and §1 is right that Tier 2 buys nothing here. But bank it at **5–12M cents**, not §1.3's 20–33M: the addressable pool is $519,961 of distribution + feeder cable, the measurements were taken on a per-cluster SPT simulator that over-states assignment sensitivity under a concave shared-tree catalog (C1), and the 615-component contiguity evidence is measured on a 4-NN proxy rather than the road graph (C2). Prefer §1.2's transportation repair over §1.3's power-diagram construction until contiguity is re-measured properly, and do **not** ship §1.7's k-raise until the k = 20 run is re-done under the 432-unit cap (B7).

**Explicitly not in the five, with reasons.** §2's Wong dual ascent should still be built — it is the best instrument in the report, it is honest about its conditionality, and it produces two permanently closed lines (cabinets provably optimal, OLT within 0.56M) — but its direct score gain is 0 and its measured by-product is 2.98M, so it ranks on decision value, not on score. §4's CP-SAT set partitioning owns the largest pot (226.4M) and is the right long-run model, but it is gated on interop, on the conflict-pricing fix (B5), on the pool-completeness fix (B6), and on a conflict-enumeration cost that is asserted rather than derived. §5.4's cyclic exchange is the right generalisation of the campaign's three failed representations and I expect it to work — but it is unmeasured and it does not state its capacity/QA invariants (E6). And §1.6, §2.1, §3.6, §3.7, §4.4 (global), §4.7 row 13 and §5.10 are all correct "do not build" verdicts that should be recorded in `docs/IMPROVEMENT_BACKLOG.md` as argued negatives — that is real output and the report should get credit for it.
