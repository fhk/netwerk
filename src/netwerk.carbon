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
import library "pipeline";

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

  RunDesign(ref d);          // two sweeps, trench-priced; better one ships

  var total: i64 = Report(ref d);
  if (total <= 0) {
    return 2;
  }
  PrintSweeps(ref d);
  let qa_errors: i32 = RunQa(ref d);
  if (qa_errors > 0) {
    return 1;
  }
  return 0;
}
