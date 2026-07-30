#!/usr/bin/env python3
"""Design-quality scorer for netwerk outputs.

Joins the interchange file (road graph + premises) with the geometry dump
from `netwerk_export` and the report from `netwerk`, computes quality
metrics, prints one 'metric: value' line each (machine-parsable), and
writes them as JSON.

    python3 tools/score_design.py \
        --interchange scenarios/s01.txt \
        --geom s01.geom.txt --report s01.report.txt --json s01.json

Composite score (lower = better), in cents:
    capex_cents
  + 50000  * drop_street_crossings
  + 20000  * drop_drop_crossings
  + 100000 * (terminals_under_4 + terminals_over_12)
  + 500000 * rings
  + 1000000 * qa_errors

All geometry predicates are exact integer orientation tests; the scorer is
fully deterministic.
"""
import argparse
import json
import re
import sys

CELL = 128  # grid-hash cell size in meters


# ---------------------------------------------------------------- parsing

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
        next(it)  # sequential id
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
    co = None
    terms, gprems, gedges = [], [], []
    with open(path) as f:
        header = f.readline().split()
        if header[:2] != ["GEOM", "1"]:
            sys.exit("geom: bad header")
        for line in f:
            t = line.split()
            if not t or t[0] == "END":
                continue
            if t[0] != "G":
                sys.exit("geom: unexpected line: " + line.strip())
            kind, vals = t[1], [int(v) for v in t[2:]]
            if kind == "co":
                co = vals[0]
            elif kind == "term":
                # tid node area ports ports_used path_m
                terms.append(vals)
            elif kind == "prem":
                # pid area term drop_m
                gprems.append(vals)
            elif kind == "edge":
                # eid trench dist_fibers feeder_fibers
                gedges.append(vals)
    return co, terms, gprems, gedges


def read_report(path):
    text = open(path).read()
    m = re.search(r"total_capex=\$(\d+)\.(\d{2})", text)
    capex_cents = int(m.group(1)) * 100 + int(m.group(2)) if m else 0

    qa_errors = 0
    in_qa = False
    verdict = "MISSING"
    for line in text.splitlines():
        if line.startswith("qa verdict:"):
            verdict = line.split(":", 1)[1].strip()
            in_qa = False
        elif line.startswith("qa:"):
            in_qa = True
        elif in_qa and " FAIL" in line:
            qa_errors += 1

    m = re.search(r"trench_m=(\d+) cable_route_m=(\d+)", text)
    trench_m = int(m.group(1)) if m else 0
    cable_route_m = int(m.group(2)) if m else 0
    return capex_cents, qa_errors, verdict, trench_m, cable_route_m


# ---------------------------------------------------- exact geometry tests

def orient(ax, ay, bx, by, cx, cy):
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)


def proper_cross(p, q, a, b):
    """True iff segments pq and ab intersect at a single interior point of
    both (endpoint touching and collinear overlap excluded)."""
    d1 = orient(a[0], a[1], b[0], b[1], p[0], p[1])
    d2 = orient(a[0], a[1], b[0], b[1], q[0], q[1])
    if (d1 > 0 and d2 > 0) or (d1 < 0 and d2 < 0) or d1 == 0 or d2 == 0:
        return False
    d3 = orient(p[0], p[1], q[0], q[1], a[0], a[1])
    d4 = orient(p[0], p[1], q[0], q[1], b[0], b[1])
    if (d3 > 0 and d4 > 0) or (d3 < 0 and d4 < 0) or d3 == 0 or d4 == 0:
        return False
    return True


