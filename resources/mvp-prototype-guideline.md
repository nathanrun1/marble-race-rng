# Marble Race — MVP Prototype Guideline

Scope: the minimum mechanic set that tests the build-exclusivity thesis. Everything here was validated by simulation except where marked OPEN. Cosmetics, inter-ball interaction, and polish are out of scope.

---

## 0. The one rule everything hangs on

**N-neutrality comes from linearity in ball value.** Per batch, total bet B splits into N balls of value B/N.

- Any payout *proportional to ball value* (multiplicative) sums to B·avg(m) regardless of N → differentiates nothing between builds.
- **Sublinear** (flat per event, value-independent) → scales with ball count → chaos channel.
- **Superlinear** (threshold-gated: zero below, full above) → requires concentration → targeting channel.

Every current and future mechanic must be classified as one of the three before it ships. Put this comment at the top of Config.

---

## 1. Base mechanics (build these first, in this order)

### 1.1 Batch launcher
- One batch every `BATCH_SECONDS` (start: 5).
- Player sets total bet B (≤ max bet) and ball count N. Each ball's value = B/N.
- Launcher sweeps one full arc per batch. Player sets a **launch phase** (a position in the arc); balls release at that phase each cycle. Phase is configuration: set once, repeats while idle.

### 1.2 Trickle income (base mechanic, not an upgrade)
- Every batch, the player receives `TRICKLE × currentMaxBet` free (start: 0.08).
- This is load-bearing, not polish: in the economy sim, targeting ruined in 55–100% of runs without it and 0% with it. It is the recovery floor that makes the high-variance pole playable at all. Ship it in the MVP.

### 1.3 Bottom slots + value-gated jackpot
- 13 landing slots. Multiplier table (edges rich, neighbors of edges among the WORST — this gradient is what makes aiming risky; do not smooth it for convenience):
  `[30, 0.55, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.55, 30]`
- Slot payout = ballValue × slotMult × (1 + baseAdditive) × pegSkewFactor.
- **Jackpot gate:** edge slots pay full multiplier only if `ballValue >= V_JACK`, else capped at 1×.
- `V_JACK = 0.4 × currentMaxBet` (player-specific, recomputed when max bet changes). Clearing the gate always requires betting a large fraction of your own ceiling with low N. This is the keystone mechanic; without it frequency is free variance reduction and builds collapse. Validated: the tiny-bet exploit (small single ball aimed at the edge) returns 0.60× under this rule.
- **Consequence (sim-proven):** the gate forces targeting to bet ≥ 0.8 × maxBet at N=2, and targeting's safe bet fraction is ~20–30% of bankroll (full-bankroll betting has geo 0.87 — ruinous). Therefore `StartMaxBet` must be small relative to starting bankroll so the forced bet sits inside that fraction. Start: bank 150, maxBet 40 (forced bet ≈ 27% of bank).
- Landing slot must be **path-correlated** (exit position from peg field → reachable slots). If physics makes any slot reachable from any path, the gate leaks to chaos. Verify this on the physical board before tuning anything else.

### 1.4 Pegs: merged flat channel with per-ball combo gate
One channel (peg-flat and combo merged — they were redundant):
- Track `bounceCount` per ball (peg contacts).
- At ball despawn: if `bounceCount >= T` (start T = 9), pay `FLAT_PER_BOUNCE × bounceCount` (flat points, value-independent).
- Below T: the ball earns **nothing** from pegs. This per-ball threshold is the hybrid punisher — a medium-weight ball that bounces some-but-not-enough gets zero. Do not convert to per-batch; do not convert to a multiplier (both re-open simulated holes).
- Payment denominated in absolute points, scaled by the flat track (§2.2).
- Consequence (sim-confirmed): heavy targeting balls earn nothing from pegs at all now, which is why the jackpot was raised to 30× and why targeting is a fractional-bet build (§1.3). Sub-threshold early-game balls also earn nothing — the new-player floor is the trickle (§1.2), not pegs. The fallback of re-splitting a small unconditional per-contact floor stays in reserve; don't pre-add.

