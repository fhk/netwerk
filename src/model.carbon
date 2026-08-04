// netwerk — design rules, equipment catalog, and the Design working store.
//
// SCOPE.md specifies rules and catalog as user-editable data. The Carbon
// toolchain has no file I/O yet, so in v0 both live here as named functions —
// one place to edit, still never scattered through the pipeline code.
// All lengths are integer meters, all money integer cents: the engine is
// pure integer arithmetic, which makes runs bit-identical by construction.

library "model";

// ---------------------------------------------------------------------------
// Design rules (SCOPE.md: rules.yml)
// ---------------------------------------------------------------------------

// Premises served per PON port at the largest split (1:32 centralized).
fn SplitterRatio() -> i32 { return 32; }
// Hard capacity limit per FDH serving area, in premises units.
fn MaxUnitsPerFdh() -> i32 { return 432; }
// Hard limit premises -> terminal, meters.
fn MaxDropM() -> i32 { return 150; }
// Optical budget proxy: max route meters CO -> premises.
fn MaxRouteM() -> i32 { return 20000; }
// Day-one take rate, percent of units provisioned with split capacity.
fn TakeRatePct() -> i32 { return 65; }
// Spare fibers added to distribution cable demand, percent.
fn SparePct() -> i32 { return 10; }
// Minimum port/capacity utilization for port-bearing equipment, percent.
// Enforced as a QA error: designs that strand capacity fail the gate.
fn UtilizationFloorPct() -> i32 { return 95; }

// ---------------------------------------------------------------------------
// Equipment catalog and cost model (SCOPE.md: catalog.yml), costs in cents.
// Every lumpy component comes in graduated sizes so remainders round into
// the smallest covering unit instead of stranding a large one.
// ---------------------------------------------------------------------------

fn CableSizeCount() -> i32 { return 6; }

fn CableSize(idx: i32) -> i32 {
  if (idx == 0) { return 12; }
  if (idx == 1) { return 24; }
  if (idx == 2) { return 48; }
  if (idx == 3) { return 96; }
  if (idx == 4) { return 144; }
  return 288;
}

// Cable material cost per meter by catalog index.
fn CableCostPerM(idx: i32) -> i64 {
  if (idx == 0) { return 95; }    // 12f  $0.95/m
  if (idx == 1) { return 130; }   // 24f  $1.30/m
  if (idx == 2) { return 210; }   // 48f  $2.10/m
  if (idx == 3) { return 340; }   // 96f  $3.40/m
  if (idx == 4) { return 470; }   // 144f $4.70/m
  return 780;                     // 288f $7.80/m
}

// Splitters: 1:2 / 1:4 / 1:8 / 1:16 / 1:32. The 1:2 tap is standard PON
// kit and closes the remainder gap — a 26-port demand had to buy a 1:32
// (81% utilization) when 16+8+2 covers it exactly.
fn SplitterSizeCount() -> i32 { return 5; }

fn SplitterSize(idx: i32) -> i32 {
  if (idx == 0) { return 2; }
  if (idx == 1) { return 4; }
  if (idx == 2) { return 8; }
  if (idx == 3) { return 16; }
  return 32;
}

fn SplitterCost(idx: i32) -> i64 {
  if (idx == 0) { return 4000; }    // 1:2   $40
  if (idx == 1) { return 6000; }    // 1:4   $60
  if (idx == 2) { return 9000; }    // 1:8   $90
  if (idx == 3) { return 12000; }   // 1:16  $120
  return 18000;                     // 1:32  $180
}

// Access terminals: 2 / 4 / 6 / 8 / 12 drop ports (the standard MST lineup).
fn TerminalSizeCount() -> i32 { return 5; }

fn TerminalSize(idx: i32) -> i32 {
  if (idx == 0) { return 2; }
  if (idx == 1) { return 4; }
  if (idx == 2) { return 6; }
  if (idx == 3) { return 8; }
  return 12;
}

