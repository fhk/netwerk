// netwerk — pipeline stages 8–10: cable sizing, costing/BOM, QA, report.
//
// SCOPE.md: quantities are exact from the design, not factored estimates;
// QA gates the run with an explicit pass/fail verdict and the CLI exit
// code. The utilization floor (rules) is enforced here as a QA error:
// stranded port capacity fails the design.

library "outputs";

import Core library "io";

import library "io_utils";
import library "model";
import library "graph";

// ---------------------------------------------------------------------------
// Cable sizing: per-edge fiber demand -> catalog cables
// ---------------------------------------------------------------------------

// Smallest catalog cable covering the demand; demand above the largest size
// stacks additional cables greedily.
fn AddCablesForDemand(demand_in: i32, len: i32, ref count_by_size: array(i32, 6),
                      ref meters_by_size: array(i64, 6)) {
  var demand: i32 = demand_in;
  let top: i32 = CableSizeCount() - 1;
  while (demand > CableSize(top)) {
    count_by_size[top] += 1;
    meters_by_size[top] += len as i64;
    demand -= CableSize(top);
  }
  var idx: i32 = 0;
  while (idx < CableSizeCount() and CableSize(idx) < demand) {
    ++idx;
  }
  count_by_size[idx] += 1;
  meters_by_size[idx] += len as i64;
}

// ---------------------------------------------------------------------------
// Equipment totals shared by the report and QA
// ---------------------------------------------------------------------------

fn TotalSplitters(ref d: Design) -> i32 {
  var total: i32 = 0;
  var c: i32 = 0;
  while (c < d.cluster_count) {
    total += d.fdh_splitters[c];
    ++c;
  }
  return total;
}

fn SplitterPortsInstalled(ref d: Design) -> i32 {
  var ports: i32 = 0;
  var c: i32 = 0;
  while (c < d.cluster_count) {
    var i: i32 = 0;
    while (i < SplitterSizeCount()) {
      ports += d.fdh_split_by_size[c * 5 + i] * SplitterSize(i);
      ++i;
    }
    ++c;
  }
  return ports;
}

fn SplitterPortsNeeded(ref d: Design) -> i32 {
  var ports: i32 = 0;
  var c: i32 = 0;
  while (c < d.cluster_count) {
    ports += d.cluster_take_units[c];
    ++c;
  }
  return ports;
}

fn TerminalPortsUsed(ref d: Design) -> i32 {
  var used: i32 = 0;
  var t: i32 = 0;
  while (t < d.term_count) {
    used += d.term_ports_used[t];
    ++t;
  }
  return used;
}

fn TerminalPortsInstalled(ref d: Design) -> i32 {
  var ports: i32 = 0;
  var t: i32 = 0;
  while (t < d.term_count) {
    if (d.term_ports_used[t] > 0) {  // merge pass leaves dissolved slots empty
      ports += TerminalSize(d.term_size_idx[t]);
    }
    ++t;
  }
  return ports;
}

fn LiveTerminals(ref d: Design) -> i32 {
  var live: i32 = 0;
  var t: i32 = 0;
  while (t < d.term_count) {
    if (d.term_ports_used[t] > 0) {
      ++live;
    }
    ++t;
  }
  return live;
}

fn FdhCapacityInstalled(ref d: Design) -> i32 {
  var cap: i32 = 0;
  var c: i32 = 0;
  while (c < d.cluster_count) {
    cap += FdhSize(d.fdh_size_idx[c]);
    ++c;
  }
  return cap;
}

// OLT line cards: full 16-port cards, then the remainder covered with the
// minimum installed ports (rounded up to the 4-port granularity and filled
// greedily from the largest card down) — the graduated-size rule again.
fn OltCards(ref d: Design, ref count_by_size: array(i32, 5)) -> i32 {
  let splitters: i32 = TotalSplitters(ref d);
  var i: i32 = 0;
  while (i < OltCardSizeCount()) {
    count_by_size[i] = 0;
    ++i;
  }
  let top: i32 = OltCardSizeCount() - 1;
  count_by_size[top] = splitters / OltCardPorts(top);
  let rem: i32 = splitters % OltCardPorts(top);
  var cards: i32 = count_by_size[top];
  if (rem > 0) {
    var need: i32 = CeilDiv(rem, OltCardPorts(0)) * OltCardPorts(0);
    var idx: i32 = top;
    while (need > 0) {
      while (idx > 0 and OltCardPorts(idx) > need) {
        --idx;
      }
      count_by_size[idx] += 1;
      ++cards;
      need -= OltCardPorts(idx);
    }
  }
  return cards;
}

