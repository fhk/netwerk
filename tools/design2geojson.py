#!/usr/bin/env python3
"""netwerk design -> per-layer GeoJSON.

Joins the interchange file (geometry: nodes, edges, premises) with the
geometry dump produced by `netwerk_export` (design: assignments, usage)
and writes one GeoJSON FeatureCollection per design layer, re-projected
to WGS84 with the exact anchor recorded by the converter's meta sidecar.

    ./build/netwerk_export < district.txt > district.geom.txt
    python3 tools/design2geojson.py \
        --interchange district.txt --geom district.geom.txt \
        --meta district.txt.meta.json --out out_dir/

Layers written: central_office, cabinets, terminals, premises, drops,
fiber_feeder, fiber_distribution, trench, serving_areas.
Deterministic output: fixed key order, 7-decimal coordinates.
"""
import argparse
import json
import math
import os
import sys


def read_interchange(path):
    toks = open(path).read().split()
    it = iter(toks)

    def expect(word):
        t = next(it)
        if t != word:
            sys.exit("interchange: expected %s, got %s" % (word, t))

    expect("NETWERK")
    if next(it) != "1":
        sys.exit("interchange: unsupported version")
    expect("NODES")
    n = int(next(it))
    nodes = []
    for _ in range(n):
        next(it)  # id (sequential)
        nodes.append((int(next(it)), int(next(it))))
    expect("EDGES")
    m = int(next(it))
    edges = []
    for _ in range(m):
        next(it)
        edges.append((int(next(it)), int(next(it)), int(next(it))))
    expect("PREMISES")
    p = int(next(it))
    prems = []
    for _ in range(p):
        next(it)
        prems.append((int(next(it)), int(next(it)), int(next(it))))
    expect("END")
    return nodes, edges, prems


