--!strict
-- Ball cosmetics: the CC (Cosmetic Coin) currency, per-player skin ownership, the equipped
-- skin, and the shop's select / buy / equip flow. Skins are defined in shared/BallSkins;
-- BallEffects.ApplyAppearance paints them. CC is earned by rebirthing (PrestigeService grants it)
-- and spent here. Passive data service: DataService owns the lifecycle (ApplyData/SerializeData/
-- Clear), this just holds state, mutates it, and pushes changes to the owning client.
--
-- NOTE: the bonus-slot LOADOUT system (which owned skins sit in the N bonus slots, and the
-- money multiplier that pays) lives in the separate LoadoutService — it's a distinct concept
-- from `equipped` here (the single VISUAL skin your marbles wear). LoadoutService depends on
-- this module only for CosmeticService.IsOwned/GetCopies.

local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Config = require(RS.Shared.Config)
local BallSkins = require(RS.Shared.BallSkins)
local BallEffects = require(RS.Shared.BallEffects)
local CosmeticBonus = require(RS.Shared.CosmeticBonus)
local Signal = require(RS.Shared.Signal)
local BallService = require(SSS.Scripts.Modules.BallService)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local ProfileStats = require(RS.Shared.ProfileStats)
-- NOTE: ProductService is required lazily in Init — it requires DataService, which
-- requires this module, so a top-level require here is a cycle.

local CosmeticService = {}

local DEFAULT_SKIN = BallSkins.GetDefaultId()

export type CosmeticData = {
	cc: number,                   -- Cosmetic Coin balance
	owned: { [string]: boolean }, -- owned skin ids (the default skin is always owned)
	equipped: string,             -- VISUAL skin id (what the marbles wear; independent of loadout)
	copies: { [string]: number }, -- total copies per owned skin (dupes star it up — CosmeticBonus)
	pity: { [string]: number },   -- per-crate rolls since the last MinRarity+ hit
	boxes: { [string]: number },  -- unopened boxes held per crate id (bought to hoard)
}

export type CosmeticInfo = {
	cc: number,
	equipped: string,
	selected: string,             -- skin highlighted in the shop (sample ball + buy-button target)
	owned: { [string]: boolean },
	copies: { [string]: number },
	pity: { [string]: number },
	boxes: { [string]: number },  -- unopened boxes held per crate id
	freeCrateIn: number,          -- seconds until the free box is claimable (0 = ready)
}

export type PurchaseResult = { ok: boolean, reason: string?, bought: boolean?, equipped: boolean? }

export type RollResult = {
	ok: boolean,
	reason: string?,   -- "invalid" | "insufficient_cc" | "not_ready"
	skinId: string?,
	rarity: number?,
	copies: number?,   -- total copies of the rolled skin after this roll
	star: number?,
	isNew: boolean?,
}

local data: { [number]: CosmeticData } = {}
local selected: { [number]: string } = {} -- in-memory shop selection (not persisted)
-- Session free-box timer (os.clock deadline per user; not persisted — the cadence is
-- "FirstDelay after join (0 = instantly), Interval after every claim" by design).
local freeDue: { [number]: number } = {}

-- (player, info) — fired after any cosmetic change.
CosmeticService.Changed = Signal.new()

local changedRE: RemoteEvent
local crateRolledRE: RemoteEvent

local function defaults(): CosmeticData
	return {
		cc = 0,
		owned = { [DEFAULT_SKIN] = true },
		equipped = DEFAULT_SKIN,
		copies = { [DEFAULT_SKIN] = 1 },
		pity = {},
		boxes = {},
	}
end

local function get(userId: number): CosmeticData
	return data[userId] or defaults()
end

local function buildInfo(player: Player): CosmeticInfo
	local d = get(player.UserId)
	return {
		cc = d.cc,
		equipped = d.equipped,
		selected = selected[player.UserId] or d.equipped,
		owned = d.owned,
		copies = d.copies,
		pity = d.pity,
		boxes = d.boxes,
		freeCrateIn = math.max(0, math.ceil((freeDue[player.UserId] or (os.clock() + Config.Crates.Free.FirstDelay)) - os.clock())),
	}