fn OltPortsInstalled(ref d: Design) -> i32 {
  var by_size: array(i32, 5);
  let card_total: i32 = OltCards(ref d, ref by_size);
  var ports: i32 = card_total * 0;
  var i: i32 = 0;
  while (i < OltCardSizeCount()) {
    ports += by_size[i] * OltCardPorts(i);
    ++i;
  }
  return ports;
}

// ---------------------------------------------------------------------------
// Utilization: used / installed, per component family
// ---------------------------------------------------------------------------

// Permille (x10 percent) for one-decimal printing without floats.
fn PctX10(used: i32, installed: i32) -> i32 {
  if (installed <= 0) {
    return 0;
  }
  return ((used as i64) * 1000 / (installed as i64)) as i32;
}

fn PrintPct(label: str, used: i32, installed: i32) {
  Core.PrintStr("  ");
  Core.PrintStr(label);
  Core.PrintStr(": ");
  PrintInt(used);
  Core.PrintStr("/");
  PrintInt(installed);
  Core.PrintStr(" = ");
  let px10: i32 = PctX10(used, installed);
  PrintInt(px10 / 10);
  Core.PrintChar('.');
  PrintDigit(px10 % 10);
  Core.PrintStr("%\n");
}

// ---------------------------------------------------------------------------
// QA checks (SCOPE.md: machine-readable verdict, non-zero exit on fail)
// ---------------------------------------------------------------------------

fn QaLine(name: str, failures: i32) {
  Core.PrintStr("  ");
  Core.PrintStr(name);
  Core.PrintStr(": ");
  if (failures == 0) {
    Core.PrintStr("ok");
  } else {
    PrintInt(failures);
    Core.PrintStr(" FAIL");
  }
  NL();
}

fn QaUtil(name: str, used: i32, installed: i32) -> i32 {
  let px10: i32 = PctX10(used, installed);
  Core.PrintStr("  ");
  Core.PrintStr(name);
  Core.PrintStr(": ");
  PrintInt(px10 / 10);
  Core.PrintChar('.');
  PrintDigit(px10 % 10);
  Core.PrintStr("%");
  if (px10 >= UtilizationFloorPct() * 10) {
    Core.PrintStr(" ok\n");
    return 0;
  }
  Core.PrintStr(" FAIL (floor ");
  PrintInt(UtilizationFloorPct());
  Core.PrintStr("%)\n");
  return 1;
}

fn RunQa(ref d: Design) -> i32 {
  Core.PrintStr("qa:\n");
  var errors: i32 = 0;

  // Every premises assigned to a serving area and a terminal.
  var unserved: i32 = 0;
  var p: i32 = 0;
  while (p < d.prem_count) {
    if (d.prem_cluster[p] == -1 or d.prem_terminal[p] == -1) {
      ++unserved;
    }
    ++p;
  }
  QaLine("premises_served", unserved);
  errors += unserved;

  // Drop-length rule (drops now run premises -> shared terminal).
  var long_drops: i32 = 0;
  p = 0;
  while (p < d.prem_count) {
    if (d.prem_drop_len[p] > MaxDropM()) {
      ++long_drops;
    }
    ++p;
  }
  QaLine("drop_length", long_drops);
  errors += long_drops;

  // Serving-area units within the chosen cabinet's capacity.
  var over_cap: i32 = 0;
  var c: i32 = 0;
  while (c < d.cluster_count) {
    if (d.cluster_units[c] > FdhSize(d.fdh_size_idx[c])) {
      ++over_cap;
    }
    ++c;
  }
  QaLine("fdh_capacity", over_cap);
  errors += over_cap;

  // Terminal ports within the chosen terminal size.
  var over_ports: i32 = 0;
  var t: i32 = 0;
  while (t < d.term_count) {
    if (d.term_ports_used[t] > TerminalSize(d.term_size_idx[t])) {
      ++over_ports;
    }
    ++t;
  }
  QaLine("terminal_ports", over_ports);
  errors += over_ports;

  // Splitter bank covers provisioned units per FDH.
  var under_split: i32 = 0;
  c = 0;
  while (c < d.cluster_count) {
    var cap: i32 = 0;
    var i: i32 = 0;
    while (i < SplitterSizeCount()) {
      cap += d.fdh_split_by_size[c * 5 + i] * SplitterSize(i);
      ++i;
    }
    if (cap < d.cluster_take_units[c]) {
      ++under_split;
    }
    ++c;
  }
  QaLine("splitter_capacity", under_split);
  errors += under_split;

  // Optical-budget proxy: feeder + distribution + drop route meters.
  var over_budget: i32 = 0;
  p = 0;
  while (p < d.prem_count) {
    let tp: i32 = d.prem_terminal[p];
    if (tp != -1) {
      let route_m: i32 = d.fdh_route_len[d.prem_cluster[p]] +
                         d.term_path_len[tp] + d.prem_drop_len[p];
      if (route_m > MaxRouteM()) {
        ++over_budget;
      }
    }
    ++p;
  }
  QaLine("route_length_budget", over_budget);
  errors += over_budget;

  // Feeder routed to every FDH (CO reachable).
  var unrouted: i32 = 0;
  c = 0;
  while (c < d.cluster_count) {
    if (d.fdh_node[c] != d.co_nodes[d.cluster_co[c]] and
        d.fdh_route_len[c] == 0) {
      ++unrouted;
    }
    ++c;
  }
  QaLine("feeder_routed", unrouted);
  errors += unrouted;

  // Utilization floor on every port-bearing component family.
  errors += QaUtil("util_terminal_ports", TerminalPortsUsed(ref d),
                   TerminalPortsInstalled(ref d));
  errors += QaUtil("util_splitter_ports", SplitterPortsNeeded(ref d),
                   SplitterPortsInstalled(ref d));
  errors += QaUtil("util_fdh_capacity", d.total_units,
                   FdhCapacityInstalled(ref d));
  errors += QaUtil("util_olt_card_ports", TotalSplitters(ref d),
                   OltPortsInstalled(ref d));

  Core.PrintStr("qa verdict: ");
  if (errors == 0) {
    Core.PrintStr("PASS\n");
  } else {
    Core.PrintStr("FAIL\n");
  }
  return errors;
}

