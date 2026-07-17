"""
Build-variety check: do specialized builds (chaos / targeting) actually beat the generic
hybrid (spam MaxBet + Frequency + BaseAdditive) under the current geometry + config?

For each archetype we take its axis loadout, find the nearest swept build (its real landing
distribution + hot/cold/combo), give it the upgrades that archetype would invest in (maxed),
and compute the per-ball EV at the bet that archetype uses. Income also scales with Frequency
(throughput) equally for all, so per-ball EV multiple + net-per-ball is the fair comparator.
"""

from __future__ import annotations
from pathlib import Path
import balance as B

BUILDS = B.parse(Path(__file__).resolve().parent.parent / "tests" / "2026-06-26.txt")
TABLE = B.SLOT_MULTS
MAXBET_T = 12
MAXBET = B.max_bet(MAXBET_T)
MINBET = 10.0


def nearest(angle, size, elast, arc, pegheat):
    return min(BUILDS, key=lambda b: (b.pegheat != pegheat, abs(abs(b.angle) - abs(angle)),
                                      abs(b.size - size), abs(b.elast - elast), abs(b.arc - arc)))


# Proportional combo: per-bounce FRACTION (not absolute pts), maxing at FLAT_FRAC_MAX/bounce.
FLAT_FRAC_MAX = 0.05  # tier-12 combo bonus = 0.05 × combo × base


def flat_frac(tier):
    return FLAT_FRAC_MAX * (tier / 12)


def per_ball(b, *, badd_t, flat_t, peg_t, bet):
    frac = [b.targets.get(s, 0) / b.n for s in range(18)]
    e_slot = sum(frac[s] * B.slot_eff_mult(TABLE, s) for s in range(18))
    hf = B.peg_heat_factor(peg_t)
    H = max(hf * (b.hot * B.HOT_HEAT + b.cold * B.COLD_HEAT), -0.75)
    heat_mult = max(0.0, 1.0 + H)
    add = 1 + B.base_additive(badd_t)
    combo_mult = 1 + (b.combo * flat_frac(flat_t) if b.combo >= B.MIN_COMBO else 0.0)
    base = bet * e_slot * heat_mult * combo_mult
    banked = base * add + B.TRICKLE_FRAC * MAXBET
    return banked, e_slot, heat_mult, combo_mult, banked / bet


def evaluate(name, *, angle, size, elast, arc, peg_t, flat_t, badd_t=12, prefer_low_bet=False):
    b = nearest(angle, size, elast, arc, peg_t)
    # pick the better of max-bet vs min-bet for this build
    cands = []
    for bet in (MAXBET, MINBET):
        banked, e, hm, cb, mult = per_ball(b, badd_t=badd_t, flat_t=flat_t, peg_t=peg_t, bet=bet)
        cands.append((banked - bet, bet, banked, e, hm, cb, mult))
    net, bet, banked, e, hm, cb, mult = max(cands, key=lambda x: x[0])
    print(f"  {name:9}  e_slot={e:.2f}  heat×={hm:.2f}  combo×={cb:.2f}  "
          f"EVmult={mult:5.2f}  combo={b.combo:4.1f}  jph={b.jackpot_hit:.3f} hot={b.hot:.1f}")
    return net


def main():
    print(f"slot table {TABLE[:9]} J={B.JACKPOT_MULT}  (maxBet@t12={MAXBET:,.0f})\n")
    print("=== per-ball EV by archetype (relevant upgrades maxed) ===")
    # Hybrid: generic. No combo, no pegheat, no aim. Size 0.75 (tier0), centered.
    evaluate("hybrid", angle=0, size=0.75, elast=0.5, arc=5, peg_t=0, flat_t=0)
    # Chaos: big bouncy ball, wide sweep, combo (FlatRate maxed), low bet.
    evaluate("chaos", angle=0, size=1.0, elast=1.0, arc=80, peg_t=0, flat_t=12, prefer_low_bet=True)
    # Targeting: small ball, aimed, low sweep, jackpot/heat (PegHeat maxed), high bet.
    evaluate("targeting", angle=65, size=0.5, elast=0.0, arc=5, peg_t=12, flat_t=0)

    print("\n=== does aim actually reach the jackpot? jackpotHit by |angle| (size 0.5, arc 5) ===")
    for ang in (0, 65):
        sel = [b for b in BUILDS if abs(b.angle) == ang and b.size == 0.5 and b.arc == 5 and b.pegheat == 0]
        jph = sum(b.jackpot_hit * b.n for b in sel) / sum(b.n for b in sel)
        edge = sum((b.targets.get(0, 0) + b.targets.get(17, 0)) for b in sel) / sum(b.n for b in sel)
        print(f"  |angle|={ang:>3}: jackpotHit={jph:.3f}  edge-slot share={edge*100:.1f}%")

    print("\n=== does small ball / low sweep concentrate landings? (Gini-ish: top-2 slot share) ===")
    for name, (sz, ar, el) in {"small/tight": (0.5, 5, 0.0), "big/wide": (1.0, 80, 1.0)}.items():
        sel = [b for b in BUILDS if b.size == sz and b.arc == ar and b.elast == el and b.pegheat == 0]
        agg = [sum(b.targets.get(s, 0) for b in sel) for s in range(18)]
        tot = sum(agg)
        top2 = sum(sorted(agg, reverse=True)[:2]) / tot
        print(f"  {name:11}: top-2-slot share = {top2*100:.1f}%  (higher = more concentrated/aimable)")


if __name__ == "__main__":
    main()
