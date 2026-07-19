"""
EV / Var of the equipped-loadout skin multipliers as a function of rolls made.

The free box (Config/Crates.Free) is claimable every ~2s; players actually claim at
some slower cadence, so everything is reported per ROLL COUNT N — the progression sim
maps time -> N with an assumed claim cadence.

Two outputs per (N, luck tier, slots k):
  ballMult  : mean over the k equipped slots of RarityBetFactor^(rarity-1)
              (each slot's launched ball value = stake x this) -> E and sd.
  moneyMult : 1 + sum over slots of RarityBonus[r] * StarMults[star]
              (the global banked multiplier from LoadoutService) -> E and sd.

Loadout = BestLoadout mirror: top-k DISTINCT owned skins by money bonus (ties by
rarity); duplicates star skins up (StarDupes thresholds).

Roll model mirrors CosmeticService/WeightedRandom.PickIndexLuckBiased:
  pick = T * U^(1/(1+luck)) walked over cumulative weights (rarity 1..9),
  skin uniform within rarity (counts from BallSkins). The Free box has no Pity in
  config (only paid boxes carry one), so none is applied.

Stdlib-only (no numpy in this environment).
"""

from __future__ import annotations
import math
import random
from bisect import bisect_left

# --- Config mirror (src/shared/Config) -------------------------------------
FREE_WEIGHTS = [75, 20, 4.5, 0.5, 0.08, 0.015, 0.004, 0.001, 0.0002]
RARITY_BONUS = [0.02, 0.05, 0.12, 0.30, 0.75, 1.8, 4, 9, 20]
STAR_DUPES = [0, 1, 3, 6, 10]           # dupes needed for star 1..5
STAR_MULTS = [1, 1.5, 2, 3, 4]
RARITY_BET_FACTOR = 2.0
SKINS_PER_RARITY = [5, 5, 12, 11, 9, 5, 5, 4, 4]   # BallSkins census
LUCK_GROWTH = 1.19

rng = random.Random(7)


def luck_at(tier: int) -> float:
    return LUCK_GROWTH ** tier - 1


def rarity_cdf(luck: float) -> list[float]:
    """Cumulative P(rarity <= i) of one luck-biased roll (exact)."""
    T = sum(FREE_WEIGHTS)
    cum, c = [], 0.0
    for w in FREE_WEIGHTS:
        c += w
        cum.append((c / T) ** (1 + luck))
    cum[-1] = 1.0
    return cum


def star_of(copies: int) -> int:
    dupes = copies - 1
    for k in range(len(STAR_DUPES), 0, -1):
        if dupes >= STAR_DUPES[k - 1]:
            return k
    return 1


def simulate(n_rolls: int, luck: float, slots: int, trials: int = 1500):
    cdf = rarity_cdf(luck)
    ball_mults, money_mults = [], []
    for _ in range(trials):
        owned: dict[tuple[int, int], int] = {}   # (rarity, skinIdx) -> copies
        for _ in range(n_rolls):
            r = bisect_left(cdf, rng.random()) + 1
            key = (r, rng.randrange(SKINS_PER_RARITY[r - 1]))
            owned[key] = owned.get(key, 0) + 1
        entries = sorted(
            ((RARITY_BONUS[r - 1] * STAR_MULTS[star_of(n) - 1], r) for (r, _), n in owned.items()),
            reverse=True,
        )[:slots]
        # empty slots (fewer owned than slots) fire the default common skin (x1)
        mults = [RARITY_BET_FACTOR ** (r - 1) for _, r in entries] + [1.0] * (slots - len(entries))
        ball_mults.append(sum(mults) / slots)
        money_mults.append(1.0 + sum(b for b, _ in entries))
    return ball_mults, money_mults


def mean_sd(xs: list[float]) -> tuple[float, float]:
    m = sum(xs) / len(xs)
    v = sum((x - m) ** 2 for x in xs) / len(xs)
    return m, math.sqrt(v)


def main():
    print(f"{'rolls':>6} {'luckT':>5} {'slots':>5} | {'E[ballMult]':>11} {'sd':>7} | {'E[moneyX]':>9} {'sd':>7}")
    for n in (25, 60, 150, 400, 900):
        for luck_tier in (0, 4, 8, 12):
            for slots in (3, 6, 10):
                bm, mm = simulate(n, luck_at(luck_tier), slots)
                bmm, bms = mean_sd(bm)
                mmm, mms = mean_sd(mm)
                print(f"{n:>6} {luck_tier:>5} {slots:>5} | {bmm:>11.2f} {bms:>7.2f} | {mmm:>9.2f} {mms:>7.2f}")
        print()


if __name__ == "__main__":
    main()
