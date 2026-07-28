// netwerk — pipeline stages 1–6: ingest, snap, cluster, place, route.
//
// Mirrors SCOPE.md's design-engine pipeline with the heuristics-first
// strategy: capacitated greedy clustering, medoid facility location,
// shortest-path Steiner approximation (Takahashi–Matsuyama) for
// distribution, and sharing-aware sequential feeder routing.

library "stages";

import Core library "io";

import library "io_utils";
import library "model";
import library "graph";

// ---------------------------------------------------------------------------
// Stage 1 — ingest & validate (reads the interchange format on stdin)
// ---------------------------------------------------------------------------

fn IngestFail(msg: str) -> bool {
  Core.PrintStr("ingest error: ");
  Core.PrintStr(msg);
  NL();
  return false;
}

fn Ingest(ref d: Design) -> bool {
  if (not ExpectWord("NETWERK")) {
    return IngestFail("missing NETWERK header");
  }
  var version: i32 = 0;
  if (not ReadInt(ref version) or version != 1) {
    return IngestFail("unsupported format version");
  }

  if (not ExpectWord("NODES")) {
    return IngestFail("missing NODES section");
  }
  var n: i32 = 0;
  if (not ReadInt(ref n) or n < 2 or n > MaxNodes()) {
    return IngestFail("node count missing or out of range");
  }
  d.node_count = n;
  var i: i32 = 0;
  while (i < n) {
    var id: i32 = 0;
    var x: i32 = 0;
    var y: i32 = 0;
    if (not ReadInt(ref id) or not ReadInt(ref x) or not ReadInt(ref y)) {
      return IngestFail("truncated node row");
    }
    if (id != i) {
      return IngestFail("node ids must be sequential from 0");
    }
    d.node_x[i] = x;
    d.node_y[i] = y;
    ++i;
  }

  if (not ExpectWord("EDGES")) {
    return IngestFail("missing EDGES section");
  }
  var m: i32 = 0;
  if (not ReadInt(ref m) or m < 1 or m > MaxEdges()) {
    return IngestFail("edge count missing or out of range");
  }
  d.edge_count = m;
  i = 0;
  while (i < m) {
    var id: i32 = 0;
    var from: i32 = 0;
    var to: i32 = 0;
    var surface: i32 = 0;
    if (not ReadInt(ref id) or not ReadInt(ref from) or
        not ReadInt(ref to) or not ReadInt(ref surface)) {
      return IngestFail("truncated edge row");
    }
    if (id != i or from < 0 or from >= n or to < 0 or to >= n or from == to) {
      return IngestFail("invalid edge row");
    }
    if (surface != SurfaceSoft() and surface != SurfaceAsphalt()) {
      return IngestFail("unknown surface class");
    }
    d.edge_from[i] = from;
    d.edge_to[i] = to;
    d.edge_surface[i] = surface;
    ++i;
  }

  if (not ExpectWord("PREMISES")) {
    return IngestFail("missing PREMISES section");
  }
  var p: i32 = 0;
  if (not ReadInt(ref p) or p < 1 or p > MaxPremises()) {
    return IngestFail("premises count missing or out of range");
  }
  d.prem_count = p;
  d.total_units = 0;
  i = 0;
  while (i < p) {
    var id: i32 = 0;
    var x: i32 = 0;
    var y: i32 = 0;
    var units: i32 = 0;
    if (not ReadInt(ref id) or not ReadInt(ref x) or
        not ReadInt(ref y) or not ReadInt(ref units)) {
      return IngestFail("truncated premises row");
    }
    if (id != i or units < 1) {
      return IngestFail("invalid premises row");
    }
    d.prem_x[i] = x;
    d.prem_y[i] = y;
    d.prem_units[i] = units;
    d.prem_cluster[i] = -1;
    d.prem_terminal[i] = -1;
    d.total_units += units;
    ++i;
  }

  if (not ExpectWord("END")) {
    return IngestFail("missing END marker");
  }
  return true;
}

// Validation that needs the graph built: connectivity from node 0.
// Returns the number of unreachable nodes (0 = fully connected).
fn ValidateConnectivity(ref d: Design) -> i32 {
  DijkstraFrom(ref d, 0, ModeMeters());
  var unreachable: i32 = 0;
  var n: i32 = 0;
  while (n < d.node_count) {
    if (d.dist[n] >= Unreached()) {
      ++unreachable;
    }
    ++n;
  }
  return unreachable;
}

// ---------------------------------------------------------------------------
// Stage 2 — snap premises to the road graph
// ---------------------------------------------------------------------------

