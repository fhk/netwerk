#!/usr/bin/env python3
"""parcels2netwerk.py — convert a (huge) parcel-polygon GeoJSON into netwerk's
v0 text interchange format (NETWERK 1).

Parcel BOUNDARIES become the permissible fiber routes (surface 0, soft
ground), parcel CENTROIDS become the customer premises, and disconnected
parcel islands are stitched together with surface-1 (asphalt) street-crossing
edges so the road graph is a single connected component.

The input file is never loaded whole: both passes stream it in chunks,
tracking brace depth (string/escape aware) to slice out one top-level feature
at a time and json.loads only that slice.

Stdlib only.  Deterministic: no randomness, all orders and tie-breaks fixed.
"""

import argparse
import json
import math
import os
import re
import sys
import time
from collections import defaultdict, deque

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------

DEG_X_M = 111320.0        # meters per degree longitude at equator (scaled by cos lat0)
DEG_Y_M = 110540.0        # meters per degree latitude
CELL_DEG = 0.02           # AOI selection grid, degrees
MIN_SEG_M = 3             # merge boundary segments shorter than this
DROP_M = 150              # premises must lie within this of some node
BRIDGE_MAX_M = 120        # islands farther than this are dropped, not bridged
CROSS_M = 40              # extra street crossings between original components
CROSS_CAP = 500           # cap on extra crossings
BRIDGE_GRID_M = 64        # grid-hash cell for nearest-pair searches
TOL_LADDER = (0, 1, 2, 4, 8)  # ring simplification tolerances (m), tried in order