def grid_insert(grid, key, x0, y0, x1, y1):
    if x0 > x1:
        x0, x1 = x1, x0
    if y0 > y1:
        y0, y1 = y1, y0
    for cx in range(x0 // CELL, x1 // CELL + 1):
        for cy in range(y0 // CELL, y1 // CELL + 1):
            grid.setdefault((cx, cy), []).append(key)


def grid_lookup(grid, x0, y0, x1, y1):
    if x0 > x1:
        x0, x1 = x1, x0
    if y0 > y1:
        y0, y1 = y1, y0
    seen = set()
    for cx in range(x0 // CELL, x1 // CELL + 1):
        for cy in range(y0 // CELL, y1 // CELL + 1):
            for k in grid.get((cx, cy), ()):
                seen.add(k)
    return seen


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interchange", required=True)
    ap.add_argument("--geom", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--json", required=True)
    args = ap.parse_args()

    nodes, edges, prems = read_interchange(args.interchange)
    co, terms, gprems, gedges = read_geom(args.geom)
    capex_cents, qa_errors, verdict, trench_m, cable_route_m = \
        read_report(args.report)

    term_node = {t[0]: t[1] for t in terms}

    # Drops: one segment per connected premises, premises -> terminal node.
    drops = []  # (pid, term_id, (px,py), (tx,ty), drop_m)
    for pid, area, term, drop_m in gprems:
        if term >= 0 and term in term_node:
            px, py = prems[pid][0], prems[pid][1]
            tn = term_node[term]
            drops.append((pid, term, (px, py), nodes[tn], drop_m, tn))

    drop_count = len(drops)
    drop_max_m = max((d[4] for d in drops), default=0)
    drop_mean_m = (sum(d[4] for d in drops) / drop_count) if drop_count else 0.0

    # --- drop vs road-edge proper crossings ---
    edge_grid = {}
    edge_ends = []
    for eid, (a, b, _surface) in enumerate(edges):
        ax, ay = nodes[a]
        bx, by = nodes[b]
        edge_ends.append((a, b, (ax, ay), (bx, by)))
        grid_insert(edge_grid, eid, ax, ay, bx, by)

    drop_street_crossings = 0
    for _pid, _term, p, q, _dm, tn in drops:
        for eid in sorted(grid_lookup(edge_grid, p[0], p[1], q[0], q[1])):
            a, b, pa, pb = edge_ends[eid]
            if a == tn or b == tn:
                continue  # edge incident to the drop's own terminal node
            if proper_cross(p, q, pa, pb):
                drop_street_crossings += 1

    # --- drop vs drop proper crossings (each pair once) ---
    drop_grid = {}
    for i, (_pid, _term, p, q, _dm, _tn) in enumerate(drops):
        grid_insert(drop_grid, i, p[0], p[1], q[0], q[1])
    drop_drop_pairs = set()
    for i, (_pid, _term, p, q, _dm, _tn) in enumerate(drops):
        for j in grid_lookup(drop_grid, p[0], p[1], q[0], q[1]):
            if j <= i or (i, j) in drop_drop_pairs:
                continue
            p2, q2 = drops[j][2], drops[j][3]
            if proper_cross(p, q, p2, q2):
                drop_drop_pairs.add((i, j))
    drop_drop_crossings = len(drop_drop_pairs)

    # --- terminal sizing (customers = ports_used on live terminals) ---
    live = [t for t in terms if t[4] > 0]
    terminal_count = len(live)
    terminals_under_4 = sum(1 for t in live if t[4] < 4)
    terminals_over_12 = sum(1 for t in live if t[4] > 12)

    # --- rings: cyclomatic number E - V + C of the used-trench graph ---
    trench_edges = [g[0] for g in gedges if g[1] == 1]
    parent = {}

    def find(x):
        root = x
        while parent[root] != root:
            root = parent[root]
        while parent[x] != root:
            parent[x], x = root, parent[x]
        return root

    vset = set()
    for eid in trench_edges:
        a, b, _ = edges[eid]
        vset.add(a)
        vset.add(b)
        parent.setdefault(a, a)
        parent.setdefault(b, b)
    comp = len(vset)
    for eid in trench_edges:
        a, b, _ = edges[eid]
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb
            comp -= 1
    rings = len(trench_edges) - len(vset) + comp

    sharing_ratio = (cable_route_m / trench_m) if trench_m else 0.0

    score = (capex_cents
             + 50000 * drop_street_crossings
             + 20000 * drop_drop_crossings
             + 100000 * (terminals_under_4 + terminals_over_12)
             + 500000 * rings
             + 1000000 * qa_errors)

    metrics = [
        ("capex_cents", capex_cents),
        ("qa_errors", qa_errors),
        ("qa_verdict", verdict),
        ("drop_count", drop_count),
        ("drop_mean_m", round(drop_mean_m, 2)),
        ("drop_max_m", drop_max_m),
        ("drop_street_crossings", drop_street_crossings),
        ("drop_drop_crossings", drop_drop_crossings),
        ("terminals_under_4", terminals_under_4),
        ("terminals_over_12", terminals_over_12),
        ("terminal_count", terminal_count),
        ("rings", rings),
        ("trench_m", trench_m),
        ("cable_route_m", cable_route_m),
        ("sharing_ratio", round(sharing_ratio, 3)),
        ("score", score),
    ]
    for k, v in metrics:
        print("%s: %s" % (k, v))

    with open(args.json, "w") as f:
        json.dump(dict(metrics), f, indent=1, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    main()
