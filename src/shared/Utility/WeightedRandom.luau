--!strict
-- Weighted random sampling, shared by server rolls and the client previews that mirror
-- them — one implementation so the previewed odds can't drift from the real ones.

local WeightedRandom = {}

-- The exact per-index probabilities PickIndexLuckBiased rolls with (no pity floor /
-- sparseness): its pick is total·u^(1/(l+1)), whose CDF over the cumulative-weight
-- fraction x is x^(l+1), so P(i) = (c_i/total)^(l+1) - (c_(i-1)/total)^(l+1) with c_i the
-- cumulative weight through index i. Display code uses this so shown odds are derived
-- from the SAME math as the roll, not a reimplementation. Returns {} when nothing has
-- positive weight.
function WeightedRandom.LuckBiasedOdds(weights: { number }, luck: number?): { number }
	local total = 0
	for _, w in weights do
		total += w
	end
	if total <= 0 then
		return {}
	end
	local exponent = (luck or 0) + 1
	local odds = table.create(#weights, 0)
	local cum = 0
	local prevF = 0
	for i, w in weights do
		cum += w
		local f = (cum / total) ^ exponent
		odds[i] = f - prevF
		prevF = f
	end
	return odds
end

-- Luck-biased pick of an INDEX from index->weight, optionally sparse (has(i) filters out
-- indices with no candidates, e.g. rarities with no skins) and floored at minIndex (pity).
--
-- Luck skews the pick via inverse-CDF sampling of F(x) = (x/total)^(l+1): draw
-- u ~ Uniform(0,1), pick = total * u^(1/(l+1)). luck = 0 recovers the exact plain uniform
-- draw (u^1 = u); luck > 0 makes u^(1/(l+1)) >= u, pushing the pick toward `total` and thus
-- toward the rarer (later) indices — without changing the displayed base odds.
--
-- Returns nil when no index has positive weight (degenerate config; caller picks a fallback).
function WeightedRandom.PickIndexLuckBiased(
	weights: { number },
	luck: number?,
	minIndex: number?,
	has: ((number) -> boolean)?
): number?
	local floor = minIndex or 1
	local total = 0
	for i = floor, #weights do
		if not has or has(i) then
			total += weights[i]
		end
	end
	if total <= 0 then
		return nil
	end
	local l = luck or 0
	local pick = total * (math.random() ^ (1 / (l + 1)))
	for i = floor, #weights do
		if not has or has(i) then
			pick -= weights[i]
			if pick <= 0 then
				return i
			end
		end
	end
	-- Float dust: pick can end a hair above 0 after the loop; the last eligible index wins.
	for i = #weights, floor, -1 do
		if not has or has(i) then
			return i
		end
	end
	return nil
end

-- Plain weighted pick of an entry from a list, weighing each via weightOf.
-- Returns nil for an empty/zero-weight list.
function WeightedRandom.PickBy<T>(list: { T }, weightOf: (T) -> number): T?
	local total = 0
	for _, entry in list do
		total += weightOf(entry)
	end
	if total <= 0 then
		return nil
	end
	local r = math.random() * total
	local acc = 0
	for _, entry in list do
		acc += weightOf(entry)
		if r <= acc then
			return entry
		end
	end
	return list[#list]
end

-- Plain weighted pick of a KEY from key->weight. Returns nil for an empty/zero-weight map.
function WeightedRandom.PickKey(weights: { [string]: number }): string?
	local total = 0
	for _, w in weights do
		total += w
	end
	if total <= 0 then
		return nil
	end
	local r = math.random() * total
	local acc = 0
	for key, w in weights do
		acc += w
		if r <= acc then
			return key
		end
	end
	return nil
end

return WeightedRandom
