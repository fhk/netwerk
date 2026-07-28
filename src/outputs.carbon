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
      ports += d.fdh_split_by_size[c * 4 + i] * SplitterSize(i);
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
fn OltCards(ref d: Design, ref count_by_size: array(i32, 3)) -> i32 {
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
  var by_size: array(i32, 3);
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
      cap += d.fdh_split_by_size[c * 4 + i] * SplitterSize(i);
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
    if (d.fdh_node[c] != d.co_node and d.fdh_route_len[c] == 0) {
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
  var olt_by_size: array(i32, 3);
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
      count2 += d.fdh_split_by_size[c3 * 4 + i];
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
