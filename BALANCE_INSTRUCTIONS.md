# Balance Instructions

Guidelines for economy balancing passes. Written 2026-07 (post per-slot launch rework:
launches stake the flat bet size, banking mints a full-value plot ball, money lands on
walk-over claim). Proposed numbers go to a results MD first — configs are only edited
after review.

## Targets

1. **Rebirth time: 15–20 minutes** (assume auto-launch always on for every owned slot,
   at the current Frequency delay, money claimed promptly). Hard ceiling ~20 min for a
   sane build.
2. **Roughly constant time per rebirth.** The first rebirth may be the slowest by some
   margin (maxable upgrades are bought from scratch); later rebirths re-max faster and
   ride the ×1.25/rebirth global multiplier. Check rebirths 1–5+ in the sim, not just
   run 1. (Prestige.CostGrowth vs MultPer is the lever; see the derivation comment in
   `Config/Prestige.luau`.)
3. **Two viable archetypes**, both feasible within the ~20 min ceiling:
   - **Chaos** — big/bouncy marbles, combo (FlatRate) income, no aim; pays through
     bounce volume.
   - **Targeting** — Angle/Arc/Size tuned at edge slots + PegHeat + jackpot gate;
     pays through E[slot mult].
   One may be meaningfully better; neither may be infeasible.
4. **Zone (bet) ladder is a constant multiple: ×4 per zone** — 10 → 40 → 160 → 640 → …
   in both stake and ball value. Zone **cost grows slightly faster than ×4** per tier so
   zones never get cheaper relative to income they unlock.
5. **Slot & auto pricing must be exponential and steep.** Each extra slot ≈ doubles
   throughput (another independent launcher), so its price must grow at least as fast
   as the income it multiplies. Anchors kept: first slot unlock $400, first auto $500.
   Current growths (2.2 / 2.0) were judged far too generous — later slots/autos should
   be mid/late-run purchases, not an early sweep.
6. **House edge for a no-build loadout** stays: default tuning E[banked/stake] < 1
   (bet-spam bleeds). Investment (upgrades, tuning, skins) is what pushes EV over 1.
7. **Slot (destroy-target) base values keep the same shape**: NOT uniform — losing
   middle, improving toward the edges, jackpot at the extreme edges behind the value
   gate. Rebalance magnitudes freely, keep the palindrome + edge-skew distribution.
8. **Skins are the ball-value multiplier engine.** Rarity multiplies ball VALUE only
   (×RarityBetFactor^(rarity−1)), never the stake. Balance must account for the
   loadout the player realistically holds (see Statistics below), not the default ×1.

## Economy surface (all knobs in scope)

| Area | Config | Knobs |
|---|---|---|
| Zone/bet ladder | `Config/Economy`, `Tracks.MaxBet` | StartBetSize, StartMaxBet, PerTier, Cost |
| Upgrade tracks | `Config/Upgrades.Tracks` | FlatRate, BaseAdditive, Frequency, PegHeat, Luck (cash+diamond barrier), NumSlots — values AND costs |
| Tuning axes | `Config/Upgrades.Axes` | Elasticity/Size/Angle/Arc costs (ranges are feel, mostly leave) |
| Slot auto | `Config/SlotAuto` | PriceBase, PriceGrowth |
| Slot payouts | `Config/Scoring.DestroyTargets` | per-ID multipliers, JackpotMultiplier |
| Scoring | `Config/Scoring` | MinCombo |
| Rebirth | `Config/Prestige` | Scale, Exponent, CostBase, CostGrowth, MultPer |
| Skins | `Config/Cosmetics` | RarityBetFactor, RarityBonus, StarDupes/StarMults |
| Crates/rolls | `Config/Crates` | box weights, free-roll Interval, pity |
| Side income | `Config/Coins`, `Config/PlaytimeBonuses`, `Config/Quests`, `Config/DailyReward`, obby rewards | onboarding drip — keep small vs. loop income at each stage |
| Start | `Config/Economy.StartingBalance` | cold-start buying power |

Diamond economy note: rebirth pays CC (= Diamonds) at RebirthCCRatio × RP spent
(~50 on rebirth 1). Luck barriers, crate purchases, and skin buys price against that
faucet — check barrier costs in "number of rebirths", not raw diamonds.

## Methods

### 1. Geotest (measurement anchor)
`/geotest <n> [ballsPerInterval]` (DevService, chat command in play mode) sweeps
bet × PegHeat tier × Arc × Angle × Size × Elasticity and prints, per build, the
landing histogram over DestroyTargetIDs 0–17 plus geometry means (hot/cold pegs,
combo, jackpotHit). This is the ONLY trustworthy source for P(slot | tuning) —
never guess landing distributions. PegHeat doesn't alter trajectories, so landing
data can be pooled across PegHeat tiers for more samples per tuning point.
Re-run after any board-geometry or ball-physics change; otherwise reuse the latest
dump in `tests/`.

### 2. Python simulation (primary hypothesis testing)
`python/` holds the tooling (`balance.py` parses geotest dumps + EV model,
`progression.py` time-to-rebirth greedy-buyer sim). Keep its config mirror in sync
with the live configs — it drifts. The sim should model the CURRENT loop:

- Per-slot pipeline: each owned+auto slot fires every `launchDelay` seconds; each
  launch spends `stake`; each bank returns `stake × skinMult × E[slot] × modifiers`.
- Income rate ≈ slots × (banked − stake) / launchDelay; lifetime-banked accrues at
  slots × banked / launchDelay toward the rebirth threshold
  `Scale × (rebirthCost)^(1/Exponent)`.
- Greedy purchaser: buy the affordable upgrade with the best income-ROI each step;
  compare forced-archetype variants (chaos-only vs targeting-only buy lists).
- E[slot mult] per archetype comes from geotest landing fractions × candidate slot
  tables. Combo income from geotest combo means × FlatRate curve, gated by MinCombo.
- Accuracy bar is LOW: a reasonably trustworthy EV sim beats an hour of live runs.
  Confirm the final candidate with one live playtest pass, not every iteration.

### 3. Statistics for skin multipliers
The free roll (every ~2 s) + luck makes the equipped loadout a random process. For
sim input, compute EV/Var of the loadout ball-value multiplier analytically:
- Roll CDF with luck: P(pick ≤ c) = (c/T)^(1+luck) over cumulative weights → exact
  per-rarity probabilities per roll.
- Best-loadout after N rolls: distribution of the top-k rarities seen (order stats
  over N iid rolls), k = owned slots; each slot's value mult = 2^(rarity−1).
- Report E and Var of the mean loadout mult at representative times (e.g. 5/15/30 min
  of rolling) and use E (minus maybe half an sd) as the sim's skinMult; variance says
  how swingy time-to-rebirth is between lucky/unlucky players.
- Same machinery for the loadout money-bonus sum (RarityBonus × StarMults).

### 4. Verification
- Sim first; live `/geotest` or manual play only to validate the chosen candidate.
- MCP playbook caveats apply (see CLAUDE.md): fresh module copies in execute_luau,
  rojo sync races — check `module.Source` in-session before trusting a play run.
- Results go to a quantity-focused MD (tables of numbers, minimal prose). Configs are
  edited only after the user reviews it.
