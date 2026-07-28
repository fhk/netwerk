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

// Computes edge lengths from node coordinates and builds adjacency.
fn BuildGraph(ref d: Design) {
  var e: i32 = 0;
  while (e < d.edge_count) {
    d.edge_len[e] = DistM(d.node_x[d.edge_from[e]], d.node_y[d.edge_from[e]],
                          d.node_x[d.edge_to[e]], d.node_y[d.edge_to[e]]);
    LinkEdge(ref d, e);
    ++e;
  }
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

// Edge weight under a mode. ModeMeters routes by plain length (clustering,
// facility location, distribution). ModeFeederCost routes feeder in cents,
// discounting edges whose trench is already open — SCOPE.md's duct/trench
// sharing falls out of the objective instead of special-case logic.
fn EdgeWeight(ref d: Design, e: i32, mode: i32) -> i64 {
  if (mode == ModeMeters()) {
    return d.edge_len[e] as i64;
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