// ---------------------------------------------------------------------------
// Costing, BOM, and the design report
// ---------------------------------------------------------------------------

fn BomLine(name: str, qty: i64, unit: str, unit_cost: i64, ext: i64) {
  Core.PrintStr("  ");
  Core.PrintStr(name);
  Core.PrintStr(" qty=");
  PrintI64(qty);
  Core.PrintStr(" ");
  Core.PrintStr(unit);
  Core.PrintStr(" unit=$");
  PrintMoney(unit_cost);
  Core.PrintStr(" ext=$");
  PrintMoney(ext);
  NL();
}

fn BomCableLine(prefix: str, size: i32, meters: i64, unit_cost: i64) {
  Core.PrintStr("  ");
  Core.PrintStr(prefix);
  PrintInt(size);
  Core.PrintStr("f qty=");
  PrintI64(meters);
  Core.PrintStr(" m unit=$");
  PrintMoney(unit_cost);
  Core.PrintStr(" ext=$");
  PrintMoney(meters * unit_cost);
  NL();
}

// Prints the full report and returns total capex in cents.
fn Report(ref d: Design) -> i64 {
  // --- size cables from per-edge demand, with spare fibers on distribution ---
  var dist_count: array(i32, 6);
  var dist_m: array(i64, 6);
  var feed_count: array(i32, 6);
  var feed_m: array(i64, 6);
  var i: i32 = 0;
  while (i < 6) {
    dist_count[i] = 0;
    dist_m[i] = 0;
    feed_count[i] = 0;
    feed_m[i] = 0;
    ++i;
  }

  var trench_m_soft: i64 = 0;
  var trench_m_asphalt: i64 = 0;
  var cable_route_m: i64 = 0;

  var e: i32 = 0;
  while (e < d.edge_count) {
    if (d.dist_fibers[e] > 0) {
      let demand: i32 = CeilDiv(d.dist_fibers[e] * (100 + SparePct()), 100);
      AddCablesForDemand(demand, d.edge_len[e], ref dist_count, ref dist_m);
      cable_route_m += d.edge_len[e] as i64;
    }
    if (d.feeder_fibers[e] > 0) {
      AddCablesForDemand(d.feeder_fibers[e], d.edge_len[e],
                         ref feed_count, ref feed_m);
      cable_route_m += d.edge_len[e] as i64;
    }
    if (d.trench_used[e]) {
      if (d.edge_surface[e] == SurfaceAsphalt()) {
        trench_m_asphalt += d.edge_len[e] as i64;
      } else {
        trench_m_soft += d.edge_len[e] as i64;
      }
    }
    ++e;
  }

  var drop_m: i64 = 0;
  var p: i32 = 0;
  while (p < d.prem_count) {
    drop_m += d.prem_drop_len[p] as i64;
    ++p;
  }

  let total_splitters: i32 = TotalSplitters(ref d);
  var olt_by_size: array(i32, 5);
  let olt_cards: i32 = OltCards(ref d, ref olt_by_size);
  let olt_chassis: i32 = CeilDiv(olt_cards, OltChassisCardSlots());

  // --- headline metrics ---
  Core.PrintStr("design:\n");
  Core.PrintStr("  premises=");
  PrintInt(d.prem_count);
  Core.PrintStr(" units=");
  PrintInt(d.total_units);
  Core.PrintStr(" serving_areas=");
  PrintInt(d.cluster_count);
  Core.PrintStr(" terminals=");
  PrintInt(LiveTerminals(ref d));
  NL();
  Core.PrintStr("  co_node=");
  PrintInt(d.co_node);
  Core.PrintStr(" head_ends=");
  PrintInt(d.co_count);
  Core.PrintStr(" olt_chassis=");
  PrintInt(olt_chassis);
  Core.PrintStr(" olt_cards=");
  PrintInt(olt_cards);
  Core.PrintStr(" pon_ports_used=");
  PrintInt(total_splitters);
  NL();
  var c2: i32 = 0;
  while (c2 < d.cluster_count) {
    Core.PrintStr("  area ");
    PrintInt(c2);
    Core.PrintStr(": fdh_node=");
    PrintInt(d.fdh_node[c2]);
    Core.PrintStr(" premises=");
    PrintInt(d.cluster_prems[c2]);
    Core.PrintStr(" units=");
    PrintInt(d.cluster_units[c2]);
    Core.PrintStr(" cabinet=");
    PrintInt(FdhSize(d.fdh_size_idx[c2]));
    Core.PrintStr(" splitters=");
    PrintInt(d.fdh_splitters[c2]);
    Core.PrintStr(" feeder_m=");
    PrintInt(d.fdh_route_len[c2]);
    NL();
    ++c2;
  }

  // --- utilization (the design objective this report proves) ---
  Core.PrintStr("utilization:\n");
  PrintPct("terminal_ports", TerminalPortsUsed(ref d),
           TerminalPortsInstalled(ref d));
  PrintPct("splitter_ports", SplitterPortsNeeded(ref d),
           SplitterPortsInstalled(ref d));
  PrintPct("fdh_capacity", d.total_units, FdhCapacityInstalled(ref d));
  PrintPct("olt_card_ports", total_splitters, OltPortsInstalled(ref d));

  // --- BOM with extended costs ---
  var total: i64 = 0;
  Core.PrintStr("bom:\n");

  let trench_soft_cost: i64 = trench_m_soft * TrenchCostPerM(SurfaceSoft());
  BomLine("trench_soft", trench_m_soft, "m",
          TrenchCostPerM(SurfaceSoft()), trench_soft_cost);
  total += trench_soft_cost;

  let trench_asphalt_cost: i64 =
      trench_m_asphalt * TrenchCostPerM(SurfaceAsphalt());
  BomLine("trench_asphalt", trench_m_asphalt, "m",
          TrenchCostPerM(SurfaceAsphalt()), trench_asphalt_cost);
  total += trench_asphalt_cost;

  i = 0;
  while (i < 6) {
    if (dist_m[i] > 0) {
      BomCableLine("dist_cable_", CableSize(i), dist_m[i], CableCostPerM(i));
      total += dist_m[i] * CableCostPerM(i);
    }
    ++i;
  }
  i = 0;
  while (i < 6) {
    if (feed_m[i] > 0) {
      BomCableLine("feeder_cable_", CableSize(i), feed_m[i], CableCostPerM(i));
      total += feed_m[i] * CableCostPerM(i);
    }
    ++i;
  }

  let drop_cable_cost: i64 = drop_m * DropCablePerM();
  BomLine("drop_cable", drop_m, "m", DropCablePerM(), drop_cable_cost);
  total += drop_cable_cost;

  let drop_cost: i64 = (d.prem_count as i64) * DropUnitCost();
  BomLine("drop_assembly", d.prem_count as i64, "ea",
          DropUnitCost(), drop_cost);
  total += drop_cost;

  // FDH cabinets by size.
  i = 0;
  while (i < FdhSizeCount()) {
    var count: i32 = 0;
    var c: i32 = 0;
    while (c < d.cluster_count) {
      if (d.fdh_size_idx[c] == i) {
        ++count;
      }
      ++c;
    }
    if (count > 0) {
      Core.PrintStr("  fdh_cabinet_");
      PrintInt(FdhSize(i));
      Core.PrintStr(" qty=");
      PrintInt(count);
      Core.PrintStr(" ea unit=$");
      PrintMoney(FdhCost(i));
      Core.PrintStr(" ext=$");
      PrintMoney((count as i64) * FdhCost(i));
      NL();
      total += (count as i64) * FdhCost(i);
    }
    ++i;
  }

  // Splitters by ratio.
  i = 0;
  while (i < SplitterSizeCount()) {
    var count2: i32 = 0;
    var c3: i32 = 0;
    while (c3 < d.cluster_count) {
      count2 += d.fdh_split_by_size[c3 * 5 + i];
      ++c3;
    }
    if (count2 > 0) {
      Core.PrintStr("  splitter_1_");
      PrintInt(SplitterSize(i));
      Core.PrintStr(" qty=");
      PrintInt(count2);
      Core.PrintStr(" ea unit=$");
      PrintMoney(SplitterCost(i));
      Core.PrintStr(" ext=$");
      PrintMoney((count2 as i64) * SplitterCost(i));
      NL();
      total += (count2 as i64) * SplitterCost(i);
    }
    ++i;
  }

  // Terminals by size.
  i = 0;
  while (i < TerminalSizeCount()) {
    var count3: i32 = 0;
    var t: i32 = 0;
    while (t < d.term_count) {
      if (d.term_ports_used[t] > 0 and d.term_size_idx[t] == i) {
        ++count3;
      }
      ++t;
    }
    if (count3 > 0) {
      Core.PrintStr("  terminal_");
      PrintInt(TerminalSize(i));
      Core.PrintStr("p qty=");
      PrintInt(count3);
      Core.PrintStr(" ea unit=$");
      PrintMoney(TerminalCost(i));
      Core.PrintStr(" ext=$");
      PrintMoney((count3 as i64) * TerminalCost(i));
      NL();
      total += (count3 as i64) * TerminalCost(i);
    }
    ++i;
  }

  // OLT line cards by size, plus per-port optics for lit ports.
  i = 0;
  while (i < OltCardSizeCount()) {
    if (olt_by_size[i] > 0) {
      Core.PrintStr("  olt_card_");
      PrintInt(OltCardPorts(i));
      Core.PrintStr("p qty=");
      PrintInt(olt_by_size[i]);
      Core.PrintStr(" ea unit=$");
      PrintMoney(OltCardCost(i));
      Core.PrintStr(" ext=$");
      PrintMoney((olt_by_size[i] as i64) * OltCardCost(i));
      NL();
      total += (olt_by_size[i] as i64) * OltCardCost(i);
    }
    ++i;
  }
  let olt_optics_cost: i64 = (total_splitters as i64) * OltPortCost();
  BomLine("olt_port_optics", total_splitters as i64, "ea",
          OltPortCost(), olt_optics_cost);
  total += olt_optics_cost;

  // --- cost rollup ---
  let trench_total: i64 = trench_m_soft + trench_m_asphalt;
  Core.PrintStr("cost:\n  total_capex=$");
  PrintMoney(total);
  NL();
  Core.PrintStr("  per_unit_passed=$");
  PrintMoney(total / (d.total_units as i64));
  NL();
  Core.PrintStr("  trench_m=");
  PrintI64(trench_total);
  Core.PrintStr(" cable_route_m=");
  PrintI64(cable_route_m);
  Core.PrintStr(" sharing_x100=");
  if (trench_total > 0) {
    PrintI64(cable_route_m * 100 / trench_total);
  } else {
    Core.PrintStr("0");
  }
  NL();
  return total;
}