fn TerminalCost(idx: i32) -> i64 {
  if (idx == 0) { return 8000; }    // 2-port  $80
  if (idx == 1) { return 12000; }   // 4-port  $120
  if (idx == 2) { return 15000; }   // 6-port  $150
  if (idx == 3) { return 18000; }   // 8-port  $180
  return 25000;                     // 12-port $250
}

// FDH cabinets: capacity in premises units served. Small pedestals are
// standard kit for cul-de-sacs and short streets — without them a
// 24-home build had to buy a 144-unit cabinet (16.6% utilization).
fn FdhSizeCount() -> i32 { return 7; }

fn FdhSize(idx: i32) -> i32 {
  if (idx == 0) { return 12; }
  if (idx == 1) { return 24; }
  if (idx == 2) { return 48; }
  if (idx == 3) { return 96; }
  if (idx == 4) { return 144; }
  if (idx == 5) { return 288; }
  return 432;
}

fn FdhCost(idx: i32) -> i64 {
  if (idx == 0) { return 30000; }   // 12-unit  pedestal $300
  if (idx == 1) { return 45000; }   // 24-unit  pedestal $450
  if (idx == 2) { return 65000; }   // 48-unit  cabinet  $650
  if (idx == 3) { return 90000; }   // 96-unit  cabinet  $900
  if (idx == 4) { return 120000; }  // 144-unit cabinet  $1200
  if (idx == 5) { return 180000; }  // 288-unit cabinet  $1800
  return 250000;                    // 432-unit cabinet  $2500
}

// OLT line cards: 1 / 2 / 4 / 8 / 16 PON ports; a chassis holds 16 card
// slots. The 1- and 2-port entries model pluggable/micro-OLT kit, which
// is what a handful of PON ports actually gets deployed on — the 4-port
// floor left a single-splitter build at 25% port utilization.
fn OltCardSizeCount() -> i32 { return 5; }

fn OltCardPorts(idx: i32) -> i32 {
  if (idx == 0) { return 1; }
  if (idx == 1) { return 2; }
  if (idx == 2) { return 4; }
  if (idx == 3) { return 8; }
  return 16;
}

fn OltCardCost(idx: i32) -> i64 {
  if (idx == 0) { return 15000; }   // 1-port  pluggable $150
  if (idx == 1) { return 22000; }   // 2-port  micro-OLT $220
  if (idx == 2) { return 40000; }   // 4-port  card      $400
  if (idx == 3) { return 70000; }   // 8-port  card      $700
  return 120000;                    // 16-port card      $1200
}

fn OltChassisCardSlots() -> i32 { return 16; }

// Surface classes for road edges.
fn SurfaceSoft() -> i32 { return 0; }
fn SurfaceAsphalt() -> i32 { return 1; }

// Trench/civil cost per meter by surface class; dominates total capex.
fn TrenchCostPerM(surface: i32) -> i64 {
  if (surface == SurfaceAsphalt()) { return 15000; }  // $150/m
  return 4500;                                        // $45/m soft
}

fn DropUnitCost() -> i64 { return 12000; }         // drop assembly, $120
fn DropCablePerM() -> i64 { return 150; }          // drop cable, $1.50/m
fn OltPortCost() -> i64 { return 8500; }           // OLT PON optics share, $85

// ---------------------------------------------------------------------------
// Capacities of the fixed-size working store.
// ---------------------------------------------------------------------------

fn MaxNodes() -> i32 { return 16384; }
fn MaxEdges() -> i32 { return 49152; }
fn MaxPremises() -> i32 { return 12288; }
fn MaxClusters() -> i32 { return 32; }
fn MaxTerminals() -> i32 { return 4096; }

// ---------------------------------------------------------------------------
// The Design object: one instance is the unit of work handed through every
// pipeline stage (SCOPE.md's project store, minus the file behind it).
// ---------------------------------------------------------------------------

class Design {
  impl as Core.UnformedInit {}