end

local function announce(player: Player)
	local info = buildInfo(player)
	CosmeticService.Changed:Fire(player, info)
	if changedRE then
		changedRE:FireClient(player, info)
	end
end

--------------------------------------------------------------------------------
-- Appearance (used by ball spawn + previews, all via BallEffects.ApplyAppearance)
--------------------------------------------------------------------------------
function CosmeticService.ApplySkin(ball: BasePart, skinId: string)
	BallEffects.ApplyAppearance(ball, { skinId = skinId })
end

function CosmeticService.GetEquipped(player: Player): string
	return get(player.UserId).equipped
end

--------------------------------------------------------------------------------
-- CC currency
--------------------------------------------------------------------------------
function CosmeticService.GetCC(player: Player): number
	return get(player.UserId).cc
end

-- Grant CC (e.g. converted from RP on a rebirth). Spending happens inside Purchase.
function CosmeticService.AddCC(player: Player, amount: number)
	if amount <= 0 then
		return
	end
	local d = data[player.UserId]
	if not d then
		return
	end
	d.cc += math.floor(amount)
	announce(player)
end

-- Dev only (DevService /cc): set the CC balance directly, raising or lowering.
function CosmeticService.SetCC(player: Player, amount: number)
	local d = data[player.UserId]
	if not d then
		return
	end
	d.cc = math.max(math.floor(amount), 0)
	announce(player)
end

--------------------------------------------------------------------------------
-- Ownership / equip / select / purchase
--------------------------------------------------------------------------------
function CosmeticService.IsOwned(player: Player, skinId: string): boolean
	return get(player.UserId).owned[skinId] == true
end

-- Highlight a skin in the shop — drives the floating sample ball and the buy button's price/state.
function CosmeticService.Select(player: Player, skinId: string)
	if not BallSkins.Get(skinId) then
		return
	end
	selected[player.UserId] = skinId
	announce(player)
end

function CosmeticService.GetSelected(player: Player): string
	return selected[player.UserId] or get(player.UserId).equipped
end

-- Add one copy of a skin (ownership + star progression). Returns the new copy total.
local function addCopy(d: CosmeticData, skinId: string): number
	d.owned[skinId] = true
	d.copies[skinId] = (d.copies[skinId] or 0) + 1
	return d.copies[skinId]
end

-- Grant a skin outright (no CC cost) and equip it — used by the Robux fallback product.
function CosmeticService.GrantSkin(player: Player, skinId: string): boolean
	local d = data[player.UserId]
	if not d or not BallSkins.Get(skinId) then
		return false
	end
	addCopy(d, skinId)
	d.equipped = skinId
	announce(player)
	return true
end

-- Buy-or-equip the given skin. Owned -> just equip. Affordable -> spend CC, own it, equip. Neither
-- -> fail with "insufficient_cc" (the client then prompts the Robux fallback).
function CosmeticService.Purchase(player: Player, skinId: string): PurchaseResult
	local d = data[player.UserId]
	local skin = BallSkins.Get(skinId)
	if not d or not skin then
		return { ok = false, reason = "invalid" }
	end
	if d.owned[skinId] then
		d.equipped = skinId
		announce(player)
		return { ok = true, equipped = true }
	end
	if d.cc >= skin.price then
		d.cc -= skin.price
		addCopy(d, skinId)
		d.equipped = skinId
		announce(player)
		return { ok = true, bought = true }
	end
	return { ok = false, reason = "insufficient_cc" }
end

--------------------------------------------------------------------------------
-- Crate rolls (Marble Boxes), star dupes, pity
--------------------------------------------------------------------------------
-- Skins grouped by rarity once (the roll picks a rarity by weight, then a uniform
-- random skin of that rarity).
local skinsByRarity: { [number]: { string } } = {}
for id, skin in BallSkins.GetAll() do
	local list = skinsByRarity[skin.rarity]
	if not list then
		list = {}
		skinsByRarity[skin.rarity] = list
	end
	table.insert(list, id)