// ---------------------------------------------------------------------------
// Geometry dump — machine-readable design detail for GIS export
// ---------------------------------------------------------------------------

// Emitted by the netwerk_export binary and consumed by
// tools/design2geojson.py, which joins these ids with the interchange
// geometry and writes per-layer GeoJSON. One line per element, "G "-prefixed:
//   G co <node>
//   G fdh <area> <node> <cabinet_units> <splitters> <units> <take_units> <feeder_m>
//   G term <id> <node> <area> <ports> <used> <path_m>          (live only)
//   G prem <id> <area> <terminal> <drop_m>
//   G edge <id> <trench01> <dist_fibers> <feeder_fibers>       (used edges only)
fn PrintGeometry(ref d: Design) {
  Core.PrintStr("GEOM 1\n");

  Core.PrintStr("G co ");
  PrintInt(d.co_node);
  NL();

  var c: i32 = 0;
  while (c < d.cluster_count) {
    Core.PrintStr("G fdh ");
    PrintInt(c);
    Core.PrintStr(" ");
    PrintInt(d.fdh_node[c]);
    Core.PrintStr(" ");
    PrintInt(FdhSize(d.fdh_size_idx[c]));
    Core.PrintStr(" ");
    PrintInt(d.fdh_splitters[c]);
    Core.PrintStr(" ");
    PrintInt(d.cluster_units[c]);
    Core.PrintStr(" ");
    PrintInt(d.cluster_take_units[c]);
    Core.PrintStr(" ");
    PrintInt(d.fdh_route_len[c]);
    NL();
    ++c;
  }

  var t: i32 = 0;
  while (t < d.term_count) {
    if (d.term_ports_used[t] > 0) {
      Core.PrintStr("G term ");
      PrintInt(t);
      Core.PrintStr(" ");
      PrintInt(d.term_node[t]);
      Core.PrintStr(" ");
      PrintInt(d.term_cluster[t]);
      Core.PrintStr(" ");
      PrintInt(TerminalSize(d.term_size_idx[t]));
      Core.PrintStr(" ");
      PrintInt(d.term_ports_used[t]);
      Core.PrintStr(" ");
      PrintInt(d.term_path_len[t]);
      NL();
    }
    ++t;
  }

  var p: i32 = 0;
  while (p < d.prem_count) {
    Core.PrintStr("G prem ");
    PrintInt(p);
    Core.PrintStr(" ");
    PrintInt(d.prem_cluster[p]);
    Core.PrintStr(" ");
    PrintInt(d.prem_terminal[p]);
    Core.PrintStr(" ");
    PrintInt(d.prem_drop_len[p]);
    NL();
    ++p;
  }

  var e: i32 = 0;
  while (e < d.edge_count) {
    if (d.trench_used[e] or d.dist_fibers[e] > 0 or d.feeder_fibers[e] > 0) {
      Core.PrintStr("G edge ");
      PrintInt(e);
      Core.PrintStr(" ");
      if (d.trench_used[e]) {
        PrintInt(1);
      } else {
        PrintInt(0);
      }
      Core.PrintStr(" ");
      PrintInt(d.dist_fibers[e]);
      Core.PrintStr(" ");
      PrintInt(d.feeder_fibers[e]);
      NL();
    }
    ++e;
  }
  Core.PrintStr("END\n");
}

