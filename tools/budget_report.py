#!/usr/bin/env python3
"""Explain a route_length_budget failure.

QA reports one number -- how many premises exceed the CO-to-ONT budget --
which says nothing about which leg is at fault. This joins the interchange
graph with a `netwerk_export` geometry dump and splits every over-budget
premises into its three legs (feeder, distribution tree path, drop), then
compares each terminal's tree path against the shortest path from its FDH.
The gap between those two is the cost of minimizing total trench: a Steiner
tree can walk a terminal a long way around to save a few metres of duct.

    ./build/netwerk_export < data/city.txt > /tmp/city.geom.txt
    python3 tools/budget_report.py --interchange data/city.txt \
        --geom /tmp/city.geom.txt [--budget 20000]
"""
import argparse
import heapq
import sys
from math import isqrt


def pct(sorted_vals, q):
    if not sorted_vals:
        return 0
    i = (len(sorted_vals) - 1) * q // 100
    return sorted_vals[i]


def summarize(name, vals, out=sys.stdout):
    v = sorted(vals)
    if not v:
        print("  %-22s n=0" % name, file=out)
        return
    print("  %-22s n=%-7d min=%-7d p50=%-7d p90=%-7d p99=%-7d max=%d"
          % (name, len(v), v[0], pct(v, 50), pct(v, 90), pct(v, 99), v[-1]),
          file=out)


def read_interchange(path):
    """Return adjacency with the engine's integer edge lengths.

    The file carries no length column -- the engine derives it as the
    truncated integer hypotenuse of the endpoint metres, so mirror that
    exactly or the comparison drifts against the design it is explaining.
    """
    toks = open(path).read().split()
    it = iter(toks)
    assert next(it) == "NETWERK" and next(it) == "1"
    assert next(it) == "NODES"
    n = int(next(it))
    xs = [0] * n
    ys = [0] * n
    for _ in range(n):
        i = int(next(it))
        xs[i] = int(next(it))
        ys[i] = int(next(it))
    assert next(it) == "EDGES"
    m = int(next(it))
    adj = [[] for _ in range(n)]
    for _ in range(m):
        next(it)                       # edge id
        a, b = int(next(it)), int(next(it))
        next(it)                       # surface
        dx, dy = xs[a] - xs[b], ys[a] - ys[b]
        length = isqrt(dx * dx + dy * dy)
        adj[a].append((b, length))
        adj[b].append((a, length))
    return adj, m


def read_geom(path):
    fdh = {}        # cluster -> (node, feeder_len)
    term = {}       # terminal -> (node, cluster, path_len)
    prem = []       # (cluster, terminal, drop_len)
    for line in open(path):
        f = line.split()
        if not f or f[0] != "G":
            continue
        if f[1] == "fdh":
            fdh[int(f[2])] = (int(f[3]), int(f[8]))
        elif f[1] == "term":
            term[int(f[2])] = (int(f[3]), int(f[4]), int(f[7]))
        elif f[1] == "prem":
            prem.append((int(f[3]), int(f[4]), int(f[5])))
    return fdh, term, prem


def dijkstra(adj, src, targets):
    """Shortest path from src to every node in `targets`. Early-exits."""
    want = set(targets)
    dist = {src: 0}
    got = {}
    pq = [(0, src)]
    while pq and len(got) < len(want):
        dv, v = heapq.heappop(pq)
        if dv > dist.get(v, 1 << 62):
            continue
        if v in want:
            got[v] = dv
        for u, w in adj[v]:
            nd = dv + w
            if nd < dist.get(u, 1 << 62):
                dist[u] = nd
                heapq.heappush(pq, (nd, u))
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interchange", required=True)
    ap.add_argument("--geom", required=True)
    ap.add_argument("--budget", type=int, default=20000)
    ap.add_argument("--detour-areas", type=int, default=12,
                    help="areas to shortest-path check (0 skips the check)")
    args = ap.parse_args()

    fdh, term, prem = read_geom(args.geom)
    budget = args.budget

    print("legs, all premises (metres):")
    feeder_of = {c: v[1] for c, v in fdh.items()}
    tp = {t: v[2] for t, v in term.items()}
    over = []
    legs_f, legs_d, legs_p, totals = [], [], [], []
    for c, t, drop in prem:
        if t < 0 or c < 0:
            continue
        f = feeder_of.get(c, 0)
        dpath = tp.get(t, 0)
        total = f + dpath + drop
        legs_f.append(f)
        legs_d.append(dpath)
        legs_p.append(drop)
        totals.append(total)
        if total > budget:
            over.append((c, t, f, dpath, drop, total))
    summarize("feeder", legs_f)
    summarize("distribution", legs_d)
    summarize("drop", legs_p)
    summarize("total", totals)

    print("\nover budget: %d of %d premises (%.1f%%)"
          % (len(over), len(totals), 100.0 * len(over) / max(1, len(totals))))
    if over:
        summarize("  feeder", [o[2] for o in over])
        summarize("  distribution", [o[3] for o in over])
        summarize("  drop", [o[4] for o in over])
        # Which single leg, on its own, already blows the budget?
        f_alone = sum(1 for o in over if o[2] > budget)
        d_alone = sum(1 for o in over if o[3] > budget)
        both = sum(1 for o in over if o[2] <= budget and o[3] <= budget)
        print("  feeder alone over budget:       %d" % f_alone)
        print("  distribution alone over budget: %d" % d_alone)
        print("  neither leg alone, sum is:      %d" % both)
        # Share of the excess attributable to each leg.
        exc_f = sum(o[2] for o in over)
        exc_d = sum(o[3] for o in over)
        exc_p = sum(o[4] for o in over)
        tot = max(1, exc_f + exc_d + exc_p)
        print("  route metres by leg: feeder %.0f%%  distribution %.0f%%  "
              "drop %.0f%%" % (100.0 * exc_f / tot, 100.0 * exc_d / tot,
                               100.0 * exc_p / tot))

    areas_over = sorted({o[0] for o in over})
    print("\nserving areas containing an over-budget premises: %d of %d"
          % (len(areas_over), len(fdh)))
    summarize("feeder of those areas", [feeder_of[c] for c in areas_over])

    if args.detour_areas <= 0:
        return
    # Tree path vs shortest path, on the areas with the worst tails. The
    # distribution tree is built to minimize total trench, so a terminal can
    # sit far down a branch that doubles back; this measures how far.
    adj, _ = read_interchange(args.interchange)
    worst = sorted(areas_over,
                   key=lambda c: -max((tp[t] for t, v in term.items()
                                       if v[1] == c), default=0))
    worst = worst[:args.detour_areas]
    print("\ntree path vs shortest path, %d worst areas:" % len(worst))
    by_area = {}
    for t, (node, c, plen) in term.items():
        by_area.setdefault(c, []).append((t, node, plen))
    ratios, gaps = [], []
    for c in worst:
        src = fdh[c][0]
        ts = by_area.get(c, [])
        sp = dijkstra(adj, src, [n for _, n, _ in ts])
        for _, node, plen in ts:
            s = sp.get(node)
            if s is None or s == 0:
                continue
            ratios.append(plen * 100 // s)
            gaps.append(plen - s)
    summarize("tree/shortest x100", ratios)
    summarize("tree - shortest (m)", gaps)


if __name__ == "__main__":
    main()
