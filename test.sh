#!/usr/bin/env bash
# Golden-file regression test: the design must pass QA (exit 0) and the
# report must be byte-identical to the committed golden output.
# Re-bless deliberately after a reviewed change:  ./test.sh --bless
set -euo pipefail
cd "$(dirname "$0")"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

./build/gen_fixture | ./build/netwerk > "$out"

if [ "${1:-}" = "--bless" ]; then
  mkdir -p tests
  cp "$out" tests/golden_report.txt
  echo "golden re-blessed: tests/golden_report.txt"
  exit 0
fi

diff -u tests/golden_report.txt "$out"
echo "golden test: PASS (QA passed, output byte-identical)"
