// netwerk — automated FTTX outside-plant design, end to end.
//
// Reads the interchange fixture format on stdin, runs the SCOPE.md pipeline
// (ingest -> graph -> cluster -> place -> terminals -> route -> provision ->
// feeder -> cost/report -> QA), prints the design and BOM on stdout, and
// exits non-zero if QA fails — usable directly as a CI gate.
//
//   ./gen_fixture | ./netwerk

import Core library "io";

import library "io_utils";
import library "model";
import library "graph";
import library "stages";
import library "outputs";

fn Run() -> i32 {
  var d: Design = Design.Make();

  if (not Ingest(ref d)) {
    return 2;
  }
  BuildGraph(ref d);

  let unreachable: i32 = ValidateConnectivity(ref d);
  if (unreachable > 0) {
    Core.PrintStr("ingest error: road graph not connected; unreachable nodes: ");
    PrintInt(unreachable);
    NL();
    return 2;
  }

  SnapPremises(ref d);
  Cluster(ref d);
  RebalanceClusters(ref d);  // pack serving areas so cabinets run full
  PlaceFdh(ref d);
  RouteDistribution(ref d);  // packs terminals per serving area as it goes
  MergeTerminals(ref d);     // utilization repair: dissolve/shrink terminals
  ProvisionSplitters(ref d);
  SelectCo(ref d);
  RouteFeeder(ref d);
  DeloopTrench(ref d);       // acyclic used trench: re-route cables on the MSF

  var total: i64 = Report(ref d);
  if (total <= 0) {
    return 2;
  }
  let qa_errors: i32 = RunQa(ref d);
  if (qa_errors > 0) {
    return 1;
  }
  return 0;
}
