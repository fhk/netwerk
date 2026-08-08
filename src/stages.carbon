// netwerk — pipeline stages 1–7: ingest, snap, cluster, place, route, pack.
//
// Mirrors SCOPE.md's design-engine pipeline with the heuristics-first
// strategy: capacitated greedy clustering, medoid facility location,
// node-centric set-cover terminal packing priced by the design-quality
// scorer (terminals first), shortest-path Steiner approximation
// (Takahashi–Matsuyama) routing the trench TO the terminals, and
// sharing-aware sequential feeder routing. Merge repair afterwards is
// scorer-priced too, with a forced fallback that keeps the utilization
// floor green.

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
    var j: i32 = 0;
    while (j < i) {
      if ((d.edge_from[j] == from and d.edge_to[j] == to) or
          (d.edge_from[j] == to and d.edge_to[j] == from)) {
        return IngestFail("duplicate edge between node pair");
      }
      ++j;
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
// it only ever over-estimates drop length, never under). Nearest is decided
// on squared euclidean distance in i64, so the integer sqrt runs once per
// premises (for the drop length) instead of once per premises-node pair.
// Comparing squared distances sharpens ties versus comparing rounded
// meters: two nodes that round to the same meter count now order by their
// exact squared distance (then by lower node id).
fn SnapPremises(ref d: Design) {
  var p: i32 = 0;
  while (p < d.prem_count) {
    var best_sq: i64 = 0;
    let best_node: i32 = NearestNode(ref d, d.prem_x[p], d.prem_y[p],
                                     ref best_sq);
    d.prem_snap_node[p] = best_node;
    d.prem_drop_len[p] = ISqrt(best_sq);
    ++p;
  }
}

// ---------------------------------------------------------------------------
// Stage 3 — capacitated clustering into serving areas
// ---------------------------------------------------------------------------

// Greedy capacity-respecting assignment against whatever reference nodes
// currently fill `seed_dist` — multi-unit premises first (first-fit
// decreasing), so MDUs always find a serving area with room. Factored out
// of Cluster because stage 3c re-runs it against the built FDH sites.
fn AssignPremises(ref d: Design) {
  let k: i32 = d.cluster_count;
  var s: i32 = 0;
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
        // Nearest reference node with spare capacity; ties -> lowest index.
        var assigned: i32 = -1;
        var best_d: i32 = 2147483647;
        var c: i32 = 0;
        while (c < k) {
          let dd: i32 = d.seed_dist[c * 131072 + p2];
          let has_room: bool =
              d.cluster_units[c] + d.prem_units[p2] <= MaxUnitsPerFdh();
          if (has_room and dd < best_d) {
            best_d = dd;
            assigned = c;
          }
          ++c;
        }
        if (assigned == -1) {
          // Nothing has room; spill to the nearest regardless — QA reports
          // the capacity violation honestly.
          var c2: i32 = 0;
          var best_d2: i32 = 2147483647;
          while (c2 < k) {
            let dd2: i32 = d.seed_dist[c2 * 131072 + p2];
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

// Seeds by farthest-point sampling on graph distance, then the greedy
// capacity-respecting assignment above.
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
      d.seed_dist[s * 131072 + p] = d.dist[d.prem_snap_node[p]] as i32;
      ++p;
    }
    ++s;
  }

  AssignPremises(ref d);
}

// ---------------------------------------------------------------------------
// Stage 3b — serving-area rebalance (pack cabinets to capacity)
// ---------------------------------------------------------------------------

// Balanced clustering spreads slack across every serving area, which
// strands cabinet capacity (five areas at ~85% fill each need five full
// cabinets). This pass concentrates the slack instead: boundary premises
// move from the emptiest cluster into the fullest not-yet-full cluster —
// nearest to the receiver's seed first — until at most one partial area
// remains, which then gets a right-sized smaller cabinet. Because k is
// the minimal cluster count, the tail can never drain to empty; the
// last-premises guard is belt and braces.
fn RebalanceClusters(ref d: Design) {
  var guard: i32 = 0;
  while (guard < d.prem_count) {
    ++guard;
    // Receiver: fullest cluster below capacity. Donor: emptiest cluster.
    var recv: i32 = -1;
    var recv_units: i32 = -1;
    var donor: i32 = -1;
    var donor_units: i32 = 2147483647;
    var c: i32 = 0;
    while (c < d.cluster_count) {
      if (d.cluster_units[c] < MaxUnitsPerFdh() and
          d.cluster_units[c] > recv_units) {
        recv_units = d.cluster_units[c];
        recv = c;
      }
      if (d.cluster_units[c] < donor_units) {
        donor_units = d.cluster_units[c];
        donor = c;
      }
      ++c;
    }
    if (recv == -1 or recv == donor or d.cluster_prems[donor] <= 1) {
      break;
    }
    // Donor premises nearest to the receiver's seed that fits.
    var best_p: i32 = -1;
    var best_d: i32 = 2147483647;
    var p: i32 = 0;
    while (p < d.prem_count) {
      if (d.prem_cluster[p] == donor and
          d.cluster_units[recv] + d.prem_units[p] <= MaxUnitsPerFdh()) {
        let dd: i32 = d.seed_dist[recv * 131072 + p];
        if (dd < best_d) {
          best_d = dd;
          best_p = p;
        }
      }
      ++p;
    }
    if (best_p == -1) {
      break;
    }
    d.prem_cluster[best_p] = recv;
    d.cluster_units[recv] += d.prem_units[best_p];
    d.cluster_prems[recv] += 1;
    d.cluster_units[donor] -= d.prem_units[best_p];
    d.cluster_prems[donor] -= 1;
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

    // Cap the candidate list at 64 nodes: keep every ceil(distinct/64)-th
    // distinct snap node in first-seen order (deterministic stride
    // sampling), so the medoid scan stays bounded on large serving areas.
    if (cand_count > 64) {
      let stride: i32 = CeilDiv(cand_count, 64);
      var kept: i32 = 0;
      var src: i32 = 0;
      while (src < cand_count) {
        cand[kept] = cand[src];
        ++kept;
        src += stride;
      }
      cand_count = kept;
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
// Stage 3c — re-assign premises to the sites actually built (one Lloyd step)
// ---------------------------------------------------------------------------

// The defect this closes (research.md 1.1 item 2, appendix A finding D7):
// `seed_dist` is measured from FARTHEST-POINT seeds, which are by
// construction extremal nodes of the road graph, and PlaceFdh then
// relocates every cabinet to a unit-weighted medoid and never re-assigns.
// So the design optimized its assignment against reference points it does
// not build, and every distribution fibre-metre downstream is priced off
// the wrong table. Refilling `seed_dist` from `fdh_node` and re-running the
// same greedy is exactly Lloyd's assignment step (A) at the updated
// centers (B) — the only step whose exactness the descent proof needs.
//
// The cabinets stay where they are: re-running PlaceFdh here would move
// the site off the members it was just assigned and reopen the same
// mismatch one order smaller. `seed_dist` is scratch after this point
// (PackTerminals reuses the array), so nothing downstream sees the seeds.

// Unit-weighted graph meters from every premises to its serving area's
// cabinet — the objective stage 3c descends, and the quantity the
// distribution cable BOM is a concave function of.
fn AssignCost(ref d: Design) -> i64 {
  var total: i64 = 0;
  var p: i32 = 0;
  while (p < d.prem_count) {
    let c: i32 = d.prem_cluster[p];
    if (c >= 0) {
      total += (d.seed_dist[c * 131072 + p] as i64) * (d.prem_units[p] as i64);
    }
    ++p;
  }
  return total;
}

fn ReassignToFdh(ref d: Design) {
  var c: i32 = 0;
  while (c < d.cluster_count) {
    DijkstraFrom(ref d, d.fdh_node[c], ModeMeters());
    var p: i32 = 0;
    while (p < d.prem_count) {
      d.seed_dist[c * 131072 + p] = d.dist[d.prem_snap_node[p]] as i32;
      ++p;
    }
    ++c;
  }
  // Priced on the same table on both sides: what the seed-based assignment
  // actually costs at the built sites, then what one Lloyd step costs.
  d.assign_cost_seed = AssignCost(ref d);
  AssignPremises(ref d);
  d.assign_cost_lloyd = AssignCost(ref d);
  d.assign_cost_exact = d.assign_cost_lloyd;
}

// ---------------------------------------------------------------------------
// Stage 3d — exact capacitated transportation repair (research.md 1.2)
// ---------------------------------------------------------------------------

// One greedy pass is not the assignment step Lloyd's descent proof needs:
// "nearest site with room" processed in id order exiles whatever is
// considered last into whichever area still has slack, at unbounded ratio.
// (Measured here: with the Lloyd step alone, premises 6710-6716 land 10 km
// from their cabinet in the leftover area and blow the optical budget.)
//
// The exact fix is small because the problem is small. With integer demands
// the assignment LP is a transportation problem, totally unimodular, so the
// LP optimum IS the integer optimum; and the residual network condenses
// onto the k <= 32 facilities: arc j -> j' priced at the cheapest single
// premises that could move from j to j'. A feasible assignment is optimal
// exactly when that condensed digraph has no negative cycle, so the repair
// is: Bellman-Ford, cancel the cycle it finds, repeat. Every cancellation
// strictly decreases a non-negative integer objective, so it terminates.
//
// Node k is a slack node: `j -> k` exists when j can absorb one more unit
// and `k -> j` when j can release one, so a cycle through it is exactly an
// improving PATH from a full area to one with spare capacity.
//
// Premises stay single-sourced (whole premises move, never fibres), and the
// cycle is applied only if it keeps every area within the 432-unit cabinet
// cap and non-empty — with u_p > 1 (MDU fixtures) a cycle need not preserve
// loads, and a repair that breaks capacity to save meters is not a repair.
fn TransportRepair(ref d: Design) {
  let k: i32 = d.cluster_count;
  if (k < 2) {
    return;
  }
  let vn: i32 = k + 1;      // facilities + the slack node
  let slack: i32 = k;
  let cap: i32 = MaxUnitsPerFdh();
  let inf: i64 = 4611686018427387904;   // half i64 max: safe to add to
  d.assign_stop = 1;                    // downgraded on every clean exit

  var w: array(i64, 263169);      // 513 x 513 condensed arc cost
  var arg: array(i32, 263169);    // the premises each arc would move
  var bfd: array(i64, 513);
  var bfp: array(i32, 513);
  var cyc: array(i32, 514);
  var dl: array(i32, 513);       // per-area unit delta of the pending cycle
  var dp: array(i32, 513);       // per-area premises delta

  var guard: i32 = 0;
  while (guard < 4096) {
    ++guard;

    // (1) Condense the residual network onto the facilities.
    var u: i32 = 0;
    while (u < vn) {
      var v: i32 = 0;
      while (v < vn) {
        w[u * 513 + v] = inf;
        arg[u * 513 + v] = -1;
        ++v;
      }
      ++u;
    }
    var p: i32 = 0;
    while (p < d.prem_count) {
      let j: i32 = d.prem_cluster[p];
      if (j >= 0) {
        let up: i64 = d.prem_units[p] as i64;
        let dj: i64 = d.seed_dist[j * 131072 + p] as i64;
        var t: i32 = 0;
        while (t < k) {
          if (t != j) {
            let delta: i64 =
                up * ((d.seed_dist[t * 131072 + p] as i64) - dj);
            let idx: i32 = j * 513 + t;
            // Ties -> lowest premises id, so the cycle is reproducible.
            if (delta < w[idx]) {
              w[idx] = delta;
              arg[idx] = p;
            }
          }
          ++t;
        }
      }
      ++p;
    }
    var j2: i32 = 0;
    while (j2 < k) {
      if (d.cluster_units[j2] < cap) {
        w[j2 * 513 + slack] = 0;     // j2 can absorb a unit
      }
      if (d.cluster_prems[j2] > 1) {
        w[slack * 513 + j2] = 0;     // j2 can release one and stay non-empty
      }
      ++j2;
    }

    // (2) Bellman-Ford with every label at zero — a virtual source into all
    // nodes, so any negative cycle anywhere is detected. vn passes; a
    // relaxation in the last one proves a negative cycle exists.
    var v0: i32 = 0;
    while (v0 < vn) {
      bfd[v0] = 0;
      bfp[v0] = -1;
      ++v0;
    }
    var found: i32 = -1;
    var pass: i32 = 0;
    while (pass < vn) {
      found = -1;
      var uu: i32 = 0;
      while (uu < vn) {
        var vv: i32 = 0;
        while (vv < vn) {
          let wt: i64 = w[uu * 513 + vv];
          if (wt < inf and bfd[uu] + wt < bfd[vv]) {
            bfd[vv] = bfd[uu] + wt;
            bfp[vv] = uu;
            found = vv;
          }
          ++vv;
        }
        ++uu;
      }
      if (found == -1) {
        break;
      }
      ++pass;
    }
    if (found == -1) {
      d.assign_stop = 0;            // no negative cycle: certified optimal
      break;
    }

    // (3) Walk vn predecessors back from the last relaxed node to land
    // inside the cycle, then read the cycle off the predecessor chain.
    var x: i32 = found;
    var step: i32 = 0;
    var broken: bool = false;
    while (step < vn) {
      if (bfp[x] == -1) {
        broken = true;
        break;
      }
      x = bfp[x];
      ++step;
    }
    if (broken) {
      d.assign_stop = 2;
      break;
    }
    var clen: i32 = 1;
    cyc[0] = x;
    var y: i32 = bfp[x];
    while (y != x and clen < 34) {
      if (y == -1) {
        broken = true;
        break;
      }
      cyc[clen] = y;
      ++clen;
      y = bfp[y];
    }
    if (broken or y != x) {
      d.assign_stop = 2;
      break;
    }

    // (4) Price the cycle and stage its load deltas. cyc is in predecessor
    // order, so the arcs are cyc[i+1] -> cyc[i], closing cyc[0] -> cyc[-1].
    var ci: i32 = 0;
    while (ci < vn) {
      dl[ci] = 0;
      dp[ci] = 0;
      ++ci;
    }
    var gain: i64 = 0;
    var arcs: i32 = 0;
    var a: i32 = 0;
    while (a < clen) {
      var from: i32 = cyc[0];
      if (a + 1 < clen) {
        from = cyc[a + 1];
      }
      let to: i32 = cyc[a];
      let wt2: i64 = w[from * 513 + to];
      if (wt2 >= inf) {
        broken = true;
        break;
      }
      gain += wt2;
      if (from != slack and to != slack) {
        let mp: i32 = arg[from * 513 + to];
        if (mp < 0) {
          broken = true;
          break;
        }
        dl[from] -= d.prem_units[mp];
        dl[to] += d.prem_units[mp];
        dp[from] -= 1;
        dp[to] += 1;
        ++arcs;
      }
      ++a;
    }
    if (broken or gain >= 0 or arcs == 0) {
      d.assign_stop = 2;            // nothing provably improving left
      break;
    }
    var feasible: bool = true;
    var c2: i32 = 0;
    while (c2 < k) {
      if (d.cluster_units[c2] + dl[c2] > cap or
          d.cluster_prems[c2] + dp[c2] < 1) {
        feasible = false;
      }
      ++c2;
    }
    if (not feasible) {
      d.assign_stop = 2;            // MDU-sized cycle would break a cabinet
      break;
    }

    // (5) Apply. Each area appears once in a simple cycle, so the premises
    // moved are distinct and the pre-cycle argmins all stay valid.
    a = 0;
    while (a < clen) {
      var from2: i32 = cyc[0];
      if (a + 1 < clen) {
        from2 = cyc[a + 1];
      }
      let to2: i32 = cyc[a];
      if (from2 != slack and to2 != slack) {
        d.prem_cluster[arg[from2 * 513 + to2]] = to2;
      }
      ++a;
    }
    var c3: i32 = 0;
    while (c3 < k) {
      d.cluster_units[c3] += dl[c3];
      d.cluster_prems[c3] += dp[c3];
      ++c3;
    }
    d.assign_cycles += 1;
    d.assign_moved += arcs;
  }
  d.assign_cost_exact = AssignCost(ref d);
}

// ---------------------------------------------------------------------------
// Stage 6 — terminal packing along the distribution tree
// ---------------------------------------------------------------------------

// Closes the open terminal: picks the smallest catalog size covering the
// ports actually used, so remainders never strand a 12-port unit.
// Marginal trench price of putting a terminal on `node`, in cents — the
// term every move price in this file was missing (research.md 5.1b: of
// the whole engine, TrenchCostPerM appeared ONCE, inside DeloopTrench's
// Dijkstra, so the stage that decides which ~1,700 nodes the trench must
// reach could not see the cost of reaching them). Zero on the first sweep
// and zero for every node the routed trench already touches; ComputePi
// fills the rest from the previous sweep's tree. Once a terminal is sited
// at a node the spur is bought, so later moves there price it at zero —
// otherwise a second batch on the same corner would pay for the same
// trench twice.
fn NodePi(ref d: Design, node: i32) -> i64 {
  if (d.pi_bought[node]) {
    return 0;
  }
  return d.node_pi[node] as i64;
}

fn CloseTerminal(ref d: Design, t: i32) {
  var idx: i32 = 0;
  while (idx < TerminalSizeCount() - 1 and
         TerminalSize(idx) < d.term_ports_used[t]) {
    ++idx;
  }
  d.term_size_idx[t] = idx;
}

// Move-comparison for the packing greedy: is (cost, k, node_i, kind) a
// strictly better per-premises move than the incumbent (bcost, bk, ...)?
// Ratio compare cost/k < bcost/bk via cross-multiplication (exact, no
// floats); ties prefer new-batch over attach, then the lower candidate
// node index, then the larger batch. bk == 0 means "no incumbent yet".
fn MoveBetter(cost: i64, k: i32, node_i: i32, kind: i32,
              bcost: i64, bk: i32, bnode_i: i32, bkind: i32) -> bool {
  if (bk == 0) {
    return true;
  }
  let lhs: i64 = cost * (bk as i64);
  let rhs: i64 = bcost * (k as i64);
  if (lhs != rhs) {
    return lhs < rhs;
  }
  if (kind != bkind) {
    return kind < bkind;
  }
  if (node_i != bnode_i) {
    return node_i < bnode_i;
  }
  return k > bk;
}

// Packs premises onto shared access terminals — node-centric set-cover
// greedy (iter 004; replaces the DFS-order DP of iters 001/003).
//
// The DP was optimal for its sequence, but the sequence was the binding
// constraint: batches had to be CONSECUTIVE runs of a linear order, while
// the cheap groups in parcel geometry are the premises AROUND a shared
// tree node (the 2-4 lots meeting at a corner reach it with zero street
// crossings). Two optimal-partition variants both stalled at ~5,400
// district crossings; a node-centric simulation cut that to ~1,550.
//
// Moves, priced exactly like the scorer (cents):
//   new-batch(node, k): open a k-port terminal (catalog k, or a 1-premises
//     fallback) at a tree node, serving the k cheapest available members
//     by (crossings, distance) — cost = 50000/crossing + hardware +
//     $1.50/m drop + 100000 if k < 4;
//   attach(node): grow the terminal already at the node by one port for
//     its cheapest available member — cost = 50000/crossing + hardware
//     step to the next catalog size + $1.50/m drop, minus 100000 when the
//     growth lifts the terminal out of the under-4 band.
// The greedy repeatedly commits the move with the lowest cost PER
// premises (exact ratio compare), so clean corner groups form first and
// stragglers attach to neighbours instead of forcing crossings or
// 2-port strays. MergeTerminals later dissolves what remains into the
// spare ports the attach moves create.
fn PackTerminals(ref d: Design, c: i32) {
  // Terminal candidate nodes: EVERY road node within drop reach of a
  // member, in ascending node id (deterministic). Packing runs BEFORE
  // distribution routing: terminals define the demand nodes, and the
  // trench is then routed TO them — so terminals sit on open trench by
  // construction instead of being confined to a tree shaped around
  // premises snap nodes (which cost ~1,800 extra forced crossings).

  // Members of this serving area, in premises-id order.
  var mem: array(i32, 512);
  var mcount: i32 = 0;
  var pm: i32 = 0;
  while (pm < d.prem_count) {
    if (d.prem_cluster[pm] == c and mcount < 512) {
      mem[mcount] = pm;
      ++mcount;
    }
    ++pm;
  }

  // Pair table: for every candidate node, every member within drop reach,
  // as (hi, lo) i32 pairs in the dead seed_dist array (hi = crossings *
  // 65536 + drop meters, lo = premises id), sorted ascending per node
  // segment — so a segment walk yields members in (crossings, distance,
  // id) order. Segments are indexed by node id. Each member keeps at most
  // 384 candidate nodes (first by ascending node id; the cap plus the
  // 512-member cap bounds the table at 196608 pairs, exactly seed_dist's
  // capacity). Pass 1 counts, pass 2 fills — identical scan order and cap
  // logic, so both passes see the same pairs.
  var cnt: array(i32, 98304);
  var ci: i32 = 0;
  while (ci < d.node_count) {
    cnt[ci] = 0;
    ++ci;
  }
  var pass: i32 = 0;
  var off: array(i32, 98305);
  var fill: array(i32, 98304);
  while (pass < 2) {
    var mi: i32 = 0;
    while (mi < mcount) {
      let p: i32 = mem[mi];
      var kept: i32 = 0;
      var n: i32 = 0;
      while (n < d.node_count and kept < 384) {
        if (d.node_x[n] >= d.prem_x[p] - MaxDropM() and
            d.node_x[n] <= d.prem_x[p] + MaxDropM() and
            d.node_y[n] >= d.prem_y[p] - MaxDropM() and
            d.node_y[n] <= d.prem_y[p] + MaxDropM()) {
          let dd: i32 = DistM(d.prem_x[p], d.prem_y[p],
                              d.node_x[n], d.node_y[n]);
          if (dd <= MaxDropM()) {
            if (pass == 0) {
              cnt[n] += 1;
            } else {
              var xc: i32 = CountDropCrossings(ref d, d.prem_x[p],
                                               d.prem_y[p], n);
              if (xc > 32000) {
                xc = 32000;  // keep hi within i32 (never near in practice)
              }
              d.seed_dist[fill[n] * 2] = xc * 65536 + dd;
              d.seed_dist[fill[n] * 2 + 1] = p;
              fill[n] += 1;
            }
            ++kept;
          }
        }
        ++n;
      }
      ++mi;
    }
    if (pass == 0) {
      // Prefix offsets, then reset fill cursors to segment starts.
      off[0] = 0;
      var oi: i32 = 0;
      while (oi < d.node_count) {
        off[oi + 1] = off[oi] + cnt[oi];
        fill[oi] = off[oi];
        ++oi;
      }
    }
    ++pass;
  }

  // Insertion sort within each node segment (segments are small), on
  // (hi, lo) — i.e. (crossings, distance, premises id).
  var sn: i32 = 0;
  while (sn < d.node_count) {
    var si: i32 = off[sn] + 1;
    while (si < off[sn + 1]) {
      let key_hi: i32 = d.seed_dist[si * 2];
      let key_lo: i32 = d.seed_dist[si * 2 + 1];
      var sj: i32 = si - 1;
      while (sj >= off[sn] and
             (d.seed_dist[sj * 2] > key_hi or
              (d.seed_dist[sj * 2] == key_hi and
               d.seed_dist[sj * 2 + 1] > key_lo))) {
        d.seed_dist[sj * 2 + 2] = d.seed_dist[sj * 2];
        d.seed_dist[sj * 2 + 3] = d.seed_dist[sj * 2 + 1];
        --sj;
      }
      d.seed_dist[sj * 2 + 2] = key_hi;
      d.seed_dist[sj * 2 + 3] = key_lo;
      ++si;
    }
    ++sn;
  }

  // term_at[node] = the attachable terminal at that node (the newest one
  // placed there this cluster). dead[node] = segment empty or fully
  // assigned; members never become available again, so dead stays dead.
  var term_at: array(i32, 98304);
  var ta: i32 = 0;
  while (ta < d.node_count) {
    term_at[ta] = -1;
    ++ta;
  }
  var dead: array(bool, 98304);
  var di: i32 = 0;
  while (di < d.node_count) {
    dead[di] = off[di + 1] == off[di];
    ++di;
  }

  var remaining: i32 = mcount;
  while (remaining > 0) {
    var bcost: i64 = 0;
    var bk: i32 = 0;
    var bnode_i: i32 = -1;
    var bkind: i32 = 0;
    var ni: i32 = 0;
    while (ni < d.node_count) {
      if (dead[ni]) {
        ++ni;
        continue;
      }
      // First 12 available members of this segment, cheapest first.
      var ac: array(i32, 12);
      var ad: array(i32, 12);
      var na: i32 = 0;
      var s: i32 = off[ni];
      while (s < off[ni + 1] and na < 12) {
        let pid: i32 = d.seed_dist[s * 2 + 1];
        if (d.prem_terminal[pid] == -1) {
          let hi: i32 = d.seed_dist[s * 2];
          ac[na] = hi / 65536;
          ad[na] = hi % 65536;
          ++na;
        }
        ++s;
      }
      if (na == 0) {
        dead[ni] = true;
        ++ni;
        continue;
      }
      // New-batch moves at catalog sizes (plus the 1-premises fallback).
      // A new batch is a new node for the trench to reach, so it carries
      // the marginal trench price; the ratio compare then amortizes that
      // spur over the batch, exactly as the ConFL greedy does.
      let pi_open: i64 = NodePi(ref d, ni);
      var pc: i64 = 0;
      var pd: i64 = 0;
      var kk: i32 = 0;
      while (kk < na) {
        pc += ac[kk] as i64;
        pd += ad[kk] as i64;
        let k: i32 = kk + 1;
        if (k == 1 or k == 2 or k == 4 or k == 6 or k == 8 or k == 12) {
          var sidx: i32 = 0;
          while (sidx < TerminalSizeCount() - 1 and TerminalSize(sidx) < k) {
            ++sidx;
          }
          var cost: i64 = 50000 * pc + TerminalCost(sidx) +
                          DropCablePerM() * pd + pi_open;
          if (k < 4) {
            cost += 100000;
          }
          if (MoveBetter(cost, k, ni, 0, bcost, bk, bnode_i, bkind)) {
            bcost = cost;
            bk = k;
            bnode_i = ni;
            bkind = 0;
          }
        }
        ++kk;
      }
      // Attach move: grow the terminal already here by one port.
      let t: i32 = term_at[ni];
      if (t != -1 and d.term_ports_used[t] < 12) {
        let used: i32 = d.term_ports_used[t];
        var nidx: i32 = 0;
        while (nidx < TerminalSizeCount() - 1 and
               TerminalSize(nidx) < used + 1) {
          ++nidx;
        }
        // Trench price too, for symmetry with the new-batch move — it is
        // zero by construction here (a terminal already stands on ni, so
        // the spur is bought), which is precisely why attach should get
        // cheaper relative to opening off-corridor.
        var cost2: i64 = 50000 * (ac[0] as i64) +
                         TerminalCost(nidx) -
                         TerminalCost(d.term_size_idx[t]) +
                         DropCablePerM() * (ad[0] as i64) +
                         NodePi(ref d, ni);
        if (used == 3) {
          cost2 -= 100000;  // growth lifts the terminal out of under-4
        }
        if (MoveBetter(cost2, 1, ni, 1, bcost, bk, bnode_i, bkind)) {
          bcost = cost2;
          bk = 1;
          bnode_i = ni;
          bkind = 1;
        }
      }
      ++ni;
    }
    if (bk == 0) {
      break;  // nobody left in reach of any candidate; QA reports them
    }

    // Commit: re-walk the winning segment for its bk cheapest available
    // members (same order the pricing walk saw).
    let node: i32 = bnode_i;
    var tgt: i32 = -1;
    if (bkind == 0) {
      if (d.term_count >= MaxTerminals()) {
        break;  // terminal store exhausted; QA reports the unserved rest
      }
      tgt = d.term_count;
      ++d.term_count;
      d.term_node[tgt] = node;
      d.term_cluster[tgt] = c;
      d.term_ports_used[tgt] = 0;
      d.term_path_len[tgt] = 0;  // set after distribution routing
      term_at[node] = tgt;
      d.pi_bought[node] = true;  // spur to this node is now paid for
    } else {
      tgt = term_at[node];
    }
    var taken: i32 = 0;
    var cs: i32 = off[bnode_i];
    while (cs < off[bnode_i + 1] and taken < bk) {
      let pid: i32 = d.seed_dist[cs * 2 + 1];
      if (d.prem_terminal[pid] == -1) {
        d.prem_terminal[pid] = tgt;
        d.prem_drop_len[pid] = d.seed_dist[cs * 2] % 65536;
        d.term_ports_used[tgt] += 1;
        ++taken;
        --remaining;
      }
      ++cs;
    }
    CloseTerminal(ref d, tgt);
  }
}

// ---------------------------------------------------------------------------
// Stage 5 — distribution routing (Steiner approximation per serving area)
// ---------------------------------------------------------------------------

// Per serving area: pack terminals first (stage 6, node-centric greedy),
// then grow a Steiner-approximation tree whose demand nodes are the
// TERMINAL nodes (unit-weighted), Takahashi–Matsuyama style: repeatedly
// attach the demand node nearest to the current tree by a fresh
// multi-source Dijkstra, so shared path prefixes are trenched once.
fn RouteDistribution(ref d: Design) {
  var c: i32 = 0;
  while (c < d.cluster_count) {
    // Terminals first (iter 004): packing picks the crossing-minimal
    // terminal nodes, and those terminals then ARE the demand the trench
    // is routed to — so every terminal sits on open trench by
    // construction, and fibers feed terminal locations instead of
    // premises snap nodes (the backlog 6b accounting gap).
    PackTerminals(ref d, c);

    // Reset per-cluster tree state and per-node demand (terminal nodes,
    // weighted by their premises' units).
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
      if (d.prem_cluster[p] == c and d.prem_terminal[p] != -1) {
        d.node_units[d.term_node[d.prem_terminal[p]]] += d.prem_units[p];
      }
      ++p;
    }
    d.in_tree[d.fdh_node[c]] = true;

    // Takahashi–Matsuyama: repeatedly attach the demand node nearest to
    // the CURRENT tree by a fresh multi-source Dijkstra. Costlier than a
    // single shortest-path tree but measurably better for terminal
    // packing: the bushier tree keeps DFS batches contiguous, which is
    // worth ~1.6 points of terminal-port utilization on the golden
    // fixture (a single-pass SPT variant fails the 95% floor).
    while (true) {
      DijkstraReset(ref d);
      n = 0;
      while (n < d.node_count) {
        if (d.in_tree[n]) {
          AddSource(ref d, n);
        }
        ++n;
      }
      DijkstraRun(ref d, ModeMeters());

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
        break;  // all reachable demand attached; QA reports the rest
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

    // Terminal route lengths, now that the tree to their nodes exists.
    var t: i32 = 0;
    while (t < d.term_count) {
      if (d.term_cluster[t] == c and d.in_tree[d.term_node[t]]) {
        d.term_path_len[t] = d.node_path_m[d.term_node[t]];
      }
      ++t;
    }
    ++c;
  }
}

// ---------------------------------------------------------------------------
// Stage 6b — terminal merge/shrink repair (utilization floor)
// ---------------------------------------------------------------------------

fn MovePremises(ref d: Design, p: i32, from: i32, to: i32) {
  d.prem_terminal[p] = to;
  d.prem_drop_len[p] = DistM(d.prem_x[p], d.prem_y[p],
                             d.node_x[d.term_node[to]],
                             d.node_y[d.term_node[to]]);
  d.term_ports_used[from] -= 1;
  d.term_ports_used[to] += 1;
}

// Dissolves a terminal if every one of its premises fits on other
// terminals within drop reach AND (unless `force`) the move is
// scorer-positive: the hardware retired plus any under-4 penalties
// cleared must exceed the street-crossing, drop-cable and hardware-step
// cost of the relocated drops. The un-priced version silently traded
// ~4,900 street crossings for utilization on the district.
//
// Growth-aware (iter 006): in priced mode a target no longer needs a
// spare port within its CHOSEN size — stepping it up the catalog
// (4p -> 6p is $30) is just another cent line in the move price, and it
// is what clears the geometry-forced under-4 strays whose neighbours sit
// exactly full. Guard rail: the district lands exactly on the 95%
// terminal-port utilization floor, so a priced dissolve must keep the
// aggregate INSTALLED-port delta <= 0 (retired ports must cover any
// growth) or the floor repair would buy the ports back with forced
// dissolves. Force mode stays strictly no-growth: its whole purpose is
// shrinking installed ports, and no-growth keeps its delta = -size(t).
// Every member's chosen target is recorded during the pricing scan and
// the commit replays the record, so scan and commit cannot diverge.
// Returns true if emptied.
fn TryDissolve(ref d: Design, t: i32, force: bool) -> bool {
  let allow_grow: bool = not force;
  // Members of t, in premises-id order (a terminal serves at most 12).
  var mp: array(i32, 12);
  var mn: i32 = 0;
  var p0: i32 = 0;
  while (p0 < d.prem_count) {
    if (d.prem_terminal[p0] == t) {
      if (mn >= 12) {
        return false;  // over-full terminal; refuse rather than misprice
      }
      mp[mn] = p0;
      ++mn;
    }
    ++p0;
  }
  if (mn == 0) {
    return false;
  }
  // Pricing scan against scratch copies of every terminal's fill and
  // size (both evolve as members are assigned).
  var scratch: array(i32, 65536);
  var ssize: array(i32, 65536);
  var u: i32 = 0;
  while (u < d.term_count) {
    scratch[u] = d.term_ports_used[u];
    ssize[u] = d.term_size_idx[u];
    ++u;
  }
  // Gain: retired hardware, plus 100000 if t itself is an under-4 stray,
  // plus 100000 per target this dissolve lifts across the 4-port line.
  var gain: i64 = TerminalCost(d.term_size_idx[t]);
  if (d.term_ports_used[t] < 4) {
    gain += 100000;
  }
  // ... plus the trench spur this terminal forced, if no other live
  // terminal still stands on its node (iter 008). This is the same
  // ConFL price the packing move pays on the way in; retiring an
  // off-corridor terminal releases the civil cost of reaching it, which
  // is exactly the trade the merge pass could not see before.
  var shares_node: bool = false;
  var q: i32 = 0;
  while (q < d.term_count) {
    if (q != t and d.term_ports_used[q] > 0 and
        d.term_node[q] == d.term_node[t]) {
      shares_node = true;
      break;
    }
    ++q;
  }
  if (not shares_node) {
    gain += d.node_pi[d.term_node[t]] as i64;
  }
  var cost: i64 = 0;
  var installed_delta: i64 = 0 - (TerminalSize(d.term_size_idx[t]) as i64);
  var chosen: array(i32, 12);
  var mi: i32 = 0;
  while (mi < mn) {
    let p: i32 = mp[mi];
    // Cheapest target in cents: 50000/crossing + hardware step (0 while
    // the target still has an in-size spare port) + $1.50/m drop.
    // Ties: fewer crossings, then nearer, then lower terminal id.
    var best: i32 = -1;
    var best_cost: i64 = 0;
    var best_step: i64 = 0;
    var best_cross: i32 = 0;
    var best_dist: i32 = 0;
    var v: i32 = 0;
    while (v < d.term_count) {
      if (v != t and d.term_cluster[v] == d.prem_cluster[p] and
          scratch[v] > 0 and scratch[v] < 12) {
        var step: i64 = 0;
        var ok: bool = true;
        if (scratch[v] >= TerminalSize(ssize[v])) {
          if (allow_grow) {
            var gidx: i32 = ssize[v];
            while (gidx < TerminalSizeCount() - 1 and
                   TerminalSize(gidx) < scratch[v] + 1) {
              ++gidx;
            }
            step = TerminalCost(gidx) - TerminalCost(ssize[v]);
          } else {
            ok = false;
          }
        }
        if (ok) {
          let dd: i32 = DistM(d.prem_x[p], d.prem_y[p],
                              d.node_x[d.term_node[v]],
                              d.node_y[d.term_node[v]]);
          if (dd <= MaxDropM()) {
            let xc: i32 = CountDropCrossings(ref d, d.prem_x[p], d.prem_y[p],
                                             d.term_node[v]);
            // Trench price of the receiving node, for symmetry with the
            // packing moves — zero by construction (v is a live terminal,
            // so its spur is already bought), but priced explicitly so
            // every move in the file reads the same cost model.
            let mc: i64 = 50000 * (xc as i64) + step +
                          DropCablePerM() * (dd as i64) +
                          NodePi(ref d, d.term_node[v]);
            if (best == -1 or mc < best_cost or
                (mc == best_cost and
                 (xc < best_cross or
                  (xc == best_cross and dd < best_dist)))) {
              best = v;
              best_cost = mc;
              best_step = step;
              best_cross = xc;
              best_dist = dd;
            }
          }
        }
      }
      ++v;
    }
    if (best == -1) {
      return false;
    }
    let old_cross: i32 = CountDropCrossings(ref d, d.prem_x[p], d.prem_y[p],
                                            d.term_node[t]);
    cost += 50000 * ((best_cross - old_cross) as i64) + best_step +
            DropCablePerM() * ((best_dist - d.prem_drop_len[p]) as i64) +
            NodePi(ref d, d.term_node[best]);  // zero: spur already bought
    if (scratch[best] == 3) {
      gain += 100000;  // target crosses the under-4 line at 4
    }
    scratch[best] += 1;
    if (scratch[best] > TerminalSize(ssize[best])) {
      var nidx: i32 = ssize[best];
      while (nidx < TerminalSizeCount() - 1 and
             TerminalSize(nidx) < scratch[best]) {
        ++nidx;
      }
      installed_delta +=
          (TerminalSize(nidx) - TerminalSize(ssize[best])) as i64;
      ssize[best] = nidx;
    }
    chosen[mi] = best;
    ++mi;
  }
  if (not force and (cost >= gain or installed_delta > 0)) {
    return false;
  }
  // Feasible (and priced, unless forced): replay the recorded choices.
  var ci: i32 = 0;
  while (ci < mn) {
    MovePremises(ref d, mp[ci], t, chosen[ci]);
    CloseTerminal(ref d, chosen[ci]);
    ++ci;
  }
  return true;
}

// Utilization repair, scorer-priced (iter 004): (1) dissolve terminals
// into neighbours' spare ports when the retired hardware plus cleared
// under-4 penalties outweigh the added crossings and drop cable; then
// (2) if the aggregate terminal-port utilization still misses the QA
// floor, force-dissolve the smallest dissolvable terminals (fewest
// moves, least damage) until it holds — the floor is a hard gate, so
// this may buy crossings, but only as a last resort, never silently.
// The old shrink phase is gone: shedding overhang premises paid
// un-priced crossings for a $30-70 hardware step.
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
          if (TryDissolve(ref d, t, false)) {
            changed = true;
          }
        }
        ++t;
      }
      ++used_level;
    }
    ++pass;
  }

  // Re-close every live terminal at its final fill before measuring.
  var t2: i32 = 0;
  while (t2 < d.term_count) {
    if (d.term_ports_used[t2] > 0) {
      CloseTerminal(ref d, t2);
    }
    ++t2;
  }

  // Utilization-floor repair: forced dissolves, smallest fills first.
  var guard: i32 = 0;
  while (guard < d.term_count) {
    ++guard;
    var used: i64 = 0;
    var installed: i64 = 0;
    var t3: i32 = 0;
    while (t3 < d.term_count) {
      if (d.term_ports_used[t3] > 0) {
        used += d.term_ports_used[t3] as i64;
        installed += TerminalSize(d.term_size_idx[t3]) as i64;
      }
      ++t3;
    }
    if (installed <= 0 or
        used * 1000 >= (UtilizationFloorPct() as i64) * 10 * installed) {
      break;  // floor holds
    }
    var done: bool = false;
    var lvl: i32 = 1;
    while (lvl < TerminalSize(TerminalSizeCount() - 1) and not done) {
      var t4: i32 = 0;
      while (t4 < d.term_count and not done) {
        if (d.term_ports_used[t4] == lvl) {
          if (TryDissolve(ref d, t4, true)) {
            done = true;
          }
        }
        ++t4;
      }
      ++lvl;
    }
    if (not done) {
      break;  // nothing dissolvable; QA reports the floor miss honestly
    }
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

    // Splitter bank: full 1:32s, then the remainder covered by the
    // minimum installed ports — rounded up to the smallest splitter's
    // granularity and filled greedily from the largest that fits. Buying
    // ONE covering splitter for the remainder stranded ports (26 ports
    // demanded a 1:32 at 81%); 16+8+2 covers it exactly.
    let top_idx: i32 = SplitterSizeCount() - 1;
    let full: i32 = take / SplitterSize(top_idx);
    let rem: i32 = take % SplitterSize(top_idx);
    d.fdh_split_by_size[c * 5 + top_idx] = full;
    var count: i32 = full;
    if (rem > 0) {
      var need: i32 = CeilDiv(rem, SplitterSize(0)) * SplitterSize(0);
      var idx: i32 = top_idx;
      while (need > 0) {
        while (idx > 0 and SplitterSize(idx) > need) {
          --idx;
        }
        d.fdh_split_by_size[c * 5 + idx] += 1;
        ++count;
        need -= SplitterSize(idx);
      }
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
// Places the head-ends. The first is the splitter-weighted 1-median over
// FDH sites — the historical single-CO choice, so any design whose feeders
// already fit the optical budget is unchanged. Then, while some serving
// area's feeder would blow its share of MaxRouteM, open another head-end at
// the worst-served FDH (farthest-first / k-center greedy, which bounds the
// covering radius) and re-assign every area to its nearest head-end.
//
// Each area's feeder allowance is MaxRouteM minus the longest
// distribution+drop tail it already carries, so the budget QA check and the
// placement rule are the same arithmetic.
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
  d.co_nodes[0] = best_node;
  d.co_count = 1;
  var z: i32 = 0;
  while (z < d.node_count) {
    d.is_co[z] = false;
    ++z;
  }
  d.is_co[best_node] = true;

  // Feeder allowance per area = budget - worst (distribution + drop) tail.
  //
  // Clamped at zero on purpose. An area whose tail alone already exceeds
  // MaxRouteM has negative headroom, and no head-end position anywhere can
  // buy it back — only re-clustering can. Left negative, that area's
  // violation (dist - slack) stays large even with a head-end on top of it,
  // so it wins the farthest-first argmax every round and the greedy spends
  // its whole budget chasing a target it cannot hit while genuinely distant
  // areas go unserved. Clamped, the argmax is driven by feeder distance,
  // which is exactly what opening a head-end fixes.
  var slack: array(i32, 512);
  var c2: i32 = 0;
  while (c2 < d.cluster_count) {
    slack[c2] = MaxRouteM();
    ++c2;
  }
  var p: i32 = 0;
  while (p < d.prem_count) {
    let cc: i32 = d.prem_cluster[p];
    let tp: i32 = d.prem_terminal[p];
    if (cc >= 0 and tp >= 0) {
      let tail: i32 = d.term_path_len[tp] + d.prem_drop_len[p];
      if (MaxRouteM() - tail < slack[cc]) {
        slack[cc] = MaxRouteM() - tail;
      }
    }
    ++p;
  }
  var c2b: i32 = 0;
  while (c2b < d.cluster_count) {
    if (slack[c2b] < 0) {
      slack[c2b] = 0;
    }
    ++c2b;
  }

  // Farthest-first until every area fits its allowance.
  var guard: i32 = 0;
  var prev_over: i64 = 9223372036854775807;
  while (guard < MaxClusters()) {
    ++guard;
    DijkstraReset(ref d);
    var k: i32 = 0;
    while (k < d.co_count) {
      AddSource(ref d, d.co_nodes[k]);
      ++k;
    }
    DijkstraRun(ref d, ModeMeters());
    var worst: i32 = -1;
    var worst_over: i64 = 0;
    var c3: i32 = 0;
    while (c3 < d.cluster_count) {
      let over: i64 = d.dist[d.fdh_node[c3]] - (slack[c3] as i64);
      if (over > worst_over or
          (over == worst_over and worst >= 0 and
           d.fdh_node[c3] < d.fdh_node[worst])) {
        worst_over = over;
        worst = c3;
      }
      ++c3;
    }
    if (worst == -1 or worst_over <= 0 or d.co_count >= MaxHeadEnds() or
        d.co_count >= d.cluster_count) {
      break;
    }
    // Defensive: adding a source only ever shrinks distances, so the worst
    // violation is non-increasing and the chosen area's own violation drops
    // to <= 0. Both breaks below are unreachable in a correct run; they keep
    // a pathological input from spinning.
    if (d.is_co[d.fdh_node[worst]] or worst_over > prev_over) {
      break;
    }
    prev_over = worst_over;
    d.co_nodes[d.co_count] = d.fdh_node[worst];
    d.is_co[d.fdh_node[worst]] = true;
    ++d.co_count;
  }

  // Assign every area to its nearest head-end (ties: lowest CO index).
  var c4: i32 = 0;
  while (c4 < d.cluster_count) {
    d.cluster_co[c4] = 0;
    ++c4;
  }
  var best_d: array(i32, 512);
  var c5: i32 = 0;
  while (c5 < d.cluster_count) {
    best_d[c5] = 2147483647;
    ++c5;
  }
  var k2: i32 = 0;
  while (k2 < d.co_count) {
    DijkstraFrom(ref d, d.co_nodes[k2], ModeMeters());
    var c6: i32 = 0;
    while (c6 < d.cluster_count) {
      let dd: i64 = d.dist[d.fdh_node[c6]];
      if (dd < (best_d[c6] as i64)) {
        best_d[c6] = dd as i32;
        d.cluster_co[c6] = k2;
      }
      ++c6;
    }
    ++k2;
  }
}

// Feeder: route CO -> each FDH sequentially, nearest FDH first, with the
// sharing-aware cost mode — trench opened by distribution or an earlier
// feeder is discounted, so feeders bundle onto shared routes naturally.
fn RouteFeeder(ref d: Design) {
  var routed: array(bool, 512);
  var c: i32 = 0;
  while (c < d.cluster_count) {
    routed[c] = false;
    d.fdh_route_len[c] = 0;
    ++c;
  }

  // One nearest-first pass per head-end, so feeder length is measured to
  // the head-end that actually serves the area.
  var co: i32 = 0;
  while (co < d.co_count) {
  var round: i32 = 0;
  while (round < d.cluster_count) {
    // Nearest unrouted FDH of THIS head-end, by shared-cost metric.
    DijkstraFrom(ref d, d.co_nodes[co], ModeFeederCost());
    var best: i32 = -1;
    var best_cost: i64 = Unreached();
    c = 0;
    while (c < d.cluster_count) {
      if (not routed[c] and d.cluster_co[c] == co and
          d.dist[d.fdh_node[c]] < best_cost) {
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
    while (v != d.co_nodes[co] and d.prev_edge[v] != -1) {
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
    ++co;
  }
}

// ---------------------------------------------------------------------------
// Stage 9 — trench deloop: force the used trench acyclic, then re-route
// every cable on the resulting forest.
// ---------------------------------------------------------------------------

// BFS over forest edges from `root`, filling the per-cluster tree state:
// in_tree, tree_parent_node/edge (toward root), node_path_m. In a forest the
// BFS path IS the unique path, so parents double as the routing table.
// Deterministic: fixed adjacency order, FIFO queue (heap_node reused).
fn ForestBfs(ref d: Design, root: i32) {
  var n: i32 = 0;
  while (n < d.node_count) {
    d.in_tree[n] = false;
    d.tree_parent_node[n] = -1;
    d.tree_parent_edge[n] = -1;
    d.node_path_m[n] = 0;
    ++n;
  }
  var head: i32 = 0;
  var tail: i32 = 0;
  d.in_tree[root] = true;
  d.heap_node[tail] = root;
  ++tail;
  while (head < tail) {
    let u: i32 = d.heap_node[head];
    ++head;
    var a: i32 = d.adj_head[u];
    while (a != -1) {
      let e: i32 = d.adj_edge[a];
      let v: i32 = d.adj_to[a];
      if (d.forest_edge[e] and not d.in_tree[v]) {
        d.in_tree[v] = true;
        d.tree_parent_node[v] = u;
        d.tree_parent_edge[v] = e;
        d.node_path_m[v] = d.node_path_m[u] + d.edge_len[e];
        d.heap_node[tail] = v;
        ++tail;
      }
      a = d.adj_next[a];
    }
  }
  d.heap_size = 0;
}

// ---------------------------------------------------------------------------
// Stage 9a — key-path local search on the trench tree (iter 011)
//
// research.md 3.2 / 5.5(b). DeloopTrench phase 1 is the Takahashi-Matsuyama
// shortest-path Steiner heuristic: required nodes are attached one at a time,
// in heap-pop order, and a corridor opened early to reach one terminal is
// never revisited once a later, cheaper corridor makes it redundant. That
// order is a construction artefact, and key-path exchange is precisely its
// repair — the classic neighbourhood of Uchoa & Werneck (ALENEX 2010).
//
// A node is KEY when it is required or its tree degree is not 2; a KEY PATH
// is a maximal tree path whose interior nodes are all non-key degree-2
// nodes. Deleting one splits the tree into exactly two components A and B
// (its interior falls out entirely — both of each interior node's edges just
// went), so reconnecting A to B by the cheapest path in the FULL road graph
// restores a tree: rings stay 0 by construction, and phases 2-4 need no
// change. Accept only strictly cheaper reconnections, so the pass is a
// strictly decreasing non-negative integer objective and terminates.
// ---------------------------------------------------------------------------

// Civil cost of opening one road edge — the objective the tree is built
// against, and the same expression DeloopTrench phase 1 relaxes on.
fn TrenchEdgeCents(ref d: Design, e: i32) -> i64 {
  return (d.edge_len[e] as i64) * TrenchCostPerM(d.edge_surface[e]);
}

// Far endpoint of edge `e` seen from `v`. By edge id, not node id, so
// parallel edges between the same pair stay distinguishable.
fn KpOther(ref d: Design, e: i32, v: i32) -> i32 {
  if (d.edge_from[e] == v) {
    return d.edge_to[e];
  }
  return d.edge_from[e];
}

// Tree degree of every node under forest_edge. Rebuilt whole between rounds;
// exchanges keep it current incrementally.
fn KpRefreshDegrees(ref d: Design) {
  var n: i32 = 0;
  while (n < d.node_count) {
    d.kp_deg[n] = 0;
    ++n;
  }
  var e: i32 = 0;
  while (e < d.edge_count) {
    if (d.forest_edge[e]) {
      ++d.kp_deg[d.edge_from[e]];
      ++d.kp_deg[d.edge_to[e]];
    }
    ++e;
  }
}

fn KpIsKey(ref d: Design, v: i32) -> bool {
  return d.kp_req[v] or d.kp_deg[v] != 2;
}

// Walks the maximal degree-2 chain leaving key node `a` along tree edge `e0`.
// Fills kp_edge[0..kp_len) and kp_cost, and returns the far key endpoint —
// or -1 when the chain is not a usable key path (edge already gone, chain
// longer than the buffer, dangling). In a tree the walk cannot revisit a
// node, so it always terminates at a key node.
fn KpWalk(ref d: Design, a: i32, e0: i32) -> i32 {
  if (not d.forest_edge[e0]) {
    return -1;
  }
  d.kp_len = 0;
  d.kp_cost = 0;
  var prev: i32 = a;
  var e: i32 = e0;
  while (d.kp_len < 1024) {
    d.kp_edge[d.kp_len] = e;
    ++d.kp_len;
    d.kp_cost += TrenchEdgeCents(ref d, e);
    let v: i32 = KpOther(ref d, e, prev);
    if (KpIsKey(ref d, v)) {
      return v;
    }
    // Interior node: degree 2 and non-required, so exactly one tree edge
    // other than the one we arrived on continues the chain.
    var it: i32 = d.adj_head[v];
    var nxt: i32 = -1;
    while (it != -1) {
      let ce: i32 = d.adj_edge[it];
      if (d.forest_edge[ce] and ce != e) {
        nxt = ce;
        break;
      }
      it = d.adj_next[it];
    }
    if (nxt == -1) {
      return -1;
    }
    prev = v;
    e = nxt;
  }
  return -1;  // chain longer than the buffer: leave this path alone
}

// BFS from `root` over the current forest edges, tagging every reached node
// with (kp_stamp, side). heap_node is the FIFO, exactly as ForestBfs uses it.
// The stamp is what makes this cheap: no O(node_count) reset per trial.
// Returns the number of nodes tagged, and for side 1 leaves the node list in
// seed_dist[32768..] so the reconnection can seed its sources in O(|A|).
fn KpMarkComponent(ref d: Design, root: i32, side: i32) -> i32 {
  let tag: i32 = d.kp_stamp * 4 + side;
  var head: i32 = 0;
  var tail: i32 = 0;
  d.kp_comp[root] = tag;
  d.heap_node[tail] = root;
  ++tail;
  while (head < tail) {
    let u: i32 = d.heap_node[head];
    ++head;
    if (side == 1) {
      d.seed_dist[393216 + head - 1] = u;
    }
    var a: i32 = d.adj_head[u];
    while (a != -1) {
      let e: i32 = d.adj_edge[a];
      let v: i32 = d.adj_to[a];
      if (d.forest_edge[e] and d.kp_comp[v] != tag) {
        d.kp_comp[v] = tag;
        d.heap_node[tail] = v;
        ++tail;
      }
      a = d.adj_next[a];
    }
  }
  d.heap_size = 0;
  return tail;
}

// Cheapest reconnection of component A to component B over the WHOLE road
// graph: multi-source Dijkstra with every A node a zero-cost source, edges
// already in the tree free, everything else at full civil cost. Settling the
// first B node gives the cheapest A-B path, and the scan is pruned at `limit`
// because only a strictly cheaper path can be accepted. Returns that B node,
// or -1. The prev chain of the returned node is a simple path whose interior
// meets neither A (those are sources, never relaxed below 0) nor B (we stop
// at the FIRST settled B node), so splicing it in keeps the tree a tree.
fn KpReconnect(ref d: Design, a_count: i32, limit: i64) -> i32 {
  let tag_b: i32 = d.kp_stamp * 4 + 2;
  DijkstraReset(ref d);
  var i: i32 = 0;
  while (i < a_count) {
    AddSource(ref d, d.seed_dist[393216 + i]);
    ++i;
  }
  while (d.heap_size > 0) {
    let u: i32 = HeapPop(ref d);
    if (d.visited[u]) {
      continue;
    }
    d.visited[u] = true;
    if (d.dist[u] >= limit) {
      return -1;  // everything still reachable costs at least as much
    }
    if (d.kp_comp[u] == tag_b) {
      return u;
    }
    var a: i32 = d.adj_head[u];
    while (a != -1) {
      let ce: i32 = d.adj_edge[a];
      let v: i32 = d.adj_to[a];
      var wgt: i64 = 0;
      if (not d.forest_edge[ce]) {
        wgt = TrenchEdgeCents(ref d, ce);
      }
      let nd: i64 = d.dist[u] + wgt;
      if (nd < d.dist[v]) {
        d.dist[v] = nd;
        d.prev_node[v] = u;
        d.prev_edge[v] = ce;
        HeapPush(ref d, v);
      }
      a = d.adj_next[a];
    }
  }
  return -1;
}

// Splices the reconnection path (prev chain from `stop` back to component A)
// into the tree, keeping kp_deg current.
fn KpApplyPath(ref d: Design, stop: i32) {
  let tag_a: i32 = d.kp_stamp * 4 + 1;
  var w: i32 = stop;
  while (d.kp_comp[w] != tag_a and d.prev_edge[w] != -1) {
    let pe: i32 = d.prev_edge[w];
    d.forest_edge[pe] = true;
    ++d.kp_deg[d.edge_from[pe]];
    ++d.kp_deg[d.edge_to[pe]];
    w = d.prev_node[w];
  }
}

// One improvement round: enumerate every key path, try them in decreasing
// cost order (ties -> smallest first-edge id, the order research.md 3.2
// measured), and swap in any strictly cheaper reconnection. Candidates are
// re-validated at trial time because an earlier exchange in the same round
// may have reshaped the tree under them. Returns the exchanges accepted.
fn KpRound(ref d: Design) -> i32 {
  KpRefreshDegrees(ref d);
  var cnt: i32 = 0;
  var a: i32 = 0;
  while (a < d.node_count) {
    if (d.kp_deg[a] > 0 and KpIsKey(ref d, a)) {
      var it: i32 = d.adj_head[a];
      while (it != -1) {
        let e: i32 = d.adj_edge[it];
        if (d.forest_edge[e] and cnt < 98304) {
          // Each key path is seen once from each end; keep the a < b copy.
          let b: i32 = KpWalk(ref d, a, e);
          if (b > a) {
            d.seed_dist[cnt] = a;
            d.seed_dist[98304 + cnt] = e;
            d.seed_dist[196608 + cnt] = d.kp_cost as i32;
            d.seed_dist[294912 + cnt] = cnt;
            ++cnt;
          }
        }
        it = d.adj_next[it];
      }
    }
    ++a;
  }
  d.kp_paths = cnt;

  // Shell sort (Knuth gaps) on the order array: decreasing cents, ties by
  // smallest first-edge id. Edge ids are unique per key path, so this is a
  // total order — the trial sequence is identical on every run.
  var gap: i32 = 1;
  while (gap * 3 + 1 < cnt) {
    gap = gap * 3 + 1;
  }
  while (gap >= 1) {
    var i: i32 = gap;
    while (i < cnt) {
      let cur: i32 = d.seed_dist[294912 + i];
      let ck: i32 = d.seed_dist[196608 + cur];
      let ce: i32 = d.seed_dist[98304 + cur];
      var j: i32 = i;
      while (j >= gap) {
        let o: i32 = d.seed_dist[294912 + j - gap];
        let ok: i32 = d.seed_dist[196608 + o];
        let oe: i32 = d.seed_dist[98304 + o];
        if (ok < ck or (ok == ck and oe > ce)) {
          d.seed_dist[294912 + j] = o;
          j = j - gap;
        } else {
          break;
        }
      }
      d.seed_dist[294912 + j] = cur;
      ++i;
    }
    gap = gap / 3;
  }

  var moves: i32 = 0;
  var k: i32 = 0;
  while (k < cnt) {
    let idx: i32 = d.seed_dist[294912 + k];
    ++k;
    let pa: i32 = d.seed_dist[idx];
    let pe0: i32 = d.seed_dist[98304 + idx];
    if (not d.forest_edge[pe0] or d.kp_deg[pa] == 0 or
        not KpIsKey(ref d, pa)) {
      continue;  // stale: an earlier exchange moved this ground
    }
    let pb: i32 = KpWalk(ref d, pa, pe0);
    if (pb < 0) {
      continue;
    }
    let old_cost: i64 = d.kp_cost;
    let plen: i32 = d.kp_len;
    // Remove the path. Its interior nodes lose both their edges and drop
    // out of the tree; pa and pb keep theirs (or, for a required leaf,
    // become a singleton component, which is the useful re-attach move).
    var pe_i: i32 = 0;
    while (pe_i < plen) {
      let pe: i32 = d.kp_edge[pe_i];
      d.forest_edge[pe] = false;
      --d.kp_deg[d.edge_from[pe]];
      --d.kp_deg[d.edge_to[pe]];
      ++pe_i;
    }
    ++d.kp_stamp;
    KpMarkComponent(ref d, pb, 2);
    let a_count: i32 = KpMarkComponent(ref d, pa, 1);
    let stop: i32 = KpReconnect(ref d, a_count, old_cost);
    if (stop >= 0) {
      KpApplyPath(ref d, stop);
      ++moves;
    } else {
      pe_i = 0;
      while (pe_i < plen) {
        let pe: i32 = d.kp_edge[pe_i];
        d.forest_edge[pe] = true;
        ++d.kp_deg[d.edge_from[pe]];
        ++d.kp_deg[d.edge_to[pe]];
        ++pe_i;
      }
    }
  }
  return moves;
}

fn KpTreeMeters(ref d: Design) -> i32 {
  var m: i32 = 0;
  var e: i32 = 0;
  while (e < d.edge_count) {
    if (d.forest_edge[e]) {
      m += d.edge_len[e];
    }
    ++e;
  }
  return m;
}

fn KpTreeCents(ref d: Design) -> i64 {
  var c: i64 = 0;
  var e: i32 = 0;
  while (e < d.edge_count) {
    if (d.forest_edge[e]) {
      c += TrenchEdgeCents(ref d, e);
    }
    ++e;
  }
  return c;
}

// The exchange preserves the tree by construction — assert it anyway, since
// a silent ring costs 500,000 in the composite. One BFS from the CO: a
// connected component with V nodes carrying exactly V-1 of the tree's edges
// proves both acyclicity and that no second component broke off, and every
// required node must be inside it.
fn KpTreeOk(ref d: Design) -> bool {
  ++d.kp_stamp;
  let reached: i32 = KpMarkComponent(ref d, d.co_node, 1);
  let tag: i32 = d.kp_stamp * 4 + 1;
  var edges: i32 = 0;
  var e: i32 = 0;
  while (e < d.edge_count) {
    if (d.forest_edge[e]) {
      ++edges;
    }
    ++e;
  }
  if (edges != reached - 1) {
    return false;
  }
  var n: i32 = 0;
  while (n < d.node_count) {
    if (d.kp_req[n] and d.kp_comp[n] != tag) {
      return false;
    }
    ++n;
  }
  return true;
}

// Rounds to fixpoint. research.md 3.2 measured convergence in 3; the cap is
// a guard, not a schedule.
fn KeyPathSearch(ref d: Design) {
  d.kp_rounds = 0;
  d.kp_moves = 0;
  d.kp_stamp = 0;
  var n: i32 = 0;
  while (n < d.node_count) {
    d.kp_comp[n] = -1;
    ++n;
  }
  var r: i32 = 0;
  while (r < 8) {
    let moves: i32 = KpRound(ref d);
    d.kp_moves += moves;
    ++d.kp_rounds;
    if (moves == 0) {
      break;
    }
    ++r;
  }
}

// Optical-budget proxy, checked the way RunQa checks it. Key-path exchange
// trades trench cost for route length, so it can push a CO->premises path
// past the budget — the district already sits at 18,060 m of 20,000 m
// (backlog 5's WATCH). Measured after the fiber re-route, with the phase-1
// tree kept in kp_saved so a violation can be undone whole.
fn TrenchRouteOverBudget(ref d: Design) -> i32 {
  var over: i32 = 0;
  d.kp_route_max = 0;
  var p: i32 = 0;
  while (p < d.prem_count) {
    let t: i32 = d.prem_terminal[p];
    if (t != -1 and d.prem_cluster[p] != -1) {
      let route_m: i32 = d.fdh_route_len[d.prem_cluster[p]] +
                         d.term_path_len[t] + d.prem_drop_len[p];
      if (route_m > MaxRouteM()) {
        ++over;
      }
      if (route_m > d.kp_route_max) {
        d.kp_route_max = route_m;
      }
    }
    ++p;
  }
  return over;
}

// Puts the phase-1 tree back, whole. Only kp_saved knows it: the exchange
// pass mutates forest_edge in place, and a partial undo would not be a tree.
fn KpRestoreTree(ref d: Design) {
  var e: i32 = 0;
  while (e < d.edge_count) {
    d.forest_edge[e] = d.kp_saved[e];
    ++e;
  }
}

// ---------------------------------------------------------------------------
// Stage 9c — priced terminal re-siting along private trench spurs (iter 012)
//
// research.md 3.3, appendix A's ranked #1. Measurement 2 of research.md 3.0:
// 28.6% of the district trench (35,387 m) exists to reach exactly ONE
// required node — a private spur to a single terminal. PackTerminals picked
// that terminal's node to minimise drop crossings and drop length, with no
// knowledge that reaching it would cost a dedicated trench, and a metre of
// soft trench buys 30 m of drop cable. Sliding the terminal back down its
// own spur onto the shared trunk retires the spur outright.
//
// It is usually worth doing and it is catastrophic to do blindly. research.md
// 3.3 measured the UNPRICED version of exactly this pass: 656 terminals moved
// to their attach points, $1,478,610 of trench retired — and 4,008 NEW street
// crossings created, $2,004,000 of penalty, turning the win into a $605,637
// LOSS. One crossing is 11.1 m of soft trench, and a parcel lattice charges
// ~k^2/4 crossings for a k-customer terminal, so concentrating terminals onto
// corridors is precisely what buys them. Every candidate position here
// therefore pays the FULL scorer delta — trench cents retired, drop cable,
// drop-street crossings via the scorer's own predicate, AND the drop-drop
// term the section skipped (appendix A haircut ii) — and only a strictly
// negative total is accepted.
//
// Port-neutral by construction: the move rewrites term_node and the drop
// lengths that follow from it, never an assignment or a port count, so
// terminal hardware, the under-4/over-12 counts, the splitter and OLT banks
// and the exactly-95.0% terminal-port utilization floor cannot move. Rings
// stay 0: the retired spur is a subtree containing no required node, and
// deleting such a subtree from a tree leaves a tree.
//
// Scratch map inside seed_dist, on a MaxNodes()=98304 stride because
// every region is indexed by node or premises id. All of it above stage 9a's 49152 (9a has
// finished by the time this runs, but keeping the ranges disjoint means the
// two stages can be read independently).
// ---------------------------------------------------------------------------

fn RsCntBase() -> i32 { return 491520; }     // required nodes in v's subtree
fn RsTermBase() -> i32 { return 589824; }    // live terminals sited at v
fn RsOrderBase() -> i32 { return 688128; }   // CO-rooted BFS order
fn RsFixedBase() -> i32 { return 786432; }   // v is the CO or an FDH site
fn RsPgHead() -> i32 { return 884736; }     // premises grid, 128 m cells
fn RsPgNext() -> i32 { return 983040; }
fn RsPList() -> i32 { return 1081344; }      // premises bucketed by terminal
fn RsPStart() -> i32 { return 1179648; }
fn RsPCur() -> i32 { return 1277952; }       // fill cursor for the buckets

// Indexes every premises by its own position. Static for the whole run —
// premises never move — but it lives in scratch that PackTerminals reuses
// between sweeps, so it is rebuilt once per pass.
fn RsBuildPremGrid(ref d: Design) {
  var c: i32 = 0;
  while (c < 16384) {
    d.seed_dist[RsPgHead() + c] = -1;
    ++c;
  }
  var p: i32 = 0;
  while (p < d.prem_count) {
    let cell: i32 = GridCell(d.prem_y[p], d.eg_miny, d.eg_cell) * 128 +
                    GridCell(d.prem_x[p], d.eg_minx, d.eg_cell);
    d.seed_dist[RsPgNext() + p] = d.seed_dist[RsPgHead() + cell];
    d.seed_dist[RsPgHead() + cell] = p;
    ++p;
  }
}

// Counting sort of premises into per-terminal buckets, ascending premises id
// within each bucket. Both the assignment and the ids are fixed for the whole
// pass, so this runs once.
fn RsBucketPremises(ref d: Design) {
  var t: i32 = 0;
  while (t <= d.term_count) {
    d.seed_dist[RsPStart() + t] = 0;
    ++t;
  }
  var p: i32 = 0;
  while (p < d.prem_count) {
    let tp: i32 = d.prem_terminal[p];
    if (tp != -1) {
      d.seed_dist[RsPStart() + tp + 1] += 1;
    }
    ++p;
  }
  t = 0;
  while (t < d.term_count) {
    d.seed_dist[RsPStart() + t + 1] += d.seed_dist[RsPStart() + t];
    d.seed_dist[RsPCur() + t] = d.seed_dist[RsPStart() + t];
    ++t;
  }
  p = 0;
  while (p < d.prem_count) {
    let tp: i32 = d.prem_terminal[p];
    if (tp != -1) {
      d.seed_dist[RsPList() + d.seed_dist[RsPCur() + tp]] = p;
      d.seed_dist[RsPCur() + tp] += 1;
    }
    ++p;
  }
}

// The required set, re-derived from the assignment exactly the way
// DeloopTrench phase 1 derives it: a terminal is live when premises are
// assigned to it. rs_term counts how many live terminals share a node —
// moving one off a node that carries two frees no trench at all — and
// rs_fixed marks the CO and the FDH sites, which pin their node whatever
// the terminals do.
fn RsMarkRequired(ref d: Design) {
  var n: i32 = 0;
  while (n < d.node_count) {
    d.seed_dist[RsTermBase() + n] = 0;
    d.seed_dist[RsFixedBase() + n] = 0;
    d.kp_req[n] = false;
    ++n;
  }
  var t: i32 = 0;
  while (t < d.term_count) {
    if (d.seed_dist[RsPStart() + t + 1] > d.seed_dist[RsPStart() + t]) {
      d.seed_dist[RsTermBase() + d.term_node[t]] += 1;
      d.kp_req[d.term_node[t]] = true;
    }
    ++t;
  }
  var c: i32 = 0;
  while (c < d.cluster_count) {
    d.seed_dist[RsFixedBase() + d.fdh_node[c]] = 1;
    d.kp_req[d.fdh_node[c]] = true;
    ++c;
  }
  var ck2: i32 = 0;
  while (ck2 < d.co_count) {
    d.seed_dist[RsFixedBase() + d.co_nodes[ck2]] = 1;
    d.kp_req[d.co_nodes[ck2]] = true;
    ++ck2;
  }
}

// Roots the trench tree at the CO: parent pointers plus the BFS visit order,
// which is what makes the subtree counts one reverse sweep instead of a
// recursion the language has no stack for.
fn RsRootTree(ref d: Design) {
  var n: i32 = 0;
  while (n < d.node_count) {
    d.in_tree[n] = false;
    d.tree_parent_node[n] = -1;
    d.tree_parent_edge[n] = -1;
    ++n;
  }
  var head: i32 = 0;
  var tail: i32 = 0;
  d.in_tree[d.co_node] = true;
  d.seed_dist[RsOrderBase() + tail] = d.co_node;
  ++tail;
  while (head < tail) {
    let u: i32 = d.seed_dist[RsOrderBase() + head];
    ++head;
    var a: i32 = d.adj_head[u];
    while (a != -1) {
      let e: i32 = d.adj_edge[a];
      let v: i32 = d.adj_to[a];
      if (d.forest_edge[e] and not d.in_tree[v]) {
        d.in_tree[v] = true;
        d.tree_parent_node[v] = u;
        d.tree_parent_edge[v] = e;
        d.seed_dist[RsOrderBase() + tail] = v;
        ++tail;
      }
      a = d.adj_next[a];
    }
  }
  d.rs_order_n = tail;
}

// cnt[v] = required nodes in v's subtree. Children precede parents in the
// reversed BFS order, so one backward sweep suffices.
fn RsCounts(ref d: Design) {
  var n: i32 = 0;
  while (n < d.node_count) {
    d.seed_dist[RsCntBase() + n] = 0;
    ++n;
  }
  var i: i32 = d.rs_order_n - 1;
  while (i >= 0) {
    let u: i32 = d.seed_dist[RsOrderBase() + i];
    if (d.kp_req[u]) {
      d.seed_dist[RsCntBase() + u] += 1;
    }
    let par: i32 = d.tree_parent_node[u];
    if (par != -1) {
      d.seed_dist[RsCntBase() + par] += d.seed_dist[RsCntBase() + u];
    }
    --i;
  }
}

// Candidate positions for a terminal standing at `v`: walk toward the CO
// while the subtree below carries this one required node, stopping at (and
// including) the first ancestor that carries more. That ancestor is the
// trunk attach point — moving there retires the whole spur — and every node
// between is a partial retirement the line search gets to price. rs_freed
// and rs_span accumulate what each stop would retire.
fn RsWalkSpur(ref d: Design, v: i32) {
  d.rs_cand_n = 0;
  var cur: i32 = v;
  var cents: i64 = 0;
  var meters: i32 = 0;
  while (d.rs_cand_n < 256) {
    let pe: i32 = d.tree_parent_edge[cur];
    if (pe == -1) {
      break;  // reached the root without meeting a shared ancestor
    }
    let par: i32 = d.tree_parent_node[cur];
    cents += TrenchEdgeCents(ref d, pe);
    meters += d.edge_len[pe];
    d.rs_cand[d.rs_cand_n] = par;
    d.rs_freed[d.rs_cand_n] = cents;
    d.rs_span[d.rs_cand_n] = meters;
    ++d.rs_cand_n;
    if (d.seed_dist[RsCntBase() + par] > 1) {
      break;  // shared from here up: this is the attach point
    }
    cur = par;
  }
}

// Change in drop-drop crossings for ONE premises whose terminal endpoint
// moves from (vx,vy) to (cx,cy), counted against every other terminal's
// drops. Pairs inside the moving terminal are excluded and need to be: they
// share an endpoint before the move and after it, so ProperCross rejects
// them either way.
//
// Every segment involved is at most MaxDropM long, so any drop whose status
// can change has its premises endpoint within one drop length of the
// bounding box of (premises, old node, new node). That box, grown by
// MaxDropM and mapped onto the 128 m premises grid, is an exact superset
// filter — GridCell's clamp is monotone, so growing the box can only grow
// the cell range.
fn RsDropDropDelta(ref d: Design, t: i32, px: i32, py: i32,
                   vx: i32, vy: i32, cx: i32, cy: i32) -> i32 {
  var lox: i32 = px;
  var hix: i32 = px;
  var loy: i32 = py;
  var hiy: i32 = py;
  if (vx < lox) { lox = vx; }
  if (vx > hix) { hix = vx; }
  if (vy < loy) { loy = vy; }
  if (vy > hiy) { hiy = vy; }
  if (cx < lox) { lox = cx; }
  if (cx > hix) { hix = cx; }
  if (cy < loy) { loy = cy; }
  if (cy > hiy) { hiy = cy; }
  let gx0: i32 = GridCell(lox - MaxDropM(), d.eg_minx, d.eg_cell);
  let gx1: i32 = GridCell(hix + MaxDropM(), d.eg_minx, d.eg_cell);
  let gy0: i32 = GridCell(loy - MaxDropM(), d.eg_miny, d.eg_cell);
  let gy1: i32 = GridCell(hiy + MaxDropM(), d.eg_miny, d.eg_cell);
  var dd: i32 = 0;
  var gy: i32 = gy0;
  while (gy <= gy1) {
    var gx: i32 = gx0;
    while (gx <= gx1) {
      var q: i32 = d.seed_dist[RsPgHead() + gy * 128 + gx];
      while (q != -1) {
        let tq: i32 = d.prem_terminal[q];
        if (tq != -1 and tq != t) {
          let qx: i32 = d.prem_x[q];
          let qy: i32 = d.prem_y[q];
          let mx: i32 = d.node_x[d.term_node[tq]];
          let my: i32 = d.node_y[d.term_node[tq]];
          var qlo: i32 = qx;
          var qhi: i32 = qx;
          if (mx < qlo) { qlo = mx; }
          if (mx > qhi) { qhi = mx; }
          var qloy: i32 = qy;
          var qhiy: i32 = qy;
          if (my < qloy) { qloy = my; }
          if (my > qhiy) { qhiy = my; }
          if (qhi >= lox and qlo <= hix and qhiy >= loy and qloy <= hiy) {
            if (ProperCross(px, py, cx, cy, qx, qy, mx, my)) { dd += 1; }
            if (ProperCross(px, py, vx, vy, qx, qy, mx, my)) { dd -= 1; }
          }
        }
        q = d.seed_dist[RsPgNext() + q];
      }
      ++gx;
    }
    ++gy;
  }
  return dd;
}

// Line search for one terminal. Returns true when it moved.
//
// The pass declines three situations outright, each because the move would
// free no trench: the node is the CO or an FDH site (the spur is needed
// whatever the terminal does), the node carries a second live terminal, or
// the subtree already carries more than this one required node.
fn RsTryTerminal(ref d: Design, t: i32) -> bool {
  let v: i32 = d.term_node[t];
  if (d.seed_dist[RsFixedBase() + v] != 0 or
      d.seed_dist[RsTermBase() + v] != 1 or
      d.seed_dist[RsCntBase() + v] != 1) {
    return false;
  }
  let ps: i32 = d.seed_dist[RsPStart() + t];
  let np: i32 = d.seed_dist[RsPStart() + t + 1] - ps;
  if (np <= 0 or np > 16) {
    return false;
  }
  RsWalkSpur(ref d, v);
  if (d.rs_cand_n == 0) {
    return false;
  }
  d.rs_spurs += 1;

  let vx: i32 = d.node_x[v];
  let vy: i32 = d.node_y[v];
  var pid: array(i32, 16);
  var sum_old_len: i64 = 0;
  var sum_old_x: i64 = 0;
  var i: i32 = 0;
  while (i < np) {
    let p: i32 = d.seed_dist[RsPList() + ps + i];
    pid[i] = p;
    sum_old_len += d.prem_drop_len[p] as i64;
    sum_old_x += CountDropCrossings(ref d, d.prem_x[p], d.prem_y[p], v) as i64;
    ++i;
  }

  var best_delta: i64 = 0;   // strict improvement only
  var best_k: i32 = -1;
  var best_node: i32 = -1;
  var k: i32 = 0;
  while (k < d.rs_cand_n) {
    let c: i32 = d.rs_cand[k];
    let cx: i32 = d.node_x[c];
    let cy: i32 = d.node_y[c];
    var ok: bool = true;
    var sum_new_len: i64 = 0;
    var sum_new_x: i64 = 0;
    var worst_len: i32 = 0;
    i = 0;
    while (i < np) {
      let p: i32 = pid[i];
      let nl: i32 = DistM(d.prem_x[p], d.prem_y[p], cx, cy);
      if (nl > MaxDropM()) {
        ok = false;   // the 150 m drop rule makes this position infeasible
        break;
      }
      if (nl > worst_len) { worst_len = nl; }
      sum_new_len += nl as i64;
      sum_new_x +=
          CountDropCrossings(ref d, d.prem_x[p], d.prem_y[p], c) as i64;
      ++i;
    }
    // Optical budget proxy. The FDH is required, so it is never inside the
    // spur's subtree, which means the tree route FDH -> terminal runs
    // through c and shortens by exactly the spur meters retired.
    // term_path_len is still RouteDistribution's value here — an
    // over-estimate of the tree route, so the check errs safe; the exact
    // gate is TrenchRouteOverBudget after the fibers are re-routed.
    if (ok and d.fdh_route_len[d.term_cluster[t]] + d.term_path_len[t] -
                   d.rs_span[k] + worst_len > MaxRouteM()) {
      ok = false;
    }
    if (ok) {
      var delta: i64 = 0 - d.rs_freed[k];
      delta += DropCablePerM() * (sum_new_len - sum_old_len);
      delta += 50000 * (sum_new_x - sum_old_x);
      // The drop-drop term is the expensive one to evaluate and (per
      // research.md 3.3's haircut ii) the one that gets WORSE as terminals
      // concentrate, so it is only spent on positions that already pay
      // without it. That narrows the neighbourhood; it never lets an
      // unpriced move through, which is the property that matters.
      if (delta < 0) {
        var dd: i32 = 0;
        i = 0;
        while (i < np) {
          let p: i32 = pid[i];
          dd += RsDropDropDelta(ref d, t, d.prem_x[p], d.prem_y[p],
                                vx, vy, cx, cy);
          ++i;
        }
        delta += 20000 * (dd as i64);
        if (delta < best_delta or (delta == best_delta and c < best_node)) {
          best_delta = delta;
          best_k = k;
          best_node = c;
        }
      }
    }
    ++k;
  }
  if (best_k < 0) {
    return false;
  }

  // Apply. Only the site and the drops that hang off it move.
  let c: i32 = d.rs_cand[best_k];
  d.term_node[t] = c;
  i = 0;
  while (i < np) {
    let p: i32 = pid[i];
    d.prem_drop_len[p] = DistM(d.prem_x[p], d.prem_y[p],
                               d.node_x[c], d.node_y[c]);
    ++i;
  }
  // Required set and subtree counts move with it, so the rest of this round
  // prices the tree that now exists rather than the one it started from
  // (research.md 3.3's haircut iii, which its own measurement skipped).
  // Ancestors of c see one node leave and one arrive, so they net to zero;
  // the spur interior drops to zero and c only loses a count if it was
  // already required.
  d.seed_dist[RsTermBase() + v] = 0;
  d.seed_dist[RsTermBase() + c] += 1;
  let c_was_req: bool = d.kp_req[c];
  d.kp_req[v] = false;
  d.kp_req[c] = true;
  var w: i32 = v;
  while (w != c) {
    d.seed_dist[RsCntBase() + w] -= 1;
    w = d.tree_parent_node[w];
  }
  if (c_was_req) {
    d.seed_dist[RsCntBase() + c] -= 1;
  }
  d.rs_moves += 1;
  d.rs_freed_cents += d.rs_freed[best_k];
  d.rs_freed_m += d.rs_span[best_k];
  d.rs_gain += best_delta;
  return true;
}

// Drops every edge whose child-side subtree holds no required node — the
// spurs the accepted moves just orphaned. Phase 4 would have pruned them
// from `trench_used` anyway (no cable runs there), but taking them out of
// forest_edge keeps the tree and its reported meters honest for phases 2-3
// and for the diagnostics. A subtree with no required node is exactly what
// may be deleted without disconnecting anything, so the result is a tree.
fn RsPruneDeadSpurs(ref d: Design) {
  var n: i32 = 0;
  while (n < d.node_count) {
    if (d.in_tree[n] and d.tree_parent_edge[n] != -1 and
        d.seed_dist[RsCntBase() + n] == 0) {
      d.forest_edge[d.tree_parent_edge[n]] = false;
    }
    ++n;
  }
}

// Rounds to fixpoint (capped). Each accept strictly decreases a bounded
// non-negative integer objective — the priced delta understates the true
// saving, because the cable that rode the retired spur is not counted — so
// the loop terminates, and terminals are tried in ascending id, so which
// fixpoint it lands on is determined.
fn ResiteTerminals(ref d: Design) {
  d.rs_rounds = 0;
  d.rs_moves = 0;
  d.rs_spurs = 0;
  d.rs_freed_cents = 0;
  d.rs_freed_m = 0;
  d.rs_gain = 0;
  RsBuildPremGrid(ref d);
  RsBucketPremises(ref d);
  var r: i32 = 0;
  while (r < 6) {
    RsMarkRequired(ref d);
    RsRootTree(ref d);
    RsCounts(ref d);
    d.rs_spurs = 0;   // the last round's census is the residual
    var moves: i32 = 0;
    var t: i32 = 0;
    while (t < d.term_count) {
      if (RsTryTerminal(ref d, t)) {
        ++moves;
      }
      ++t;
    }
    d.rs_rounds += 1;
    ++r;
    if (moves == 0) {
      break;
    }
  }
  if (d.rs_moves > 0) {
    RsMarkRequired(ref d);
    RsRootTree(ref d);
    RsCounts(ref d);
    RsPruneDeadSpurs(ref d);
  }
}

// Puts every terminal back where the packing stage sited it, and with it
// the drops that follow. Paired with KpRestoreTree in the route-budget undo:
// phases 2-3 have to be re-run against the tree AND the sites they were
// measured on.
fn RsRestoreSites(ref d: Design) {
  var t: i32 = 0;
  while (t < d.term_count) {
    d.term_node[t] = d.rs_saved_node[t];
    ++t;
  }
  var p: i32 = 0;
  while (p < d.prem_count) {
    let tp: i32 = d.prem_terminal[p];
    if (tp != -1) {
      d.prem_drop_len[p] = DistM(d.prem_x[p], d.prem_y[p],
                                 d.node_x[d.term_node[tp]],
                                 d.node_y[d.term_node[tp]]);
    }
    ++p;
  }
}

// DeloopTrench phases 2-3, factored out so the route-budget guard can run
// them, look at the result, and re-run them on the restored tree. Fibers
// feed TERMINAL locations (post-merge assignment), so the kept trench always
// reaches every terminal (backlog 6b).
fn RouteOnTrenchTree(ref d: Design) {
  // Phase 2: re-route distribution on the tree, cluster by cluster.
  var e: i32 = 0;
  while (e < d.edge_count) {
    d.dist_fibers[e] = 0;
    ++e;
  }
  var n: i32 = 0;
  var c: i32 = 0;
  while (c < d.cluster_count) {
    ForestBfs(ref d, d.fdh_node[c]);
    n = 0;
    while (n < d.node_count) {
      d.node_units[n] = 0;
      ++n;
    }
    var p: i32 = 0;
    while (p < d.prem_count) {
      if (d.prem_cluster[p] == c and d.prem_terminal[p] != -1) {
        d.node_units[d.term_node[d.prem_terminal[p]]] += d.prem_units[p];
      }
      ++p;
    }
    n = 0;
    while (n < d.node_count) {
      if (d.node_units[n] > 0 and d.in_tree[n]) {
        var walk: i32 = n;
        while (walk != d.fdh_node[c] and d.tree_parent_edge[walk] != -1) {
          d.dist_fibers[d.tree_parent_edge[walk]] += d.node_units[n];
          walk = d.tree_parent_node[walk];
        }
      }
      ++n;
    }
    var t: i32 = 0;
    while (t < d.term_count) {
      if (d.term_cluster[t] == c and d.in_tree[d.term_node[t]]) {
        d.term_path_len[t] = d.node_path_m[d.term_node[t]];
      }
      ++t;
    }
    ++c;
  }

  // Phase 3: re-route feeder CO -> each FDH on the tree.
  e = 0;
  while (e < d.edge_count) {
    d.feeder_fibers[e] = 0;
    ++e;
  }
  ForestBfs(ref d, d.co_node);
  c = 0;
  while (c < d.cluster_count) {
    d.fdh_route_len[c] = 0;
    if (not d.is_co[d.fdh_node[c]] and d.in_tree[d.fdh_node[c]]) {
      let fibers: i32 = d.fdh_splitters[c] + 1;
      var v: i32 = d.fdh_node[c];
      var meters: i32 = 0;
      // Stop at the first head-end on the way to the root: in a tree that
      // is the head-end actually feeding this area.
      while (not d.is_co[v] and d.tree_parent_edge[v] != -1) {
        let pe: i32 = d.tree_parent_edge[v];
        d.feeder_fibers[pe] += fibers;
        meters += d.edge_len[pe];
        v = d.tree_parent_node[v];
      }
      d.fdh_route_len[c] = meters;
    }
    ++c;
  }
}

// The union of per-cluster distribution trees and feeder paths chooses its
// corridors independently, so the used trench both re-opened the road
// lattice's cycles AND paid for corridors a global view would never open.
// Fix: build one global Steiner tree (shortest-path heuristic) over the
// FULL road graph — required nodes are the CO, every FDH, and every live
// terminal node — then re-route distribution fibers (per-cluster,
// terminal-node units to FDH, same sizing semantics as RouteDistribution)
// and feeder fibers (CO -> FDH) along the tree's unique paths, refresh
// term_path_len / fdh_route_len, and keep trench only where cable actually
// runs. Cables detour slightly (cable is $0.95-7.80/m) but every corridor
// dropped saves its trench ($45-150/m); a subset of a tree is acyclic, so
// rings stay 0 by construction. Vs the old spanning forest restricted to
// already-open trench, the global tree cut district trench
// 134,276 m -> ~123,700 m (~-$0.5M) with the worst CO->premises route at
// 18,060 m of the 20,000 m optical budget.
fn DeloopTrench(ref d: Design) {
  // Phase 1: global Steiner tree via incremental multi-source Dijkstra in
  // trench cents. Tree nodes are 0-cost sources and tree edges relax at 0,
  // so each required node connects by the cheapest path to the CURRENT
  // tree. Required markers live in node_units (phase 2 resets it); the
  // in_tree flags are rebuilt by ForestBfs afterwards. Everything is
  // sequential with a deterministic heap, so the tree is fully determined.
  var e: i32 = 0;
  while (e < d.edge_count) {
    d.forest_edge[e] = false;
    ++e;
  }
  var n: i32 = 0;
  while (n < d.node_count) {
    d.node_units[n] = 0;
    d.in_tree[n] = false;
    d.kp_req[n] = false;   // stage 9a needs the required set after phase 1
    ++n;
  }
  var remaining: i32 = 0;
  var p1: i32 = 0;
  while (p1 < d.prem_count) {
    if (d.prem_terminal[p1] != -1) {
      let tn: i32 = d.term_node[d.prem_terminal[p1]];
      if (d.node_units[tn] == 0) {
        d.node_units[tn] = 1;
        d.kp_req[tn] = true;
        ++remaining;
      }
    }
    ++p1;
  }
  var c1: i32 = 0;
  while (c1 < d.cluster_count) {
    let fnode: i32 = d.fdh_node[c1];
    if (d.node_units[fnode] == 0) {
      d.node_units[fnode] = 1;
      d.kp_req[fnode] = true;
      ++remaining;
    }
    ++c1;
  }
  var ck: i32 = 0;
  while (ck < d.co_count) {
    let cn: i32 = d.co_nodes[ck];
    if (d.node_units[cn] == 0) {
      d.node_units[cn] = 1;
      d.kp_req[cn] = true;
      ++remaining;
    }
    ++ck;
  }
  DijkstraReset(ref d);
  d.in_tree[d.co_node] = true;
  d.node_units[d.co_node] = 0;
  --remaining;
  AddSource(ref d, d.co_node);
  while (remaining > 0 and d.heap_size > 0) {
    let u: i32 = HeapPop(ref d);
    if (d.node_units[u] == 1 and not d.in_tree[u]) {
      // Connect u: walk the prev chain back to the tree. Chain dists are
      // strictly decreasing and only tree nodes have dist 0, so the walk
      // terminates on the tree. Every new node becomes a 0-cost source.
      var w: i32 = u;
      while (not d.in_tree[w]) {
        d.forest_edge[d.prev_edge[w]] = true;
        d.in_tree[w] = true;
        if (d.node_units[w] == 1) {
          d.node_units[w] = 0;
          --remaining;
        }
        d.dist[w] = 0;
        HeapPush(ref d, w);
        w = d.prev_node[w];
      }
      continue;
    }
    var a: i32 = d.adj_head[u];
    while (a != -1) {
      let ce: i32 = d.adj_edge[a];
      let v: i32 = d.adj_to[a];
      var wgt: i64 = 0;
      if (not d.forest_edge[ce]) {
        wgt = (d.edge_len[ce] as i64) * TrenchCostPerM(d.edge_surface[ce]);
      }
      let ndist: i64 = d.dist[u] + wgt;
      if (ndist < d.dist[v]) {
        d.dist[v] = ndist;
        d.prev_node[v] = u;
        d.prev_edge[v] = ce;
        HeapPush(ref d, v);
      }
      a = d.adj_next[a];
    }
  }

  // Phase 1b: key-path local search (stage 9a). Keep the constructed tree
  // first — the exchange can lengthen CO->premises routes, and the only
  // honest undo for that is the tree the heuristic built.
  d.kp_trench_before = KpTreeMeters(ref d);
  d.kp_cents_before = KpTreeCents(ref d);
  e = 0;
  while (e < d.edge_count) {
    d.kp_saved[e] = d.forest_edge[e];
    ++e;
  }
  KeyPathSearch(ref d);
  d.kp_rollback = 0;
  if (not KpTreeOk(ref d)) {
    KpRestoreTree(ref d);
    d.kp_rollback = 2;
  }

  // Read the key-path result off the tree BEFORE re-siting touches it, so
  // the 9a diagnostic keeps meaning what it meant at iter 011.
  d.kp_trench_after = KpTreeMeters(ref d);
  d.kp_cents_after = KpTreeCents(ref d);

  // Phase 1c: priced terminal re-siting on the private spurs of the tree
  // that survived 1b (stage 9c). Sites are kept so the route-budget undo
  // below can restore the pair — tree and terminals — it measured.
  var t0: i32 = 0;
  while (t0 < d.term_count) {
    d.rs_saved_node[t0] = d.term_node[t0];
    ++t0;
  }
  ResiteTerminals(ref d);

  // Phases 2-3: re-route distribution and feeder on the tree, then check the
  // optical budget the exchange could have blown and undo the whole pass if
  // it did. Rolling back wholesale rather than per-move is the cheap correct
  // choice: term_path_len only exists after a full ForestBfs per cluster, so
  // a per-move check would cost more than the search itself.
  RouteOnTrenchTree(ref d);
  var over: i32 = TrenchRouteOverBudget(ref d);
  if ((d.kp_moves > 0 or d.rs_moves > 0) and d.kp_rollback == 0 and over > 0) {
    KpRestoreTree(ref d);
    RsRestoreSites(ref d);
    d.kp_rollback = 1;
    d.kp_trench_after = d.kp_trench_before;
    d.kp_cents_after = d.kp_cents_before;
    d.rs_moves = 0;
    d.rs_freed_m = 0;
    d.rs_freed_cents = 0;
    d.rs_gain = 0;
    RouteOnTrenchTree(ref d);
    over = TrenchRouteOverBudget(ref d);  // refreshes the reported max too
  }

  // Phase 4: trench only where cable actually runs. A subset of a forest
  // is acyclic, so the scorer's cyclomatic number is 0 by construction.
  e = 0;
  while (e < d.edge_count) {
    d.trench_used[e] = d.forest_edge[e] and
                       (d.dist_fibers[e] > 0 or d.feeder_fibers[e] > 0);
    ++e;
  }
}

// ---------------------------------------------------------------------------
// Stage 9b — priced 2-opt drop uncrossing (iter 009)
// ---------------------------------------------------------------------------

// Two drops that share a terminal can never PROPERLY cross — they share an
// endpoint, and ProperCross excludes endpoint touches — so every drop-drop
// crossing in the design is inter-terminal, i.e. a property of the
// premises -> terminal ASSIGNMENT alone and not of where the terminals
// stand. The uncrossing lemma then says such a crossing is an artefact
// rather than a geometric tax: if p1->t1 and p2->t2 properly cross, the
// four points are in convex position with the two drops as the diagonals of
// p1 p2 t1 t2, so routing through the crossing point and applying the
// triangle inequality twice gives
//     |p1 t2| + |p2 t1| < |p1 t1| + |p2 t2|
// and the swapped pair are opposite SIDES of that quadrilateral, so they
// cannot cross each other. Swapping keeps each terminal's port count, its
// catalog size and its node, so hardware, the under-4 count, splitter and
// fiber accounting and the exactly-95.0% terminal-port utilization floor
// cannot move: this is the one repair pass that cannot spend budget
// elsewhere (research.md 5.2, appendix A ranked item 4).
//
// What the lemma does NOT cover is priced: the shorter drop may cross a
// street the longer one avoided (50000), and either new drop may cross a
// THIRD drop (20000). So each candidate pays the full scorer delta and is
// taken only when it is strictly negative. That objective is a non-negative
// integer which strictly decreases on every accept, so the fixpoint loop
// provably terminates; the scan runs in ascending premises id, so which
// fixpoint it lands on is determined.

// Applies the swap. Only the two drops move: the two premises exchange
// terminals, and with them the serving area of the terminal they land on
// (the invariant prem_cluster[p] == term_cluster[prem_terminal[p]] holds
// everywhere in this file). The exchange is BALANCED and equal-unit, so
// cluster_units, cluster_prems and every per-(cluster, node) fiber demand
// come out exactly as they went in — which is why the pass can run after
// the cable has already been sized.
fn SwapDrops(ref d: Design, p1: i32, p2: i32) {
  let t1: i32 = d.prem_terminal[p1];
  let t2: i32 = d.prem_terminal[p2];
  d.prem_terminal[p1] = t2;
  d.prem_terminal[p2] = t1;
  d.prem_cluster[p1] = d.term_cluster[t2];
  d.prem_cluster[p2] = d.term_cluster[t1];
  d.prem_drop_len[p1] = DistM(d.prem_x[p1], d.prem_y[p1],
                              d.node_x[d.term_node[t2]],
                              d.node_y[d.term_node[t2]]);
  d.prem_drop_len[p2] = DistM(d.prem_x[p2], d.prem_y[p2],
                              d.node_x[d.term_node[t1]],
                              d.node_y[d.term_node[t1]]);
}

// Scorer delta in cents of swapping the terminals of p1 and p2; a positive
// value rejects, and 1 is the sentinel for "infeasible" (150 m drop rule or
// the optical route budget). Prices exactly the three terms a swap can
// move — drop cable, the two re-routed drops' street crossings, and every
// drop-drop pair containing p1 or p2 — and nothing else, because nothing
// else CAN move.
fn SwapDelta(ref d: Design, p1: i32, p2: i32) -> i64 {
  let t1: i32 = d.prem_terminal[p1];
  let t2: i32 = d.prem_terminal[p2];
  let ax: i32 = d.prem_x[p1];
  let ay: i32 = d.prem_y[p1];
  let bx: i32 = d.prem_x[p2];
  let by: i32 = d.prem_y[p2];
  let n1x: i32 = d.node_x[d.term_node[t1]];
  let n1y: i32 = d.node_y[d.term_node[t1]];
  let n2x: i32 = d.node_x[d.term_node[t2]];
  let n2y: i32 = d.node_y[d.term_node[t2]];
  let l1: i32 = DistM(ax, ay, n2x, n2y);
  let l2: i32 = DistM(bx, by, n1x, n1y);
  if (l1 > MaxDropM() or l2 > MaxDropM()) {
    return 1;
  }
  // Optical budget proxy, measured the way QA measures it: each premises
  // inherits the feeder leg of the area its new terminal belongs to.
  if (d.fdh_route_len[d.term_cluster[t2]] + d.term_path_len[t2] + l1 >
          MaxRouteM() or
      d.fdh_route_len[d.term_cluster[t1]] + d.term_path_len[t1] + l2 >
          MaxRouteM()) {
    return 1;
  }

  var delta: i64 = DropCablePerM() *
      ((l1 + l2 - d.prem_drop_len[p1] - d.prem_drop_len[p2]) as i64);
  delta += 50000 * ((CountDropCrossings(ref d, ax, ay, d.term_node[t2]) +
                     CountDropCrossings(ref d, bx, by, d.term_node[t1]) -
                     CountDropCrossings(ref d, ax, ay, d.term_node[t1]) -
                     CountDropCrossings(ref d, bx, by, d.term_node[t2])) as i64);

  // Drop-drop: the only pairs whose crossing status can change are the ones
  // containing p1 or p2, so one scan over the other live drops settles all
  // of them. Every one of the four segments lies inside the bounding box of
  // the four endpoints, so that box is an exact prefilter.
  var lox: i32 = ax;
  var hix: i32 = ax;
  var loy: i32 = ay;
  var hiy: i32 = ay;
  var cx: array(i32, 3);
  var cy: array(i32, 3);
  cx[0] = bx;   cy[0] = by;
  cx[1] = n1x;  cy[1] = n1y;
  cx[2] = n2x;  cy[2] = n2y;
  var q: i32 = 0;
  while (q < 3) {
    if (cx[q] < lox) { lox = cx[q]; }
    if (cx[q] > hix) { hix = cx[q]; }
    if (cy[q] < loy) { loy = cy[q]; }
    if (cy[q] > hiy) { hiy = cy[q]; }
    ++q;
  }
  var dd: i32 = 0;
  var k: i32 = 0;
  while (k < d.prem_count) {
    let tk: i32 = d.prem_terminal[k];
    if (k != p1 and k != p2 and tk != -1) {
      let kx: i32 = d.prem_x[k];
      let ky: i32 = d.prem_y[k];
      let mx: i32 = d.node_x[d.term_node[tk]];
      let my: i32 = d.node_y[d.term_node[tk]];
      var klox: i32 = kx;
      var khix: i32 = kx;
      if (mx < klox) { klox = mx; }
      if (mx > khix) { khix = mx; }
      var kloy: i32 = ky;
      var khiy: i32 = ky;
      if (my < kloy) { kloy = my; }
      if (my > khiy) { khiy = my; }
      if (khix >= lox and klox <= hix and khiy >= loy and kloy <= hiy) {
        if (ProperCross(ax, ay, n2x, n2y, kx, ky, mx, my)) { dd += 1; }
        if (ProperCross(bx, by, n1x, n1y, kx, ky, mx, my)) { dd += 1; }
        if (ProperCross(ax, ay, n1x, n1y, kx, ky, mx, my)) { dd -= 1; }
        if (ProperCross(bx, by, n2x, n2y, kx, ky, mx, my)) { dd -= 1; }
      }
    }
    ++k;
  }
  // The candidate pair itself: it crosses today (that is why it is a
  // candidate) and the swapped pair are opposite sides of the convex
  // quadrilateral, so this is -1 in every real case. Tested, not assumed.
  if (ProperCross(ax, ay, n2x, n2y, bx, by, n1x, n1y)) { dd += 1; }
  dd -= 1;
  delta += 20000 * (dd as i64);
  return delta;
}

// Runs the 2-opt uncrossing to a fixpoint (bounded at 8 scans). A swap is
// attempted for every crossing pair with EQUAL UNIT COUNTS; unequal units
// would shift fiber demand between terminal nodes after DeloopTrench has
// already sized the cable, and are refused.
//
// research.md 5.2 asks for a same-serving-area restriction in v1, on the
// grounds that a cross-area swap needs the per-cluster fiber bookkeeping of
// backlog item 2. Measured: with that restriction the district clears only
// 55 of 692 crossings and 579 of the residual 637 are cross-area pairs — so
// the restriction, not the geometry, was the binding constraint. It is also
// unnecessary, and for a reason specific to SWAPS: item 2's bookkeeping
// problem belongs to a one-way move (dissolve), which changes cluster_units
// and every aggregate derived from it. A swap is an EXCHANGE — area A loses
// p1's units and gains p2's, which are equal — so cluster_units,
// cluster_prems, cluster_take_units, the cabinet size and each cluster's
// per-node fiber demand are all invariant. The pass therefore runs
// unrestricted, and residual_xarea drops to whatever geometry really costs.
//
// The last scan accepts nothing, so its counts are the residual, split into
// cross-area pairs and the rest (priced out, or blocked by the 150 m rule
// or the optical budget).
fn UncrossDrops(ref d: Design) {
  d.ux_swaps = 0;
  d.ux_rounds = 0;
  d.ux_residual = 0;
  d.ux_residual_xarea = 0;
  var changed: bool = true;
  while (changed and d.ux_rounds < 8) {
    changed = false;
    d.ux_rounds += 1;
    d.ux_residual = 0;
    d.ux_residual_xarea = 0;
    var i: i32 = 0;
    while (i < d.prem_count) {
      var ti: i32 = d.prem_terminal[i];
      if (ti == -1) {
        ++i;
        continue;
      }
      let px: i32 = d.prem_x[i];
      let py: i32 = d.prem_y[i];
      var qx: i32 = d.node_x[d.term_node[ti]];
      var qy: i32 = d.node_y[d.term_node[ti]];
      var lox: i32 = px;
      var hix: i32 = px;
      var loy: i32 = py;
      var hiy: i32 = py;
      if (qx < lox) { lox = qx; }
      if (qx > hix) { hix = qx; }
      if (qy < loy) { loy = qy; }
      if (qy > hiy) { hiy = qy; }
      var j: i32 = i + 1;
      while (j < d.prem_count) {
        let tj: i32 = d.prem_terminal[j];
        if (tj != -1 and tj != ti) {
          let rx: i32 = d.prem_x[j];
          let ry: i32 = d.prem_y[j];
          let sx: i32 = d.node_x[d.term_node[tj]];
          let sy: i32 = d.node_y[d.term_node[tj]];
          var jlox: i32 = rx;
          var jhix: i32 = rx;
          if (sx < jlox) { jlox = sx; }
          if (sx > jhix) { jhix = sx; }
          var jloy: i32 = ry;
          var jhiy: i32 = ry;
          if (sy < jloy) { jloy = sy; }
          if (sy > jhiy) { jhiy = sy; }
          if (jhix >= lox and jlox <= hix and jhiy >= loy and jloy <= hiy and
              ProperCross(px, py, qx, qy, rx, ry, sx, sy)) {
            let xarea: bool = d.prem_cluster[i] != d.prem_cluster[j];
            d.ux_residual += 1;
            if (xarea) {
              d.ux_residual_xarea += 1;
            }
            if (d.prem_units[i] == d.prem_units[j] and
                SwapDelta(ref d, i, j) < 0) {
              SwapDrops(ref d, i, j);
              d.ux_swaps += 1;
              d.ux_residual -= 1;
              if (xarea) {
                d.ux_residual_xarea -= 1;
              }
              changed = true;
              // Drop i moved: re-read it for the rest of this scan.
              ti = d.prem_terminal[i];
              qx = d.node_x[d.term_node[ti]];
              qy = d.node_y[d.term_node[ti]];
              lox = px;
              hix = px;
              loy = py;
              hiy = py;
              if (qx < lox) { lox = qx; }
              if (qx > hix) { hix = qx; }
              if (qy < loy) { loy = qy; }
              if (qy > hiy) { hiy = qy; }
            }
          }
        }
        ++j;
      }
      ++i;
    }
  }
}

// ---------------------------------------------------------------------------
// Stage 10 — connected-facility-location price feedback (iter 008)
// ---------------------------------------------------------------------------

// Fills node_pi from the trench this run actually routed: one multi-source
// Dijkstra in ModeTrenchMarginal seeded from every node the used trench
// touches, so pi_v is the cheapest incremental civil spend that would
// bring the tree to v (0 on the corridor itself). Dijkstra labels are
// unique given the weights, so pi is determined regardless of heap pop
// order among equal keys. Also measures the distribution — min, median by
// binary search on the value, max, and how many nodes cost more than the
// street-crossing penalty to reach — because the coefficient is the point
// of the experiment, not a side effect (research.md appendix A, D4).
fn ComputePi(ref d: Design) {
  var n: i32 = 0;
  while (n < d.node_count) {
    d.in_tree[n] = false;
    ++n;
  }
  var e: i32 = 0;
  while (e < d.edge_count) {
    if (d.trench_used[e]) {
      d.in_tree[d.edge_from[e]] = true;
      d.in_tree[d.edge_to[e]] = true;
    }
    ++e;
  }
  DijkstraReset(ref d);
  n = 0;
  while (n < d.node_count) {
    if (d.in_tree[n]) {
      AddSource(ref d, n);
    }
    ++n;
  }
  DijkstraRun(ref d, ModeTrenchMarginal());

  d.pi_min = 2147483647;
  d.pi_max = 0;
  d.pi_nodes_over_50k = 0;
  n = 0;
  while (n < d.node_count) {
    var pv: i64 = d.dist[n];
    if (pv >= Unreached()) {
      pv = 0;  // unreachable node: no spur is possible, so price nothing
    }
    if (pv > 2000000000) {
      pv = 2000000000;
    }
    let pi32: i32 = pv as i32;
    d.node_pi[n] = pi32;
    if (pi32 < d.pi_min) { d.pi_min = pi32; }
    if (pi32 > d.pi_max) { d.pi_max = pi32; }
    if (pi32 > 50000) { d.pi_nodes_over_50k += 1; }
    ++n;
  }
  if (d.node_count == 0) {
    d.pi_min = 0;
  }

  // Median by binary search on the value: smallest v with #{pi <= v}
  // at least half the nodes. 31 counting passes, fully deterministic.
  var lo: i64 = 0;
  var hi: i64 = d.pi_max as i64;
  let half: i32 = (d.node_count + 1) / 2;
  while (lo < hi) {
    let mid: i64 = (lo + hi) / 2;
    var below: i32 = 0;
    n = 0;
    while (n < d.node_count) {
      if ((d.node_pi[n] as i64) <= mid) {
        below += 1;
      }
      ++n;
    }
    if (below >= half) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  d.pi_med = lo as i32;

  // The population that actually matters is not "every road node" but
  // "every node a terminal could legally stand on" — inside 150 m of some
  // premises. That distribution IS the marginal-trench-per-terminal
  // coefficient three other research.md techniques are budgeted against
  // (appendix A, D4: ~90,000 cents at the top, ~0 in the middle, NOT the
  // flat 210,000 of section 5). Same bounding-box-then-exact scan the
  // packing pair table uses, so the two see the same candidate set.
  // in_tree is free scratch here: RouteDistribution rebuilds it.
  n = 0;
  while (n < d.node_count) {
    d.in_tree[n] = false;
    ++n;
  }
  var p: i32 = 0;
  while (p < d.prem_count) {
    n = 0;
    while (n < d.node_count) {
      if (not d.in_tree[n] and
          d.node_x[n] >= d.prem_x[p] - MaxDropM() and
          d.node_x[n] <= d.prem_x[p] + MaxDropM() and
          d.node_y[n] >= d.prem_y[p] - MaxDropM() and
          d.node_y[n] <= d.prem_y[p] + MaxDropM() and
          DistM(d.prem_x[p], d.prem_y[p], d.node_x[n], d.node_y[n]) <=
              MaxDropM()) {
        d.in_tree[n] = true;
      }
      ++n;
    }
    ++p;
  }
  d.pi_cand_count = 0;
  d.pi_cand_over_50k = 0;
  var cand_max: i64 = 0;
  n = 0;
  while (n < d.node_count) {
    if (d.in_tree[n]) {
      d.pi_cand_count += 1;
      if (d.node_pi[n] > 50000) {
        d.pi_cand_over_50k += 1;
      }
      if ((d.node_pi[n] as i64) > cand_max) {
        cand_max = d.node_pi[n] as i64;
      }
    }
    ++n;
  }
  lo = 0;
  hi = cand_max;
  let cand_half: i32 = (d.pi_cand_count + 1) / 2;
  while (lo < hi) {
    let mid: i64 = (lo + hi) / 2;
    var below: i32 = 0;
    n = 0;
    while (n < d.node_count) {
      if (d.in_tree[n] and (d.node_pi[n] as i64) <= mid) {
        below += 1;
      }
      ++n;
    }
    if (below >= cand_half) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  d.pi_cand_med = lo as i32;
}

// Drops node_pi back to zero: the unpriced sweep must be reproducible
// bit-for-bit, so the fallback re-run starts from the same state sweep 1
// started from.
fn ZeroPi(ref d: Design) {
  var n: i32 = 0;
  while (n < d.node_count) {
    d.node_pi[n] = 0;
    ++n;
  }
}

// Measures the kept design against the price that produced it: how many
// live terminals sit off the previous sweep's corridor, and what their
// spurs are worth. All zero when sweep 1 is kept (its terminals define
// the corridor pi was measured from).
fn MeasurePiOnTerminals(ref d: Design) {
  d.pi_term_priced = 0;
  d.pi_term_over_50k = 0;
  d.pi_term_sum = 0;
  var t: i32 = 0;
  while (t < d.term_count) {
    if (d.term_ports_used[t] > 0) {
      let pv: i32 = d.node_pi[d.term_node[t]];
      if (pv > 0) {
        d.pi_term_priced += 1;
        d.pi_term_sum += pv as i64;
      }
      if (pv > 50000) {
        d.pi_term_over_50k += 1;
      }
    }
    ++t;
  }
}

// Clears every piece of state the packing/routing/costing stages write,
// so a second sweep starts from exactly what PlaceFdh left behind. The
// clustering, FDH siting and graph are untouched — they do not depend on
// terminals, and re-deriving them would only cost time. Correctness of
// this reset is checkable: with pi forced to zero, sweep 2 must score
// identically to sweep 1.
fn ResetForSweep(ref d: Design) {
  var p: i32 = 0;
  while (p < d.prem_count) {
    d.prem_terminal[p] = -1;
    d.prem_drop_len[p] = DistM(d.prem_x[p], d.prem_y[p],
                               d.node_x[d.prem_snap_node[p]],
                               d.node_y[d.prem_snap_node[p]]);
    ++p;
  }
  d.term_count = 0;
  var e: i32 = 0;
  while (e < d.edge_count) {
    d.trench_used[e] = false;
    d.forest_edge[e] = false;
    d.dist_fibers[e] = 0;
    d.feeder_fibers[e] = 0;
    ++e;
  }
  var c: i32 = 0;
  while (c < d.cluster_count) {
    d.fdh_route_len[c] = 0;
    var i: i32 = 0;
    while (i < SplitterSizeCount()) {
      d.fdh_split_by_size[c * 5 + i] = 0;  // ProvisionSplitters accumulates
      ++i;
    }
    ++c;
  }
  var n: i32 = 0;
  while (n < d.node_count) {
    d.pi_bought[n] = false;
    ++n;
  }
}

// Everything from terminal packing to the delooped trench — the part of
// the pipeline a sweep re-decides. Clustering and FDH siting stay put.
fn DesignSweep(ref d: Design) {
  RouteDistribution(ref d);  // packs terminals per serving area as it goes
  MergeTerminals(ref d);     // scorer-priced dissolve + utilization repair
  ProvisionSplitters(ref d);
  SelectCo(ref d);
  RouteFeeder(ref d);
  DeloopTrench(ref d);       // acyclic used trench: re-route cables on the MSF
}
