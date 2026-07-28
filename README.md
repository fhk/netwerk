# netwerk

Automated FTTX outside-plant network design, written in
[Carbon](https://github.com/carbon-language/carbon-lang).

Given premises, a road network, an equipment catalog, and design rules,
netwerk produces a complete draft design — serving areas, FDH (cabinet) and
terminal placement, distribution and feeder routing with trench sharing,
splitter provisioning, cable sizing — plus a bill of materials, a capex
estimate, and a QA verdict wired to the exit code.

**[SCOPE.md](SCOPE.md) is the project's design document**: the FTTX domain
background, goals and non-goals, data model, algorithms, architecture, and
roadmap. This repository ships its M0 vertical slice: the full pipeline
running end to end on a deterministic synthetic town.

## Quick start

Requires the pinned Carbon nightly toolchain (prebuilt, Linux x86_64/macOS):

```sh
curl -L -O https://github.com/carbon-language/carbon-lang/releases/download/v0.0.0-0.nightly.2026.07.27/carbon_toolchain-0.0.0-0.nightly.2026.07.27.tar.gz
tar xzf carbon_toolchain-0.0.0-0.nightly.2026.07.27.tar.gz
./build.sh
./build/gen_fixture | ./build/netwerk
```

`gen_fixture` prints a seeded synthetic town (~430 premises, grid streets,
a few MDUs) in the `NETWERK 1` text interchange format; `netwerk` ingests it,
runs every design stage, and prints the design, BOM, cost rollup, and QA
report. Output is byte-identical on every run and platform — the engine is
pure integer arithmetic (meters and cents).

```
cost:
  total_capex=$679433.50
  per_unit_passed=$1489.98
  trench_m=10890 cable_route_m=11770 sharing_x100=108
qa verdict: PASS
```

## Testing

```sh
./test.sh          # QA gate + byte-exact golden diff against tests/golden_report.txt
./test.sh --bless  # deliberately re-bless the golden after a reviewed change
```

CI (GitHub Actions) downloads the pinned toolchain, builds, and runs the same
gate on every push.

## Why Carbon?

The algorithm core needs only arrays, integers, and control flow — which the
Carbon toolchain already compiles fast — and Carbon's C++ interop is the
designed route to GDAL/PROJ/HiGHS for GeoPackage I/O, real CRS handling, and
MILP refinement later, without a rewrite. The full rationale, constraints,
and milestone plan are in [SCOPE.md](SCOPE.md#system-architecture).

## License

Apache-2.0.
