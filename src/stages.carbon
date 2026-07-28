// netwerk — pipeline stages 1–7: ingest, snap, cluster, place, route, pack.
//
// Mirrors SCOPE.md's design-engine pipeline with the heuristics-first
// strategy: capacitated greedy clustering, medoid facility location,
// shortest-path Steiner approximation (Takahashi–Matsuyama) for
// distribution, tree-ordered terminal packing into graduated catalog
// sizes, and sharing-aware sequential feeder routing. Packing exists to
// hit the utilization floor: remainders round into the smallest covering
// catalog unit instead of stranding a large one.

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
// capacity-respecting assignment — multi-unit premises first (first-fit
// decreasing), so MDUs always find a serving area with room.
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
      d.seed_dist[s * 12288 + p] = d.dist[d.prem_snap_node[p]] as i32;
      ++p;
    }
    ++s;
  }

  s = 0;
  while (s < k) {
    d.cluster_units[s] = 0;
    d.cluster_prems[s] = 0;
    ++s;
  }

  // Two assignment passes: MDUs (units > 1) first, then single units.
  var pass: i32 = 0;
  while (pass < 2) {
    var p2: i32 = 0;
    while (p2 < d.prem_count) {
      let is_mdu: bool = d.prem_units[p2] > 1;
      if ((pass == 0 and is_mdu) or (pass == 1 and not is_mdu)) {
        // Nearest seed with spare capacity.
        var assigned: i32 = -1;
        var best_d: i32 = 2147483647;
        var c: i32 = 0;
        while (c < k) {
          let dd: i32 = d.seed_dist[c * 12288 + p2];
          let has_room: bool =
              d.cluster_units[c] + d.prem_units[p2] <= MaxUnitsPerFdh();
          if (has_room and dd < best_d) {
            best_d = dd;
            assigned = c;
          }
          ++c;
        }
        if (assigned == -1) {
          // No seed has room; spill to the nearest seed regardless — QA
          // reports the capacity violation honestly.
          var c2: i32 = 0;
          var best_d2: i32 = 2147483647;
          while (c2 < k) {
            let dd2: i32 = d.seed_dist[c2 * 12288 + p2];
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
      }
      ++p2;
    }
    ++pass;
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
// Stage 6 — terminal packing along the distribution tree
// ---------------------------------------------------------------------------

// Closes the open terminal: picks the smallest catalog size covering the
// ports actually used, so remainders never strand a 12-port unit.
fn CloseTerminal(ref d: Design, t: i32) {
  var idx: i32 = 0;
  while (idx < TerminalSizeCount() - 1 and
         TerminalSize(idx) < d.term_ports_used[t]) {
    ++idx;
  }
  d.term_size_idx[t] = idx;
}

// Packs premises onto shared access terminals by batching.
//
// The serving area's premises are ordered by depth-first position of their
// snap node on the distribution tree (so consecutive premises are physical
// neighbours), then cut into full batches of the largest terminal size.
// Each batch's terminal is sited at the member snap node minimizing the
// worst drop; if no node covers the whole batch within the max-drop rule,
// the batch shrinks until one does (a single premises is always covered by
// its own snap node). Only the final batch per serving area is partial,
// and it closes onto the smallest covering catalog size — so stranded
// ports are bounded by roughly one partial terminal per serving area.
fn PackTerminals(ref d: Design, c: i32) {
  let max_ports: i32 = TerminalSize(TerminalSizeCount() - 1);

  // Depth-first node order over the cluster's tree via an explicit stack.
  var node_order: array(i32, 1024);
  var order_count: i32 = 0;
  var stack: array(i32, 1024);
  var top: i32 = 0;
  stack[top] = d.fdh_node[c];
  ++top;
  while (top > 0) {
    --top;
    let n: i32 = stack[top];
    if (d.node_units[n] > 0) {
      node_order[order_count] = n;
      ++order_count;
    }
    var a: i32 = d.adj_head[n];
    while (a != -1) {
      let v: i32 = d.adj_to[a];
      if (d.in_tree[v] and d.tree_parent_node[v] == n and top < 1024) {
        stack[top] = v;
        ++top;
      }
      a = d.adj_next[a];
    }
  }

  // Premises in DFS-node order (id order within a node).
  var ordered: array(i32, 512);
  var m: i32 = 0;
  var oi: i32 = 0;
  while (oi < order_count) {
    var p: i32 = 0;
    while (p < d.prem_count) {
      if (d.prem_cluster[p] == c and
          d.prem_snap_node[p] == node_order[oi] and m < 512) {
        ordered[m] = p;
        ++m;
      }
      ++p;
    }
    ++oi;
  }

  // Cut into batches, largest terminal first, shrinking on infeasibility.
  var i: i32 = 0;
  while (i < m) {
    var size: i32 = m - i;
    if (size > max_ports) {
      size = max_ports;
    }
    while (size >= 1) {
      // Best covering node among the batch's snap nodes: minimize the
      // worst drop (ties: lower node id).
      var best_node: i32 = -1;
      var best_maxd: i32 = 2147483647;
      var bi: i32 = 0;
      while (bi < size) {
        let cn: i32 = d.prem_snap_node[ordered[i + bi]];
        var maxd: i32 = 0;
        var bj: i32 = 0;
        while (bj < size) {
          let pj: i32 = ordered[i + bj];
          let dd: i32 = DistM(d.prem_x[pj], d.prem_y[pj],
                              d.node_x[cn], d.node_y[cn]);
          if (dd > maxd) {
            maxd = dd;
          }
          ++bj;
        }
        if (maxd <= MaxDropM() and
            (maxd < best_maxd or
             (maxd == best_maxd and cn < best_node))) {
          best_maxd = maxd;
          best_node = cn;
        }
        ++bi;
      }
      if (best_node != -1) {
        if (d.term_count < MaxTerminals()) {
          let nt: i32 = d.term_count;
          ++d.term_count;
          d.term_node[nt] = best_node;
          d.term_cluster[nt] = c;
          d.term_ports_used[nt] = size;
          d.term_path_len[nt] = d.node_path_m[best_node];
          var bk: i32 = 0;
          while (bk < size) {
            let pk: i32 = ordered[i + bk];
            d.prem_terminal[pk] = nt;
            d.prem_drop_len[pk] = DistM(d.prem_x[pk], d.prem_y[pk],
                                        d.node_x[best_node],
                                        d.node_y[best_node]);
            ++bk;
          }
          CloseTerminal(ref d, nt);
        }
        i += size;
        break;
      }
      --size;
    }
  }
}

// ---------------------------------------------------------------------------
// Stage 5 — distribution routing (Steiner approximation per serving area)
// ---------------------------------------------------------------------------

// Takahashi–Matsuyama: grow a tree from the FDH, repeatedly attaching the
// demand node nearest to the current tree by its shortest path. A classic
// 2-approximation of the Steiner tree on the road graph. Terminals are
// packed onto the finished tree afterwards (stage 6), so the tree targets
// are the premises' snap nodes.
fn RouteDistribution(ref d: Design) {
  var c: i32 = 0;
  while (c < d.cluster_count) {
    // Reset per-cluster tree state and per-node demand.
    var n: i32 = 0;
    while (n < d.node_count) {
      d.in_tree[n] = false;
      d.tree_parent_node[n] = -1;
      d.tree_parent_edge[n] = -1;
      d.node_path_m[n] = 0;
      d.node_units[n] = 0;
      ++n;
    }
    var p: i32 = 0;
    while (p < d.prem_count) {
      if (d.prem_cluster[p] == c) {
        d.node_units[d.prem_snap_node[p]] += d.prem_units[p];
      }
      ++p;
    }
    d.in_tree[d.fdh_node[c]] = true;

    // Attach every demand node of this cluster.
    var remaining: i32 = 0;
    n = 0;
    while (n < d.node_count) {
      if (d.node_units[n] > 0 and not d.in_tree[n]) {
        ++remaining;
      }
      ++n;
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

      // Nearest unattached demand node.
      var best_node: i32 = -1;
      var best_dist: i64 = Unreached();
      n = 0;
      while (n < d.node_count) {
        if (d.node_units[n] > 0 and not d.in_tree[n] and
            d.dist[n] < best_dist) {
          best_dist = d.dist[n];
          best_node = n;
        }
        ++n;
      }
      if (best_node == -1) {
        break;  // disconnected demand; QA reports it as unserved
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

      // Recount unattached demand nodes (several may share the added path).
      remaining = 0;
      n = 0;
      while (n < d.node_count) {
        if (d.node_units[n] > 0 and not d.in_tree[n]) {
          ++remaining;
        }
        ++n;
      }
    }

    // Fiber accounting and path lengths: every demand node's units flow
    // along its tree path to the FDH (distribution sized for 100% of
    // units — homes passed).
    n = 0;
    while (n < d.node_count) {
      if (d.node_units[n] > 0 and d.in_tree[n]) {
        var walk: i32 = n;
        var path_m: i32 = 0;
        while (walk != d.fdh_node[c] and d.tree_parent_edge[walk] != -1) {
          let e: i32 = d.tree_parent_edge[walk];
          d.dist_fibers[e] += d.node_units[n];
          path_m += d.edge_len[e];
          walk = d.tree_parent_node[walk];
        }
        d.node_path_m[n] = path_m;
      }
      ++n;
    }

    // Stage 6 packs terminals while this cluster's tree state is live.
    PackTerminals(ref d, c);
    ++c;
  }
}

// ---------------------------------------------------------------------------
// Stage 6b — terminal merge/shrink repair (utilization floor)
// ---------------------------------------------------------------------------

// Best target terminal for premises p: same serving area, spare port below
// the largest catalog size, within drop reach, nearest first (ties: lowest
// terminal id). `exclude` is the terminal being dissolved or shrunk.
fn BestTargetTerminal(ref d: Design, p: i32, exclude: i32) -> i32 {
  var best: i32 = -1;
  var best_dist: i32 = 2147483647;
  let max_ports: i32 = TerminalSize(TerminalSizeCount() - 1);
  var u: i32 = 0;
  while (u < d.term_count) {
    if (u != exclude and d.term_cluster[u] == d.prem_cluster[p] and
        d.term_ports_used[u] > 0 and d.term_ports_used[u] < max_ports) {
      let dd: i32 = DistM(d.prem_x[p], d.prem_y[p],
                          d.node_x[d.term_node[u]], d.node_y[d.term_node[u]]);
      if (dd <= MaxDropM() and dd < best_dist) {
        best_dist = dd;
        best = u;
      }
    }
    ++u;
  }
  return best;
}

fn MovePremises(ref d: Design, p: i32, from: i32, to: i32) {
  d.prem_terminal[p] = to;
  d.prem_drop_len[p] = DistM(d.prem_x[p], d.prem_y[p],
                             d.node_x[d.term_node[to]],
                             d.node_y[d.term_node[to]]);
  d.term_ports_used[from] -= 1;
  d.term_ports_used[to] += 1;
}

// Dissolves a terminal if every one of its premises fits on other
// terminals within drop reach. Returns true if the terminal was emptied.
fn TryDissolve(ref d: Design, t: i32) -> bool {
  // Feasibility first, against a scratch copy of port counts.
  var scratch: array(i32, 2048);
  var u: i32 = 0;
  while (u < d.term_count) {
    scratch[u] = d.term_ports_used[u];
    ++u;
  }
  let max_ports: i32 = TerminalSize(TerminalSizeCount() - 1);
  var p: i32 = 0;
  while (p < d.prem_count) {
    if (d.prem_terminal[p] == t) {
      var best: i32 = -1;
      var best_dist: i32 = 2147483647;
      var v: i32 = 0;
      while (v < d.term_count) {
        if (v != t and d.term_cluster[v] == d.prem_cluster[p] and
            scratch[v] > 0 and scratch[v] < max_ports) {
          let dd: i32 = DistM(d.prem_x[p], d.prem_y[p],
                              d.node_x[d.term_node[v]],
                              d.node_y[d.term_node[v]]);
          if (dd <= MaxDropM() and dd < best_dist) {
            best_dist = dd;
            best = v;
          }
        }
        ++v;
      }
      if (best == -1) {
        return false;
      }
      scratch[best] += 1;
    }
    ++p;
  }
  // Feasible: commit with the same greedy, against the live counts.
  p = 0;
  while (p < d.prem_count) {
    if (d.prem_terminal[p] == t) {
      let target: i32 = BestTargetTerminal(ref d, p, t);
      MovePremises(ref d, p, t, target);
    }
    ++p;
  }
  return true;
}

// Utilization repair: (1) dissolve small terminals entirely into their
// neighbours' spare ports, smallest first, until a fixed point; then
// (2) shrink terminals sitting just above a catalog size boundary by
// shedding the overhang. Both moves only ever reduce installed ports;
// drop-length and capacity rules are re-checked by QA as usual.
fn MergeTerminals(ref d: Design) {
  var pass: i32 = 0;
  var changed: bool = true;
  while (changed and pass < 8) {
    changed = false;
    var used_level: i32 = 1;
    while (used_level < TerminalSize(TerminalSizeCount() - 1)) {
      var t: i32 = 0;
      while (t < d.term_count) {
        if (d.term_ports_used[t] == used_level) {
          if (TryDissolve(ref d, t)) {
            changed = true;
          }
        }
        ++t;
      }
      ++used_level;
    }
    ++pass;
  }

  // Shrink to the next size boundary where neighbours have room.
  var t2: i32 = 0;
  while (t2 < d.term_count) {
    if (d.term_ports_used[t2] > 0) {
      // Largest catalog size at or below current fill minus what fits.
      var boundary: i32 = 0;
      var i: i32 = 0;
      while (i < TerminalSizeCount()) {
        if (TerminalSize(i) < d.term_ports_used[t2]) {
          boundary = TerminalSize(i);
        }
        ++i;
      }
      // Shed the overhang above the boundary if targets exist.
      while (boundary > 0 and d.term_ports_used[t2] > boundary) {
        // Move the premises of t2 with the shortest move distance.
        var move_p: i32 = -1;
        var move_target: i32 = -1;
        var move_dist: i32 = 2147483647;
        var p: i32 = 0;
        while (p < d.prem_count) {
          if (d.prem_terminal[p] == t2) {
            let target: i32 = BestTargetTerminal(ref d, p, t2);
            if (target != -1) {
              let dd: i32 = DistM(d.prem_x[p], d.prem_y[p],
                                  d.node_x[d.term_node[target]],
                                  d.node_y[d.term_node[target]]);
              if (dd < move_dist) {
                move_dist = dd;
                move_p = p;
                move_target = target;
              }
            }
          }
          ++p;
        }
        if (move_p == -1) {
          break;
        }
        MovePremises(ref d, move_p, t2, move_target);
      }
    }
    ++t2;
  }

  // Re-close every live terminal at its final fill.
  var t3: i32 = 0;
  while (t3 < d.term_count) {
    if (d.term_ports_used[t3] > 0) {
      CloseTerminal(ref d, t3);
    }
    ++t3;
  }
}

// ---------------------------------------------------------------------------
// Stage 7 — splitter provisioning, CO selection, feeder routing
// ---------------------------------------------------------------------------

// Splitter banks per FDH: as many full 1:32s as fit the provisioned ports,
// then the smallest catalog splitter covering the remainder.
fn ProvisionSplitters(ref d: Design) {
  var c: i32 = 0;
  while (c < d.cluster_count) {
    var take: i32 = CeilDiv(d.cluster_units[c] * TakeRatePct(), 100);
    if (take < 1) {
      take = 1;
    }
    d.cluster_take_units[c] = take;

    let top_idx: i32 = SplitterSizeCount() - 1;
    let full: i32 = take / SplitterSize(top_idx);
    let rem: i32 = take % SplitterSize(top_idx);
    d.fdh_split_by_size[c * 4 + top_idx] = full;
    var count: i32 = full;
    if (rem > 0) {
      var idx: i32 = 0;
      while (idx < top_idx and SplitterSize(idx) < rem) {
        ++idx;
      }
      d.fdh_split_by_size[c * 4 + idx] += 1;
      ++count;
    }
    d.fdh_splitters[c] = count;

    // Cabinet: smallest catalog FDH covering this serving area's units.
    var fidx: i32 = 0;
    while (fidx < FdhSizeCount() - 1 and FdhSize(fidx) < d.cluster_units[c]) {
      ++fidx;
    }
    d.fdh_size_idx[c] = fidx;
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
}

// Feeder: route CO -> each FDH sequentially, nearest FDH first, with the
// sharing-aware cost mode — trench opened by distribution or an earlier
// feeder is discounted, so feeders bundle onto shared routes naturally.
fn RouteFeeder(ref d: Design) {
  var routed: array(bool, 32);
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
