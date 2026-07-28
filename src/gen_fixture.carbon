// netwerk — deterministic synthetic-town fixture generator.
//
// Emits the netwerk interchange text format on stdout: a grid road network
// with two asphalt arterials, plus premises parcels along every street —
// mostly single-family units with a few MDUs near the town center. The
// generator is seeded and pure-integer, so the fixture is byte-identical on
// every run: this file doubles as the golden-test input (SCOPE.md M1).
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

// Grid dimensions and spacing (meters).
fn GridW() -> i32 { return 10; }
fn GridH() -> i32 { return 10; }
fn Spacing() -> i32 { return 110; }

fn NodeId(col: i32, row: i32) -> i32 {
  return row * GridW() + col;
}

// The two arterial streets (asphalt): the central row and column.
fn IsArterialH(row: i32) -> bool { return row == 5; }
fn IsArterialV(col: i32) -> bool { return col == 5; }

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
      if (IsArterialH(row)) {
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
      if (IsArterialV(col2)) {
        surface = SurfaceAsphalt();
      }
      PrintRow4(eid, NodeId(col2, row2), NodeId(col2, row2 + 1), surface);
      ++eid;
      ++row2;
    }
    ++col2;
  }

  // --- premises: parcels along each horizontal street, both sides ---
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
    var pid: i32 = 0;
    row = 0;
    while (row < GridH()) {
      var c: i32 = 0;
      while (c < GridW() - 1) {
        // Three lots along the block, two sides of the street.
        var lot: i32 = 0;
        while (lot < 3) {
          var side: i32 = 0;
          while (side < 2) {
            // 82% of lots are built.
            if (Rand(100) < 82) {
              let x: i32 = c * Spacing() + 25 + lot * 30 + Rand(11);
              var y: i32 = row * Spacing() - 18;
              if (side == 1) {
                y = row * Spacing() + 18;
              }
              // Mostly single-family; MDUs cluster near the arterials.
              var units: i32 = 1;
              let near_center: bool =
                  (row >= 4 and row <= 6) and (c >= 3 and c <= 6);
              if (near_center and Rand(100) < 12) {
                units = 4 + Rand(13);  // 4..16-unit MDU
              }
              if (pass == 1) {
                PrintRow4(pid, x, y, units);
              }
              ++pid;
            }
            ++side;
          }
          ++lot;
        }
        ++c;
      }
      ++row;
    }
    total = pid;
    ++pass;
  }
  Core.PrintStr("END\n");
}
