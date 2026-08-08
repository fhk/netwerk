#!/usr/bin/env python3
"""Cape Coral canal network -> netwerk interchange format.

The canal POLYGONS are the routing surface: each polygon's outer ring is a
closed path along the canal bank, and that is where fiber gets installed.
Every 50 ft along a bank there is an opportunity to CROSS to the opposite
side of the same canal. Address points are the customer premises.

    python3 tools/canals2netwerk.py \
        --canals data/canals.geojson \
        --addresses data/capecoral_addresses.geojson \
        --out data/capecoral_canals.txt

Modelling choices, stated explicitly:
  * bank edges  -> surface 0 (soft ground, $45/m): the canal-side easement
  * crossings   -> surface 1 (hard, $150/m): boring or bridging a canal is
    real civil work, and pricing it above the bank makes the design choose
    crossings deliberately rather than treating water as free to hop
  * land bridges-> surface 0: the dry land between canals carries streets

Output is deterministic (stable ordering, integer metres) and is
self-validated by re-reading the emitted file.
"""
import argparse
import json
import math
import os
import sys
import time

FT = 0.3048
DEG_X_M = 111320.0
DEG_Y_M = 110540.0


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def outer_rings(geom):
    if not geom:
        return []
    t = geom.get("type")
    if t == "Polygon":
        return [geom["coordinates"][0]] if geom["coordinates"] else []
    if t == "MultiPolygon":
        return [p[0] for p in geom["coordinates"] if p]
    return []


def resample_ring(pts, spacing):
    """Samples a closed ring at fixed arc-length spacing.

    Returns (samples, arc) where arc[i] is the along-ring distance of
    samples[i] from the ring start. The ring is closed, so the walk wraps.
    """
    ring = list(pts)
    if ring[0] != ring[-1]:
        ring.append(ring[0])
    total = 0.0
    seglen = []
    for i in range(len(ring) - 1):
        d = math.dist(ring[i], ring[i + 1])
        seglen.append(d)
        total += d
    if total < spacing:
        return [], [], total
    out, arc = [], []
    target = 0.0
    i, acc = 0, 0.0
    while target < total and i < len(seglen):
        while i < len(seglen) and acc + seglen[i] < target:
            acc += seglen[i]
            i += 1
        if i >= len(seglen):
            break
        if seglen[i] <= 0:
            i += 1
            continue
        t = (target - acc) / seglen[i]
        x = ring[i][0] + t * (ring[i + 1][0] - ring[i][0])
        y = ring[i][1] + t * (ring[i + 1][1] - ring[i][1])
        out.append((x, y))
        arc.append(target)
        target += spacing
    return out, arc, total


