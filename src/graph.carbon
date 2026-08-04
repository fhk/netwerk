// netwerk — road-graph construction and shortest paths.
//
// SCOPE.md pipeline stage 2: noded routable graph with per-edge attributes.
// Dijkstra is the routing primitive shared by clustering, facility location,
// distribution (Steiner-heuristic) and feeder routing. Weights are i64 cents
// (or plain meters), so a single implementation serves every stage.

library "graph";

import library "model";

// Sentinel "unreached" distance; far above any real path cost but safe to
// add edge weights to without overflow.
fn Unreached() -> i64 {
  return 1000000000000000;
}

// Registers one undirected edge in the adjacency lists. Callers append the
// edge to the edge arrays first, then link it here.
fn LinkEdge(ref d: Design, e: i32) {
  let a: i32 = d.edge_from[e];
  let b: i32 = d.edge_to[e];
  d.adj_to[d.adj_count] = b;
  d.adj_edge[d.adj_count] = e;
  d.adj_next[d.adj_count] = d.adj_head[a];
  d.adj_head[a] = d.adj_count;
  ++d.adj_count;
  d.adj_to[d.adj_count] = a;
  d.adj_edge[d.adj_count] = e;
  d.adj_next[d.adj_count] = d.adj_head[b];
  d.adj_head[b] = d.adj_count;
  ++d.adj_count;
}

// --- exact segment crossing + edge spatial grid ----------------------------
//
// A drop (premises -> terminal node) must not properly cross any road edge
// except at its own frontage. These are the scorer's exact integer
// orientation predicates, accelerated by a 128 m grid over edge bounding
// boxes so packing and repair can rank terminal candidates by the street
// crossings they would create.

fn Orient(ax: i32, ay: i32, bx: i32, by: i32, cx: i32, cy: i32) -> i64 {
  let abx: i64 = (bx - ax) as i64;
  let aby: i64 = (by - ay) as i64;
  let acx: i64 = (cx - ax) as i64;
  let acy: i64 = (cy - ay) as i64;
  return abx * acy - aby * acx;
}

// True iff segments pq and ab intersect at a single interior point of both
// (endpoint touches and collinear overlaps excluded) — the scorer's test.
fn ProperCross(px: i32, py: i32, qx: i32, qy: i32,
               ax: i32, ay: i32, bx: i32, by: i32) -> bool {
  let d1: i64 = Orient(ax, ay, bx, by, px, py);
  let d2: i64 = Orient(ax, ay, bx, by, qx, qy);
  if ((d1 > 0 and d2 > 0) or (d1 < 0 and d2 < 0) or d1 == 0 or d2 == 0) {
    return false;
  }
  let d3: i64 = Orient(px, py, qx, qy, ax, ay);
  let d4: i64 = Orient(px, py, qx, qy, bx, by);
  if ((d3 > 0 and d4 > 0) or (d3 < 0 and d4 < 0) or d3 == 0 or d4 == 0) {
    return false;
  }
  return true;
}

// Grid coordinate of a world coordinate, clamped into the 128-cell axis.
// Clamping is monotone, so intersecting bounding boxes always land in
// intersecting cell ranges — the grid stays a true superset prefilter.
fn GridCell(v: i32, origin: i32) -> i32 {
  var c: i32 = (v - origin) / 128;
  if (c < 0) { c = 0; }
  if (c > 127) { c = 127; }
  return c;
}

