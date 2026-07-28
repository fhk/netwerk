#!/usr/bin/env bash
# Golden-file regression tests: each design must pass QA (exit 0) and its
# report must be byte-identical to the committed golden output.
# Re-bless deliberately after a reviewed change:  ./test.sh --bless
set -euo pipefail
cd "$(dirname "$0")"

bless="${1:-}"
fail=0

check() { # name, golden, output
  if [ "$bless" = "--bless" ]; then
    cp "$3" "$2"
    echo "golden re-blessed: $2"
  elif ! diff -u "$2" "$3"; then
    fail=1
  else
    echo "golden test ($1): PASS (QA passed, output byte-identical)"
  fi
}

out30="$(mktemp)"; outp="$(mktemp)"
trap 'rm -f "$out30" "$outp"' EXIT
mkdir -p tests

./build/gen_fixture | ./build/netwerk > "$out30"
check "synthetic 30x30" tests/golden_report.txt "$out30"

if [ -f data/parcels_district.txt ]; then
  ./build/netwerk < data/parcels_district.txt > "$outp"
  check "parcel district" tests/golden_parcels_report.txt "$outp"
fi

exit $fail
