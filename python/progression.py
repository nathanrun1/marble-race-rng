"""
Progression / time-to-first-prestige simulator.

Deterministic EV sim: the player auto-launches at the launch-delay rate, always bets
max, and greedily buys whichever upgrade gives the best income-ROI it can afford.
Income and lifetime-banked accrue at the launch rate (balls are pipelined, per the
request to assume reward at frequency rate). We stop when lifetimeBanked reaches the
first-prestige threshold and report wall-clock time.

Everything tunable (slot table, BaseAdditive curve, prices, frequency, prestige
threshold) is a parameter so we can search for a ~30-minute first prestige.

Run AFTER balance.py (reuses its parser to get per-build landing/geometry data).
"""

from __future__ import annotations

from pathlib import Path
import balance as B

# --- data-derived landing distributions & geometry by (size-bin, pegheat-tier) ---
import os
_TEST = os.environ.get("GEOTEST", "2026-06-26.txt")
BUILDS = B.parse(Path(__file__).resolve().parent.parent / "tests" / _TEST)


def bin_stats(size_small: bool, pegheat: int):
    """Avg landing dist + hot/cold/combo over builds matching a size bin & pegheat tier."""
    sel = [b for b in BUILDS
           if b.pegheat == pegheat and ((b.size == 0.5) if size_small else (b.size == 0.75))]
    agg = [0.0] * 18
    tot = hot = cold = combo = 0.0
    for b in sel:
        for s, c in b.targets.items():
            agg[s] += c
        tot += b.n
        hot += b.hot * b.n
        cold += b.cold * b.n
        combo += b.combo * b.n
    frac = [a / tot for a in agg]
    return frac, hot / tot, cold / tot, combo / tot


# Precompute the four corners we interpolate/pick between.
STATS = {(small, ph): bin_stats(small, ph) for small in (False, True) for ph in (0, 6, 12)}


def nearest_ph(ph_tier: int) -> int:
    return min((0, 6, 12), key=lambda k: abs(k - ph_tier))


# ---------------------------------------------------------------------------
# Config under test (defaults mirror the live game; override to test changes)
# ---------------------------------------------------------------------------
class Cfg:
    slot_half = B.SLOT_BASE_HALF
    jackpot_mult = B.JACKPOT_MULT
    # BaseAdditive curve coeffs (Base, C1, C2, C3)
    badd = (B.BADD_BASE, B.BADD_C1, B.BADD_C2, B.BADD_C3)
    # cost overrides {track: (base, growth)}; falls back to B.COST
    cost = dict(B.COST)
    freq_base, freq_pertier, freq_maxtier = B.FREQ_BASE, B.FREQ_PERTIER, B.FREQ_MAXTIER
    maxbet_pertier = B.MAXBET_PERTIER
    trickle_frac = B.TRICKLE_FRAC
    prestige_scale, prestige_exp, prestige_costbase = B.PRESTIGE_SCALE, B.PRESTIGE_EXP, B.PRESTIGE_COSTBASE


def badd(cfg, t):
    a, c1, c2, c3 = cfg.badd
    return a + c1 * t + c2 * t**2 + c3 * t**3


def max_bet(cfg, t):
    return B.START_MAX_BET * (cfg.maxbet_pertier ** t)


def launch_delay(cfg, t):
    return max(1 / 60, cfg.freq_base * (cfg.freq_pertier ** t))


def cost_to_raise(cfg, track, frm):
    base, growth = cfg.cost[track]
    return base * (growth ** frm)


MIN_BET = 10.0  # Config.LoadoutDefaults.Bet


def banked_for_bet(cfg, tiers, bet):
    """EV banked for one ball at the current tiers for a chosen bet (value)."""
    small = tiers["Size"] > 0
    frac, hot, cold, combo = STATS[(small, nearest_ph(tiers["PegHeat"]))]
    table = cfg.slot_half + cfg.slot_half[::-1]
    e_slot = sum(frac[s] * B.slot_eff_mult(table, s, cfg.jackpot_mult) for s in range(18))

    hf = B.PEGHEAT_PERTIER * tiers["PegHeat"]
    H = max(hf * (hot * B.HOT_HEAT + cold * B.COLD_HEAT), -0.75)
    heat_mult = max(0.0, 1.0 + H)

    add = 1 + badd(cfg, tiers["BaseAdditive"])
    per_value = e_slot * heat_mult * add                       # marginal banked per unit bet
    combo_bonus = (combo * B.flat_per_bounce(tiers["FlatRate"]) if combo >= B.MIN_COMBO else 0.0) * add
    trickle = cfg.trickle_frac * max_bet(cfg, tiers["MaxBet"])  # flat, bet-independent
    banked = bet * per_value + combo_bonus + trickle
    return banked, per_value


