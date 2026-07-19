"""
Time-to-rebirth simulator for the CURRENT (2026-07) per-slot launch loop.

Loop model (mirrors BallLaunchService / ScoreHandler / BallPlotService):
  - Each owned slot with AUTO fires every launchDelay(FreqTier) seconds.
  - A launch SPENDS stake = betSize(selected zone tier). Ball value = stake x skin
    rarity mult (2^(r-1)) of the skin in that slot.
  - Bank: banked = value * E[slotMult] * heatMult (with BaseAdditive folded into the
    multipliers and the jackpot) + comboBonus + trickle, then x prestige x skin money
    mult. Claim (walk-over) assumed prompt -> credited immediately.
  - Rebirth at lifetimeBanked >= Scale * (CostBase*CostGrowth^n)^(1/Exponent);
    global mult x1.25 per rebirth; cash/upgrades reset (Luck persists, ignored run 1).

Landing data comes from a /geotest dump (tests/<file>), parsed by balance.py's parser.
Archetype = which builds we average landing stats over + which tracks the greedy
buyer may purchase.

Usage: python3 rebirth_sim.py [dumpfile] [--table name] [--quiet]
"""

from __future__ import annotations

import math
import os
import sys
from pathlib import Path

import balance as B

# ---------------------------------------------------------------------------
# LIVE config mirror (src/shared/Config, 2026-07-18) — keep in sync
# ---------------------------------------------------------------------------
START_BET = 10.0            # Economy.StartBetSize (zone tier 0)
START_MAX_BET = 40.0        # Economy.StartMaxBet (zone tier 1)
ZONE_PERTIER = 1.5          # Tracks.MaxBet.PerTier
TRICKLE_FRAC = 0.05         # Economy.TrickleFraction (x owned max bet, per bank)
STARTING_BALANCE = 1000.0

FLAT_BASE, FLAT_PERTIER = 0.2, 1.85
BADD_C1 = 0.05
FREQ_BASE, FREQ_PERTIER, FREQ_MAXTIER = 2.0, 0.82, 12
PEGHEAT_PERTIER = 0.05
MIN_COMBO = 17              # Scoring.MinCombo (live; balance.py's 5 is stale)
JACKPOT_MULT = 12.0
SLOT_HALF = [None, 2.6, 1.8, 1.3, 1.1, 0.62, 0.52, 0.45, 0.4]  # S5; None = jackpot
BADD_MAXTIER = 12

NUMSLOTS_MAXTIER = 9        # +9 -> 10 slots
AUTO_SWEEP = 0.25

PRESTIGE_SCALE, PRESTIGE_EXP = 18820.0, 0.35
PRESTIGE_COSTBASE, PRESTIGE_COSTGROWTH, PRESTIGE_MULTPER = 50.0, 1.1525, 1.25

# Cost curves (Base, Growth); price of tier t->t+1 = Base * Growth^t.
COST = {
    "MaxBet": (250.0, 1.9),
    "FlatRate": (260.0, 1.9),
    "BaseAdditive": (300.0, 1.7),
    "Frequency": (230.0, 1.9),
    "PegHeat": (220.0, 1.7),
    "NumSlots": (400.0, 2.2),
    "Elasticity": (1500.0, 4.5),
    "Size": (2000.0, 1.8),
    "Angle": (1500.0, 4.5),
    "Arc": (1500.0, 4.5),
}
AUTO_BASE, AUTO_GROWTH = 500.0, 2.0    # SlotAuto.PriceFor(slot)

# Side income (rough, deliberately coarse): coins ~ E[value]/spawn-interval.
# Coin EV ~ 50 + 25*6.8 = 220 per coin, every ~45 s -> ~5/s. Playtime rungs added at
# their timestamps. Obby ignored (one-time, optional).
COIN_RATE = 220.0 / 45.0
PLAYTIME_RUNGS = [(3 * 60, 1000), (15 * 60, 5000), (45 * 60, 20000), (90 * 60, 50000)]

