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
import library "pipeline";

// The Design is ~300 MB at full-city caps — file scope (BSS), not stack.
var d: Design;

fn Run() -> i32 {
  InitDesign(ref d);

  if (not Ingest(ref d)) {
    return 2;
  }
  BuildGraph(ref d);
  if (ValidateConnectivity(ref d) > 0) {
    Core.PrintStr("ingest error: road graph not connected\n");
    return 2;
  }

  RunDesign(ref d);

  PrintGeometry(ref d);
  return 0;
}