def log(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# streaming GeoJSON feature scanner
# ---------------------------------------------------------------------------

_STRUCT = re.compile(rb'[{}"\\]')


def stream_top_objects(path, chunk_size=1 << 24):
    """Yield raw byte slices of each depth-2 JSON object in the file.

    The file is one FeatureCollection object (depth 1); every element of its
    "features" array is an object at depth 2 (the "crs" member is too — the
    caller filters by "type").  Scanning is chunked; only structural
    characters ({ } " \\) are visited, with string/escape tracking so braces
    inside property strings never confuse the depth counter.
    """
    buf = bytearray()
    base = 0            # absolute file offset of buf[0]
    scan = 0            # offset in buf where scanning resumes
    depth = 0
    in_str = False
    esc_abs = -1        # absolute position of an escaped character to skip
    feat_start = -1     # absolute offset of the current depth-2 object start
    with open(path, "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            buf += chunk
            for m in _STRUCT.finditer(buf, scan):
                i = m.start()
                a = base + i
                if a == esc_abs:
                    continue
                c = buf[i]
                if in_str:
                    if c == 0x5C:          # backslash: escape next char
                        esc_abs = a + 1
                    elif c == 0x22:        # closing quote
                        in_str = False
                    continue
                if c == 0x22:              # opening quote
                    in_str = True
                elif c == 0x7B:            # {
                    depth += 1
                    if depth == 2 and feat_start < 0:
                        feat_start = a
                elif c == 0x7D:            # }
                    depth -= 1
                    if depth == 1 and feat_start >= 0:
                        yield bytes(buf[feat_start - base:a + 1 - base])
                        feat_start = -1
            scan = len(buf)
            if feat_start < 0:
                base += len(buf)
                del buf[:]
                scan = 0
            else:
                cut = feat_start - base
                if cut > 0:
                    del buf[:cut]
                    base += cut
                    scan = len(buf)


_FEATURE_PREFIX = b'{"type":"Feature"'


def stream_features(path, want=None):
    """Yield (index, parsed_or_None) for every Feature object, in file order.

    `want` is an optional predicate on the feature index; when it returns
    False the feature is counted but not parsed (parsed_or_None is None).
    Non-Feature depth-2 objects (e.g. "crs") are parsed, identified, and
    skipped without consuming an index — identically in every pass, so
    indices always line up between passes.
    """
    idx = 0
    for raw in stream_top_objects(path):
        if raw.startswith(_FEATURE_PREFIX):
            if want is None or want(idx):
                yield idx, json.loads(raw)
            else:
                yield idx, None
            idx += 1
            continue
        obj = json.loads(raw)
        if isinstance(obj, dict) and obj.get("type") == "Feature":
            if want is None or want(idx):
                yield idx, obj
            else:
                yield idx, None
            idx += 1
        # else: crs or other metadata object — skip, no index consumed


# ---------------------------------------------------------------------------
# geometry helpers
# ---------------------------------------------------------------------------

def outer_rings(geom):
    """Outer ring coordinate lists for Polygon / MultiPolygon; holes skipped."""
    if not isinstance(geom, dict):
        return []
    t = geom.get("type")
    co = geom.get("coordinates")
    if not co:
        return []
    if t == "Polygon":
        return [co[0]] if co[0] else []
    if t == "MultiPolygon":
        return [poly[0] for poly in co if poly and poly[0]]
    return []


def centroid_bbox(rings):
    """Area-weighted shoelace centroid over outer rings + bbox (lon/lat).

    Falls back to the plain vertex mean when total area degenerates.
    Returns (clon, clat, minlon, minlat, maxlon, maxlat) or None.
    """
    a2_sum = 0.0
    cx_sum = 0.0
    cy_sum = 0.0
    sx = sy = 0.0
    nv = 0
    minlon = minlat = math.inf
    maxlon = maxlat = -math.inf
    for ring in rings:
        n = len(ring)
        if n < 3:
            for c in ring:
                x, y = c[0], c[1]
                sx += x
                sy += y
                nv += 1
                if x < minlon: minlon = x
                if x > maxlon: maxlon = x
                if y < minlat: minlat = y
                if y > maxlat: maxlat = y
            continue
        for i in range(n):
            c1 = ring[i]
            c2 = ring[(i + 1) % n]
            x1, y1 = c1[0], c1[1]
            x2, y2 = c2[0], c2[1]
            cr = x1 * y2 - x2 * y1
            a2_sum += cr
            cx_sum += (x1 + x2) * cr
            cy_sum += (y1 + y2) * cr
            sx += x1
            sy += y1
            nv += 1
            if x1 < minlon: minlon = x1
            if x1 > maxlon: maxlon = x1
            if y1 < minlat: minlat = y1
            if y1 > maxlat: maxlat = y1
    if nv == 0:
        return None
    if abs(a2_sum) > 1e-14:
        clon = cx_sum / (3.0 * a2_sum)
        clat = cy_sum / (3.0 * a2_sum)
    else:
        clon = sx / nv
        clat = sy / nv
    return clon, clat, minlon, minlat, maxlon, maxlat


def cell_of(lon, lat):
    return (math.floor(lon / CELL_DEG), math.floor(lat / CELL_DEG))


def fid_key(fid, idx):
    """Deterministic sort key for feature ids of any type."""
    if isinstance(fid, bool) or fid is None:
        return (2, idx)
    if isinstance(fid, int):
        return (0, fid)
    if isinstance(fid, float) and fid == int(fid):
        return (0, int(fid))
    return (1, str(fid))


# ---------------------------------------------------------------------------
# ring simplification (all-integer, deterministic)
# ---------------------------------------------------------------------------

def _dedupe_ring(pts):
    out = []
    for p in pts:
        if not out or out[-1] != p:
            out.append(p)
    if len(out) > 1 and out[0] == out[-1]:
        out.pop()
    return out


def _cross(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _remove_collinear(pts):
    """Remove vertices strictly collinear with their cyclic neighbors."""
    while len(pts) > 2:
        changed = False
        st = []
        for p in pts:
            while len(st) >= 2 and _cross(st[-2], st[-1], p) == 0:
                st.pop()
                changed = True
            st.append(p)
        while len(st) >= 3 and _cross(st[-2], st[-1], st[0]) == 0:
            st.pop()
            changed = True
        while len(st) >= 3 and _cross(st[-1], st[0], st[1]) == 0:
            st.pop(0)
            changed = True
        pts = st
        if not changed:
            break
    return pts


def _merge_short(pts, min_seg):
    """Merge segments shorter than min_seg by dropping their far endpoint.

    The ring is first rotated to start at its lexicographically smallest
    vertex so the result is independent of the source ring's start vertex.
    """
    if len(pts) < 2:
        return pts
    k = min(range(len(pts)), key=lambda i: pts[i])
    pts = pts[k:] + pts[:k]
    m2 = min_seg * min_seg
    out = [pts[0]]
    for p in pts[1:]:
        dx = p[0] - out[-1][0]
        dy = p[1] - out[-1][1]
        if dx * dx + dy * dy < m2:
            continue
        out.append(p)
    if len(out) > 2:
        dx = out[0][0] - out[-1][0]
        dy = out[0][1] - out[-1][1]
        if dx * dx + dy * dy < m2:
            out.pop()
    return out


def _simplify_offset(pts, tol):
    """Drop vertices whose perpendicular offset from the chord of their
    cyclic neighbors is <= tol (meters).  Integer arithmetic throughout."""
    tol2 = tol * tol
    while len(pts) > 3:
        changed = False
        i = 0
        while i < len(pts) and len(pts) > 3:
            a = pts[i - 1]
            b = pts[i]
            c = pts[(i + 1) % len(pts)]
            dx = c[0] - a[0]
            dy = c[1] - a[1]
            l2 = dx * dx + dy * dy
            if l2 == 0:
                ex = b[0] - a[0]
                ey = b[1] - a[1]
                near = (ex * ex + ey * ey) <= tol2
            else:
                cr = dx * (b[1] - a[1]) - dy * (b[0] - a[0])
                near = cr * cr <= tol2 * l2
            if near:
                pts.pop(i)
                changed = True
            else:
                i += 1
        if not changed:
            break
    return pts


def base_simplify(pts):
    """Tolerance-0 pipeline: dedupe, collinear removal, short-segment merge."""
    pts = _dedupe_ring(pts)
    if len(pts) > 2:
        pts = _remove_collinear(pts)
    pts = _merge_short(pts, MIN_SEG_M)
    if len(pts) > 2:
        pts = _remove_collinear(pts)
    return pts


def simplify_ring(pts, tol):
    """Offset-tolerance simplification on top of an already base-simplified
    ring (applied fresh each budget iteration; deterministic)."""
    if tol > 0 and len(pts) > 3:
        pts = _simplify_offset(list(pts), tol)
        if len(pts) > 2:
            pts = _remove_collinear(pts)
        return pts
    return list(pts)


# ---------------------------------------------------------------------------
# grid-hash helpers
# ---------------------------------------------------------------------------

def _ring_cells(cx, cy, r):
    if r == 0:
        yield (cx, cy)
        return
    for dx in range(-r, r + 1):
        yield (cx + dx, cy - r)
        yield (cx + dx, cy + r)
    for dy in range(-r + 1, r):
        yield (cx - r, cy + dy)
        yield (cx + r, cy + dy)


# ---------------------------------------------------------------------------
# graph assembly for one (AOI, tolerance) attempt
# ---------------------------------------------------------------------------

class Parcel(object):
    __slots__ = ("idx", "fid", "key", "cell", "rings", "cx", "cy", "reps")

    def __init__(self, idx, fid, cell, rings, cx, cy):
        self.idx = idx
        self.fid = fid
        self.key = fid_key(fid, idx)
        self.cell = cell
        self.rings = rings
        self.cx = cx
        self.cy = cy
        self.reps = ()


def assemble(parcels, tol, args):
    """Build the full graph for the given parcels at the given tolerance.

    Returns a result dict; result["over"] is set when a hard budget is
    exceeded (caller then raises tolerance or shrinks the AOI).
    """
    nodes = []            # provisional id -> (x, y)
    node_id = {}
    bnd_edges = []        # (a, b) with a < b, creation order, surface 0
    edge_set = set()

    for pc in parcels:    # already sorted by feature id
        reps = []
        for ring in pc.rings:
            pts = simplify_ring(ring, tol)
            if len(pts) < 2:
                continue
            if len(pts) == 2:
                segs = [(pts[0], pts[1])]
            else:
                segs = [(pts[i], pts[(i + 1) % len(pts)])
                        for i in range(len(pts))]
            rep = None
            for a, b in segs:
                if a == b:
                    continue
                ia = node_id.get(a)
                if ia is None:
                    ia = node_id[a] = len(nodes)
                    nodes.append(a)
                ib = node_id.get(b)
                if ib is None:
                    ib = node_id[b] = len(nodes)
                    nodes.append(b)
                if rep is None:
                    rep = ia
                key = (ia, ib) if ia < ib else (ib, ia)
                if key in edge_set:
                    continue
                edge_set.add(key)
                bnd_edges.append(key)
            if rep is not None:
                reps.append(rep)
        pc.reps = tuple(reps)

    nn = len(nodes)
    if nn < 2 or not bnd_edges:
        return {"over": True, "nodes": nn, "edges": len(bnd_edges),
                "why": "degenerate graph"}
    if nn > args.max_nodes or len(bnd_edges) > args.max_edges:
        return {"over": True, "nodes": nn, "edges": len(bnd_edges),
                "why": "boundary graph over budget"}

    # --- union-find over boundary edges -----------------------------------
    parent = list(range(nn))
    size = [1] * nn

    def find(x):
        r = x
        while parent[r] != r:
            r = parent[r]
        while parent[x] != r:
            parent[x], x = r, parent[x]
        return r

    def union(x, y):
        rx, ry = find(x), find(y)
        if rx == ry:
            return rx
        if size[rx] < size[ry] or (size[rx] == size[ry] and ry < rx):
            rx, ry = ry, rx
        parent[ry] = rx
        size[rx] += size[ry]
        return rx

    for a, b in bnd_edges:
        union(a, b)

    orig_comp = [find(i) for i in range(nn)]
    comps = defaultdict(list)
    for i in range(nn):
        comps[orig_comp[i]].append(i)      # each list ascending by node id
    comps = dict(comps)
    n_orig_comps = len(comps)

    # --- grid hash of all nodes for nearest searches ----------------------
    G = BRIDGE_GRID_M
    grid = defaultdict(list)
    for i, (x, y) in enumerate(nodes):
        grid[(x // G, y // G)].append(i)   # ascending by node id

    alive = [True] * nn
    bridges = []            # (a, b) surface 1, creation order
    dropped_comps = 0
    limit2 = BRIDGE_MAX_M * BRIDGE_MAX_M
    max_ring = BRIDGE_MAX_M // G + 2

    # --- stitch islands ---------------------------------------------------
    while len(comps) > 1:
        root = min(comps, key=lambda r: (len(comps[r]), comps[r][0]))
        comp_nodes = comps[root]
        best = None                          # (d2, a, b), d2 <= limit2 only
        for a in comp_nodes:
            ax, ay = nodes[a]
            ca, cb = ax // G, ay // G
            r = 0
            while r <= max_ring:
                if r >= 1:
                    md = (r - 1) * G
                    bound = best[0] if best is not None else limit2
                    if md * md > bound:
                        break
                for cell in _ring_cells(ca, cb, r):
                    lst = grid.get(cell)
                    if not lst:
                        continue
                    for b in lst:
                        if not alive[b] or find(b) == root:
                            continue
                        bx, by = nodes[b]
                        d2 = (bx - ax) * (bx - ax) + (by - ay) * (by - ay)
                        if d2 > limit2:
                            continue
                        cand = (d2, a, b)
                        if best is None or cand < best:
                            best = cand
                r += 1
        if best is None:
            # remote island: drop its nodes; parcels resolved below
            for i in comp_nodes:
                alive[i] = False
            del comps[root]
            dropped_comps += 1
        else:
            _, a, b = best
            rb = find(b)
            nr = union(a, b)
            merged = sorted(comps[root] + comps[rb])
            del comps[root]
            del comps[rb]
            comps[nr] = merged
            key = (a, b) if a < b else (b, a)
            edge_set.add(key)
            bridges.append((a, b))

    if not comps:
        return {"over": True, "nodes": 0, "edges": 0,
                "why": "all components dropped"}

    kept_bnd = [(a, b) for a, b in bnd_edges if alive[a] and alive[b]]
    # a component merged by an earlier bridge may itself be dropped later;
    # its bridge edges die with it
    bridges = [(a, b) for a, b in bridges if alive[a] and alive[b]]
    n_alive = sum(alive)

    # --- extra street crossings (<= CROSS_M between original components) --
    G2 = CROSS_M
    grid2 = defaultdict(list)
    for i, (x, y) in enumerate(nodes):
        if alive[i]:
            grid2[(x // G2, y // G2)].append(i)
    cand = []
    for a in range(nn):
        if not alive[a]:
            continue
        ax, ay = nodes[a]
        ca, cb = ax // G2, ay // G2
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                lst = grid2.get((ca + dx, cb + dy))
                if not lst:
                    continue
                for b in lst:
                    if b <= a or orig_comp[b] == orig_comp[a]:
                        continue
                    bx, by = nodes[b]
                    d2 = (bx - ax) * (bx - ax) + (by - ay) * (by - ay)
                    if d2 > G2 * G2:
                        continue
                    if (a, b) in edge_set:
                        continue
                    cand.append((d2, a, b))
    cand.sort()
    crossings = []
    for d2, a, b in cand:
        if len(crossings) >= CROSS_CAP:
            break
        key = (a, b)
        if key in edge_set:
            continue
        edge_set.add(key)
        crossings.append((a, b))

    # --- parcels dropped with their island --------------------------------
    dropped_parcels = 0
    surviving = []
    for pc in parcels:
        if pc.reps and all(not alive[r] for r in pc.reps):
            dropped_parcels += 1
        else:
            surviving.append(pc)

    # --- premises: centroid within DROP_M of some alive node --------------
    G3 = DROP_M
    grid3 = defaultdict(list)
    for i, (x, y) in enumerate(nodes):
        if alive[i]:
            grid3[(x // G3, y // G3)].append(i)
    d2max = DROP_M * DROP_M
    premises = []
    dropped_far = 0
    for pc in surviving:
        px, py = pc.cx, pc.cy
        ca, cb = px // G3, py // G3
        ok = False
        for dx in (-1, 0, 1):
            if ok:
                break
            for dy in (-1, 0, 1):
                lst = grid3.get((ca + dx, cb + dy))
                if not lst:
                    continue
                for i in lst:
                    x, y = nodes[i]
                    if (x - px) * (x - px) + (y - py) * (y - py) <= d2max:
                        ok = True
                        break
                if ok:
                    break
        if ok:
            premises.append(pc)
        else:
            dropped_far += 1

    total_edges = len(kept_bnd) + len(bridges) + len(crossings)
    res = {
        "over": False,
        "nodes_xy": nodes,
        "alive": alive,
        "n_alive": n_alive,
        "bnd_edges": kept_bnd,
        "bridges": bridges,
        "crossings": crossings,
        "premises": premises,
        "n_orig_comps": n_orig_comps,
        "dropped_comps": dropped_comps,
        "dropped_parcels": dropped_parcels,
        "dropped_far": dropped_far,
        "nodes": n_alive,
        "edges": total_edges,
    }
    if (n_alive > args.max_nodes or total_edges > args.max_edges
            or len(premises) > args.max_premises):
        res["over"] = True
        res["why"] = "final graph over budget"
    if n_alive < 2 or total_edges < 1 or len(premises) < 1:
        res["over"] = True
        res["why"] = "final graph degenerate"
    return res


# ---------------------------------------------------------------------------
# emission + self-validation
# ---------------------------------------------------------------------------

def emit(res, out_path):
    nodes = res["nodes_xy"]
    alive = res["alive"]
    alive_ids = [i for i in range(len(nodes)) if alive[i]]
    order = sorted(alive_ids, key=lambda i: (nodes[i][1], nodes[i][0]))
    newid = {}
    for k, i in enumerate(order):
        newid[i] = k

    all_edges = ([(a, b, 0) for a, b in res["bnd_edges"]]
                 + [(a, b, 1) for a, b in res["bridges"]]
                 + [(a, b, 1) for a, b in res["crossings"]])

    lines = ["NETWERK 1"]
    lines.append("NODES %d" % len(order))
    for k, i in enumerate(order):
        x, y = nodes[i]
        lines.append("%d %d %d" % (k, x, y))
    lines.append("EDGES %d" % len(all_edges))
    for eid, (a, b, s) in enumerate(all_edges):
        lines.append("%d %d %d %d" % (eid, newid[a], newid[b], s))
    lines.append("PREMISES %d" % len(res["premises"]))
    for pid, pc in enumerate(res["premises"]):
        lines.append("%d %d %d 1" % (pid, pc.cx, pc.cy))
    lines.append("END")
    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")


def self_validate(out_path, args):
    """Re-read the emitted file and check every engine-facing invariant."""
    with open(out_path) as f:
        toks = f.read().split()
    pos = [0]

    def nxt():
        t = toks[pos[0]]
        pos[0] += 1
        return t

    assert nxt() == "NETWERK", "missing NETWERK header"
    assert nxt() == "1", "bad version"
    assert nxt() == "NODES", "missing NODES"
    n = int(nxt())
    assert 2 <= n <= args.max_nodes, "node count out of budget: %d" % n
    nx = [0] * n
    ny = [0] * n
    for i in range(n):
        assert int(nxt()) == i, "node ids not sequential at %d" % i
        nx[i] = int(nxt())
        ny[i] = int(nxt())
    assert nxt() == "EDGES", "missing EDGES"
    m = int(nxt())
    assert 1 <= m <= args.max_edges, "edge count out of budget: %d" % m
    seen = set()
    adj = [[] for _ in range(n)]
    n_cross = 0
    for i in range(m):
        assert int(nxt()) == i, "edge ids not sequential at %d" % i
        a = int(nxt())
        b = int(nxt())
        s = int(nxt())
        assert 0 <= a < n and 0 <= b < n, "edge endpoint out of range"
        assert a != b, "self-loop edge %d" % i
        assert s in (0, 1), "bad surface class"
        key = (a, b) if a < b else (b, a)
        assert key not in seen, "duplicate edge between %d and %d" % (a, b)
        seen.add(key)
        adj[a].append(b)
        adj[b].append(a)
        if s == 1:
            n_cross += 1
    assert nxt() == "PREMISES", "missing PREMISES"
    p = int(nxt())
    assert 1 <= p <= args.max_premises, "premises count out of budget: %d" % p
    px = [0] * p
    py = [0] * p
    for i in range(p):
        assert int(nxt()) == i, "premises ids not sequential at %d" % i
        px[i] = int(nxt())
        py[i] = int(nxt())
        assert int(nxt()) >= 1, "premises units < 1"
    assert nxt() == "END", "missing END"
    assert pos[0] == len(toks), "trailing tokens after END"

    # single connected component (BFS from 0)
    seen_n = [False] * n
    seen_n[0] = True
    dq = deque([0])
    reached = 1
    while dq:
        u = dq.popleft()
        for v in adj[u]:
            if not seen_n[v]:
                seen_n[v] = True
                reached += 1
                dq.append(v)
    assert reached == n, "graph not connected: %d/%d reachable" % (reached, n)

    # every premises within DROP_M of some node
    G3 = DROP_M
    grid3 = defaultdict(list)
    for i in range(n):
        grid3[(nx[i] // G3, ny[i] // G3)].append(i)
    d2max = DROP_M * DROP_M
    for i in range(p):
        ca, cb = px[i] // G3, py[i] // G3
        ok = False
        for dx in (-1, 0, 1):
            if ok:
                break
            for dy in (-1, 0, 1):
                for j in grid3.get((ca + dx, cb + dy), ()):
                    if ((nx[j] - px[i]) ** 2 + (ny[j] - py[i]) ** 2) <= d2max:
                        ok = True
                        break
                if ok:
                    break
        assert ok, "premises %d farther than %dm from every node" % (i, DROP_M)

    return {"nodes": n, "edges": m, "crossings": n_cross, "premises": p,
            "avg_degree": 2.0 * m / n}


# ---------------------------------------------------------------------------
# main pipeline
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="Convert parcel GeoJSON to netwerk v1 interchange.")
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--out", dest="out", required=True)
    ap.add_argument("--max-nodes", type=int, default=16000)
    ap.add_argument("--max-edges", type=int, default=48000)
    ap.add_argument("--max-premises", type=int, default=12000)
    args = ap.parse_args()

    t0 = time.time()

    # ---- Pass 1: stream, per-feature centroid + bbox ---------------------
    log("pass 1: streaming %s ..." % args.inp)
    fids = []
    clons = []
    clats = []
    minlon = minlat = math.inf
    maxlon = maxlat = -math.inf
    n_feat = 0
    n_nopoly = 0
    for idx, f in stream_features(args.inp):
        geom = f.get("geometry")
        rings = outer_rings(geom)
        cb = centroid_bbox(rings) if rings else None
        fids.append(f.get("id"))
        if cb is None:
            clons.append(math.nan)
            clats.append(math.nan)
            n_nopoly += 1
        else:
            clon, clat, mnl, mnt, mxl, mxt = cb
            clons.append(clon)
            clats.append(clat)
            if mnl < minlon: minlon = mnl
            if mnt < minlat: minlat = mnt
            if mxl > maxlon: maxlon = mxl
            if mxt > maxlat: maxlat = mxt
        n_feat += 1
        if n_feat % 100000 == 0:
            log("  ... %d features (%.0fs)" % (n_feat, time.time() - t0))
    log("pass 1 done: %d features (%d without polygon geometry), %.0fs"
        % (n_feat, n_nopoly, time.time() - t0))
    log("global bbox: lon [%.6f, %.6f]  lat [%.6f, %.6f]"
        % (minlon, maxlon, minlat, maxlat))

    # ---- AOI selection on a CELL_DEG grid --------------------------------
    counts = defaultdict(int)
    for i in range(n_feat):
        if clons[i] == clons[i]:  # not NaN
            counts[cell_of(clons[i], clats[i])] += 1
    if not counts:
        log("FATAL: no polygon features found")
        sys.exit(2)
    ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    seed = None
    for cell, cnt in ranked:
        if cnt <= args.max_premises:
            seed = cell
            break
    if seed is None:
        log("FATAL: every grid cell exceeds --max-premises")
        sys.exit(2)
    aoi = {seed}
    total = counts[seed]
    while True:
        cand = set()
        for (cx, cy) in aoi:
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    c = (cx + dx, cy + dy)
                    if c not in aoi and counts.get(c, 0) > 0:
                        cand.add(c)
        if not cand:
            break
        best = sorted(cand, key=lambda c: (-counts[c], c))[0]
        if total + counts[best] > args.max_premises:
            break
        aoi.add(best)
        total += counts[best]
    log("AOI seed cell %s (%d parcels); grew to %d cells, %d parcels"
        % (str(seed), counts[seed], len(aoi), total))

    def aoi_bbox_deg(cells):
        xs = [c[0] for c in cells]
        ys = [c[1] for c in cells]
        return (min(xs) * CELL_DEG, min(ys) * CELL_DEG,
                (max(xs) + 1) * CELL_DEG, (max(ys) + 1) * CELL_DEG)

    ab = aoi_bbox_deg(aoi)
    lon0 = (ab[0] + ab[2]) / 2.0
    lat0 = (ab[1] + ab[3]) / 2.0
    kx = DEG_X_M * math.cos(math.radians(lat0))
    ky = DEG_Y_M
    log("AOI bbox (deg): lon [%.4f, %.4f] lat [%.4f, %.4f]; center (%.4f, %.4f)"
        % (ab[0], ab[2], ab[1], ab[3], lon0, lat0))

    # ---- Pass 2: stream again, project AOI features ----------------------
    in_aoi = [False] * n_feat
    for i in range(n_feat):
        if clons[i] == clons[i] and cell_of(clons[i], clats[i]) in aoi:
            in_aoi[i] = True

    log("pass 2: extracting %d AOI parcels ..." % total)
    parcels = []
    for idx, f in stream_features(args.inp, want=lambda i: in_aoi[i]):
        if f is None:
            continue
        rings_ll = outer_rings(f.get("geometry"))
        rings = []
        for ring in rings_ll:
            pts = [(int(round((c[0] - lon0) * kx)),
                    int(round((c[1] - lat0) * ky))) for c in ring]
            pts = base_simplify(pts)
            if len(pts) >= 2:
                rings.append(pts)
        cx = int(round((clons[idx] - lon0) * kx))
        cy = int(round((clats[idx] - lat0) * ky))
        parcels.append(Parcel(idx, fids[idx], cell_of(clons[idx], clats[idx]),
                              rings, cx, cy))
    log("pass 2 done: %d parcels, %.0fs" % (len(parcels), time.time() - t0))

    # free pass-1 arrays we no longer need
    del clons, clats, fids, in_aoi

    # ---- budget loop: tolerance ladder, then AOI fringe shrink -----------
    parcels.sort(key=lambda pc: (pc.key, pc.idx))
    res = None
    final_tol = None
    shrunk_cells = 0
    while True:
        active = [pc for pc in parcels if pc.cell in aoi]
        for tol in TOL_LADDER:
            r = assemble(active, tol, args)
            log("  attempt tol=%dm: nodes=%d edges=%d%s"
                % (tol, r.get("nodes", 0), r.get("edges", 0),
                   " OVER (%s)" % r["why"] if r["over"] else ""))
            if not r["over"]:
                res = r
                final_tol = tol
                break
        if res is not None:
            break
        # shrink AOI: remove least-dense fringe cells (never the seed)
        fringe = []
        for c in aoi:
            if c == seed:
                continue
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    if (dx or dy) and (c[0] + dx, c[1] + dy) not in aoi:
                        fringe.append(c)
                        break
                else:
                    continue
                break
        if not fringe:
            log("FATAL: cannot fit budgets even with a single cell")
            sys.exit(2)
        victim = sorted(fringe, key=lambda c: (counts[c], c))[0]
        aoi.remove(victim)
        shrunk_cells += 1
        log("  shrinking AOI: removed fringe cell %s (%d parcels); %d cells left"
            % (str(victim), counts[victim], len(aoi)))

    ab = aoi_bbox_deg(aoi)
    emit(res, args.out)
    stats = self_validate(args.out, args)
    out_size = os.path.getsize(args.out)

    n_prem = len(res["premises"])
    log("self-validation passed, %.0fs total" % (time.time() - t0))
    print("=== parcels2netwerk stats ===")
    print("input features           : %d" % n_feat)
    print("global bbox (deg)        : lon [%.6f, %.6f] lat [%.6f, %.6f]"
          % (minlon, maxlon, minlat, maxlat))
    print("AOI cells / parcels      : %d / %d (shrunk %d fringe cells)"
          % (len(aoi), len([p for p in parcels if p.cell in aoi]), shrunk_cells))
    print("AOI bbox (deg)           : lon [%.4f, %.4f] lat [%.4f, %.4f]"
          % (ab[0], ab[2], ab[1], ab[3]))
    print("simplification tolerance : %d m" % final_tol)
    print("original components      : %d" % res["n_orig_comps"])
    print("nodes                    : %d (budget %d)" % (stats["nodes"], args.max_nodes))
    print("edges                    : %d (budget %d)" % (stats["edges"], args.max_edges))
    print("  boundary edges         : %d" % len(res["bnd_edges"]))
    print("  bridge crossings       : %d" % len(res["bridges"]))
    print("  extra crossings (<=%dm): %d (cap %d)"
          % (CROSS_M, len(res["crossings"]), CROSS_CAP))
    print("premises                 : %d (budget %d)" % (n_prem, args.max_premises))
    print("dropped island components: %d (gap > %d m)" % (res["dropped_comps"], BRIDGE_MAX_M))
    print("dropped island parcels   : %d" % res["dropped_parcels"])
    print("dropped far premises     : %d (> %d m from every node)"
          % (res["dropped_far"], DROP_M))
    print("avg node degree          : %.2f" % stats["avg_degree"])
    print("output                   : %s (%d bytes)" % (args.out, out_size))


if __name__ == "__main__":
    main()
