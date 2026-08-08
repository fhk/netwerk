#!/usr/bin/env python3
"""Audit canal-crossing spacing in a converted interchange graph.

The brief was a crossing to the opposite bank every 50 ft. The converter
resamples each bank at that pitch and then adds a crossing wherever the
along-bank detour to the facing node is far longer than the straight hop,
which is a proxy, not a guarantee. This measures what actually landed: for
every bank node, the distance along the bank to the nearest node that has a
crossing edge.

    python3 tools/check_crossings.py --interchange data/city.txt
"""
import argparse
from math import isqrt


def read(path):
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
    edges = []
    for _ in range(m):
        next(it)
        a, b = int(next(it)), int(next(it))
        s = int(next(it))
        edges.append((a, b, s))
    return xs, ys, edges


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interchange", required=True)
    ap.add_argument("--pitch", type=float, default=15.24, help="metres (50 ft)")
    args = ap.parse_args()

    xs, ys, edges = read(args.interchange)
    n = len(xs)

    def length(a, b):
        dx, dy = xs[a] - xs[b], ys[a] - ys[b]
        return isqrt(dx * dx + dy * dy)

    # Bank edges are surface 0 and about one pitch long; crossings are the
    # tagged asphalt edges the converter added.
    bank = [[] for _ in range(n)]
    crossing_deg = [0] * n
    n_bank = n_cross = 0
    cross_len = []
    for a, b, s in edges:
        if s == 0:
            bank[a].append(b)
            bank[b].append(a)
            n_bank += 1
        else:
            crossing_deg[a] += 1
            crossing_deg[b] += 1
            cross_len.append(length(a, b))
            n_cross += 1

    print("edges: %d bank, %d crossing/land" % (n_bank, n_cross))
    if cross_len:
        cl = sorted(cross_len)
        print("crossing length m: min=%d p50=%d p90=%d max=%d"
              % (cl[0], cl[len(cl) // 2], cl[len(cl) * 9 // 10], cl[-1]))
    have = sum(1 for v in range(n) if crossing_deg[v] > 0)
    print("nodes with a crossing: %d of %d (%.1f%%)"
          % (have, n, 100.0 * have / n))

    # Walk each bank component and record the gap, in metres of bank, between
    # consecutive nodes that carry a crossing.
    seen = [False] * n
    gaps = []
    worst = 0
    for start in range(n):
        if seen[start] or not bank[start]:
            continue
        # BFS the bank component, tracking distance to the last crossing node
        # along the walk. Banks are paths and rings, so a walk is faithful.
        stack = [(start, 0.0)]
        seen[start] = True
        while stack:
            v, since = stack.pop()
            since = 0.0 if crossing_deg[v] > 0 else since
            if crossing_deg[v] > 0:
                gaps.append(0.0)
            for u in bank[v]:
                if not seen[u]:
                    seen[u] = True
                    d = since + length(v, u)
                    if crossing_deg[u] == 0:
                        worst = max(worst, d)
                        gaps.append(d)
                    stack.append((u, d))

    g = sorted(gaps)
    if g:
        print("bank metres to the nearest crossing: p50=%.0f p90=%.0f "
              "p99=%.0f max=%.0f" % (g[len(g) // 2], g[len(g) * 9 // 10],
                                     g[len(g) * 99 // 100], g[-1]))
        within = sum(1 for v in g if v <= args.pitch)
        print("nodes within one %.2f m pitch of a crossing: %.1f%%"
              % (args.pitch, 100.0 * within / len(g)))


if __name__ == "__main__":
    main()
