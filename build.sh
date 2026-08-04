#!/usr/bin/env bash
# Builds the netwerk binaries with the pinned Carbon nightly toolchain.
#
# Set CARBON to the toolchain driver, or place the unpacked toolchain next to
# the repo. Download (Linux x86_64 / macOS):
#   https://github.com/carbon-language/carbon-lang/releases/tag/v0.0.0-0.nightly.2026.07.27
set -euo pipefail
cd "$(dirname "$0")"

TOOLCHAIN_VERSION="0.0.0-0.nightly.2026.07.27"
CARBON="${CARBON:-./carbon_toolchain-${TOOLCHAIN_VERSION}/bin/carbon}"

if ! command -v "$CARBON" >/dev/null 2>&1 && [ ! -x "$CARBON" ]; then
  echo "error: carbon toolchain not found at '$CARBON'." >&2
  echo "Set CARBON=/path/to/carbon or unpack the pinned nightly here:" >&2
  echo "  curl -L -O https://github.com/carbon-language/carbon-lang/releases/download/v${TOOLCHAIN_VERSION}/carbon_toolchain-${TOOLCHAIN_VERSION}.tar.gz" >&2
  echo "  tar xzf carbon_toolchain-${TOOLCHAIN_VERSION}.tar.gz" >&2
  exit 1
fi

mkdir -p build
"$CARBON" build --output=build/gen_fixture \
  src/io_utils.carbon src/model.carbon src/gen_fixture.carbon
"$CARBON" build --output=build/netwerk \
  src/io_utils.carbon src/model.carbon src/graph.carbon \
  src/stages.carbon src/outputs.carbon src/pipeline.carbon src/netwerk.carbon
"$CARBON" build --output=build/netwerk_export \
  src/io_utils.carbon src/model.carbon src/graph.carbon \
  src/stages.carbon src/outputs.carbon src/pipeline.carbon \
  src/netwerk_export.carbon
echo "built: build/gen_fixture build/netwerk build/netwerk_export"
echo "run:   ./build/gen_fixture | ./build/netwerk"
