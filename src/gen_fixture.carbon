// netwerk — deterministic synthetic-town fixture generator.
//
// Emits the netwerk interchange text format on stdout: a 30x30 grid road
// network with asphalt arterials, plus premises parcels along every street
// — mostly single-family units with an MDU district near the town center.
// Scale target: ~10,000 households (units). The generator is seeded and
// pure-integer, so the fixture is byte-identical on every run: this file
// doubles as the golden-test input (SCOPE.md M0).
//
// Format (whitespace/comma separated):
//   NETWERK 1
//   NODES <n>      then per node:      id x y
//   EDGES <m>      then per edge:      id from to surface   (0 soft, 1 asphalt)
//   PREMISES <p>   then per premises:  id x y units
//   END

import Core library "io";

import library "io_utils";
import library "model";

// Lehmer / Park–Miller linear congruential generator: deterministic and
// entirely in i64, so identical everywhere.
var lcg_state: i64 = 20260728;

fn Rand(n: i32) -> i32 {
  lcg_state = (lcg_state * 48271) % 2147483647;
  return (lcg_state % (n as i64)) as i32;
}

// Grid dimensions and spacing (meters). 30x30 nodes = 900 nodes, 1740
// street edges; ~5.3 built lots per block side at 88% occupancy lands the
// town at roughly 10k households with the MDU district included.
fn GridW() -> i32 { return 30; }
fn GridH() -> i32 { return 30; }
fn Spacing() -> i32 { return 100; }

fn NodeId(col: i32, row: i32) -> i32 {
  return row * GridW() + col;
}

// Arterial streets (asphalt): rows and columns 10 and 20.
fn IsArterial(idx: i32) -> bool { return idx == 10 or idx == 20; }

// The MDU district: blocks bounded by nodes 11..19 in both axes.
fn InMduZone(a: i32, b: i32) -> bool {
  return a >= 11 and a <= 19 and b >= 11 and b <= 19;
}

fn PrintRow3(a: i32, b: i32, c: i32) {
  PrintInt(a);
  Core.PrintStr(" ");
  PrintInt(b);
  Core.PrintStr(" ");
  PrintInt(c);
  NL();
}

fn PrintRow4(a: i32, b: i32, c: i32, dd: i32) {
  PrintInt(a);
  Core.PrintStr(" ");
  PrintInt(b);
  Core.PrintStr(" ");
  PrintInt(c);
  Core.PrintStr(" ");
  PrintInt(dd);
  NL();
}

// Emits (or counts) the premises along one street edge running from
// (x0,y0) horizontally or vertically. Three lots per side, 88% built.
fn EdgePremises(pid_in: i32, x0: i32, y0: i32, horizontal: bool,
                mdu_zone: bool, emit: bool) -> i32 {
  var pid: i32 = pid_in;
  var lot: i32 = 0;
  while (lot < 3) {
    var side: i32 = 0;
    while (side < 2) {
      if (Rand(100) < 88) {
        let along: i32 = 25 + lot * 25 + Rand(11);
        var off: i32 = -16;
        if (side == 1) {
          off = 16;
        }
        var x: i32 = x0 + along;
        var y: i32 = y0 + off;
        if (not horizontal) {
          x = x0 + off;
          y = y0 + along;
        }
        // Mostly single-family; MDUs cluster in the town-center district.
        var units: i32 = 1;
        if (mdu_zone and Rand(100) < 12) {
          units = 4 + Rand(13);  // 4..16-unit MDU
        }
        if (emit) {
          PrintRow4(pid, x, y, units);
        }
        ++pid;
      }
      ++side;
    }
    ++lot;
  }
  return pid;
}

fn Run() {
  Core.PrintStr("NETWERK 1\n");

  // --- nodes ---
  let node_count: i32 = GridW() * GridH();
  Core.PrintStr("NODES ");
  PrintInt(node_count);
  NL();
  var row: i32 = 0;
  while (row < GridH()) {
    var col: i32 = 0;
    while (col < GridW()) {
      PrintRow3(NodeId(col, row), col * Spacing(), row * Spacing());
      ++col;
    }
    ++row;
  }

  // --- edges: horizontal then vertical grid streets ---
  let edge_count: i32 = (GridW() - 1) * GridH() + GridW() * (GridH() - 1);
  Core.PrintStr("EDGES ");
  PrintInt(edge_count);
  NL();
  var eid: i32 = 0;
  row = 0;
  while (row < GridH()) {
    var col: i32 = 0;
    while (col < GridW() - 1) {
      var surface: i32 = SurfaceSoft();
      if (IsArterial(row)) {
        surface = SurfaceAsphalt();
      }
      PrintRow4(eid, NodeId(col, row), NodeId(col + 1, row), surface);
      ++eid;
      ++col;
    }
    ++row;
  }
  var col2: i32 = 0;
  while (col2 < GridW()) {
    var row2: i32 = 0;
    while (row2 < GridH() - 1) {
      var surface: i32 = SurfaceSoft();
      if (IsArterial(col2)) {
        surface = SurfaceAsphalt();
      }
      PrintRow4(eid, NodeId(col2, row2), NodeId(col2, row2 + 1), surface);
      ++eid;
      ++row2;
    }
    ++col2;
  }

  // --- premises along every street edge, both sides ---
  // Two passes over the same PRNG sequence: first to count, then to emit,
  // so the header count matches without buffering. Reset the seed between
  // passes to replay the identical sequence.
  var pass: i32 = 0;
  var total: i32 = 0;
  while (pass < 2) {
    lcg_state = 977001331;
    if (pass == 1) {
      Core.PrintStr("PREMISES ");
      PrintInt(total);
      NL();
    }
    let emit: bool = pass == 1;
    var pid: i32 = 0;
    row = 0;
    while (row < GridH()) {
      var c: i32 = 0;
      while (c < GridW() - 1) {
        pid = EdgePremises(pid, c * Spacing(), row * Spacing(), true,
                           InMduZone(c, row), emit);
        ++c;
      }
      ++row;
    }
    var c2: i32 = 0;
    while (c2 < GridW()) {
      var r2: i32 = 0;
      while (r2 < GridH() - 1) {
        pid = EdgePremises(pid, c2 * Spacing(), r2 * Spacing(), false,
                           InMduZone(c2, r2), emit);
        ++r2;
      }
      ++c2;
    }
    total = pid;
    ++pass;
  }
  Core.PrintStr("END\n");
}