end

-- Roll a rarity from weights, optionally clamped to >= minRarity (pity). Rarities with
-- no skins defined are skipped regardless of weight.
--
-- `luck` (l, default 0) biases the pick toward rarer rarities WITHOUT changing the displayed
-- base odds (the weights themselves, and thus "1 in X", are untouched — only which number
-- gets drawn shifts). Standard weighted sampling draws a uniform pick in [0,total] and walks
-- rarities common->rare, subtracting each weight, until the pick goes <= 0 (whichever rarity's
-- subtraction crosses zero wins — larger picks survive past the bulk common/uncommon weight
-- and land on rarer buckets). Luck skews the pick via inverse-CDF sampling of
-- F(x) = (x/total)^(l+1): draw u ~ Uniform(0,1), pick = total * u^(1/(l+1)). l=0 recovers
-- the exact original uniform draw (u^1 = u); l>0 makes u^(1/(l+1)) >= u, pushing the pick
-- toward `total` and thus toward rarer rarities.
local function rollRarity(weights: { number }, minRarity: number?, luck: number?): number
	local floor = minRarity or 1
	local total = 0
	for rarity = floor, #weights do
		if skinsByRarity[rarity] then
			total += weights[rarity]
		end
	end
	if total <= 0 then
		-- Degenerate config (e.g. pity floor above every weighted rarity): highest
		-- rarity that has skins at all.
		for rarity = #weights, 1, -1 do
			if skinsByRarity[rarity] then
				return rarity
			end
		end
		return 1
	end
	local l = luck or 0
	local u = math.random()
	local pick = total * (u ^ (1 / (l + 1)))
	for rarity = floor, #weights do
		if skinsByRarity[rarity] then
			pick -= weights[rarity]
			if pick <= 0 then
				return rarity
			end
		end
	end
	return floor
end

type BoxDef = { Id: string, Name: string, Cost: number?, Product: string?, Weights: { number }, Pity: { Every: number, MinRarity: number }? }

local boxById: { [string]: BoxDef } = {}
for _, box in Config.Crates.Boxes :: { BoxDef } do
	boxById[box.Id] = box
end