  fn Make() -> Design {
    returned var d: Design;
    d.node_count = 0;
    d.edge_count = 0;
    d.adj_count = 0;
    d.prem_count = 0;
    d.cluster_count = 0;
    d.term_count = 0;
    d.co_node = -1;
    d.total_units = 0;
    d.heap_size = 0;
    d.assign_cost_seed = 0;
    d.assign_cost_lloyd = 0;
    d.assign_cost_exact = 0;
    d.assign_cycles = 0;
    d.assign_moved = 0;
    d.assign_stop = 0;
    var i: i32 = 0;
    while (i < MaxNodes()) {
      d.adj_head[i] = -1;
      d.node_pi[i] = 0;       // sweep 1 prices trench at zero, as before
      d.pi_bought[i] = false;
      ++i;
    }
    var e: i32 = 0;
    while (e < MaxEdges()) {
      d.dist_fibers[e] = 0;
      d.feeder_fibers[e] = 0;
      d.trench_used[e] = false;
      ++e;
    }
    var c: i32 = 0;
    while (c < MaxClusters() * SplitterSizeCount()) {
      d.fdh_split_by_size[c] = 0;
      ++c;
    }
    return var;
  }

  // --- road graph nodes ---
  var node_count: i32;
  var node_x: array(i32, 16384);
  var node_y: array(i32, 16384);

  // --- road graph edges (undirected) ---
  var edge_count: i32;
  var edge_from: array(i32, 49152);
  var edge_to: array(i32, 49152);
  var edge_len: array(i32, 49152);
  var edge_surface: array(i32, 49152);

  // --- adjacency lists (two directed half-edges per edge) ---
  var adj_count: i32;
  var adj_head: array(i32, 16384);
  var adj_next: array(i32, 98304);
  var adj_to: array(i32, 98304);
  var adj_edge: array(i32, 98304);

  // --- premises ---
  var prem_count: i32;
  var total_units: i32;
  var prem_x: array(i32, 12288);
  var prem_y: array(i32, 12288);
  var prem_units: array(i32, 12288);
  var prem_snap_node: array(i32, 12288);
  var prem_drop_len: array(i32, 12288);
  var prem_cluster: array(i32, 12288);
  var prem_terminal: array(i32, 12288);

  // --- serving areas / FDH sites ---
  var cluster_count: i32;
  var seed_node: array(i32, 32);
  var cluster_units: array(i32, 32);
  var cluster_prems: array(i32, 32);
  var cluster_take_units: array(i32, 32);  // units provisioned at take rate
  var fdh_node: array(i32, 32);
  var fdh_splitters: array(i32, 32);       // total splitter count (all sizes)
  var fdh_split_by_size: array(i32, 160);  // [cluster * 5 + size_idx]
  var fdh_size_idx: array(i32, 32);        // chosen cabinet size per cluster
  var fdh_route_len: array(i32, 32);       // feeder route meters CO -> FDH
  // Graph distance premises <- each cluster seed, row-major [seed][premises].
  // Dead after stage 3b; stage 6 (PackTerminals) reuses it as the packing
  // pair table — up to 196608 (hi, lo) i32 pairs: hi = crossings * 65536 +
  // drop_m, lo = premises id. The Design object lives on the stack, so new
  // scratch must reuse dead arrays instead of growing the class.
  var seed_dist: array(i32, 393216);       // 32 x 12288

  // --- access terminals ---
  var term_count: i32;
  var term_node: array(i32, 4096);
  var term_cluster: array(i32, 4096);
  var term_ports_used: array(i32, 4096);
  var term_size_idx: array(i32, 4096);     // catalog size chosen at close
  var term_path_len: array(i32, 4096);     // tree route meters terminal -> FDH

  // --- CO / OLT ---
  var co_node: i32;

  // --- per-edge cable/trench usage (design results) ---
  var dist_fibers: array(i32, 49152);
  var feeder_fibers: array(i32, 49152);
  var trench_used: array(bool, 49152);
  // Spanning-forest membership of the used trench (stage 9, DeloopTrench).
  var forest_edge: array(bool, 49152);

  // --- distribution-tree working state (reset per serving area) ---
  var in_tree: array(bool, 16384);
  var tree_parent_node: array(i32, 16384);  // toward the FDH
  var tree_parent_edge: array(i32, 16384);
  var node_path_m: array(i32, 16384);       // tree route meters node -> FDH
  var node_units: array(i32, 16384);        // demand units snapped per node