# Skin table: (rolls, slots) -> (ballMult, moneyMult) at luck 0, E minus ~0.5 sd to be
# conservative (from skin_stats.py). Interpolated on rolls, nearest on slots.
SKIN_TABLE = {
    3:  [(25, 2.2, 1.19), (60, 3.1, 1.30), (150, 3.6, 1.47), (400, 5.3, 1.68), (900, 7.8, 2.11)],
    6:  [(25, 1.9, 1.36), (60, 2.5, 1.56), (150, 3.3, 1.78), (400, 3.9, 2.25), (900, 6.9, 2.89)],
    10: [(25, 1.5, 1.39), (60, 2.1, 1.84), (150, 3.1, 2.29), (400, 3.7, 3.04), (900, 5.6, 3.84)],
}
ROLL_INTERVAL = 8.0         # assumed seconds between free-box claims while playing


def rolls_at(T: float) -> float:
    """Cumulative free-box rolls after T seconds of play (piecewise cadence).
    Default mirrors a flat ROLL_INTERVAL; variants override FAST_ROLLS/FAST_INT/SLOW_INT
    to model a front-loaded cadence (quick early collection, slow long-tail)."""
    fast_n, fast_int, slow_int = ROLL_CADENCE
    if fast_int <= 0:
        return T / slow_int
    fast_T = fast_n * fast_int
    if T <= fast_T:
        return T / fast_int
    return fast_n + (T - fast_T) / slow_int


ROLL_CADENCE = (0, 0.0, ROLL_INTERVAL)   # (fast rolls, fast interval, slow interval)

BEGINNERS_LUCK = (1.15, 15 * 60)         # Economy.BeginnersLuck (run-1 only)


def skin_mults(rolls: float, slots: int) -> tuple[float, float]:
    k = min(SKIN_TABLE, key=lambda s: abs(s - slots))
    tab = SKIN_TABLE[k]
    if rolls <= tab[0][0]:
        f = rolls / tab[0][0]
        return 1 + (tab[0][1] - 1) * f, 1 + (tab[0][2] - 1) * f
    for (r0, b0, m0), (r1, b1, m1) in zip(tab, tab[1:]):
        if rolls <= r1:
            f = (rolls - r0) / (r1 - r0)
            return b0 + (b1 - b0) * f, m0 + (m1 - m0) * f
    return tab[-1][1], tab[-1][2]


# ---------------------------------------------------------------------------
# Derived stats
# ---------------------------------------------------------------------------
def bet_size(zone_tier: int) -> float:
    if zone_tier <= 0:
        return START_BET
    return START_MAX_BET * ZONE_PERTIER ** (zone_tier - 1)


def launch_delay(freq_tier: int) -> float:
    return max(1 / 60, FREQ_BASE * FREQ_PERTIER ** min(freq_tier, FREQ_MAXTIER))


def slot_eff(table_half, slot: int, jmult: float, badd: float) -> float:
    """Effective payout multiple of a ball landing in `slot`, additive folded in."""
    half = table_half + table_half[::-1]
    m = half[slot]
    if m is None:
        return 1.0 + jmult * (1 + badd)   # jackpot: base + base*J*(1+badd)
    return m * (1 + badd)