def rates(cfg, tiers):
    """Optimal bet: max if each marginal bet unit is +EV (per_value>1), else min (harvest trickle)."""
    mx = max_bet(cfg, tiers["MaxBet"])
    _, per_value = banked_for_bet(cfg, tiers, mx)
    bet = mx if per_value >= 1.0 else MIN_BET
    banked, _ = banked_for_bet(cfg, tiers, bet)
    d = launch_delay(cfg, tiers["Frequency"])
    return banked / d, (banked - bet) / d   # lifetime/sec, net cash/sec


TRACKS = ["MaxBet", "BaseAdditive", "FlatRate", "PegHeat", "Frequency", "Size"]
TIER_CAP = {"Frequency": 12, "Size": 12, "MaxBet": 30, "BaseAdditive": 12,
            "FlatRate": 30, "PegHeat": 12}  # FlatRate uncapped (no MaxTier in Config)


# Obby seed: a one-time bootstrap. A build must be self-sustaining after this — no drip,
# so we verify the player isn't forced to keep farming the obby for momentum.
OBBY_SEED = 600.0          # ~ one hard obby + an easy one
OBBY_DRIP = 0.0


def simulate(cfg, target_minutes=30, verbose=False):
    tiers = {t: 0 for t in TRACKS}
    balance = OBBY_SEED
    lifetime = 0.0
    t = 0.0
    threshold = cfg.prestige_scale * (cfg.prestige_costbase ** (1 / cfg.prestige_exp))
    dt = 0.5
    buys = []
    while lifetime < threshold and t < 3600 * 6:
        life_rate, cash_rate = rates(cfg, tiers)
        balance += (cash_rate + OBBY_DRIP) * dt
        lifetime += life_rate * dt
        t += dt
        # Greedy: best income-ROI upgrade we can afford.
        best, best_roi = None, 0.0
        base_life, _ = rates(cfg, tiers)
        for tr in TRACKS:
            if tiers[tr] >= TIER_CAP[tr]:
                continue
            c = cost_to_raise(cfg, tr, tiers[tr])
            if c > balance:
                continue
            tiers[tr] += 1
            nl, _ = rates(cfg, tiers)
            tiers[tr] -= 1
            roi = (nl - base_life) / c
            if roi > best_roi:
                best, best_roi = tr, roi
        if best:
            balance -= cost_to_raise(cfg, best, tiers[best])
            tiers[best] += 1
            if verbose:
                buys.append((round(t), best, tiers[best]))
    mins = t / 60
    return mins, tiers, lifetime, threshold, buys


class Proposed(Cfg):
    # Avenue 2: house-edge slot table -> no-build base E[mult] < 1 (bet-spam bleeds).
    # The jackpot (rare edge, ~3.6%) dominated E[mult], so it's pulled down hardest.
    slot_half = [20, 2.2, 1.1, 0.55, 0.35, 0.25, 0.17, 0.12, 0.08]
    jackpot_mult = 12
    # Avenue 1: flatten the absurd cubic BaseAdditive (was x26 at t12) to linear +5%/tier.
    badd = (0.0, 0.05, 0.0, 0.0)
    # Avenue 1: slow the compounding. Bet grows 1.5x/tier (was 4.05), cost 1.9x/tier.
    maxbet_pertier = 1.5
    cost = dict(B.COST)  # already mirrors live config
    # Frequency: gentler throughput gains.
    freq_pertier = 0.82
    prestige_costbase = 50.0  # tuned for ~30 min first prestige (post launch-speed change)


def report(label, cfg):
    # no-build per-ball EV under this slot table (tier-0 additive 1+badd(t0)).
    frac, hot, cold, combo = STATS[(False, 0)]
    table = cfg.slot_half + cfg.slot_half[::-1]
    e_slot = sum(frac[s] * B.slot_eff_mult(table, s, cfg.jackpot_mult) for s in range(18))
    nobuild_mult = e_slot * (1 + badd(cfg, 0))
    mins, tiers, lifetime, thr, buys = simulate(cfg, verbose=True)
    print(f"=== {label} ===")
    print(f"  no-build E[slot]={e_slot:.3f}  EV multiple={nobuild_mult:.3f} "
          f"+trickle {cfg.trickle_frac:.3f} -> net/Bet {nobuild_mult + cfg.trickle_frac - 1:+.3f} "
          f"({'EXPLOIT' if nobuild_mult + cfg.trickle_frac > 1 else 'ok, bleeds'})")
    print(f"  time to first prestige: {mins:.1f} min   (threshold LB={thr:,.0f})")
    print(f"  end tiers: {tiers}")
    print(f"  first 14 buys: {buys[:14]}\n")


def main():
    report("CURRENT", Cfg)
    report("PROPOSED", Proposed)


if __name__ == "__main__":
    main()
