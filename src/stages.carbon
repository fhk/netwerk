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
    var best_node: i32 = 0;
    var best_sq: i64 = 9223372036854775807;
    var n: i32 = 0;
    while (n < d.node_count) {
      let dx: i64 = (d.prem_x[p] - d.node_x[n]) as i64;
      let dy: i64 = (d.prem_y[p] - d.node_y[n]) as i64;
      let sq: i64 = dx * dx + dy * dy;
      if (sq < best_sq) {
        best_sq = sq;
        best_node = n;
      }
      ++n;
    }
    d.prem_snap_node[p] = best_node;
    d.prem_drop_len[p] = ISqrt(best_sq);
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
        let dd: i32 = d.seed_dist[recv * 12288 + p];
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
  var cnt: array(i32, 16384);
  var ci: i32 = 0;
  while (ci < d.node_count) {
    cnt[ci] = 0;
    ++ci;
  }
  var pass: i32 = 0;
  var off: array(i32, 16385);
  var fill: array(i32, 16384);
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
  var term_at: array(i32, 16384);
  var ta: i32 = 0;
  while (ta < d.node_count) {
    term_at[ta] = -1;
    ++ta;
  }
  var dead: array(bool, 16384);
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
                          DropCablePerM() * pd;
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
        var cost2: i64 = 50000 * (ac[0] as i64) +
                         TerminalCost(nidx) -
                         TerminalCost(d.term_size_idx[t]) +
                         DropCablePerM() * (ad[0] as i64);
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
  var scratch: array(i32, 4096);
  var ssize: array(i32, 4096);
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
            let mc: i64 = 50000 * (xc as i64) + step +
                          DropCablePerM() * (dd as i64);
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
            DropCablePerM() * ((best_dist - d.prem_drop_len[p]) as i64);
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
    ++n;
  }
  var remaining: i32 = 0;
  var p1: i32 = 0;
  while (p1 < d.prem_count) {
    if (d.prem_terminal[p1] != -1) {
      let tn: i32 = d.term_node[d.prem_terminal[p1]];
      if (d.node_units[tn] == 0) {
        d.node_units[tn] = 1;
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
      ++remaining;
    }
    ++c1;
  }
  if (d.node_units[d.co_node] == 0) {
    d.node_units[d.co_node] = 1;
    ++remaining;
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

  // Phase 2: re-route distribution on the forest, cluster by cluster.
  e = 0;
  while (e < d.edge_count) {
    d.dist_fibers[e] = 0;
    ++e;
  }
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
        // Fibers feed TERMINAL locations (post-merge assignment), so the
        // kept trench always reaches every terminal (backlog 6b).
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

  // Phase 3: re-route feeder CO -> each FDH on the forest.
  e = 0;
  while (e < d.edge_count) {
    d.feeder_fibers[e] = 0;
    ++e;
  }
  ForestBfs(ref d, d.co_node);
  c = 0;
  while (c < d.cluster_count) {
    d.fdh_route_len[c] = 0;
    if (d.fdh_node[c] != d.co_node and d.in_tree[d.fdh_node[c]]) {
      let fibers: i32 = d.fdh_splitters[c] + 1;
      var v: i32 = d.fdh_node[c];
      var meters: i32 = 0;
      while (v != d.co_node and d.tree_parent_edge[v] != -1) {
        let pe: i32 = d.tree_parent_edge[v];
        d.feeder_fibers[pe] += fibers;
        meters += d.edge_len[pe];
        v = d.tree_parent_node[v];
      }
      d.fdh_route_len[c] = meters;
    }
    ++c;
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