class Archetype:
    """Landing stats pooled over geotest builds matching `pred`, + allowed buys."""

    def __init__(self, name, builds, pred, tracks, pegheat_from_data=True):
        self.name = name
        self.tracks = tracks
        sel = [b for b in builds if b.n > 0 and pred(b)]
        assert sel, f"no geotest builds match archetype {name}"
        agg = [0.0] * 18
        tot = hot = cold = combo = 0.0
        for b in sel:
            for s, c in b.targets.items():
                agg[s] += c
            tot += b.n
            hot += b.hot * b.n
            cold += b.cold * b.n
            combo += b.combo * b.n
        self.frac = [a / tot for a in agg]
        self.hot, self.cold, self.combo = hot / tot, cold / tot, combo / tot
        self.n_builds = len(sel)
        self.n_balls = int(tot)

    def e_slot(self, table_half, jmult, badd, pegheat_tier, gate_open=True) -> float:
        e = 0.0
        for s in range(18):
            m = slot_eff(table_half, s, jmult, badd)
            if not gate_open and s in (0, 17):
                # Gate closed: the jackpot slot is walled off; the ball spills into the
                # neighboring edge slot instead.
                m = (table_half[1] or 1.0) * (1 + badd)
            e += self.frac[s] * m
        hf = PEGHEAT_PERTIER * pegheat_tier
        H = max(hf * (self.hot - self.cold), -0.75)   # mean-field heat
        return e * max(0.0, 1 + H)


# ---------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------
class Tunables:
    """Everything the balance pass may change, defaulting to LIVE values."""
    zone_pertier = ZONE_PERTIER
    cost = dict(COST)
    auto = (AUTO_BASE, AUTO_GROWTH)
    slot_half = SLOT_HALF
    jackpot_mult = JACKPOT_MULT
    badd_c1 = BADD_C1
    flat = (FLAT_BASE, FLAT_PERTIER)
    freq = (FREQ_BASE, FREQ_PERTIER, FREQ_MAXTIER)
    prestige = (PRESTIGE_SCALE, PRESTIGE_EXP, PRESTIGE_COSTBASE, PRESTIGE_COSTGROWTH, PRESTIGE_MULTPER)
    trickle_frac = TRICKLE_FRAC
    min_combo = MIN_COMBO
    starting_balance = STARTING_BALANCE
    zone_maxtier = 30
    vjack_frac = 0.55   # Economy.VJackFraction; gate opens iff ballMult >= this (betting max)
    name = "live"


def zone_bet(cfg, tier):
    if tier <= 0:
        return START_BET
    return START_MAX_BET * cfg.zone_pertier ** (tier - 1)