def grid_build(points, cell):
    g = {}
    for idx, (x, y) in enumerate(points):
        g.setdefault((int(x // cell), int(y // cell)), []).append(idx)
    return g


def grid_near(g, cell, x, y, radius):
    r = int(radius // cell) + 1
    cx, cy = int(x // cell), int(y // cell)
    for dx in range(-r, r + 1):
        for dy in range(-r, r + 1):
            for i in g.get((cx + dx, cy + dy), ()):
                yield i


class DSU:
    def __init__(self, n):
        self.p = list(range(n))

    def find(self, a):
        while self.p[a] != a:
            self.p[a] = self.p[self.p[a]]
            a = self.p[a]
        return a

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra == rb:
            return False
        if ra > rb:
            ra, rb = rb, ra
        self.p[rb] = ra
        return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--canals", default="data/canals.geojson")
    ap.add_argument("--addresses", default="data/capecoral_addresses.geojson")
    ap.add_argument("--out", default="data/capecoral_canals.txt")
    ap.add_argument("--spacing-ft", type=float, default=50.0,
                    help="bank resample / crossing interval (feet)")
    ap.add_argument("--max-cross", type=float, default=120.0,
                    help="max canal width to cross (metres)")
    ap.add_argument("--max-drop", type=float, default=150.0,
                    help="engine max drop length (metres)")
    ap.add_argument("--land-link", type=float, default=200.0,
                    help="join banks of DIFFERENT canals within this many "
                         "metres — the streets on the land between them")
    ap.add_argument("--max-land-links", type=int, default=60000)
    ap.add_argument("--max-nodes", type=int, default=98304)
    ap.add_argument("--max-edges", type=int, default=262144)
    ap.add_argument("--max-premises", type=int, default=196608)
    args = ap.parse_args()

    t0 = time.time()
    spacing = args.spacing_ft * FT

    # ---- load canals, choose the projection anchor -----------------------
    canals = json.load(open(args.canals))
    xs, ys = [], []
    for f in canals["features"]:
        for r in outer_rings(f.get("geometry")):
            for c in r:
                xs.append(c[0])
                ys.append(c[1])
    lon0 = (min(xs) + max(xs)) / 2.0
    lat0 = (min(ys) + max(ys)) / 2.0
    kx = DEG_X_M * math.cos(math.radians(lat0))
    ky = DEG_Y_M
    log("anchor lon0=%.6f lat0=%.6f  kx=%.3f ky=%.3f" % (lon0, lat0, kx, ky))

    def proj(c):
        return ((c[0] - lon0) * kx, (c[1] - lat0) * ky)

    # ---- nodes: dedupe on integer metres ---------------------------------
    node_key = {}
    node_xy = []
    ring_of = []

    def node_id(x, y):
        k = (int(round(x)), int(round(y)))
        i = node_key.get(k)
        if i is None:
            i = len(node_xy)
            node_key[k] = i
            node_xy.append(k)
            ring_of.append(cur_ring[0])
        return i

    cur_ring = [-1]     # ring index currently being emitted
    edges = {}          # (a,b) a<b -> surface (0 keeps priority over 1)

    def add_edge(a, b, surface):
        if a == b:
            return False
        k = (a, b) if a < b else (b, a)
        prev = edges.get(k)
        if prev is None:
            edges[k] = surface
            return True
        if surface < prev:      # soft ground wins over a hard crossing
            edges[k] = surface
        return False

    # ---- 1-3: resample rings, bank edges, 50 ft crossings ----------------
    n_rings = 0
    bank_edges = 0
    cross_pairs = set()
    cross_lens = []
    for f in canals["features"]:
        for ring in outer_rings(f.get("geometry")):
            pts = [proj(c) for c in ring]
            if len(pts) < 3:
                continue
            samples, arc, total = resample_ring(pts, spacing)
            if len(samples) < 2:
                continue
            cur_ring[0] = n_rings
            n_rings += 1
            ids = [node_id(x, y) for (x, y) in samples]
            m = len(ids)
            for i in range(m):
                if add_edge(ids[i], ids[(i + 1) % m], 0):
                    bank_edges += 1

            # crossing: nearest sample on the SAME ring that is genuinely
            # across the water — along-ring separation must exceed 3x the
            # straight-line distance, so neighbours and rounded ends never
            # qualify.
            g = grid_build(samples, args.max_cross)
            for i in range(m):
                xi, yi = samples[i]
                best, bestd = -1, args.max_cross + 1.0
                for j in grid_near(g, args.max_cross, xi, yi, args.max_cross):
                    if j == i:
                        continue
                    d = math.dist(samples[i], samples[j])
                    if d >= bestd or d <= 0:
                        continue
                    sep = abs(arc[i] - arc[j])
                    sep = min(sep, total - sep)
                    if sep > 3.0 * d:
                        best, bestd = j, d
                if best >= 0:
                    a, b = ids[i], ids[best]
                    if a != b:
                        k = (a, b) if a < b else (b, a)
                        if k not in cross_pairs:
                            cross_pairs.add(k)
                            cross_lens.append(bestd)
    log("rings=%d  bank nodes=%d  bank edges=%d  crossing pairs=%d  (%.0fs)"
        % (n_rings, len(node_xy), bank_edges, len(cross_pairs), time.time() - t0))

    # budget: if edges overflow, drop the LONGEST crossings first
    crossings = sorted(zip(cross_lens, sorted(cross_pairs)))
    room = args.max_edges - bank_edges
    dropped_cross = 0
    if len(crossings) > room:
        dropped_cross = len(crossings) - room
        crossings = crossings[:room]
        log("edge budget: dropped %d longest crossings" % dropped_cross)
    cross_edges = 0
    for d, (a, b) in crossings:
        if add_edge(a, b, 1):
            cross_edges += 1

    # ---- 5: bridge the disconnected canals across dry land ---------------
    dsu = DSU(len(node_xy))
    for (a, b) in edges:
        dsu.union(a, b)
    comps = {}
    for i in range(len(node_xy)):
        comps.setdefault(dsu.find(i), []).append(i)
    log("components before bridging: %d" % len(comps))

    CELL = 200.0
    grid = {}
    for i, (x, y) in enumerate(node_xy):
        grid.setdefault((int(x // CELL), int(y // CELL)), []).append(i)

    bridges = 0
    bridge_lens = []
    order = sorted(comps.keys(), key=lambda r: (len(comps[r]), r))
    for root in order:
        # the component may already have been merged by an earlier bridge
        while True:
            r = dsu.find(root)
            members = comps.get(root, [])
            best = None
            radius = CELL
            while best is None and radius <= 20000.0:
                for i in members:
                    xi, yi = node_xy[i]
                    for j in grid_near(grid, CELL, xi, yi, radius):
                        if dsu.find(j) == r:
                            continue
                        d = math.dist(node_xy[i], node_xy[j])
                        if d <= radius and (best is None or
                                            (d, i, j) < best):
                            best = (d, i, j)
                radius *= 2.0
            if best is None:
                break
            d, i, j = best
            if dsu.union(i, j):
                add_edge(i, j, 0)
                bridges += 1
                bridge_lens.append(d)
            break
        # after one bridge this component is attached; the global loop
        # continues until a final connectivity check passes
    # repeat until a single component remains
    passes = 0
    while passes < 200:
        roots = {}
        for i in range(len(node_xy)):
            roots.setdefault(dsu.find(i), []).append(i)
        if len(roots) <= 1:
            break
        passes += 1
        # bridge the smallest remaining component to anything else
        rk = sorted(roots.keys(), key=lambda r: (len(roots[r]), r))[0]
        members = roots[rk]
        best = None
        radius = CELL
        while best is None and radius <= 40000.0:
            for i in members:
                xi, yi = node_xy[i]
                for j in grid_near(grid, CELL, xi, yi, radius):
                    if dsu.find(j) == rk:
                        continue
                    d = math.dist(node_xy[i], node_xy[j])
                    if d <= radius and (best is None or (d, i, j) < best):
                        best = (d, i, j)
            radius *= 2.0
        if best is None:
            break
        d, i, j = best
        dsu.union(i, j)
        add_edge(i, j, 0)
        bridges += 1
        bridge_lens.append(d)
    log("bridges added: %d  (max %.0f m)  passes=%d"
        % (bridges, max(bridge_lens) if bridge_lens else 0, passes))

    # Extra land bridges. The spanning set above makes the network
    # connected but nearly a TREE OF CANALS: with no shortcuts, a route
    # between two adjacent canals can detour kilometres, which showed up as
    # a 73.9 km distribution tail in the first city design. The dry land
    # between canals carries streets, so any two banks within
    # --land-link metres of each other are genuinely joinable.
    extra = 0
    if args.land_link > 0:
        LCELL = args.land_link
        lg = {}
        for i, (x, y) in enumerate(node_xy):
            lg.setdefault((int(x // LCELL), int(y // LCELL)), []).append(i)
        cand = []
        for i, (x, y) in enumerate(node_xy):
            for j in grid_near(lg, LCELL, x, y, args.land_link):
                if j <= i:
                    continue
                if ring_of[i] == ring_of[j]:
                    continue          # same canal: that is a crossing, not land
                dd = math.dist(node_xy[i], node_xy[j])
                if dd <= args.land_link:
                    cand.append((int(round(dd)), i, j))
        cand.sort()
        for dd, i, j in cand:
            if extra >= args.max_land_links:
                break
            if len(edges) >= args.max_edges:
                break
            if add_edge(i, j, 0):
                extra += 1
        log("extra land links: %d (of %d candidates within %.0f m)"
            % (extra, len(cand), args.land_link))

    # ---- 6: premises ------------------------------------------------------
    addrs = json.load(open(args.addresses))
    prem = []
    for f in addrs["features"]:
        g = f.get("geometry")
        if not g or g.get("type") != "Point":
            continue
        x, y = proj(g["coordinates"])
        prem.append((int(round(x)), int(round(y))))

    pgrid = {}
    PCELL = args.max_drop
    for i, (x, y) in enumerate(node_xy):
        pgrid.setdefault((int(x // PCELL), int(y // PCELL)), []).append(i)
    kept, far = [], 0
    for (x, y) in prem:
        ok = False
        for j in grid_near(pgrid, PCELL, x, y, args.max_drop):
            if math.dist((x, y), node_xy[j]) <= args.max_drop:
                ok = True
                break
        if ok:
            kept.append((x, y))
        else:
            far += 1
    log("premises: %d kept, %d dropped (> %.0f m from any node)"
        % (len(kept), far, args.max_drop))
    if len(kept) > args.max_premises:
        log("premises budget exceeded: %d > %d" % (len(kept), args.max_premises))
        sys.exit(1)

    # ---- emit -------------------------------------------------------------
    if len(node_xy) > args.max_nodes:
        log("node budget exceeded: %d > %d" % (len(node_xy), args.max_nodes))
        sys.exit(1)
    if len(edges) > args.max_edges:
        log("edge budget exceeded: %d > %d" % (len(edges), args.max_edges))
        sys.exit(1)

    with open(args.out, "w") as fh:
        fh.write("NETWERK 1\n")
        fh.write("NODES %d\n" % len(node_xy))
        for i, (x, y) in enumerate(node_xy):
            fh.write("%d %d %d\n" % (i, x, y))
        ek = sorted(edges.keys())
        fh.write("EDGES %d\n" % len(ek))
        for i, k in enumerate(ek):
            fh.write("%d %d %d %d\n" % (i, k[0], k[1], edges[k]))
        fh.write("PREMISES %d\n" % len(kept))
        for i, (x, y) in enumerate(kept):
            fh.write("%d %d %d 1\n" % (i, x, y))
        fh.write("END\n")

    meta = {"projection": "equirectangular", "lon0": lon0, "lat0": lat0,
            "kx_m_per_deg": kx, "ky_m_per_deg": ky, "crs": "EPSG:4326"}
    with open(args.out + ".meta.json", "w") as mf:
        json.dump(meta, mf, indent=1, sort_keys=True)
        mf.write("\n")

    # ---- self-validate by re-reading -------------------------------------
    toks = open(args.out).read().split()
    it = iter(toks)
    assert next(it) == "NETWERK" and next(it) == "1"
    assert next(it) == "NODES"
    n = int(next(it))
    nx = []
    for i in range(n):
        assert int(next(it)) == i
        nx.append((int(next(it)), int(next(it))))
    assert next(it) == "EDGES"
    m = int(next(it))
    adj = [[] for _ in range(n)]
    seen = set()
    hard = 0
    for i in range(m):
        assert int(next(it)) == i
        a, b, s = int(next(it)), int(next(it)), int(next(it))
        assert a != b, "self loop"
        k = (a, b) if a < b else (b, a)
        assert k not in seen, "duplicate edge"
        seen.add(k)
        adj[a].append(b)
        adj[b].append(a)
        hard += (s == 1)
    assert next(it) == "PREMISES"
    p = int(next(it))
    for i in range(p):
        assert int(next(it)) == i
        int(next(it)), int(next(it)), int(next(it))
    assert next(it) == "END"
    # single connected component
    seenn = [False] * n
    stack = [0]
    seenn[0] = True
    cnt = 1
    while stack:
        v = stack.pop()
        for w in adj[v]:
            if not seenn[w]:
                seenn[w] = True
                cnt += 1
                stack.append(w)
    assert cnt == n, "graph not connected: %d/%d" % (cnt, n)

    sz = os.path.getsize(args.out)
    cl = sorted(cross_lens)
    log("")
    log("=" * 62)
    log("nodes            : %d  (budget %d)" % (n, args.max_nodes))
    log("edges            : %d  (budget %d)" % (m, args.max_edges))
    log("  bank (soft)    : %d" % (m - hard))
    log("  crossings(hard): %d  dropped %d" % (hard, dropped_cross))
    if cl:
        log("  crossing len m : min %.0f  p50 %.0f  p90 %.0f  max %.0f"
            % (cl[0], cl[len(cl)//2], cl[int(len(cl)*0.9)], cl[-1]))
    log("  land bridges   : %d" % bridges)
    log("premises         : %d  (dropped %d)" % (p, far))
    log("connected        : yes (%d/%d)" % (cnt, n))
    log("output           : %s (%d bytes)" % (args.out, sz))
    log("wall time        : %.0fs" % (time.time() - t0))
    log("=" * 62)


if __name__ == "__main__":
    main()
