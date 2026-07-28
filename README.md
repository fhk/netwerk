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

`gen_fixture` prints a seeded synthetic town at 10k-household scale (9,190
premises, 9,919 households, grid streets, an MDU district) in the `NETWERK 1`
text interchange format; `netwerk` ingests it, runs every design stage, and
prints the design, BOM, cost rollup, and QA report — in about half a second.
Output is byte-identical on every run and platform — the engine is pure
integer arithmetic (meters and cents).

The design minimizes installed equipment against a 95% utilization floor,
enforced as QA errors: graduated catalog sizes (splitters 1:4–1:32,
terminals 4/8/12 ports, FDH cabinets 144–432, OLT cards 8/16 ports) let
every remainder round into the smallest covering unit, and terminals are
batch-packed along the distribution tree.

```
utilization:
  terminal_ports: 9190/9548 = 96.2%
  splitter_ports: 6452/6608 = 97.6%
  fdh_capacity: 9919/9936 = 99.8%
  olt_card_ports: 207/208 = 99.5%
cost:
  total_capex=$9662979.50
  per_unit_passed=$974.18
  trench_m=130700 cable_route_m=148000 sharing_x100=113
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