def sim_run(cfg: Tunables, arch: Archetype, prestige_n: int = 0, rolls0: float = 0.0,
            time0: float = 0.0, verbose=False, max_hours=6.0):
    """Simulate one rebirth run; returns (minutes, buys, end_tiers)."""
    scale, pexp, cbase, cgrow, multper = cfg.prestige
    threshold = scale * (cbase * cgrow ** prestige_n) ** (1 / pexp)
    prestige_mult = multper ** prestige_n

    tiers = {t: 0 for t in ("MaxBet", "FlatRate", "BaseAdditive", "Frequency", "PegHeat", "NumSlots")}
    autos = 1 if prestige_n == 0 else 1   # slot 1 auto must be bought too; start none owned
    autos = 0
    cash = cfg.starting_balance
    lifetime = 0.0
    t = 0.0
    dt = 1.0
    buys = []
    rung_i = sum(1 for rt, _ in PLAYTIME_RUNGS if rt <= time0)

    fb, fp = cfg.flat
    f0, fpt, fmx = cfg.freq

    def income(tiers, autos):
        """(cash/sec, lifetime/sec) with current tiers/autos."""
        slots_owned = 1 + tiers["NumSlots"]
        firing = min(autos, slots_owned)
        if firing == 0:
            firing = 1  # manual play: assume the player hand-fires ~1 slot's worth
        stake = zone_bet(cfg, tiers["MaxBet"])
        delay = max(1 / 60, f0 * fpt ** min(tiers["Frequency"], fmx))
        badd = cfg.badd_c1 * tiers["BaseAdditive"]
        rolls = rolls0 + rolls_at(time0 + t)
        ball_mult, money_mult = skin_mults(rolls, slots_owned)
        bl_mult, bl_secs = BEGINNERS_LUCK
        if time0 + t < bl_secs:
            money_mult *= bl_mult
        gate_open = ball_mult >= cfg.vjack_frac
        e_slot = arch.e_slot(cfg.slot_half, cfg.jackpot_mult, badd, tiers["PegHeat"], gate_open)
        combo_bonus = arch.combo * (fb * fp ** tiers["FlatRate"]) if arch.combo >= cfg.min_combo else 0.0
        trickle = cfg.trickle_frac * zone_bet(cfg, tiers["MaxBet"])
        banked = (stake * ball_mult * e_slot + combo_bonus + trickle) * prestige_mult * money_mult
        rate = firing / delay
        return (banked - stake) * rate + COIN_RATE, banked * rate

    def purchases(tiers, autos):
        out = []
        ab, ag = cfg.auto
        for tr in arch.tracks:
            cap = {"Frequency": fmx, "BaseAdditive": BADD_MAXTIER, "NumSlots": NUMSLOTS_MAXTIER,
                   "PegHeat": 12, "MaxBet": cfg.zone_maxtier}.get(tr, 30)
            if tiers[tr] < cap:
                base, gr = cfg.cost[tr]
                out.append((tr, base * gr ** tiers[tr]))
        if autos < 1 + tiers["NumSlots"]:
            out.append(("Auto", ab * ag ** autos))
        elif tiers["NumSlots"] < NUMSLOTS_MAXTIER:
            # A new slot only earns once its auto is owned too — price them as a bundle.
            sb, sg = cfg.cost["NumSlots"]
            out.append(("Slot+Auto", sb * sg ** tiers["NumSlots"] + ab * ag ** autos))
        return out

    while lifetime < threshold and t < 3600 * max_hours:
        cps, lps = income(tiers, autos)
        cash += cps * dt
        lifetime += lps * dt
        t += dt
        while rung_i < len(PLAYTIME_RUNGS) and time0 + t >= PLAYTIME_RUNGS[rung_i][0]:
            cash += PLAYTIME_RUNGS[rung_i][1]
            rung_i += 1
        # First auto is a QoL buy with ~0 marginal income in this model (manual play
        # covers one slot) — a real player buys it ASAP anyway; force it.
        if autos == 0:
            ab, ag = cfg.auto
            if cash >= ab:
                cash -= ab
                autos = 1
                buys.append((round(t), "Auto"))
        # Greedy best-ROI purchase, repeated while affordable.
        bought = True
        while bought:
            bought = False
            base_c, _ = income(tiers, autos)
            best, best_roi, best_cost = None, 1e-7, 0.0
            for tr, cost in purchases(tiers, autos):
                if cost > cash:
                    continue
                if tr == "Auto":
                    nc, _ = income(tiers, autos + 1)
                elif tr == "Slot+Auto":
                    tiers["NumSlots"] += 1
                    nc, _ = income(tiers, autos + 1)
                    tiers["NumSlots"] -= 1
                else:
                    tiers[tr] += 1
                    nc, _ = income(tiers, autos)
                    tiers[tr] -= 1
                roi = (nc - base_c) / cost
                if roi > best_roi:
                    best, best_roi, best_cost = tr, roi, cost
            if best:
                cash -= best_cost
                if best == "Auto":
                    autos += 1
                elif best == "Slot+Auto":
                    tiers["NumSlots"] += 1
                    autos += 1
                else:
                    tiers[best] += 1
                buys.append((round(t), best))
                bought = True
    return t / 60, buys, tiers, autos


def run_report(cfg: Tunables, arch: Archetype, n_rebirths=5, quiet=False):
    t_total = 0.0
    times = []
    for n in range(n_rebirths):
        mins, buys, tiers, autos = sim_run(cfg, arch, prestige_n=n, time0=t_total * 60)
        times.append(mins)
        t_total += mins
        if not quiet and n == 0:
            first = ", ".join(f"{b}@{s}s" for s, b in buys[:12])
            print(f"    run1 buys: {first}")
            print(f"    run1 end: tiers={tiers} autos={autos}")
    return times