def read_geom(path):
    cos = []
    fdhs, terms, gprems, gedges = [], [], [], []
    with open(path) as f:
        header = f.readline().split()
        if header[:2] != ["GEOM", "1"]:
            sys.exit("geom: bad header")
        for line in f:
            t = line.split()
            if not t:
                continue
            if t[0] == "END":
                break
            if t[0] != "G":
                sys.exit("geom: unexpected line: " + line.strip())
            kind, vals = t[1], [int(v) for v in t[2:]]
            if kind == "co":
                cos.append(vals[0])          # one line per head-end
            elif kind == "fdh":
                fdhs.append(vals)
            elif kind == "term":
                terms.append(vals)
            elif kind == "prem":
                gprems.append(vals)
            elif kind == "edge":
                gedges.append(vals)
    return cos, fdhs, terms, gprems, gedges


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interchange", required=True)
    ap.add_argument("--geom", required=True)
    ap.add_argument("--meta", help="converter meta sidecar with the anchor")
    ap.add_argument("--anchor", help="lon0,lat0 if no meta (e.g. synthetic)")
    ap.add_argument("--out", required=True, help="output directory")
    args = ap.parse_args()

    if args.meta:
        meta = json.load(open(args.meta))
        lon0, lat0 = meta["lon0"], meta["lat0"]
        kx, ky = meta["kx_m_per_deg"], meta["ky_m_per_deg"]
    elif args.anchor:
        lon0, lat0 = (float(v) for v in args.anchor.split(","))
        kx = 111320.0 * math.cos(math.radians(lat0))
        ky = 110540.0
    else:
        sys.exit("need --meta or --anchor")

    def ll(xy):
        return [round(lon0 + xy[0] / kx, 7), round(lat0 + xy[1] / ky, 7)]

    nodes, edges, prems = read_interchange(args.interchange)
    cos, fdhs, terms, gprems, gedges = read_geom(args.geom)
    if not cos:
        sys.exit("geom: no CO record")
    co = cos[0]
    term_by_id = {t[0]: t for t in terms}

    os.makedirs(args.out, exist_ok=True)
    written = {}

    def feature(geom_type, coords, props):
        return {"type": "Feature",
                "geometry": {"type": geom_type, "coordinates": coords},
                "properties": props}

    def write(layer, features):
        path = os.path.join(args.out, layer + ".geojson")
        with open(path, "w") as f:
            json.dump({"type": "FeatureCollection",
                       "name": layer,
                       "features": features},
                      f, separators=(",", ":"), sort_keys=True)
            f.write("\n")
        written[layer] = len(features)

    # --- head-ends: the primary CO first, then any reach-driven OLT sites ---
    write("central_office", [
        feature("Point", ll(nodes[n]),
                {"node": n, "head_end": i,
                 "kind": "co_olt" if i == 0 else "remote_olt"})
        for i, n in enumerate(cos)])

    # --- cabinets (FDH) ---
    write("cabinets", [
        feature("Point", ll(nodes[a[1]]),
                {"serving_area": a[0], "node": a[1], "cabinet_units": a[2],
                 "splitters": a[3], "units": a[4], "take_units": a[5],
                 "feeder_m": a[6]})
        for a in fdhs])

    # --- terminals ---
    write("terminals", [
        feature("Point", ll(nodes[t[1]]),
                {"terminal": t[0], "node": t[1], "serving_area": t[2],
                 "ports": t[3], "ports_used": t[4], "path_m": t[5]})
        for t in terms])

    # --- premises and drops ---
    prem_feats, drop_feats = [], []
    for pid, area, term, drop_m in gprems:
        x, y, units = prems[pid]
        props = {"premises": pid, "units": units, "serving_area": area,
                 "terminal": term, "drop_m": drop_m,
                 "status": "connected" if term >= 0 else "unserved"}
        prem_feats.append(feature("Point", ll((x, y)), props))
        if term >= 0:
            tn = term_by_id[term][1]
            drop_feats.append(feature(
                "LineString", [ll((x, y)), ll(nodes[tn])],
                {"premises": pid, "terminal": term, "drop_m": drop_m}))
    write("premises", prem_feats)
    write("drops", drop_feats)

    # --- fiber cables and trench, per used edge ---
    feeder, dist, trench = [], [], []
    for eid, tr, dfib, ffib in gedges:
        a, b, surface = edges[eid]
        line = [ll(nodes[a]), ll(nodes[b])]
        if ffib > 0:
            feeder.append(feature("LineString", line,
                                  {"edge": eid, "fibers": ffib,
                                   "role": "feeder"}))
        if dfib > 0:
            dist.append(feature("LineString", line,
                                {"edge": eid, "fibers": dfib,
                                 "role": "distribution"}))
        if tr:
            trench.append(feature(
                "LineString", line,
                {"edge": eid,
                 "surface": "asphalt" if surface == 1 else "soft",
                 "shared": bool(ffib > 0 and dfib > 0)}))
    write("fiber_feeder", feeder)
    write("fiber_distribution", dist)
    write("trench", trench)

    # --- serving areas: convex hull of member premises ---
    def hull(points):  # Andrew monotone chain
        pts = sorted(set(points))
        if len(pts) < 3:
            return None
        def half(seq):
            h = []
            for pt in seq:
                while len(h) >= 2 and (
                        (h[-1][0] - h[-2][0]) * (pt[1] - h[-2][1]) -
                        (h[-1][1] - h[-2][1]) * (pt[0] - h[-2][0])) <= 0:
                    h.pop()
                h.append(pt)
            return h[:-1]
        return half(pts) + half(pts[::-1])

    by_area = {}
    for pid, area, term, _ in gprems:
        if area >= 0:
            by_area.setdefault(area, []).append(prems[pid][:2])
    area_feats = []
    for a in sorted(by_area):
        h = hull(by_area[a])
        if h:
            ring = [ll(pt) for pt in h] + [ll(h[0])]
            area_feats.append(feature("Polygon", [ring],
                                      {"serving_area": a,
                                       "premises": len(by_area[a])}))
    write("serving_areas", area_feats)

    # --- self-check ---
    assert written["premises"] == len(gprems) == len(prems)
    assert written["cabinets"] == len(fdhs)
    assert written["terminals"] == len(terms)
    assert written["drops"] == sum(1 for g in gprems if g[2] >= 0)
    for layer in sorted(written):
        print("%-20s %6d features" % (layer, written[layer]))


if __name__ == "__main__":
    main()
