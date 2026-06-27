"""
Marble-race economy analysis off a /geotest dump.

Goal: figure out why "spam max bet, upgrade max bet, repeat" is a viable no-build
strategy, and what to change. The core fact (see BallLaunchService): each launch is
ONE ball, value = Bet, and it costs Bet. So per ball:

    net = banked - Bet,   banked = value * E[mult] * (1+additive) + comboBonus + trickle

Because value == cost == Bet, the per-ball EV *multiple* (banked/Bet) is independent
of Bet size. If that multiple > 1 for the no-build loadout, then ANY bet is +EV and
bigger bets just scale the profit — which is exactly the exploit. Pricing can't fix
that; only the slot multipliers / geometry / heat (the things that set E[mult]) can.

This script:
  1. Parses each build's slot histogram + geometry means.
  2. Confirms which slots are the jackpot (20x) slots.
  3. Computes the per-ball EV multiple for the no-build loadout vs real builds,
     under the current slot table — and lets us try alternative slot tables.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# Game config mirror (keep in sync with src/shared/Config.luau)
# ---------------------------------------------------------------------------
# Mirrors the live Config after the rebalance.
START_MAX_BET = 40.0
MAXBET_PERTIER = 1.5
FLATRATE_BASE, FLATRATE_PERTIER = 0.2, 1.85  # tiny base (no early carry) + steep uncapped ramp
BADD_BASE, BADD_C1, BADD_C2, BADD_C3 = 0.0, 0.05, 0.0, 0.0
FREQ_BASE, FREQ_PERTIER, FREQ_MAXTIER = 2.0, 0.82, 12
PEGHEAT_PERTIER = 0.05
TRICKLE_FRAC = 0.01
JACKPOT_MULT = 12.0
MIN_COMBO = 5
HOT_HEAT, COLD_HEAT = 1.0, -1.0
PRESTIGE_SCALE, PRESTIGE_EXP, PRESTIGE_COSTBASE = 10000.0, 0.35, 50.0
BASE_GROWTH = 4.5

# Cost curves: price to buy tier t -> t+1 is Base * Growth^t.
COST = {
    "MaxBet": (250.0, 1.9),
    "FlatRate": (260.0, 1.9),
    "BaseAdditive": (300.0, 1.7),
    "Frequency": (230.0, 1.9),
    "PegHeat": (220.0, 1.7),
    "Arc": (105.0, BASE_GROWTH),
    "Angle": (105.0, BASE_GROWTH),
    "Size": (200.0, 1.8),
    "Elasticity": (105.0, BASE_GROWTH),
}

# Slot multipliers, 18 slots (palindrome). Jackpot slots pay via the jackpot mechanic
# (base += base*JACKPOT_MULT => effective (1+JACKPOT_MULT)x), the rest via PointMul.
SLOT_BASE_HALF = [20, 2.2, 1.1, 0.55, 0.35, 0.25, 0.17, 0.12, 0.08]  # live (Config.DestroyTargets)
SLOT_MULTS = SLOT_BASE_HALF + SLOT_BASE_HALF[::-1]   # len 18
JACKPOT_SLOTS = {0, 17}


def max_bet(tier: int) -> float:
    return START_MAX_BET * (MAXBET_PERTIER ** tier)


def flat_per_bounce(tier: int) -> float:
    return FLATRATE_BASE * (FLATRATE_PERTIER ** tier)


def base_additive(tier: int) -> float:
    return BADD_BASE + BADD_C1 * tier + BADD_C2 * tier**2 + BADD_C3 * tier**3


def launch_delay(tier: int) -> float:
    return max(1 / 60, FREQ_BASE * (FREQ_PERTIER ** tier))


def peg_heat_factor(tier: int) -> float:
    return PEGHEAT_PERTIER * tier


def cost_to_raise(track: str, from_tier: int) -> float:
    base, growth = COST[track]
    return base * (growth ** from_tier)


def prestige_points(lifetime_banked: float) -> float:
    return (lifetime_banked / PRESTIGE_SCALE) ** PRESTIGE_EXP


def lifetime_for_pp(pp: float) -> float:
    return PRESTIGE_SCALE * (pp ** (1 / PRESTIGE_EXP))


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------
@dataclass
class Build:
    idx: int
    bet: float
    arc: float
    angle: float
    size: float
    elast: float
    pegheat: int
    hot: float
    cold: float
    neutral: float
    combo: float
    jackpot_hit: float
    targets: dict[int, int] = field(default_factory=dict)
    n: int = 0  # resolved balls (sum of target counts)


HEADER_RE = re.compile(
    r"\[\s*(\d+)/\d+\]\s*Bet=\s*([\d.]+)\s*Arc=\s*(-?[\d.]+)°\s*Angle=\s*(-?[\d.]+)°\s*"
    r"Size=([\d.]+)\s*Elast=([\d.]+)\s*PegHeat=(\d+)"
)
STAT_RE = re.compile(r"(hotPegs|coldPegs|neutralPegs|combo|jackpotHit)\s+mean=\s*(-?[\d.]+)")
TARGETS_RE = re.compile(r"targets:\s*(.+?)\s*(?:-\s*Server|$)")


def parse(path: Path) -> list[Build]:
    builds: list[Build] = []
    cur: Build | None = None
    for line in path.read_text().splitlines():
        h = HEADER_RE.search(line)
        if h:
            cur = Build(
                idx=int(h[1]), bet=float(h[2]), arc=float(h[3]), angle=float(h[4]),
                size=float(h[5]), elast=float(h[6]), pegheat=int(h[7]),
                hot=0, cold=0, neutral=0, combo=0, jackpot_hit=0,
            )
            builds.append(cur)
            continue
        if cur is None:
            continue
        s = STAT_RE.search(line)
        if s:
            val = float(s[2])
            setattr(cur, {"hotPegs": "hot", "coldPegs": "cold", "neutralPegs": "neutral",
                          "combo": "combo", "jackpotHit": "jackpot_hit"}[s[1]], val)
            continue
        t = TARGETS_RE.search(line)
        if t:
            for tok in t[1].split():
                k, _, v = tok.partition(":")
                if k == "?":
                    continue
                cur.targets[int(k)] = int(v)
            cur.n = sum(cur.targets.values())
    return builds


# ---------------------------------------------------------------------------
# EV model
# ---------------------------------------------------------------------------
def slot_eff_mult(slot_mults: list[float], slot: int, jackpot_mult: float = JACKPOT_MULT) -> float:
    if slot in JACKPOT_SLOTS:
        return 1.0 + jackpot_mult          # jackpot mechanic on base=value
    return slot_mults[slot]


def expected_slot_mult(b: Build, slot_mults: list[float]) -> float:
    """E[mult] over the destroy-target histogram (the slot part of the payout)."""
    if b.n == 0:
        return 0.0
    tot = 0.0
    for slot, cnt in b.targets.items():
        tot += cnt * slot_eff_mult(slot_mults, slot)
    return tot / b.n


def ev_multiple(b: Build, slot_mults: list[float], badd_tier: int, flat_tier: int,
                pegheat_tier: int | None = None) -> float:
    """
    Per-ball banked / value (the EV multiple). value cancels Bet, so this >1 means
    the loadout is net +EV regardless of bet size (the exploit condition), ignoring
    the small trickle which adds TRICKLE_FRAC * maxBet/value on top.

    Approximations (mean-based; we lack per-ball trajectories):
      - heat: H ~ heatFactor*(hot*HOT + cold*COLD), clamped >=0; payout *max(0,1+H).
      - combo: only pays if mean combo >= MIN_COMBO (step at the mean).
    """
    ph = b.pegheat if pegheat_tier is None else pegheat_tier
    e_slot = expected_slot_mult(b, slot_mults)

    # Heat multiplier on the base payout.
    hf = peg_heat_factor(ph)
    H = max(hf * (b.hot * HOT_HEAT + b.cold * COLD_HEAT), -0.75)
    heat_mult = max(0.0, 1.0 + H)

    base_payout = e_slot * heat_mult                       # multiples of value
    combo_bonus = (b.combo * flat_per_bounce(flat_tier)) if b.combo >= MIN_COMBO else 0.0
    banked = base_payout + combo_bonus                     # combo_bonus is absolute pts...
    # combo_bonus is absolute points, not a multiple of value; but value (=Bet) here is
    # large, so as a multiple it's combo_bonus/value -> negligible unless value is tiny.
    # We report the multiple assuming value = bet of this build:
    banked_mult = base_payout * (1 + base_additive(badd_tier)) \
        + (combo_bonus / b.bet if b.bet else 0.0)
    return banked_mult


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
def closest(builds, *, angle, size, elast, arc, pegheat):
    """Nearest build to a target loadout (the sweep only samples a grid)."""
    def key(b):
        return (b.pegheat != pegheat, abs(b.angle) - 0 if False else 0,
                abs(b.angle - angle), abs(b.size - size), abs(b.elast - elast), abs(b.arc - arc))
    return min(builds, key=key)


def main():
    import sys
    fname = sys.argv[1] if len(sys.argv) > 1 else "2026-06-25.txt"
    path = Path(__file__).resolve().parent.parent / "tests" / fname
    print(f"# {fname}")
    builds = parse(path)
    print(f"parsed {len(builds)} builds, {builds[0].n} balls each\n")

    # --- confirm jackpot slots: jackpotHit*N vs count[0]+count[17] ---
    err = 0.0
    for b in builds:
        edge = b.targets.get(0, 0) + b.targets.get(17, 0)
        err += abs(edge - b.jackpot_hit * b.n)
    print(f"jackpot-slot check: mean |count[0]+count[17] - jackpotHit*N| = {err/len(builds):.2f} balls")
    print("(near 0 confirms slots 0 & 17 are the 20x jackpot targets)\n")

    # --- no-build loadout proxy: tier-0 axes (Angle 0, Size 0.75, Elast 0.5, Arc 15),
    #     PegHeat 0, and the max bet. Sweep grid -> nearest is Arc=5. ---
    nobuild = closest(builds, angle=0, size=0.75, elast=0.5, arc=5, pegheat=0)
    # no-build only buys MaxBet, so BaseAdditive tier 0, FlatRate tier 0.
    e_slot = expected_slot_mult(nobuild, SLOT_MULTS)
    mult = ev_multiple(nobuild, SLOT_MULTS, badd_tier=0, flat_tier=0)
    print("=== NO-BUILD (spam max bet) ===")
    print(f"  proxy build #{nobuild.idx}: Angle={nobuild.angle} Size={nobuild.size} "
          f"Elast={nobuild.elast} Arc={nobuild.arc} PegHeat=0")
    print(f"  E[slot mult]           = {e_slot:.3f}")
    print(f"  EV multiple (banked/Bet)= {mult:.3f}  + trickle {TRICKLE_FRAC:.3f}")
    print(f"  -> net per ball / Bet   = {mult + TRICKLE_FRAC - 1:+.3f}  "
          f"({'PROFITABLE - exploit' if mult + TRICKLE_FRAC > 1 else 'net loss - ok'})\n")

    # --- distribution of EV multiple across ALL swept builds (real builds use their
    #     own pegheat tier; for additive/flat we assume maxed since a real build buys them) ---
    rows = []
    for b in builds:
        m = ev_multiple(b, SLOT_MULTS, badd_tier=12, flat_tier=12) + TRICKLE_FRAC
        rows.append((m, b))
    rows.sort(key=lambda r: r[0], reverse=True)
    print("=== TOP 5 builds by EV multiple (additive/flat maxed) ===")
    for m, b in rows[:5]:
        print(f"  x{m:6.2f}  Angle={b.angle:>4} Arc={b.arc:>4} Size={b.size} "
              f"Elast={b.elast} PegHeat={b.pegheat}  E[slot]={expected_slot_mult(b, SLOT_MULTS):.2f} "
              f"hot={b.hot:.1f} combo={b.combo:.1f}")
    print(f"\n  median EV multiple across builds: {sorted(r[0] for r in rows)[len(rows)//2]:.2f}")
    print(f"  min / max: {rows[-1][0]:.2f} / {rows[0][0]:.2f}")

    # E[slot mult] just from geometry (no upgrades) across builds — shows how much the
    # slot table alone pays for different aim, the lever for no-build EV.
    geos = sorted(expected_slot_mult(b, SLOT_MULTS) for b in builds if b.pegheat == 0)
    print(f"\n  E[slot mult] (geometry only, PegHeat=0): "
          f"min={geos[0]:.2f} median={geos[len(geos)//2]:.2f} max={geos[-1]:.2f}")

    # --- landing distribution by aim (PegHeat=0), to see which slots each aim hits ---
    print("\n=== landing fraction by slot, by |Angle| (PegHeat=0) ===")
    print("  slot:  " + " ".join(f"{s:>5}" for s in range(18)))
    print("  mult:  " + " ".join(f"{slot_eff_mult(SLOT_MULTS, s):>5.2f}" for s in range(18)))
    bins = {
        "aim0  ": lambda b: b.angle == 0,
        "aim65 ": lambda b: abs(b.angle) == 65,
        "size.5": lambda b: b.size == 0.5,
        "sz.75 ": lambda b: b.size == 0.75,
        "size1 ": lambda b: b.size == 1.0,
        "nobild": lambda b: b.angle == 0 and b.size == 0.75,   # tier-0 axes
    }
    dists = {}
    for name, pred in bins.items():
        agg = [0] * 18
        tot = 0
        for b in builds:
            if b.pegheat == 0 and pred(b):
                for s, c in b.targets.items():
                    agg[s] += c
                    tot += c
        frac = [a / tot for a in agg]
        dists[name] = frac
        print(f"  {name}: " + " ".join(f"{f*100:>5.1f}" for f in frac))

    def e_mult_from_frac(frac, slot_mults, jmult=JACKPOT_MULT):
        return sum(frac[s] * slot_eff_mult(slot_mults, s, jmult) for s in range(18))

    print("\n=== candidate slot tables: E[slot mult] for aim0 (no-build) vs aim65 ===")
    print("  target: aim0 * 1.05 + 0.01 (trickle) < 1.0 ; aim65 comfortably > 1.0")
    candidates = {
        "current [20,5,2,1.25,1,.75,.5,.5,.25] J=20": (SLOT_BASE_HALF, 20),
        "softer mids [J,3,1.5,.8,.5,.35,.25,.2,.15] J=20": ([20, 3, 1.5, 0.8, 0.5, 0.35, 0.25, 0.2, 0.15], 20),
        "house-edge [J,2.5,1.2,.6,.4,.3,.2,.15,.1] J=15": ([20, 2.5, 1.2, 0.6, 0.4, 0.3, 0.2, 0.15, 0.1], 15),
        "steep [J,2,1,.5,.3,.2,.15,.1,.08] J=12": ([20, 2, 1, 0.5, 0.3, 0.2, 0.15, 0.1, 0.08], 12),
    }
    for label, (half, jm) in candidates.items():
        table = half + half[::-1]
        nb = e_mult_from_frac(dists["nobild"], table, jm)
        s5 = e_mult_from_frac(dists["size.5"], table, jm)
        nobuild_net = nb * 1.05 + 0.01
        print(f"  {label}")
        print(f"      no-build E[mult]={nb:.3f} -> net/Bet={nobuild_net-1:+.3f}"
              f"   |   size0.5 E[mult]={s5:.3f}")


if __name__ == "__main__":
    main()
