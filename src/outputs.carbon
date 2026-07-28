// netwerk — pipeline stages 8–10: cable sizing, costing/BOM, QA, report.
//
// SCOPE.md: quantities are exact from the design, not factored estimates;
// QA gates the run with an explicit pass/fail verdict and the CLI exit code.

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

  // Drop-length rule.
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

  // FDH capacity.
  var over_cap: i32 = 0;
  var c: i32 = 0;
  while (c < d.cluster_count) {
    if (d.cluster_units[c] > MaxUnitsPerFdh()) {
      ++over_cap;
    }
    ++c;
  }
  QaLine("fdh_capacity", over_cap);
  errors += over_cap;

  // Terminal port capacity.
  var over_ports: i32 = 0;
  var t: i32 = 0;
  while (t < d.term_count) {
    if (d.term_ports_used[t] > TerminalPorts()) {
      ++over_ports;
    }
    ++t;
  }
  QaLine("terminal_ports", over_ports);
  errors += over_ports;

  // Splitter capacity covers provisioned units.
  var under_split: i32 = 0;
  c = 0;
  while (c < d.cluster_count) {
    if (d.fdh_splitters[c] * SplitterRatio() < d.cluster_take_units[c]) {
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

  var total_splitters: i32 = 0;
  var c: i32 = 0;
  while (c < d.cluster_count) {
    total_splitters += d.fdh_splitters[c];
    ++c;
  }

  // --- headline metrics ---
  Core.PrintStr("design:\n");
  Core.PrintStr("  premises=");
  PrintInt(d.prem_count);
  Core.PrintStr(" units=");
  PrintInt(d.total_units);
  Core.PrintStr(" serving_areas=");
  PrintInt(d.cluster_count);
  Core.PrintStr(" terminals=");
  PrintInt(d.term_count);
  NL();
  Core.PrintStr("  co_node=");
  PrintInt(d.co_node);
  Core.PrintStr(" olt_chassis=");
  PrintInt(d.olt_count);
  Core.PrintStr(" pon_ports=");
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
    Core.PrintStr(" splitters=");
    PrintInt(d.fdh_splitters[c2]);
    Core.PrintStr(" feeder_m=");
    PrintInt(d.fdh_route_len[c2]);
    NL();
    ++c2;
  }

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
      let ext: i64 = dist_m[i] * CableCostPerM(i);
      Core.PrintStr("  dist_cable_");
      PrintInt(CableSize(i));
      Core.PrintStr("f qty=");
      PrintI64(dist_m[i]);
      Core.PrintStr(" m unit=$");
      PrintMoney(CableCostPerM(i));
      Core.PrintStr(" ext=$");
      PrintMoney(ext);
      NL();
      total += ext;
    }
    ++i;
  }
  i = 0;
  while (i < 6) {
    if (feed_m[i] > 0) {
      let ext2: i64 = feed_m[i] * CableCostPerM(i);
      Core.PrintStr("  feeder_cable_");
      PrintInt(CableSize(i));
      Core.PrintStr("f qty=");
      PrintI64(feed_m[i]);
      Core.PrintStr(" m unit=$");
      PrintMoney(CableCostPerM(i));
      Core.PrintStr(" ext=$");
      PrintMoney(ext2);
      NL();
      total += ext2;
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

  let fdh_cost: i64 = (d.cluster_count as i64) * FdhUnitCost();
  BomLine("fdh_cabinet", d.cluster_count as i64, "ea",
          FdhUnitCost(), fdh_cost);
  total += fdh_cost;

  let split_cost: i64 = (total_splitters as i64) * SplitterUnitCost();
  BomLine("splitter_1_32", total_splitters as i64, "ea",
          SplitterUnitCost(), split_cost);
  total += split_cost;

  let term_cost: i64 = (d.term_count as i64) * TerminalUnitCost();
  BomLine("terminal_12p", d.term_count as i64, "ea",
          TerminalUnitCost(), term_cost);
  total += term_cost;

  let olt_cost: i64 = (total_splitters as i64) * OltPortCost();
  BomLine("olt_pon_port", total_splitters as i64, "ea",
          OltPortCost(), olt_cost);
  total += olt_cost;

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