// Indexes every edge into the cells covered by its bounding box.
fn BuildEdgeGrid(ref d: Design) {
  var minx: i32 = d.node_x[0];
  var miny: i32 = d.node_y[0];
  var n: i32 = 1;
  while (n < d.node_count) {
    if (d.node_x[n] < minx) { minx = d.node_x[n]; }
    if (d.node_y[n] < miny) { miny = d.node_y[n]; }
    ++n;
  }
  d.eg_minx = minx;
  d.eg_miny = miny;
  var c: i32 = 0;
  while (c < 16384) {
    d.eg_head[c] = -1;
    ++c;
  }
  d.eg_count = 0;
  d.eg_query = 0;
  var e: i32 = 0;
  while (e < d.edge_count) {
    d.eg_stamp[e] = 0;
    var cx0: i32 = GridCell(d.node_x[d.edge_from[e]], minx);
    var cx1: i32 = GridCell(d.node_x[d.edge_to[e]], minx);
    var cy0: i32 = GridCell(d.node_y[d.edge_from[e]], miny);
    var cy1: i32 = GridCell(d.node_y[d.edge_to[e]], miny);
    if (cx1 < cx0) { let tx: i32 = cx0; cx0 = cx1; cx1 = tx; }
    if (cy1 < cy0) { let ty: i32 = cy0; cy0 = cy1; cy1 = ty; }
    var cy: i32 = cy0;
    while (cy <= cy1) {
      var cx: i32 = cx0;
      while (cx <= cx1) {
        if (d.eg_count < 131072) {
          d.eg_edge[d.eg_count] = e;
          d.eg_next[d.eg_count] = d.eg_head[cy * 128 + cx];
          d.eg_head[cy * 128 + cx] = d.eg_count;
          ++d.eg_count;
        }
        ++cx;
      }
      ++cy;
    }
    ++e;
  }
}

// Number of road edges the drop (px,py) -> node tn properly crosses,
// excluding edges incident to tn (the drop's own frontage) — exactly the
// scorer's drop_street_crossings contribution for this drop.
fn CountDropCrossings(ref d: Design, px: i32, py: i32, tn: i32) -> i32 {
  let qx: i32 = d.node_x[tn];
  let qy: i32 = d.node_y[tn];
  ++d.eg_query;
  var cx0: i32 = GridCell(px, d.eg_minx);
  var cx1: i32 = GridCell(qx, d.eg_minx);
  var cy0: i32 = GridCell(py, d.eg_miny);
  var cy1: i32 = GridCell(qy, d.eg_miny);
  if (cx1 < cx0) { let tx: i32 = cx0; cx0 = cx1; cx1 = tx; }
  if (cy1 < cy0) { let ty: i32 = cy0; cy0 = cy1; cy1 = ty; }
  var cnt: i32 = 0;
  var cy: i32 = cy0;
  while (cy <= cy1) {
    var cx: i32 = cx0;
    while (cx <= cx1) {
      var it: i32 = d.eg_head[cy * 128 + cx];
      while (it != -1) {
        let e: i32 = d.eg_edge[it];
        if (d.eg_stamp[e] != d.eg_query) {
          d.eg_stamp[e] = d.eg_query;
          let a: i32 = d.edge_from[e];
          let b: i32 = d.edge_to[e];
          if (a != tn and b != tn and
              ProperCross(px, py, qx, qy,
                          d.node_x[a], d.node_y[a],
                          d.node_x[b], d.node_y[b])) {
            ++cnt;
          }
        }
        it = d.eg_next[it];
      }
      ++cx;
    }
    ++cy;
  }
  return cnt;
}

// Computes edge lengths from node coordinates, builds adjacency, and
// indexes the edge grid for drop-crossing queries.
fn BuildGraph(ref d: Design) {
  var e: i32 = 0;
  while (e < d.edge_count) {
    d.edge_len[e] = DistM(d.node_x[d.edge_from[e]], d.node_y[d.edge_from[e]],
                          d.node_x[d.edge_to[e]], d.node_y[d.edge_to[e]]);
    LinkEdge(ref d, e);
    ++e;
  }
  BuildEdgeGrid(ref d);
}

// --- binary min-heap over d.dist, lazy insertion ---

fn HeapLess(ref d: Design, i: i32, j: i32) -> bool {
  return d.dist[d.heap_node[i]] < d.dist[d.heap_node[j]];
}

fn HeapSwap(ref d: Design, i: i32, j: i32) {
  let t: i32 = d.heap_node[i];
  d.heap_node[i] = d.heap_node[j];
  d.heap_node[j] = t;
}