// v0 snaps to the nearest graph node (SCOPE.md stage 2 snaps to drop
// candidates along edges; node snapping is the documented simplification —
// it only ever over-estimates drop length, never under).
fn SnapPremises(ref d: Design) {
  var p: i32 = 0;
  while (p < d.prem_count) {
    var best_node: i32 = 0;
    var best_dist: i32 = 2147483647;
    var n: i32 = 0;
    while (n < d.node_count) {
      let dm: i32 = DistM(d.prem_x[p], d.prem_y[p], d.node_x[n], d.node_y[n]);
      if (dm < best_dist) {
        best_dist = dm;
        best_node = n;
      }
      ++n;
    }
    d.prem_snap_node[p] = best_node;
    d.prem_drop_len[p] = best_dist;
    ++p;
  }
}

// ---------------------------------------------------------------------------
// Stage 3 — capacitated clustering into serving areas
// ---------------------------------------------------------------------------

// Seeds by farthest-point sampling on graph distance, then greedy
// capacity-respecting assignment of premises to their nearest seed.
fn Cluster(ref d: Design) {
  var k: i32 = CeilDiv(d.total_units, MaxUnitsPerFdh());
  if (k < 1) {
    k = 1;
  }
  if (k > MaxClusters()) {
    k = MaxClusters();
  }
  d.cluster_count = k;

  // Farthest-point seeding, seeded from premises 0's snap node.
  d.seed_node[0] = d.prem_snap_node[0];
  var s: i32 = 1;
  while (s < k) {
    DijkstraReset(ref d);
    var t: i32 = 0;
    while (t < s) {
      AddSource(ref d, d.seed_node[t]);
      ++t;
    }
    DijkstraRun(ref d, ModeMeters());
    var far_node: i32 = d.prem_snap_node[0];
    var far_dist: i64 = -1;
    var p: i32 = 0;
    while (p < d.prem_count) {
      let sn: i32 = d.prem_snap_node[p];
      if (d.dist[sn] > far_dist) {
        far_dist = d.dist[sn];
        far_node = sn;
      }
      ++p;
    }
    d.seed_node[s] = far_node;
    ++s;
  }

  // Graph distance from every seed to every premises' snap node.
  s = 0;
  while (s < k) {
    DijkstraFrom(ref d, d.seed_node[s], ModeMeters());
    var p: i32 = 0;
    while (p < d.prem_count) {
      d.seed_dist[s * 2048 + p] = d.dist[d.prem_snap_node[p]] as i32;
      ++p;
    }
    ++s;
  }

  // Greedy assignment in premises order: nearest seed with spare capacity.
  s = 0;
  while (s < k) {
    d.cluster_units[s] = 0;
    d.cluster_prems[s] = 0;
    ++s;
  }
  var p2: i32 = 0;
  while (p2 < d.prem_count) {
    // Nearest seed with spare capacity.
    var assigned: i32 = -1;
    var best_d: i32 = 2147483647;
    var c: i32 = 0;
    while (c < k) {
      let dd: i32 = d.seed_dist[c * 2048 + p2];
      let has_room: bool =
          d.cluster_units[c] + d.prem_units[p2] <= MaxUnitsPerFdh();
      if (has_room and dd < best_d) {
        best_d = dd;
        assigned = c;
      }
      ++c;
    }
    if (assigned == -1) {
      // No seed has room (take-rate overshoot); spill to the nearest seed
      // regardless — QA will report the capacity violation honestly.
      var c2: i32 = 0;
      var best_d2: i32 = 2147483647;
      while (c2 < k) {
        let dd2: i32 = d.seed_dist[c2 * 2048 + p2];
        if (dd2 < best_d2) {
          best_d2 = dd2;
          assigned = c2;
        }
        ++c2;
      }
    }
    d.prem_cluster[p2] = assigned;
    d.cluster_units[assigned] += d.prem_units[p2];
    d.cluster_prems[assigned] += 1;
    ++p2;
  }
}

// ---------------------------------------------------------------------------
// Stage 4 — FDH placement (facility location, per serving area)
// ---------------------------------------------------------------------------

