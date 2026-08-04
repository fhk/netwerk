// netwerk — the design pipeline and its trench-price feedback loop.
//
// Stages 1-9 run in stages.carbon; this library owns the ORDER, and the
// one thing the order was missing. research.md 5.1b (and appendix A's
// ranked item 3) point out that terminal packing is one half of a
// Connected Facility Location problem whose other half — the trench that
// has to reach every terminal it opens — was priced at exactly zero:
// TrenchCostPerM appeared once in the whole engine, inside DeloopTrench.
//
// The cheap fix is one Gauss-Seidel sweep of the coordination between the
// two stages:
//   1. run the pipeline as before (the trench price is zero everywhere);
//   2. price the routed trench — pi_v = marginal cents to reach v;
//   3. re-decide every terminal with pi_v inside the move cost;
//   4. keep whichever sweep scores better on the ledger's own formula.
// Step 4 is what makes this safe rather than hopeful: the priced sweep is
// a candidate, not a conclusion. When it loses, the unpriced sweep is
// re-run from the same reset state with pi back at zero, which reproduces
// it bit-for-bit (same code, same inputs) rather than trying to keep a
// second 7 MB design object alive on the stack.

library "pipeline";

import library "model";
import library "graph";
import library "stages";
import library "outputs";

// Clustering and FDH siting depend on premises geometry only, so they run
// once and both sweeps inherit them; everything downstream is re-decided.
fn RunDesign(ref d: Design) {
  SnapPremises(ref d);
  Cluster(ref d);
  RebalanceClusters(ref d);  // pack serving areas so cabinets run full
  PlaceFdh(ref d);
  ReassignToFdh(ref d);      // assign against the sites actually built
  TransportRepair(ref d);    // and make that assignment exactly optimal

  // Sweep 1 — identical to iter 007: node_pi is all zeros, so every move
  // price in stages.carbon reduces to what it was.
  DesignSweep(ref d);
  d.sweep_score_a = SweepScore(ref d);

  // Sweep 2 — price the trench sweep 1 routed, then re-pack against it.
  ComputePi(ref d);
  ResetForSweep(ref d);
  DesignSweep(ref d);
  d.sweep_score_b = SweepScore(ref d);

  // Measured before the decision: these numbers describe what the priced
  // sweep chose, which is the experiment's output whether or not it wins.
  MeasurePiOnTerminals(ref d);

  if (d.sweep_score_b < d.sweep_score_a) {
    d.sweep_kept = 2;
  } else {
    d.sweep_kept = 1;
    ZeroPi(ref d);
    ResetForSweep(ref d);
    DesignSweep(ref d);
  }

  // Stage 9b, on the design that ships. Priced 2-opt drop uncrossing
  // (research.md 5.2) swaps the terminals of two crossing drops whenever
  // the full scorer delta pays. It runs ONCE, after the sweep decision,
  // for two reasons: it is a pure assignment repair, so re-deciding a
  // sweep cannot benefit from it; and it is the only stage that rewrites
  // prem_cluster, which the sweeps inherit and must not see move (the
  // fallback re-run has to reproduce sweep 1 bit-for-bit). The sweep
  // scores above are therefore pre-uncrossing on both sides — a fair
  // comparison, just not the final number.
  UncrossDrops(ref d);
}