def variant(name: str, **over) -> Tunables:
    cfg = Tunables()
    cfg.name = name
    for k, v in over.items():
        if k in ("cost",):
            merged = dict(COST)
            merged.update(v)
            v = merged
        setattr(cfg, k, v)
    return cfg


def compare(builds, cfgs, n_rebirths=6):
    archs = make_archetypes(builds)
    for arch in archs:
        print(f"== {arch.name} ({arch.n_builds} builds / {arch.n_balls} balls) "
              f"combo={arch.combo:.1f} hot={arch.hot:.1f} cold={arch.cold:.1f} ==")
        for cfg in cfgs:
            global ROLL_CADENCE
            ROLL_CADENCE = getattr(cfg, "cadence", (0, 0.0, ROLL_INTERVAL))
            e0 = arch.e_slot(cfg.slot_half, cfg.jackpot_mult, 0.0, 0)
            t_total = 0.0
            times = []
            for n in range(n_rebirths):
                mins, _, _, _ = sim_run(cfg, arch, prestige_n=n, time0=t_total * 60)
                times.append(mins)
                t_total += mins
            print(f"  {cfg.name:<22} E0[slot]={e0:5.3f} | " +
                  "  ".join(f"{m:5.1f}" for m in times))
    print()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    quiet = "--quiet" in sys.argv
    fname = args[0] if args else os.environ.get("GEOTEST", "2026-07-18.txt")
    builds = B.parse(Path(__file__).resolve().parent.parent / "tests" / fname)
    print(f"# {fname}: {len(builds)} builds")

    if "--search" in sys.argv:
        compare(builds, search_variants())
        return

    archs = make_archetypes(builds)
    cfg = Tunables()
    cfg.name = "live"
    for arch in archs:
        print(f"== {arch.name} ({arch.n_builds} builds / {arch.n_balls} balls) "
              f"combo={arch.combo:.1f} hot={arch.hot:.1f} ==")
        e0 = arch.e_slot(cfg.slot_half, cfg.jackpot_mult, 0.0, 0)
        print(f"    E[slot] (no upgrades) = {e0:.3f}")
        times = run_report(cfg, arch, quiet=quiet)
        print("    rebirth times (min): " + "  ".join(f"{m:.1f}" for m in times))


def proposed() -> Tunables:
    """The 2026-07 rebalance proposal (see BALANCE_RESULTS.md)."""
    cfg = variant("proposed",
        zone_pertier=4.0,
        cost={
            "MaxBet": (2000.0, 5.0),
            "NumSlots": (400.0, 6.0),
            "Frequency": (800.0, 3.4),
            "FlatRate": (600.0, 2.9),
            "BaseAdditive": (600.0, 2.9),
            "PegHeat": (480.0, 2.9),
        },
        auto=(500.0, 6.0),
        min_combo=14,
        vjack_frac=2.5,
        freq=(2.0, 0.88, 8),
        starting_balance=1500.0,
        prestige=(18820.0 * 15000, 0.35, 50.0, 2.4, 1.15))
    cfg.cadence = (40, 10, 90)   # free-box: 40 quick claims (~10s), then ~90s
    return cfg


def search_variants():
    """Candidate configs for the balance pass — edit freely while iterating."""
    return [variant("live"), proposed()]


def make_archetypes(builds):
    # Tuning bins come from the sweep grid; adjust after inspecting the dump.
    # PegHeat tiers don't change trajectories — pool across them for sample size.
    chaos = Archetype(
        "chaos", builds,
        pred=lambda b: b.elast >= 0.9 and b.size >= 0.9 and abs(b.angle) < 1,
        tracks=["MaxBet", "FlatRate", "Frequency", "NumSlots", "BaseAdditive"],
    )
    targeting = Archetype(
        "targeting", builds,
        pred=lambda b: abs(b.angle) >= 60 and b.size <= 0.6,
        tracks=["MaxBet", "PegHeat", "Frequency", "NumSlots", "BaseAdditive"],
    )
    return [chaos, targeting]


if __name__ == "__main__":
    main()