fn HeapPush(ref d: Design, node: i32) {
  d.heap_node[d.heap_size] = node;
  var i: i32 = d.heap_size;
  ++d.heap_size;
  while (i > 0) {
    let parent: i32 = (i - 1) / 2;
    if (HeapLess(ref d, i, parent)) {
      HeapSwap(ref d, i, parent);
      i = parent;
    } else {
      break;
    }
  }
}

fn HeapPop(ref d: Design) -> i32 {
  let top: i32 = d.heap_node[0];
  --d.heap_size;
  d.heap_node[0] = d.heap_node[d.heap_size];
  var i: i32 = 0;
  while (true) {
    let l: i32 = 2 * i + 1;
    let r: i32 = 2 * i + 2;
    var smallest: i32 = i;
    if (l < d.heap_size and HeapLess(ref d, l, smallest)) {
      smallest = l;
    }
    if (r < d.heap_size and HeapLess(ref d, r, smallest)) {
      smallest = r;
    }
    if (smallest == i) {
      break;
    }
    HeapSwap(ref d, i, smallest);
    i = smallest;
  }
  return top;
}

// --- Dijkstra ---

// Weight modes for edge relaxation.
fn ModeMeters() -> i32 { return 0; }
fn ModeFeederCost() -> i32 { return 1; }
fn ModeTrenchMarginal() -> i32 { return 2; }

// Edge weight under a mode. ModeMeters routes by plain length (clustering,
// facility location, distribution). ModeFeederCost routes feeder in cents,
// discounting edges whose trench is already open — SCOPE.md's duct/trench
// sharing falls out of the objective instead of special-case logic.
// ModeTrenchMarginal is the same idea with the cable term dropped and the
// discount made total: open trench is free, unopened trench costs its full
// civil price, so a multi-source run from the routed trench measures the
// MARGINAL cents of reaching each node (the ConFL price pi_v, iter 008).
fn EdgeWeight(ref d: Design, e: i32, mode: i32) -> i64 {
  if (mode == ModeMeters()) {
    return d.edge_len[e] as i64;
  }
  if (mode == ModeTrenchMarginal()) {
    if (d.trench_used[e]) {
      return 0;
    }
    return (d.edge_len[e] as i64) * TrenchCostPerM(d.edge_surface[e]);
  }
  var per_m: i64 = CableCostPerM(4);  // representative feeder cable, 144f
  if (not d.trench_used[e]) {
    per_m = per_m + TrenchCostPerM(d.edge_surface[e]);
  }
  return (d.edge_len[e] as i64) * per_m;
}

// Resets Dijkstra state. Callers then seed sources with AddSource and Run.
fn DijkstraReset(ref d: Design) {
  var n: i32 = 0;
  while (n < d.node_count) {
    d.dist[n] = Unreached();
    d.prev_node[n] = -1;
    d.prev_edge[n] = -1;
    d.visited[n] = false;
    ++n;
  }
  d.heap_size = 0;
}

fn AddSource(ref d: Design, node: i32) {
  d.dist[node] = 0;
  HeapPush(ref d, node);
}

fn DijkstraRun(ref d: Design, mode: i32) {
  while (d.heap_size > 0) {
    let u: i32 = HeapPop(ref d);
    if (d.visited[u]) {
      continue;
    }
    d.visited[u] = true;
    var a: i32 = d.adj_head[u];
    while (a != -1) {
      let v: i32 = d.adj_to[a];
      let w: i64 = d.dist[u] + EdgeWeight(ref d, d.adj_edge[a], mode);
      if (w < d.dist[v]) {
        d.dist[v] = w;
        d.prev_node[v] = u;
        d.prev_edge[v] = d.adj_edge[a];
        HeapPush(ref d, v);
      }
      a = d.adj_next[a];
    }
  }
}

// Convenience: single-source run.
fn DijkstraFrom(ref d: Design, source: i32, mode: i32) {
  DijkstraReset(ref d);
  AddSource(ref d, source);
  DijkstraRun(ref d, mode);
}
