# Balance Results — 2026-07 proposal

Sim-derived (python/rebirth_sim.py, `proposed()` variant; geotest tests/2026-07-18.txt,
486 builds / 12,150 balls). NOT yet applied to configs.

## Config changes

| Config | Key | Live | Proposed |
|---|---|---|---|
| Economy | StartingBalance | 1000 | **1500** |
| Economy | VJackFraction | 0.55 | **2.5** |
| Upgrades.MaxBet (Zone) | PerTier | 1.5 | **4.0** |
| Upgrades.MaxBet | Cost | 250 × 1.9^t | **2000 × 5.0^t** |
| Upgrades.Frequency | PerTier / MaxTier | 0.82 / 12 | **0.88 / 8** |
| Upgrades.Frequency | Cost | 230 × 1.9^t | **800 × 3.4^t** |
| Upgrades.FlatRate (Combo) | Cost | 260 × 1.9^t | **600 × 2.9^t** (value curve unchanged) |
| Upgrades.BaseAdditive (Mult) | Cost | 300 × 1.7^t | **600 × 2.9^t** (value unchanged) |
| Upgrades.PegHeat | Cost | 220 × 1.7^t | **480 × 2.9^t** (value unchanged) |
| Upgrades.NumSlots | Cost | 400 × 2.2^t | **400 × 6.0^t** |
| SlotAuto | PriceGrowth | 2.0 | **6.0** (PriceBase 500 kept) |
| Scoring | MinCombo | 17 | **14** |
| Scoring | slot table / JackpotMultiplier | S5 / 12 | unchanged |
| Prestige | Scale | 18,820 | **2.823e8** (×15,000) |
| Prestige | CostGrowth | 1.1525 | **2.4** |
| Prestige | MultPer | 1.25 | **1.15** |
| Prestige | Exponent / CostBase | 0.35 / 50 | unchanged |
| Crates.Free | Interval | 2 s flat | **~10 s for first ~40 claims, then ~90 s** (needs small feature: interval steps up after N lifetime free rolls) |
| Upgrades.Luck / Cosmetics / Coins / Playtime | — | — | unchanged |

## Ladders (proposed)

| Zone tier | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| stake | 10 | 40 | 160 | 640 | 2.56k | 10.24k | 40.9k | 163.8k |
| cost | — | 2k | 10k | 50k | 250k | 1.25M | 6.25M | 31.25M |

| Slot # | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|
| unlock | 400 | 2.4k | 14.4k | 86.4k | 518k | 3.11M | 18.7M | 112M | 672M |
| auto | 3k | 18k | 108k | 648k | 3.89M | 23.3M | 140M | 840M | 5.04B |
| (auto slot 1) | 500 | | | | | | | | |

Frequency delay by tier: 2.00, 1.76, 1.55, 1.36, 1.20, 1.06, 0.93, 0.82, 0.72 s (cap t8).
Prestige PP costs: 50, 120, 288, 691, 1659, 3981, … (first-rebirth lifetime-banked ≈ 2.0e13).

## Predicted rebirth times (min, rebirths 1→8)

| Build | times |
|---|---|
| chaos | 29, 19, 19, 19, 16, 15, 15, 15 |
| targeting | 18, 16, 11, 9, 12, 13, 13, 12 |

Targeting optimal by ~30%; both inside the ≤20 min plateau; first run slowest.

## Guardrails (fresh geotest, no upgrades/skins)

| Loadout | E[slot] gate closed | gate open | combo mean |
|---|---|---|---|
| no-build (defaults) | 0.909 | 1.325 | 12.0 |
| chaos (big+bouncy) | 0.880 | 1.203 | 16.6 |
| targeting (edge+small) | 0.995 | 1.569 | 9.7 |

- No-build bleeds (0.909 + 0.05 trickle < 1). Board-wide +EV in live config came
  entirely from the jackpot: VJackFraction 0.55 means the gate is ALWAYS open when
  betting your max tier (ball value ≥ stake). At 2.5, only balls with rarity mult
  ≥ 2.5 (rarity ≥ 3, ×4) open it — jackpot EV routes through rare marbles (targeting's
  payoff), no code change, constant only.
- MinCombo 14 < 16.6: the chaos build's combo channel actually pays (17 excluded it).
- Skins are the intended EV-over-1 engine: E[ballMult] ≈ ×1.9 (25 rolls) → ×2.5
  (60) → ×3.9 (400) at 6 slots, luck 0 (skin_stats.py).

## Load-bearing assumptions

1. **Free-box cadence**: flat 2 s claims give ~450 rolls/hour → skin mults explode and
   every rebirth collapses to ~5 min regardless of pricing. The front-loaded cadence
   (fast first ~40, then ~90 s) is REQUIRED for the numbers above. Luck upgrades
   re-accelerate quality later (not modeled; slack exists).
2. Sim player is greedy-optimal with autos always on and instant claims; real players
   are slower, so live times land above these floors — bias chosen accordingly
   (plateaus at the low end of 15–20).
3. Rebirth resets upgrades/autos/cash; skin collection and Luck persist (matches live).
4. LaunchMaxBetBatch (Robux ball-drop perk) still values balls at GetMaxBet — at
   PerTier 4.0 those free balls get ×2.7 more valuable per zone vs live; revisit that
   perk before shipping zones.

## Suggested verification order after applying

1. `/geotest 25 2` unchanged (board untouched) — skip unless physics changes.
2. Live run 1 with dev commands: check zone 1 affordable ≤ ~2 min, first rebirth
   reachable, warn cadence acceptable at higher stakes.
3. Confirm jackpot gate: common ball at max bet must NOT open it; rare (×4) must.