// Medoid over the serving area's snap nodes: the candidate minimizing
// unit-weighted graph distance to all member premises.
fn PlaceFdh(ref d: Design) {
  var c: i32 = 0;
  while (c < d.cluster_count) {
    // Collect distinct candidate nodes from member snap nodes.
    var cand: array(i32, 256);
    var cand_count: i32 = 0;
    var p: i32 = 0;
    while (p < d.prem_count) {
      if (d.prem_cluster[p] == c and cand_count < 256) {
        let sn: i32 = d.prem_snap_node[p];
        var seen: bool = false;
        var j: i32 = 0;
        while (j < cand_count) {
          if (cand[j] == sn) {
            seen = true;
            break;
          }
          ++j;
        }
        if (not seen) {
          cand[cand_count] = sn;
          ++cand_count;
        }
      }
      ++p;
    }

    var best_node: i32 = d.seed_node[c];
    var best_score: i64 = 9223372036854775807;
    var ci: i32 = 0;
    while (ci < cand_count) {
      DijkstraFrom(ref d, cand[ci], ModeMeters());
      var score: i64 = 0;
      p = 0;
      while (p < d.prem_count) {
        if (d.prem_cluster[p] == c) {
          score += d.dist[d.prem_snap_node[p]] * (d.prem_units[p] as i64);
        }
        ++p;
      }
      if (score < best_score or
          (score == best_score and cand[ci] < best_node)) {
        best_score = score;
        best_node = cand[ci];
      }
      ++ci;
    }
    d.fdh_node[c] = best_node;
    ++c;
  }
}

// ---------------------------------------------------------------------------
// Stage 5 — terminal placement
// ---------------------------------------------------------------------------

// Access terminals at each snap node holding premises, respecting the
// drop-port capacity; premises are then anchored to their terminal.
fn PlaceTerminals(ref d: Design) {
  d.term_count = 0;
  var p: i32 = 0;
  while (p < d.prem_count) {
    let node: i32 = d.prem_snap_node[p];
    let cl: i32 = d.prem_cluster[p];
    // Find an existing terminal at this node (same cluster) with a free port.
    var t: i32 = 0;
    var found: i32 = -1;
    while (t < d.term_count) {
      if (d.term_node[t] == node and d.term_cluster[t] == cl and
          d.term_ports_used[t] < TerminalPorts()) {
        found = t;
        break;
      }
      ++t;
    }
    if (found == -1 and d.term_count < MaxTerminals()) {
      found = d.term_count;
      d.term_node[found] = node;
      d.term_cluster[found] = cl;
      d.term_ports_used[found] = 0;
      d.term_units[found] = 0;
      d.term_path_len[found] = 0;
      ++d.term_count;
    }
    d.prem_terminal[p] = found;
    if (found != -1) {
      d.term_ports_used[found] += 1;
      d.term_units[found] += d.prem_units[p];
    }
    ++p;
  }
}

// ---------------------------------------------------------------------------
// Stage 6 — distribution routing (Steiner approximation per serving area)
// ---------------------------------------------------------------------------

// Takahashi–Matsuyama: grow a tree from the FDH, repeatedly attaching the
// terminal nearest to the current tree by its shortest path. A classic
// 2-approximation of the Steiner tree on the road graph.
fn RouteDistribution(ref d: Design) {
  var c: i32 = 0;
  while (c < d.cluster_count) {
    // Reset per-cluster tree state.
    var n: i32 = 0;
    while (n < d.node_count) {
      d.in_tree[n] = false;
      d.tree_parent_node[n] = -1;
      d.tree_parent_edge[n] = -1;
      ++n;
    }
    d.in_tree[d.fdh_node[c]] = true;

    // Attach every terminal node of this cluster.
    var remaining: i32 = 0;
    var t: i32 = 0;
    while (t < d.term_count) {
      if (d.term_cluster[t] == c and not d.in_tree[d.term_node[t]]) {
        ++remaining;
      }
      ++t;
    }
    while (remaining > 0) {
      // Multi-source Dijkstra from all tree nodes.
      DijkstraReset(ref d);
      n = 0;
      while (n < d.node_count) {
        if (d.in_tree[n]) {
          AddSource(ref d, n);
        }
        ++n;
      }
      DijkstraRun(ref d, ModeMeters());

      // Nearest unattached terminal node.
      var best_node: i32 = -1;
      var best_dist: i64 = Unreached();
      t = 0;
      while (t < d.term_count) {
        let tn: i32 = d.term_node[t];
        if (d.term_cluster[t] == c and not d.in_tree[tn] and
            d.dist[tn] < best_dist) {
          best_dist = d.dist[tn];
          best_node = tn;
        }
        ++t;
      }
      if (best_node == -1) {
        break;  // disconnected terminal; QA reports it as unserved
      }

      // Walk the path back to the tree, adding edges and parent pointers.
      var v: i32 = best_node;
      while (not d.in_tree[v]) {
        let pe: i32 = d.prev_edge[v];
        let pn: i32 = d.prev_node[v];
        d.in_tree[v] = true;
        d.tree_parent_node[v] = pn;
        d.tree_parent_edge[v] = pe;
        d.trench_used[pe] = true;
        v = pn;
      }

      // Recount unattached terminals (several may share the added path).
      remaining = 0;
      t = 0;
      while (t < d.term_count) {
        if (d.term_cluster[t] == c and not d.in_tree[d.term_node[t]]) {
          ++remaining;
        }
        ++t;
      }
    }

    // Fiber accounting: every terminal's units flow along its tree path to
    // the FDH (distribution sized for 100% of units — homes passed).
    t = 0;
    while (t < d.term_count) {
      if (d.term_cluster[t] == c and d.in_tree[d.term_node[t]]) {
        var walk: i32 = d.term_node[t];
        var path_m: i32 = 0;
        while (walk != d.fdh_node[c] and d.tree_parent_edge[walk] != -1) {
          let e: i32 = d.tree_parent_edge[walk];
          d.dist_fibers[e] += d.term_units[t];
          path_m += d.edge_len[e];
          walk = d.tree_parent_node[walk];
        }
        d.term_path_len[t] = path_m;
      }
      ++t;
    }
    ++c;
  }
}