// ---------------------------------------------------------------------------
// Sweep scoring — the comparison that decides which packing sweep ships
// ---------------------------------------------------------------------------

fn IMin(a: i32, b: i32) -> i32 {
  if (a < b) { return a; }
  return b;
}

fn IMax(a: i32, b: i32) -> i32 {
  if (a > b) { return a; }
  return b;
}

// Street crossings over every connected drop — the scorer's own predicate
// via the shared edge grid, so the engine ranks sweeps on the same number
// the ledger will report.
fn DropStreetCrossings(ref d: Design) -> i32 {
  var total: i32 = 0;
  var p: i32 = 0;
  while (p < d.prem_count) {
    let t: i32 = d.prem_terminal[p];
    if (t != -1) {
      total += CountDropCrossings(ref d, d.prem_x[p], d.prem_y[p],
                                  d.term_node[t]);
    }
    ++p;
  }
  return total;
}

// Drop-drop proper crossings, each unordered pair once. Bounding boxes
// that do not overlap cannot properly cross, so the prefilter is exact —
// it matches the scorer's grid hash, which is a coarser superset of the
// same test.
fn DropDropCrossings(ref d: Design) -> i32 {
  var total: i32 = 0;
  var i: i32 = 0;
  while (i < d.prem_count) {
    let ti: i32 = d.prem_terminal[i];
    if (ti == -1) {
      ++i;
      continue;
    }
    let px: i32 = d.prem_x[i];
    let py: i32 = d.prem_y[i];
    let qx: i32 = d.node_x[d.term_node[ti]];
    let qy: i32 = d.node_y[d.term_node[ti]];
    let lox: i32 = IMin(px, qx);
    let hix: i32 = IMax(px, qx);
    let loy: i32 = IMin(py, qy);
    let hiy: i32 = IMax(py, qy);
    var j: i32 = i + 1;
    while (j < d.prem_count) {
      let tj: i32 = d.prem_terminal[j];
      if (tj != -1) {
        let rx: i32 = d.prem_x[j];
        let ry: i32 = d.prem_y[j];
        let sx: i32 = d.node_x[d.term_node[tj]];
        let sy: i32 = d.node_y[d.term_node[tj]];
        if (IMax(rx, sx) >= lox and IMin(rx, sx) <= hix and
            IMax(ry, sy) >= loy and IMin(ry, sy) <= hiy and
            ProperCross(px, py, qx, qy, rx, ry, sx, sy)) {
          ++total;
        }
      }
      ++j;
    }
    ++i;
  }
  return total;
}

