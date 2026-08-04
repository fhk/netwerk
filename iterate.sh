#!/usr/bin/env bash
# One design-improvement iteration: rebuild, golden gate, game rooms,
# score every fixture, summarize, append to the ledger, commit, push.
#
#   bash iterate.sh <N> "<title>"
#
# BLESS=1 bash iterate.sh <N> "<title>"  re-blesses the goldens — use ONLY
# when a deliberate output change occurred and QA still passes.
set -euo pipefail
cd "$(dirname "$0")"

N="${1:?usage: iterate.sh <N> \"<title>\"}"
TITLE="${2:?usage: iterate.sh <N> \"<title>\"}"
NNN=$(printf '%03d' "$((10#$N))")   # 10# so "010" is ten, not octal eight

# Toolchain: explicit CARBON env wins; else the session scratchpad copy;
# else build.sh's default (toolchain unpacked next to the repo).
SCRATCH_CARBON="/tmp/claude-0/-home-user-netwerk/c96678cd-ce3d-5748-99b6-67ac7c297bd3/scratchpad/carbon_toolchain-0.0.0-0.nightly.2026.07.27/bin/carbon"
if [ -z "${CARBON:-}" ] && [ -x "$SCRATCH_CARBON" ]; then
  export CARBON="$SCRATCH_CARBON"
fi

./build.sh

# --- golden gate ---------------------------------------------------------
golden_status=PASS
if [ "${BLESS:-0}" = "1" ]; then
  ./test.sh --bless
  golden_status=BLESSED
elif ! ./test.sh; then
  golden_status=FAIL
fi

outdir="results/iter_${NNN}"
mkdir -p "$outdir"
echo "golden: $golden_status" > "$outdir/golden.txt"

# --- game rooms ----------------------------------------------------------
squidgame tests/scenarios 2>&1 | tee "$outdir/squidgame.txt" || true

# --- score every fixture -------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

score_one() { # name, interchange
  local name="$1" fixture="$2"
  ./build/netwerk < "$fixture" > "$tmp/$name.report.txt" || true
  ./build/netwerk_export < "$fixture" > "$tmp/$name.geom.txt"
  python3 tools/score_design.py \
    --interchange "$fixture" \
    --geom "$tmp/$name.geom.txt" \
    --report "$tmp/$name.report.txt" \
    --json "$outdir/$name.json" | sed "s/^/  $name /"
}

for s in scenarios/*.txt; do
  name="$(basename "$s" .txt)"
  score_one "$name" "$s"
done
score_one "parcels" "data/parcels_district.txt"

# --- summarize + ledger --------------------------------------------------
GOLDEN="$golden_status" NNN="$NNN" TITLE="$TITLE" OUTDIR="$outdir" \
python3 - <<'PY'
import glob, json, os

outdir = os.environ["OUTDIR"]
nnn = os.environ["NNN"]
title = os.environ["TITLE"]
golden = os.environ["GOLDEN"]

rows = []
for path in sorted(glob.glob(os.path.join(outdir, "*.json"))):
    name = os.path.basename(path)[:-5]
    rows.append((name, json.load(open(path))))

def tot(key):
    return sum(m[key] for _, m in rows)

total = tot("score")

# delta vs the previous iteration that recorded a total
prev_total = prev_iter = None
for d in sorted(glob.glob("results/iter_*")):
    if d == outdir or not os.path.isdir(d):
        continue
    tpath = os.path.join(d, "total.txt")
    if os.path.exists(tpath):
        prev_total = int(open(tpath).read().strip())
        prev_iter = os.path.basename(d)

with open(os.path.join(outdir, "total.txt"), "w") as f:
    f.write("%d\n" % total)

cols = ["score", "capex_cents", "qa_errors", "drop_street_crossings",
        "drop_drop_crossings", "terminals_under_4", "terminals_over_12",
        "rings", "terminal_count", "drop_mean_m", "drop_max_m"]
with open(os.path.join(outdir, "summary.md"), "w") as f:
    f.write("# Iteration %s — %s\n\n" % (nnn, title))
    f.write("golden: %s\n\n" % golden)
    f.write("| fixture | " + " | ".join(cols) + " |\n")
    f.write("|---" * (len(cols) + 1) + "|\n")
    for name, m in rows:
        f.write("| %s | " % name +
                " | ".join(str(m[c]) for c in cols) + " |\n")
    f.write("| **total** | " +
            " | ".join(str(tot(c)) for c in cols[:-2]) + " | | |\n\n")
    f.write("**Composite total: %d**" % total)
    if prev_total is not None:
        delta = total - prev_total
        f.write(" (delta vs %s: %+d)" % (prev_iter, delta))
    f.write("\n")

ledger = "results/LEDGER.md"
if not os.path.exists(ledger):
    with open(ledger, "w") as f:
        f.write("# Improvement ledger\n\n")
        f.write("Composite score (lower is better) summed over all "
                "scenarios and the parcel district.\n\n")
        f.write("| iter | title | total_score | capex | street-x | "
                "drop-x | term-viol | rings | qa |\n")
        f.write("|---|---|---|---|---|---|---|---|---|\n")
with open(ledger, "a") as f:
    f.write("| %s | %s | %d | %d | %d | %d | %d | %d | %d |\n" % (
        nnn, title, total, tot("capex_cents"),
        tot("drop_street_crossings"), tot("drop_drop_crossings"),
        tot("terminals_under_4") + tot("terminals_over_12"),
        tot("rings"), tot("qa_errors")))

print("iteration %s total composite score: %d" % (nnn, total))
if prev_total is not None:
    print("delta vs %s: %+d" % (prev_iter, total - prev_total))
PY

# --- commit + push -------------------------------------------------------
git add -A
git commit -m "iter ${NNN}: ${TITLE}

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011nHZzSsTzA6i3pVB6G7qGq"
git push origin claude/fttx-network-design-system-ghloxm
echo "iterate: done (iter ${NNN}: ${TITLE}, golden ${golden_status})"