// ---------------------------------------------------------------------------
// Stage 7 — CO selection, splitter provisioning, feeder routing
// ---------------------------------------------------------------------------

fn ProvisionSplitters(ref d: Design) {
  var c: i32 = 0;
  while (c < d.cluster_count) {
    var take: i32 = CeilDiv(d.cluster_units[c] * TakeRatePct(), 100);
    if (take < 1) {
      take = 1;
    }
    d.cluster_take_units[c] = take;
    d.fdh_splitters[c] = CeilDiv(take, SplitterRatio());
    ++c;
  }
}

// CO site: the FDH node minimizing splitter-weighted graph distance to all
// FDHs (the CO co-locates with the largest gravity centre of the design).
fn SelectCo(ref d: Design) {
  var best_node: i32 = d.fdh_node[0];
  var best_score: i64 = 9223372036854775807;
  var ci: i32 = 0;
  while (ci < d.cluster_count) {
    DijkstraFrom(ref d, d.fdh_node[ci], ModeMeters());
    var score: i64 = 0;
    var c: i32 = 0;
    while (c < d.cluster_count) {
      score += d.dist[d.fdh_node[c]] * (d.fdh_splitters[c] as i64);
      ++c;
    }
    if (score < best_score or
        (score == best_score and d.fdh_node[ci] < best_node)) {
      best_score = score;
      best_node = d.fdh_node[ci];
    }
    ++ci;
  }
  d.co_node = best_node;

  var total_splitters: i32 = 0;
  var c2: i32 = 0;
  while (c2 < d.cluster_count) {
    total_splitters += d.fdh_splitters[c2];
    ++c2;
  }
  d.olt_count = CeilDiv(total_splitters, OltChassisPorts());
}

// Feeder: route CO -> each FDH sequentially, nearest FDH first, with the
// sharing-aware cost mode — trench opened by distribution or an earlier
// feeder is discounted, so feeders bundle onto shared routes naturally.
fn RouteFeeder(ref d: Design) {
  var routed: array(bool, 64);
  var c: i32 = 0;
  while (c < d.cluster_count) {
    routed[c] = false;
    d.fdh_route_len[c] = 0;
    ++c;
  }

  var round: i32 = 0;
  while (round < d.cluster_count) {
    // Nearest unrouted FDH by current shared-cost metric.
    DijkstraFrom(ref d, d.co_node, ModeFeederCost());
    var best: i32 = -1;
    var best_cost: i64 = Unreached();
    c = 0;
    while (c < d.cluster_count) {
      if (not routed[c] and d.dist[d.fdh_node[c]] < best_cost) {
        best_cost = d.dist[d.fdh_node[c]];
        best = c;
      }
      ++c;
    }
    if (best == -1) {
      break;
    }
    // Feeder fibers for this FDH: one per splitter plus one spare.
    let fibers: i32 = d.fdh_splitters[best] + 1;
    var v: i32 = d.fdh_node[best];
    var meters: i32 = 0;
    while (v != d.co_node and d.prev_edge[v] != -1) {
      let e: i32 = d.prev_edge[v];
      d.feeder_fibers[e] += fibers;
      d.trench_used[e] = true;
      meters += d.edge_len[e];
      v = d.prev_node[v];
    }
    d.fdh_route_len[best] = meters;
    routed[best] = true;
    ++round;
  }
}