// The QA families a packing sweep can actually move, counted the way the
// scorer counts them: one error per failing CHECK, not per failing item.
// Cabinet/splitter/OLT families depend only on the cluster assignment,
// which no sweep touches, so they cannot differ between sweeps.
fn SweepQaErrors(ref d: Design) -> i32 {
  var errors: i32 = 0;
  var unserved: i32 = 0;
  var long_drops: i32 = 0;
  var over_budget: i32 = 0;
  var p: i32 = 0;
  while (p < d.prem_count) {
    let t: i32 = d.prem_terminal[p];
    if (d.prem_cluster[p] == -1 or t == -1) {
      ++unserved;
    }
    if (d.prem_drop_len[p] > MaxDropM()) {
      ++long_drops;
    }
    if (t != -1) {
      let route_m: i32 = d.fdh_route_len[d.prem_cluster[p]] +
                         d.term_path_len[t] + d.prem_drop_len[p];
      if (route_m > MaxRouteM()) {
        ++over_budget;
      }
    }
    ++p;
  }
  if (unserved > 0) { ++errors; }
  if (long_drops > 0) { ++errors; }
  if (over_budget > 0) { ++errors; }

  var over_ports: i32 = 0;
  var t2: i32 = 0;
  while (t2 < d.term_count) {
    if (d.term_ports_used[t2] > TerminalSize(d.term_size_idx[t2])) {
      ++over_ports;
    }
    ++t2;
  }
  if (over_ports > 0) { ++errors; }

  let used: i32 = TerminalPortsUsed(ref d);
  let installed: i32 = TerminalPortsInstalled(ref d);
  if (PctX10(used, installed) < UtilizationFloorPct() * 10) {
    ++errors;
  }
  return errors;
}

