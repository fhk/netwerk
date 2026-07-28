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

// Splitters: 1:4 / 1:8 / 1:16 / 1:32.
fn SplitterSizeCount() -> i32 { return 4; }

fn SplitterSize(idx: i32) -> i32 {
  if (idx == 0) { return 4; }
  if (idx == 1) { return 8; }
  if (idx == 2) { return 16; }
  return 32;
}

fn SplitterCost(idx: i32) -> i64 {
  if (idx == 0) { return 6000; }    // 1:4   $60
  if (idx == 1) { return 9000; }    // 1:8   $90
  if (idx == 2) { return 12000; }   // 1:16  $120
  return 18000;                     // 1:32  $180
}

// Access terminals: 4 / 8 / 12 drop ports.
fn TerminalSizeCount() -> i32 { return 3; }

fn TerminalSize(idx: i32) -> i32 {
  if (idx == 0) { return 4; }
  if (idx == 1) { return 8; }
  return 12;
}

fn TerminalCost(idx: i32) -> i64 {
  if (idx == 0) { return 12000; }   // 4-port  $120
  if (idx == 1) { return 18000; }   // 8-port  $180
  return 25000;                     // 12-port $250
}

// FDH cabinets: capacity in premises units served.
fn FdhSizeCount() -> i32 { return 3; }

fn FdhSize(idx: i32) -> i32 {
  if (idx == 0) { return 144; }
  if (idx == 1) { return 288; }
  return 432;
}

fn FdhCost(idx: i32) -> i64 {
  if (idx == 0) { return 120000; }  // 144-unit $1200
  if (idx == 1) { return 180000; }  // 288-unit $1800
  return 250000;                    // 432-unit $2500
}

// OLT line cards: 4 / 8 / 16 PON ports; a chassis holds 16 card slots.
fn OltCardSizeCount() -> i32 { return 3; }

fn OltCardPorts(idx: i32) -> i32 {
  if (idx == 0) { return 4; }
  if (idx == 1) { return 8; }
  return 16;
}

fn OltCardCost(idx: i32) -> i64 {
  if (idx == 0) { return 40000; }   // 4-port card  $400
  if (idx == 1) { return 70000; }   // 8-port card  $700
  return 120000;                    // 16-port card $1200
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

fn MaxNodes() -> i32 { return 1024; }
fn MaxEdges() -> i32 { return 4096; }
fn MaxPremises() -> i32 { return 12288; }
fn MaxClusters() -> i32 { return 32; }
fn MaxTerminals() -> i32 { return 2048; }

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
    var i: i32 = 0;
    while (i < MaxNodes()) {
      d.adj_head[i] = -1;
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
  var node_x: array(i32, 1024);
  var node_y: array(i32, 1024);

  // --- road graph edges (undirected) ---
  var edge_count: i32;
  var edge_from: array(i32, 4096);
  var edge_to: array(i32, 4096);
  var edge_len: array(i32, 4096);
  var edge_surface: array(i32, 4096);

  // --- adjacency lists (two directed half-edges per edge) ---
  var adj_count: i32;
  var adj_head: array(i32, 1024);
  var adj_next: array(i32, 8192);
  var adj_to: array(i32, 8192);
  var adj_edge: array(i32, 8192);

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
  var fdh_split_by_size: array(i32, 128);  // [cluster * 4 + size_idx]
  var fdh_size_idx: array(i32, 32);        // chosen cabinet size per cluster
  var fdh_route_len: array(i32, 32);       // feeder route meters CO -> FDH
  // Graph distance premises <- each cluster seed, row-major [seed][premises].
  var seed_dist: array(i32, 393216);       // 32 x 12288

  // --- access terminals ---
  var term_count: i32;
  var term_node: array(i32, 2048);
  var term_cluster: array(i32, 2048);
  var term_ports_used: array(i32, 2048);
  var term_size_idx: array(i32, 2048);     // catalog size chosen at close
  var term_path_len: array(i32, 2048);     // tree route meters terminal -> FDH

  // --- CO / OLT ---
  var co_node: i32;

  // --- per-edge cable/trench usage (design results) ---
  var dist_fibers: array(i32, 4096);
  var feeder_fibers: array(i32, 4096);
  var trench_used: array(bool, 4096);

  // --- distribution-tree working state (reset per serving area) ---
  var in_tree: array(bool, 1024);
  var tree_parent_node: array(i32, 1024);  // toward the FDH
  var tree_parent_edge: array(i32, 1024);
  var node_path_m: array(i32, 1024);       // tree route meters node -> FDH
  var node_units: array(i32, 1024);        // demand units snapped per node

  // --- Dijkstra working state (reused across stages) ---
  var dist: array(i64, 1024);
  var prev_node: array(i32, 1024);
  var prev_edge: array(i32, 1024);
  var visited: array(bool, 1024);
  // Lazy-insertion binary heap: up to one entry per relaxation.
  var heap_size: i32;
  var heap_node: array(i32, 8192);
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
