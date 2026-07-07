--!strict
-- Skin power math, shared by server (CosmeticService applies the loadout multiplier at
-- banking, EquipBest fills slots) and client (LoadoutUI / CosmeticsShop show stars and
-- bonus percentages). Pure functions of Config.Cosmetics + BallSkins + a copies table —
-- no player objects, no yielding.
--
--   copies[skinId] = total copies rolled/owned (>= 1 once owned). Duplicates star the
--   skin up (Config.Cosmetics.StarDupes); each skin in the loadout contributes
--   RarityBonus[rarity] × StarMults[star], and the total is one global money multiplier
--   ×(1 + sum) applied at banking.

local RS = game:GetService("ReplicatedStorage")

local Config = require(RS.Shared.Config)
local BallSkins = require(RS.Shared.BallSkins)

local CosmeticBonus = {}

local MAX_STAR = #Config.Cosmetics.StarDupes

-- Star level (1..MAX_STAR) for a total copy count (0 copies -> 0, i.e. not owned).
function CosmeticBonus.StarOf(copies: number): number
	if copies <= 0 then
		return 0
	end
	local dupes = copies - 1
	local star = 1
	for k = MAX_STAR, 1, -1 do
		if dupes >= Config.Cosmetics.StarDupes[k] then
			star = k
			break
		end
	end
	return star
end

-- Duplicates still needed for the next star, or nil if already at max star.
function CosmeticBonus.DupesToNextStar(copies: number): number?
	local star = CosmeticBonus.StarOf(copies)
	if star >= MAX_STAR then
		return nil
	end
	local dupes = math.max(copies - 1, 0)
	return Config.Cosmetics.StarDupes[star + 1] - dupes
end

-- Money bonus contributed by one skin at `copies` (0 if unknown skin or not owned).
function CosmeticBonus.SkinBonus(skinId: string, copies: number): number
	local skin = BallSkins.Get(skinId)
	local star = CosmeticBonus.StarOf(copies)
	if not skin or star == 0 then
		return 0
	end
	return Config.Cosmetics.RarityBonus[skin.rarity] * Config.Cosmetics.StarMults[star]
end

-- Total bonus (the "+X%" sum) for a loadout: slot array of skin ids (holes allowed).
function CosmeticBonus.LoadoutBonus(loadout: { [number]: string? }, copies: { [string]: number }): number
	local sum = 0
	local seen: { [string]: boolean } = {}
	for slot = 1, Config.Cosmetics.LoadoutSlots do
		local id = loadout[slot]
		if id and not seen[id] then -- a skin only counts once even if duped into two slots
			seen[id] = true
			sum += CosmeticBonus.SkinBonus(id, copies[id] or 0)
		end
	end
	return sum
end

-- The best LoadoutSlots skins by bonus, descending (ties broken by rarity then name for
-- stability). Input is the owned-copies table; returns an array of skin ids (may be
-- shorter than the slot count if fewer skins are owned).
function CosmeticBonus.BestLoadout(copies: { [string]: number }): { string }
	local entries: { { id: string, bonus: number, rarity: number } } = {}
	for id, n in copies do
		local bonus = CosmeticBonus.SkinBonus(id, n)
		if bonus > 0 then
			local skin = BallSkins.Get(id)
			table.insert(entries, { id = id, bonus = bonus, rarity = if skin then skin.rarity else 0 })
		end
	end
	table.sort(entries, function(a, b)
		if a.bonus ~= b.bonus then
			return a.bonus > b.bonus
		end
		if a.rarity ~= b.rarity then
			return a.rarity > b.rarity
		end
		return a.id < b.id
	end)
	local out: { string } = {}
	for i = 1, math.min(#entries, Config.Cosmetics.LoadoutSlots) do
		out[i] = entries[i].id
	end
	return out
end

return CosmeticBonus