// Composite score of the current design, restricted to the terms a
// packing sweep can change: trench, all cable, drop cable, terminal
// hardware, and every penalty in tools/score_design.py's formula. FDH
// cabinets, splitters, OLT cards and drop assemblies follow from the
// cluster assignment, which sweeps leave alone, so they are constant
// offsets and are omitted; rings are 0 by construction (DeloopTrench
// ships a subset of a tree). Same units and same coefficients as the
// ledger, so "sweep 2 scored better" means the same thing here as there.
fn SweepScore(ref d: Design) -> i64 {
  var dist_count: array(i32, 6);
  var dist_m: array(i64, 6);
  var feed_count: array(i32, 6);
  var feed_m: array(i64, 6);
  var i: i32 = 0;
  while (i < 6) {
    dist_count[i] = 0;
    dist_m[i] = 0;
    feed_count[i] = 0;
    feed_m[i] = 0;
    ++i;
  }
  var score: i64 = 0;
  var e: i32 = 0;
  while (e < d.edge_count) {
    if (d.dist_fibers[e] > 0) {
      let demand: i32 = CeilDiv(d.dist_fibers[e] * (100 + SparePct()), 100);
      AddCablesForDemand(demand, d.edge_len[e], ref dist_count, ref dist_m);
    }
    if (d.feeder_fibers[e] > 0) {
      AddCablesForDemand(d.feeder_fibers[e], d.edge_len[e],
                         ref feed_count, ref feed_m);
    }
    if (d.trench_used[e]) {
      score += (d.edge_len[e] as i64) * TrenchCostPerM(d.edge_surface[e]);
    }
    ++e;
  }
  i = 0;
  while (i < 6) {
    score += (dist_m[i] + feed_m[i]) * CableCostPerM(i);
    ++i;
  }
  var p: i32 = 0;
  while (p < d.prem_count) {
    score += (d.prem_drop_len[p] as i64) * DropCablePerM();
    ++p;
  }
  var viol: i64 = 0;
  var t: i32 = 0;
  while (t < d.term_count) {
    let used: i32 = d.term_ports_used[t];
    if (used > 0) {
      score += TerminalCost(d.term_size_idx[t]);
      if (used < 4 or used > 12) {
        viol += 1;
      }
    }
    ++t;
  }
  score += 50000 * (DropStreetCrossings(ref d) as i64);
  score += 20000 * (DropDropCrossings(ref d) as i64);
  score += 100000 * viol;
  score += 1000000 * (SweepQaErrors(ref d) as i64);
  return score;
}

