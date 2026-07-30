// netwerk_export — same deterministic pipeline as netwerk, but instead of
// the human report it emits the machine-readable geometry dump for GIS
// export (see PrintGeometry in outputs.carbon):
//
//   ./build/netwerk_export < district.txt > district.geom.txt
//   python3 tools/design2geojson.py ...   # -> per-layer GeoJSON

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
  if (ValidateConnectivity(ref d) > 0) {
    Core.PrintStr("ingest error: road graph not connected\n");
    return 2;
  }

  SnapPremises(ref d);
  Cluster(ref d);
  RebalanceClusters(ref d);
  PlaceFdh(ref d);
  RouteDistribution(ref d);
  MergeTerminals(ref d);
  ProvisionSplitters(ref d);
  SelectCo(ref d);
  RouteFeeder(ref d);
  DeloopTrench(ref d);

  PrintGeometry(ref d);
  return 0;
}
