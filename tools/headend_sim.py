#!/usr/bin/env python3
"""How many head-ends would the reach constraint actually buy?

Replays SelectCo's farthest-first siting against a finished design without
re-running the hour-long pipeline. Clustering is fixed before siting, so the
per-area tails in a geometry dump are exactly the ones the engine would see;
only the feeder lengths change, and shortest-path feeder is a lower bound on
what the sharing-aware router produces. Use it to decide whether a change to
head-end siting is worth a full run, and what it would cost.

    ./build/netwerk_export < data/city.txt > /tmp/city.geom.txt
    python3 tools/headend_sim.py --interchange data/city.txt \
        --geom /tmp/city.geom.txt
"""
import argparse
import heapq
import sys
from math import isqrt


def read_graph(path):
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
        next(it)
        a, b = int(next(it)), int(next(it))
        next(it)
        dx, dy = xs[a] - xs[b], ys[a] - ys[b]
        w = isqrt(dx * dx + dy * dy)
        adj[a].append((b, w))
        adj[b].append((a, w))
    return adj


def read_geom(path):
    fdh, term, prem = {}, {}, []
    for line in open(path):
        f = line.split()
        if not f or f[0] != "G":
            continue
        if f[1] == "fdh":
            fdh[int(f[2])] = (int(f[3]), int(f[5]))       # node, splitters
        elif f[1] == "term":
            term[int(f[2])] = (int(f[4]), int(f[7]))     # cluster, path_len
        elif f[1] == "prem":
            prem.append((int(f[3]), int(f[4]), int(f[5]))) # cl, term, drop
    return fdh, term, prem


def multi_source(adj, sources):
    dist = [1 << 62] * len(adj)
    pq = []
    for s in sources:
        dist[s] = 0
        pq.append((0, s))
    heapq.heapify(pq)
    while pq:
        dv, v = heapq.heappop(pq)
        if dv > dist[v]:
            continue
        for u, w in adj[v]:
            nd = dv + w
            if nd < dist[u]:
                dist[u] = nd
                heapq.heappush(pq, (nd, u))
    return dist


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interchange", required=True)
    ap.add_argument("--geom", required=True)
    ap.add_argument("--budget", type=int, default=20000)
    ap.add_argument("--site-cost", type=int, default=120000)
    ap.add_argument("--max-sites", type=int, default=512)
    args = ap.parse_args()

    fdh_raw, term, prem = read_geom(args.geom)
    fdh = {c: v[0] for c, v in fdh_raw.items()}
    weight = {c: v[1] for c, v in fdh_raw.items()}
    adj = read_graph(args.interchange)
    budget = args.budget

    # Worst distribution+drop tail per area -- the part siting cannot touch.
    tail = {c: 0 for c in fdh}
    for c, t, drop in prem:
        if c < 0 or t < 0:
            continue
        v = term[t][1] + drop
        if v > tail[c]:
            tail[c] = v
    unfixable = [c for c in fdh if tail[c] > budget]
    slack = {c: max(0, budget - tail[c]) for c in fdh}

    print("serving areas: %d" % len(fdh))
    print("areas whose tail alone exceeds the budget: %d (siting cannot help "
          "these -- only re-clustering can)" % len(unfixable))

    # Seed at the splitter-weighted 1-median of the FDH set, as the engine
    # does, then farthest-first on violation.
    best_score, best_node = None, None
    for c in sorted(fdh):
        dist = multi_source(adj, [fdh[c]])
        s = sum(dist[fdh[k]] * weight[k] for k in fdh)
        if best_score is None or s < best_score:
            best_score, best_node = s, fdh[c]
    sites = [best_node]

    opened = []
    while len(sites) < args.max_sites:
        dist = multi_source(adj, sites)
        worst, worst_over = None, 0
        for c in sorted(fdh):
            over = dist[fdh[c]] - slack[c]
            if over > worst_over:
                worst_over, worst = over, c
        if worst is None:
            break
        if fdh[worst] in sites:
            break
        sites.append(fdh[worst])
        opened.append((len(sites), worst, worst_over))
        if len(sites) % 10 == 0:
            print("  %3d sites, worst violation %d m" % (len(sites),
                                                         worst_over),
                  file=sys.stderr)

    dist = multi_source(adj, sites)
    over_areas = [c for c in fdh if dist[fdh[c]] > slack[c]]
    over_prem = 0
    for c, t, drop in prem:
        if c < 0 or t < 0:
            continue
        if dist[fdh[c]] + term[t][1] + drop > budget:
            over_prem += 1

    print("\nhead-ends the reach constraint requires: %d" % len(sites))
    print("residual areas over budget: %d (all of them tail-limited: %s)"
          % (len(over_areas), set(over_areas) <= set(unfixable)))
    print("residual premises over budget: %d of %d" % (over_prem, len(prem)))
    print("site capital added: $%s" % format(
        (len(sites) - 1) * args.site_cost, ","))
    print("\nnote: feeder here is shortest path, a lower bound on the "
          "sharing-aware router -- the real count is this or higher.")


if __name__ == "__main__":
    main()