// The measured trench price and what the second sweep did with it. Placed
// before the qa block on purpose: the scorer counts qa errors by scanning
// report lines between "qa:" and "qa verdict:".
fn PrintSweeps(ref d: Design) {
  Core.PrintStr("sweeps:\n");
  // Stage 3c/3d: unit-weighted meters premises -> its own cabinet, on the
  // one table that matters (distance from the sites actually built). The
  // three numbers are the same assignment problem scored three ways:
  // what the farthest-point seeds chose, what one Lloyd step chose, and
  // the transportation optimum at those same sites.
  Core.PrintStr("  assignment_m: seeds=");
  PrintI64(d.assign_cost_seed);
  Core.PrintStr(" lloyd=");
  PrintI64(d.assign_cost_lloyd);
  Core.PrintStr(" exact=");
  PrintI64(d.assign_cost_exact);
  Core.PrintStr(" cycles=");
  PrintInt(d.assign_cycles);
  Core.PrintStr(" moved=");
  PrintInt(d.assign_moved);
  Core.PrintStr(" stop=");
  PrintInt(d.assign_stop);
  NL();
  Core.PrintStr("  trench_price_cents: min=");
  PrintInt(d.pi_min);
  Core.PrintStr(" median=");
  PrintInt(d.pi_med);
  Core.PrintStr(" max=");
  PrintInt(d.pi_max);
  Core.PrintStr(" nodes_over_50k=");
  PrintInt(d.pi_nodes_over_50k);
  NL();
  Core.PrintStr("  trench_price_candidates: n=");
  PrintInt(d.pi_cand_count);
  Core.PrintStr(" median=");
  PrintInt(d.pi_cand_med);
  Core.PrintStr(" over_50k=");
  PrintInt(d.pi_cand_over_50k);
  NL();
  Core.PrintStr("  priced_sweep_terminals: priced=");
  PrintInt(d.pi_term_priced);
  Core.PrintStr(" over_50k=");
  PrintInt(d.pi_term_over_50k);
  Core.PrintStr(" spur_cents=");
  PrintI64(d.pi_term_sum);
  NL();
  Core.PrintStr("  sweep_score: unpriced=");
  PrintI64(d.sweep_score_a);
  Core.PrintStr(" priced=");
  PrintI64(d.sweep_score_b);
  Core.PrintStr(" kept=");
  PrintInt(d.sweep_kept);
  NL();
  // What the 2-opt uncrossing pass did and what it could not reach. The
  // residual split is the measurement that sizes the next piece of work:
  // xarea pairs are the ones v1 refuses for want of per-cluster fiber
  // bookkeeping (backlog item 2), the rest are priced-out or blocked by
  // the 150 m drop rule.
  Core.PrintStr("  uncross_2opt: swaps=");
  PrintInt(d.ux_swaps);
  Core.PrintStr(" scans=");
  PrintInt(d.ux_rounds);
  Core.PrintStr(" residual=");
  PrintInt(d.ux_residual);
  Core.PrintStr(" residual_xarea=");
  PrintInt(d.ux_residual_xarea);
  NL();
  // Stage 9a: what key-path exchange took off the constructed Steiner tree.
  // before/after are the TREE's meters and civil cents (phase 4 then prunes
  // to the trench actually reported), so the cents delta is the direct,
  // isqrt-exact answer to research.md 3.2 — and to appendix A's D2, which
  // asks whether that section's -15.5M or section 2's 25.55M dual slack
  // ceiling is the one telling the truth. rollback is the undo counter:
  // 1 = an exchange pushed a CO->premises route past MaxRouteM and the
  // whole pass was reverted, 2 = the tree invariant failed (must be 0).
  Core.PrintStr("  keypath_exchange: rounds=");
  PrintInt(d.kp_rounds);
  Core.PrintStr(" moves=");
  PrintInt(d.kp_moves);
  Core.PrintStr(" paths=");
  PrintInt(d.kp_paths);
  Core.PrintStr(" tree_m=");
  PrintInt(d.kp_trench_before);
  Core.PrintStr("->");
  PrintInt(d.kp_trench_after);
  Core.PrintStr(" cents=");
  PrintI64(d.kp_cents_before);
  Core.PrintStr("->");
  PrintI64(d.kp_cents_after);
  Core.PrintStr(" rollback=");
  PrintInt(d.kp_rollback);
  Core.PrintStr(" route_max_m=");
  PrintInt(d.kp_route_max);
  NL();
  // Stage 9c: what priced re-siting took off the same tree. spurs is the
  // residual census — terminals still standing on a private spur after the
  // search stopped, i.e. the ones whose spur is worth less than the drops
  // and crossings that retiring it would buy. gain is the summed scorer
  // delta of the accepted moves and is an UNDER-statement of the real
  // saving: the cable that rode each retired spur goes with it and is not
  // priced here.
  Core.PrintStr("  spur_resite: rounds=");
  PrintInt(d.rs_rounds);
  Core.PrintStr(" moves=");
  PrintInt(d.rs_moves);
  Core.PrintStr(" spurs_left=");
  PrintInt(d.rs_spurs);
  Core.PrintStr(" trench_m=-");
  PrintInt(d.rs_freed_m);
  Core.PrintStr(" cents=-");
  PrintI64(d.rs_freed_cents);
  Core.PrintStr(" gain=");
  PrintI64(d.rs_gain);
  NL();
}