  // --- connected-facility-location trench price (stage 6, iter 008) ---
  // node_pi[v] = marginal trench cents to bring the ROUTED trench to v,
  // i.e. the ConFL dual price the packing move cost was missing. Zero for
  // every node the trench already touches, and identically zero on the
  // first sweep (which therefore reproduces the pre-iter-008 design).
  // pi_bought[v] = a terminal has already been sited at v this sweep, so
  // the spur to v is paid for and further moves there price it at zero.
  var node_pi: array(i32, 16384);
  var pi_bought: array(bool, 16384);

  // --- priced 2-opt drop uncrossing (stage 9b, iter 009) ---
  // Every drop-drop crossing is inter-terminal (ProperCross excludes shared
  // endpoints), so the uncrossing pass reports what the ASSIGNMENT could not
  // repair: how many crossings survive, and how many of those are pairs in
  // different serving areas — the swaps v1 refuses for want of per-cluster
  // fiber bookkeeping (backlog item 2).
  var ux_swaps: i32;
  var ux_rounds: i32;
  var ux_residual: i32;
  var ux_residual_xarea: i32;

  // --- two-sweep bookkeeping, reported under "sweeps:" ---
  var pi_min: i32;
  var pi_med: i32;
  var pi_max: i32;
  var pi_nodes_over_50k: i32;      // road nodes whose spur costs > $500
  var pi_cand_count: i32;          // road nodes within drop reach of a premises
  var pi_cand_med: i32;            // median spur cents over those candidates
  var pi_cand_over_50k: i32;
  var pi_term_priced: i32;         // kept design's terminals with pi > 0
  var pi_term_over_50k: i32;
  var pi_term_sum: i64;            // total priced spur cents in the design
  var sweep_score_a: i64;          // sweep 1 (pi == 0), partial composite
  var sweep_score_b: i64;          // sweep 2 (pi priced)
  var sweep_kept: i32;             // 1 or 2

  // --- stage 3c diagnostics (Lloyd re-assign + transportation repair) ---
  var assign_cost_seed: i64;       // unit-weighted m against the seeds
  var assign_cost_lloyd: i64;      // after re-assigning to the built sites
  var assign_cost_exact: i64;      // after cancelling every negative cycle
  var assign_cycles: i32;          // cycles cancelled
  var assign_moved: i32;           // premises that changed serving area
  var assign_stop: i32;            // 0 = optimality certificate, 1 = guard,
                                   // 2 = stopped (capacity / degenerate)

  // --- edge spatial grid (128 m cells, 128x128; drop-crossing prefilter) ---
  var eg_minx: i32;
  var eg_miny: i32;
  var eg_count: i32;
  var eg_query: i32;
  var eg_head: array(i32, 16384);
  var eg_next: array(i32, 131072);
  var eg_edge: array(i32, 131072);
  var eg_stamp: array(i32, 49152);

  // --- Dijkstra working state (reused across stages) ---
  var dist: array(i64, 16384);
  var prev_node: array(i32, 16384);
  var prev_edge: array(i32, 16384);
  var visited: array(bool, 16384);
  // Lazy-insertion binary heap: up to one entry per relaxation.
  var heap_size: i32;
  var heap_node: array(i32, 131072);
}

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

// Integer square root (Newton), for euclidean distances.
fn ISqrt(v: i64) -> i32 {
  if (v <= 0) { return 0; }
  var x: i64 = v;
  var y: i64 = (x + 1) / 2;
  while (y < x) {
    x = y;
    y = (x + v / x) / 2;
  }
  return x as i32;
}

fn DistM(x1: i32, y1: i32, x2: i32, y2: i32) -> i32 {
  let dx: i64 = (x1 - x2) as i64;
  let dy: i64 = (y1 - y2) as i64;
  return ISqrt(dx * dx + dy * dy);
}

// Ceiling division for capacity math.
fn CeilDiv(a: i32, b: i32) -> i32 {
  return (a + b - 1) / b;
}