### 1.5 Peg skew (value-proportional layer, separate from 1.4)
- Pegs have colors. Each contact with a peg also applies a small **value-proportional** bonus/malus to that ball.
- Skew redistributes: boosting the hot color cuts the others; total conserved. Sharpening is therefore net-negative on a random path and only pays when the path is aimed through hot pegs (heavy + phase control).
- Start: hot gain +100% of the peg's proportional value, cold cut −50% (G=1.0, Kc=0.5).

---

## 2. Independent upgrade tracks (the idle layer — pole-aligned by design)

Three separately purchasable tracks. Purchase order sets the economy's ratios; this is intentional and is where long-run replayability lives. All three use **superlinear cost curves** (next tier cost > current tier's total benefit over a short horizon) — this is the anti-snowball mechanism, nothing else is.

| Track | Effect per tier | Pole it feeds (sim result) | Coupled effect |
|---|---|---|---|
| **Max Bet** | maxBet ×= M (try M = 2) | Neither directly — a **timing decision**. Each tier doubles V_JACK and the forced bet before bankroll catches up; buying it early ruined targeting in every sim run (bet-rush stalled at ~41 points). Buy only once bankroll ≥ ~10× current ceiling. | V_JACK and trickle rise with it |
| **Flat Rate** | FLAT_PER_BOUNCE ×= M | **Chaos** (flat-rush was chaos's best order: 85.6M vs 57M) | none |
| **Base Additive** | +flat % on final slot payout, additive within itself | **Targeting** (add-rush was targeting's best order: 84.3M vs 797K) — it multiplies jackpot payouts, so it scales the targeting channel, not a universal | none |

- The original guess (Max Bet = targeting track, Additive = universal) was wrong; the sim corrected it. Additive is the targeting investment; Max Bet is a double-edged throughput unlock both builds want *eventually* and neither should rush.
- Cost curve starting point: `cost(tier) = baseCost × tier^2.5` (baseCost ≈ 200, ≈ 5× StartMaxBet), with Max Bet tier cost always > current maxBet. Tune in playtest.
- Track check passed in sim: no single purchase order dominated both builds (flat-rush wins chaos, add-rush wins targeting, both converge to ~84–86M over 150 batches). Re-verify on the physics-fit constants.

## 3. Synergetic upgrades (configuration axes — sliders, not stacks)

Owning these extends a slider's range or unlocks moving it. A ball occupies one point per axis; opposite ends cancel by construction.

| Upgrade | Axis | Effect | Serves | Built-in cost |
|---|---|---|---|---|
| Ball Frequency | A | unlock higher N (2 → 4 → 8 → 16) | Chaos | ball value B/N falls under V_JACK → no jackpot |
| Ball Weight | B | slider heavy↔light; contacts ≈ 4 (heavy) to ~22 (light) | both ends | heavy: few contacts, fails combo T; light: unaimable |
| Ball Size | B-adj | smaller = fewer contacts, tighter path | Targeting | fewer contacts = less flat/combo income |
| Launcher Arc | C | widens reachable sweep range (more positions to pin) | Targeting | none direct; only useful with heavy + phase pinning |
| Peg Skew | D | sharpen↔flatten hot-color allocation | Targeting | net-negative unaimed |

MVP can hardcode two presets instead of full sliders if time is short tonight: **Targeting** (N=1–2, heavy, pinned phase at edge, skew sharp, small) and **Chaos** (N=12+, light, free sweep, skew flat). The thesis test only needs the two corners plus one hybrid.

---

## 4. Starting constants (Config module, one table)

```lua
Config.Batch = { Seconds = 5 }
Config.Economy = { StartBank = 150, StartMaxBet = 40, TrickleFraction = 0.08, -- × maxBet per batch
                   TierCostBase = 200, TierCostExp = 2.5 }
Config.Slots = { Mults = {30,0.55,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.55,30},
                 JackpotIndices = {1, 13}, VJackFraction = 0.4 }  -- of current maxBet
Config.Pegs  = { FlatPerBounce = 0.5,    -- absolute points; doubled per Flat Rate tier
                 ComboThreshold = 9,
                 ProportionalValue = 0.012, -- skewable value-% per contact
                 SkewHotGain = 1.0, SkewColdCut = 0.5 }
Config.Weight = { ContactsHeavy = 4, ContactsLight = 22 } -- lambda = 4 + 18*(1-w)
```

Validated relationships these encode (preserve the *ratios* when retuning):
- Targeting (N=2, aimed, sharp, betting ~25% of bankroll): arith ≈ 2.7×, geo ≈ 1.11/batch at Kelly fraction, jackpot ~13% of batches. Full-bankroll betting: geo 0.87 — losing. Targeting is a **fractional-bet build by design**.
- Chaos (N=12–16, light, flat, full-bet): arith = geo ≈ 2.0–2.4× (near-zero variance).
- All tested hybrids/exploits: 0.60–1.34, strictly below both poles (tiny-bet jackpot 0.60, aim+freq 0.80, centrist 0.89, unaimed sharp skew 1.34).
- Naked ball: ~0.66× (net loss by design; trickle carries the new player to first purchases).
- 150-batch economy, best track order per pole: targeting 84.3M, chaos 85.6M — balanced endpoints via different paths.

The decimals are model-fit, not physics-fit. After the board physically exists, log (contacts per ball by weight, landing slot distribution by phase/weight) and re-fit `ContactsHeavy/Light` and the aim spread to reality, then re-check the four rows above against logged returns.

---

## 5. Implementation seam (maps to existing architecture)

- Per-ball config → **Attributes** set by BallLaunchService at spawn: `Value, Weight, Size, BatchId, OwnerId`. One value per attribute enforces one-point-per-axis for free.
- Board content → **CollectionService** tags: `Peg` (attrs: `Color, ProportionalValue`), `Slot` (attrs: `Mult, IsJackpot`). Content editable without code changes.
- Bounce counting → ScoringService increments per-ball on peg contact (existing hit-detection path; the liveness guard from the despawn bug applies here — a despawned ball must stop accumulating).
- Combo settlement → at despawn check `bounceCount >= T`, pay flat; **per-batch state is per-player server-side** and must be cleaned on disconnect (ties into the open orphaned-ball policy — settle or void a leaver's in-flight batch, decide which).
- Jackpot gate → value check in slot-touch handler: `ball:GetAttribute("Value") >= Config.Slots.VJackFraction * profile.MaxBet`.
- All payout resolution server-authoritative (same anti-cheat boundary as physics).

---

## 6. MVP acceptance tests (run these before adding anything)

1. **Pole sanity:** Targeting preset (betting ~25% of bankroll, ≥ 0.8×maxBet) and Chaos preset both net-positive over 50 batches; Targeting visibly swingy (most batches lose, occasional jackpot), Chaos visibly steady.
2. **Buy-everything check:** a hybrid (N=6, medium weight, pinned, half-sharp skew) underperforms both presets over 50 batches. If it doesn't, the leak is almost certainly the gate (1.3) or the combo threshold scope (1.4) — check those before retuning constants.
3. **Gate check:** Chaos preset never receives an edge-slot full payout; Targeting at N=3+ loses jackpot access; a small bet (≤0.1×maxBet) on a single aimed ball nets a loss.
4. **Skew check:** sharpened skew with free sweep (no pinning) earns *less* than flat skew. If it earns more, skew isn't conserved or hot-rate-while-unaimed is too high.
5. **Track check:** Flat-rush wins for chaos, Additive-rush wins for targeting, Max-Bet-rush is the worst order for targeting. If any single order wins for both builds, reprice (§2).
6. **Ruin check:** with trickle on, a targeting player who busts can rebuild to a gate-clearing bet within a tolerable number of batches (sim: zero permanent busts at trickle 0.08×maxBet). With trickle off, busts should be common — confirming the trickle is doing the work.
7. **Snowball check:** time from start to 100× starting bankroll. If under a few minutes, the geo means are too high — scale all three reward channels down by the same factor (ratios preserved).

---

## 7. Deliberately deferred

- Re-splitting an unconditional peg floor (only if early-game pacing is dead).
- Per-level ratio drift for high-tier feel (V_JACK creeping faster than flats) — post-prototype lever.
- Inter-ball interaction, cosmetics-as-readout, orphaned-ball policy finalization (decide settle-or-void for §5 cleanup, full policy later).