-- Roll one skin from a box for the player: pity bookkeeping, copy/star grant, announce.
-- Cost/eligibility are the CALLER's job (RollCrate spends cc; ClaimFreeCrate gates on the
-- timer) — this is the shared inner roll.
local function rollFrom(player: Player, d: CosmeticData, box: BoxDef): RollResult
	local pity = box.Pity
	local count = d.pity[box.Id] or 0
	local forced = pity ~= nil and (count + 1) >= pity.Every
	local luck = ProfileStats.GetLuck(ProfileService.GetUpgrades(player))
	local rarity = rollRarity(box.Weights, (if forced and pity then pity.MinRarity else nil), luck)
	if pity then
		d.pity[box.Id] = if rarity >= pity.MinRarity then 0 else count + 1
	end

	local pool = skinsByRarity[rarity] :: { string }
	local skinId = pool[math.random(#pool)]
	local isNew = d.owned[skinId] ~= true
	local copies = addCopy(d, skinId)

	announce(player)
	return {
		ok = true,
		skinId = skinId,
		rarity = rarity,
		copies = copies,
		star = CosmeticBonus.StarOf(copies),
		isNew = isNew,
	}
end

-- Open one Marble Box: consumes a held (pre-bought) box first, otherwise pays the
-- cc cost from Config.Crates.Boxes on the spot.
function CosmeticService.RollCrate(player: Player, boxId: string): RollResult
	local d = data[player.UserId]
	local box = boxById[boxId]
	if not d or not box then
		return { ok = false, reason = "invalid" }
	end
	local held = d.boxes[box.Id] or 0
	if held > 0 then
		if held > 1 then
			d.boxes[box.Id] = held - 1
		else
			d.boxes[box.Id] = nil
		end
	else
		local cost = box.Cost or 0
		if d.cc < cost then
			return { ok = false, reason = "insufficient_cc" }
		end
		d.cc -= cost
	end
	return rollFrom(player, d, box)
end

-- Buy one box WITHOUT opening it (hoard to open later — RollCrate consumes held
-- boxes before charging cc). Returns the same shape as RollCrate for shared
-- client error handling; ok=true carries no skin fields.
function CosmeticService.BuyCrate(player: Player, boxId: string): RollResult
	local d = data[player.UserId]
	local box = boxById[boxId]
	if not d or not box then
		return { ok = false, reason = "invalid" }
	end
	local cost = box.Cost or 0
	if d.cc < cost then
		return { ok = false, reason = "insufficient_cc" }
	end
	d.cc -= cost
	d.boxes[box.Id] = (d.boxes[box.Id] or 0) + 1
	announce(player)
	return { ok = true }
end

-- Open one box FREE of charge (no Diamonds; pity ticks as usual) — used by rewards that
-- grant a crate opening (e.g. the daily reward's Crate kind). `boxId` must be a
-- Config.Crates.Boxes id.
function CosmeticService.GrantCrateRoll(player: Player, boxId: string): RollResult
	local d = data[player.UserId]
	local box = boxById[boxId]
	if not d or not box then
		return { ok = false, reason = "invalid" }
	end
	return rollFrom(player, d, box)
end

-- Bank `count` (default 1) unopened boxes into the player's stash — no roll, no charge.
-- Used by grants that award the box itself (daily reward); RollCrate opens stashed
-- boxes before charging Diamonds.
function CosmeticService.AddBox(player: Player, boxId: string, count: number?): boolean
	local d = data[player.UserId]
	local box = boxById[boxId]
	if not d or not box then
		return false
	end
	d.boxes[box.Id] = (d.boxes[box.Id] or 0) + math.max(1, math.floor(count or 1))
	announce(player)
	return true
end

-- GrantCrateRoll, plus a CrateRolled push so the client presents the result (reel or
-- banner) — for server-initiated grants with no invoke to return through (starter pack).
function CosmeticService.GrantCrateRollAnnounced(player: Player, boxId: string): RollResult
	local result = CosmeticService.GrantCrateRoll(player, boxId)
	if result.ok and crateRolledRE then
		crateRolledRE:FireClient(player, boxId, result)
	end
	return result
end

-- Claim the session free box (FirstDelay after join, Interval after each claim).
function CosmeticService.ClaimFreeCrate(player: Player): RollResult
	local d = data[player.UserId]
	if not d then
		return { ok = false, reason = "invalid" }
	end
	local due = freeDue[player.UserId]
	if not due or os.clock() < due then
		return { ok = false, reason = "not_ready" }
	end
	freeDue[player.UserId] = os.clock() + Config.Crates.Free.Interval
	return rollFrom(player, d, Config.Crates.Free :: BoxDef)
end

--------------------------------------------------------------------------------
-- Visual equip (the bonus-slot LOADOUT itself lives in LoadoutService)
--------------------------------------------------------------------------------
-- Every copy count a player has (dupes star it up — CosmeticBonus). LoadoutService reads this
-- for EquipBest (CosmeticBonus.BestLoadout) and its money-multiplier calc (CosmeticBonus.LoadoutBonus).
function CosmeticService.GetCopies(player: Player): { [string]: number }
	return get(player.UserId).copies
end

-- Set the VISUAL skin (what marbles wear) — independent of the bonus loadout.
function CosmeticService.SetEquipped(player: Player, skinId: string): boolean
	local d = data[player.UserId]
	if not d or d.owned[skinId] ~= true then
		return false
	end
	d.equipped = skinId
	announce(player)
	return true
end

--------------------------------------------------------------------------------
-- Ball spawn paint
--------------------------------------------------------------------------------
local function onBallSpawn(ball: BasePart, ballInfo: BallService.BallInfo)
	local ownerId = ballInfo.ownerUserId
	local d = if ownerId then data[ownerId] else nil
	-- ballInfo.skinId is which LOADOUT slot's ball this actually is (CORE LOOP REWORK —
	-- BallLaunchService's round-robin batch); falls back to the single VISUAL equipped skin
	-- for any spawn path that doesn't specify one (dev/test launches, Robux ball-drop perk).
	local skinId = ballInfo.skinId or (if d then d.equipped else DEFAULT_SKIN)
	-- Stamped so anything reading the ball LATER (e.g. BallPlotService, at banking time) can
	-- reconstruct this specific ball's appearance even if the player's loadout has since changed.
	ball:SetAttribute(Config.Attributes.SkinId, skinId)
	CosmeticService.ApplySkin(ball, skinId)
end

--------------------------------------------------------------------------------
-- Data lifecycle (DataService-driven)
--------------------------------------------------------------------------------
function CosmeticService.ApplyData(player: Player, saved: CosmeticData?)
	local d = defaults()
	if saved then
		if type(saved.cc) == "number" then
			d.cc = saved.cc
		end
		if type(saved.owned) == "table" then
			for id, on in saved.owned do
				if on == true and BallSkins.Get(id) then
					d.owned[id] = true
				end
			end
		end
		if type(saved.equipped) == "string" and d.owned[saved.equipped] then
			d.equipped = saved.equipped
		end
		if type(saved.copies) == "table" then
			for id, n in saved.copies do
				if type(n) == "number" and n >= 1 and BallSkins.Get(id) then
					d.copies[id] = math.floor(n)
				end
			end
		end
		if type(saved.pity) == "table" then
			for boxId, n in saved.pity do
				if boxById[boxId] and type(n) == "number" and n >= 0 then
					d.pity[boxId] = math.floor(n)
				end
			end
		end
		if type(saved.boxes) == "table" then
			for boxId, n in saved.boxes do
				if boxById[boxId] and type(n) == "number" and n >= 1 then
					d.boxes[boxId] = math.floor(n)
				end
			end
		end
	end
	d.owned[DEFAULT_SKIN] = true -- the default skin is always owned
	-- Migration: pre-crate saves have owned skins but no copy counts — seed them at 1
	-- so stars/bonuses work (nobody loses a skin, everyone starts at ★1).
	for id in d.owned do
		if not d.copies[id] then
			d.copies[id] = 1
		end
	end
	data[player.UserId] = d
	selected[player.UserId] = d.equipped
	freeDue[player.UserId] = os.clock() + Config.Crates.Free.FirstDelay
	announce(player)
end

function CosmeticService.SerializeData(player: Player): CosmeticData
	return get(player.UserId)
end

function CosmeticService.Clear(player: Player)
	data[player.UserId] = nil
	selected[player.UserId] = nil
	freeDue[player.UserId] = nil
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------
local function getRemote(name: string, class: string): Instance
	local existing = RS.Remote:FindFirstChild(name)
	if existing then
		return existing
	end
	local r = Instance.new(class)
	r.Name = name
	r.Parent = RS.Remote
	return r
end

function CosmeticService.Init()
	changedRE = getRemote("CosmeticChanged", "RemoteEvent") :: RemoteEvent

	;(getRemote("GetCosmeticInfo", "RemoteFunction") :: RemoteFunction).OnServerInvoke = function(player: Player)
		return buildInfo(player)
	end
	;(getRemote("PurchaseCosmetic", "RemoteFunction") :: RemoteFunction).OnServerInvoke = function(player: Player, skinId: any)
		if type(skinId) ~= "string" then
			return { ok = false, reason = "invalid" }
		end
		return CosmeticService.Purchase(player, skinId)
	end
	;(getRemote("SelectCosmetic", "RemoteEvent") :: RemoteEvent).OnServerEvent:Connect(function(player: Player, skinId: any)
		if type(skinId) == "string" then
			CosmeticService.Select(player, skinId)
		end
	end)

	-- Crate rolls + free box.
	;(getRemote("RollCrate", "RemoteFunction") :: RemoteFunction).OnServerInvoke = function(player: Player, boxId: any)
		if type(boxId) ~= "string" then
			return { ok = false, reason = "invalid" }
		end
		return CosmeticService.RollCrate(player, boxId)
	end
	;(getRemote("ClaimFreeCrate", "RemoteFunction") :: RemoteFunction).OnServerInvoke = function(player: Player)
		return CosmeticService.ClaimFreeCrate(player)
	end
	;(getRemote("BuyCrate", "RemoteFunction") :: RemoteFunction).OnServerInvoke = function(player: Player, boxId: any)
		if type(boxId) ~= "string" then
			return { ok = false, reason = "invalid" }
		end
		return CosmeticService.BuyCrate(player, boxId)
	end

	-- Visual equip (fire-and-forget: the CosmeticChanged push carries the authoritative state
	-- either way). The bonus-slot LOADOUT remotes (SetLoadoutSlot/EquipBestLoadout) are owned
	-- by LoadoutService now.
	;(getRemote("EquipCosmetic", "RemoteEvent") :: RemoteEvent).OnServerEvent:Connect(function(player: Player, skinId: any)
		if type(skinId) == "string" then
			CosmeticService.SetEquipped(player, skinId)
		end
	end)

	-- Robux crate purchases: one dev product per box (Config.Crates.Boxes[].Product)
	-- opens one box on receipt, exactly like a Diamonds roll (pity ticks too). The
	-- result is pushed to the buyer over CrateRolled so the client can play the reel
	-- reveal (receipts complete asynchronously — there's no invoke to return through).
	crateRolledRE = getRemote("CrateRolled", "RemoteEvent") :: RemoteEvent
	local ProductService = require(RS.Shared.ProductService) -- lazy: see the note at the top requires
	local PolicyGate = require(RS.Shared.PolicyGate)

	-- Diamond packs (Config.DiamondPacks): one dev product each, granting a flat Diamonds
	-- amount on receipt. Registered here because Diamonds ARE this service's cc.
	-- Paid-random-items-restricted players can't buy Diamonds or crates with Robux (the
	-- client hides/blocks the prompts; refusing the receipt here is the backstop — the
	-- unconsumed purchase is never granted and Roblox eventually reverses it).
	local flyRE = getRemote("PlayCurrencyFly", "RemoteEvent") :: RemoteEvent -- client CurrencyFlyUI listens
	for _, pack in Config.DiamondPacks do
		local packProductId = tonumber(pack.Product)
		if packProductId and packProductId ~= 0 then
			local amount = pack.Diamonds
			ProductService.RegisterProduct(packProductId, function(player: Player, _receiptInfo: any): boolean
				if PolicyGate.PaidRandomItemsRestricted(player) then
					return false -- policy-restricted: never consume this purchase
				end
				if not data[player.UserId] then
					return false -- data not loaded yet; ProcessReceipt retries
				end
				CosmeticService.AddCC(player, amount)
				flyRE:FireClient(player, "Diamonds") -- 💎 fly-to-balance celebration
				return true
			end)
		end
	end

	for _, box in Config.Crates.Boxes :: { BoxDef } do
		local productId = tonumber(box.Product)
		if productId and productId ~= 0 then
			ProductService.RegisterProduct(productId, function(player: Player, _receiptInfo: any): boolean
				if PolicyGate.PaidRandomItemsRestricted(player) then
					return false -- policy-restricted: never consume this purchase
				end
				local d = data[player.UserId]
				if not d then
					return false -- data not loaded yet; ProcessReceipt retries
				end
				local result = rollFrom(player, d, box)
				crateRolledRE:FireClient(player, box.Id, result)
				return true
			end)
		end
	end

	-- The Signal fires LIFO, and Services bootstrap inits CosmeticService BEFORE BallEffects — so
	-- this handler (connected first) runs LAST, painting the equipped skin's colour over BallEffects'
	-- default base colour rather than being overwritten by it.
	BallService.BallSpawned:Connect(onBallSpawn)
	Players.PlayerRemoving:Connect(function(player: Player)
		selected[player.UserId] = nil
	end)
end

return CosmeticService
