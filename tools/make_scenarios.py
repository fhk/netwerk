#!/usr/bin/env python3
"""Deterministic scenario generator for the design-quality harness.

Writes small NETWERK 1 interchange fixtures (same shape as
data/parcels_district.txt) into scenarios/, one per named situation the
design engine must handle well:

  s01_single_street   one straight street, premises on both sides
  s02_parallel_streets two parallel streets 30 m apart; premises in the
                       middle band tempt drops into crossing a street
  s03_grid5           5x5 street grid, ~150 premises
  s04_culdesac        T junction with a dead-end stub and an end cluster
  s05_two_islands     two street clusters joined by one 25 m crossing edge
  s06_mdu_block       one street, few premises with units 8..16

No randomness: every coordinate is a closed-form integer, so output is
byte-identical on every run.
"""
import os

OUT = os.path.join(os.path.dirname(__file__), "..", "scenarios")

SOFT, ASPHALT = 0, 1


class Builder:
    def __init__(self):
        self.nodes = []          # (x, y)
        self.node_at = {}        # (x, y) -> id
        self.edges = []          # (a, b, surface)
        self.edge_set = set()
        self.prems = []          # (x, y, units)

    def node(self, x, y):
        key = (x, y)
        if key not in self.node_at:
            self.node_at[key] = len(self.nodes)
            self.nodes.append(key)
        return self.node_at[key]

    def edge(self, a, b, surface=SOFT):
        key = (min(a, b), max(a, b))
        if a != b and key not in self.edge_set:
            self.edge_set.add(key)
            self.edges.append((a, b, surface))

    def street(self, x0, y0, x1, y1, step=30, surface=SOFT):
        """Straight street subdivided into `step`-meter segments.
        Axis-aligned only (all scenarios use rectilinear streets)."""
        assert x0 == x1 or y0 == y1
        length = abs(x1 - x0) + abs(y1 - y0)
        assert length % step == 0
        dx = (x1 - x0) // (length // step)
        dy = (y1 - y0) // (length // step)
        prev = self.node(x0, y0)
        x, y = x0, y0
        for _ in range(length // step):
            x, y = x + dx, y + dy
            cur = self.node(x, y)
            self.edge(prev, cur, surface)
            prev = cur

    def prem(self, x, y, units=1):
        self.prems.append((x, y, units))

    def write(self, name):
        path = os.path.join(OUT, name + ".txt")
        with open(path, "w") as f:
            f.write("NETWERK 1\n")
            f.write("NODES %d\n" % len(self.nodes))
            for i, (x, y) in enumerate(self.nodes):
                f.write("%d %d %d\n" % (i, x, y))
            f.write("EDGES %d\n" % len(self.edges))
            for i, (a, b, s) in enumerate(self.edges):
                f.write("%d %d %d %d\n" % (i, a, b, s))
            f.write("PREMISES %d\n" % len(self.prems))
            for i, (x, y, u) in enumerate(self.prems):
                f.write("%d %d %d %d\n" % (i, x, y, u))
            f.write("END\n")
        print("%-24s nodes=%-4d edges=%-4d premises=%-3d units=%d" % (
            name, len(self.nodes), len(self.edges), len(self.prems),
            sum(p[2] for p in self.prems)))


def s01_single_street():
    b = Builder()
    b.street(0, 0, 360, 0)
    for i in range(12):
        x = 15 + 30 * i
        b.prem(x, 12)
        b.prem(x, -12)
    b.write("s01_single_street")


def s02_parallel_streets():
    b = Builder()
    b.street(0, 0, 300, 0)
    b.street(0, 30, 300, 30)
    b.edge(b.node(0, 0), b.node(0, 30))
    b.edge(b.node(300, 0), b.node(300, 30))
    for i in range(10):
        x = 15 + 30 * i
        b.prem(x, -12)   # outer side of street A
        b.prem(x, 42)    # outer side of street B
        b.prem(x, 12)    # middle band, fronts street A
        b.prem(x, 18)    # middle band, fronts street B
    b.write("s02_parallel_streets")


def s03_grid5():
    b = Builder()
    for k in range(5):
        b.street(0, 120 * k, 480, 120 * k)
        b.street(120 * k, 0, 120 * k, 480)
    for k in range(5):
        y = 120 * k
        for i in range(16):
            b.prem(15 + 30 * i, y + 12)
        for i in range(15):
            b.prem(30 + 30 * i, y - 12)
    b.write("s03_grid5")


def s04_culdesac():
    b = Builder()
    b.street(0, 0, 360, 0)               # main street
    b.street(150, 0, 150, -150)          # side street ending dead
    for i in range(12):
        x = 15 + 30 * i
        b.prem(x, 12)
        b.prem(x, -12)
    for i in range(5):
        y = -15 - 30 * i
        b.prem(138, y)
        b.prem(162, y)
    # cluster around the dead end
    b.prem(135, -162)
    b.prem(150, -168)
    b.prem(165, -162)
    b.prem(132, -148)
    b.prem(168, -148)
    b.prem(150, -158)
    b.write("s04_culdesac")


def s05_two_islands():
    b = Builder()

    def island(cx):
        b.street(cx - 120, 0, cx + 120, 0)
        b.street(cx, -120, cx, 120)
        for i in range(8):
            x = cx - 105 + 30 * i
            b.prem(x, 12)
            b.prem(x, -12)
        for y in (-105, -75, -45, 45, 75, 105):
            b.prem(cx - 12, y)
            b.prem(cx + 12, y)

    island(0)
    island(265)
    # single 25 m crossing edge joining the islands
    b.edge(b.node(120, 0), b.node(145, 0), ASPHALT)
    b.write("s05_two_islands")


def s06_mdu_block():
    b = Builder()
    b.street(0, 0, 240, 0)
    units = [8, 12, 16, 10, 9, 14, 11, 13]
    for i, u in enumerate(units):
        x = 15 + 30 * i
        y = 15 if i % 2 == 0 else -15
        b.prem(x, y, u)
    b.write("s06_mdu_block")


def main():
    os.makedirs(OUT, exist_ok=True)
    s01_single_street()
    s02_parallel_streets()
    s03_grid5()
    s04_culdesac()
    s05_two_islands()
    s06_mdu_block()


if __name__ == "__main__":
    main()
