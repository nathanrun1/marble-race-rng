--!strict
-- Ball cosmetics: the CC (Cosmetic Coin) currency, per-player skin ownership, the equipped
-- skin, and the shop's select / buy / equip flow. Skins are defined in shared/BallSkins;
-- BallEffects.ApplyAppearance paints them. CC is earned by rebirthing (PrestigeService grants it)
-- and spent here. Passive data service: DataService owns the lifecycle (ApplyData/SerializeData/
-- Clear), this just holds state, mutates it, and pushes changes to the owning client.

local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local BallSkins = require(RS.Shared.BallSkins)
local BallEffects = require(RS.Shared.BallEffects)
local Signal = require(RS.Shared.Signal)
local BallService = require(SSS.Scripts.Modules.BallService)

local CosmeticService = {}

local DEFAULT_SKIN = BallSkins.GetDefaultId()

export type CosmeticData = {
	cc: number,                   -- Cosmetic Coin balance
	owned: { [string]: boolean }, -- owned skin ids (the default skin is always owned)
	equipped: string,             -- equipped skin id
}

export type CosmeticInfo = {
	cc: number,
	equipped: string,
	selected: string,             -- skin highlighted in the shop (sample ball + buy-button target)
	owned: { [string]: boolean },
}

export type PurchaseResult = { ok: boolean, reason: string?, bought: boolean?, equipped: boolean? }

local data: { [number]: CosmeticData } = {}
local selected: { [number]: string } = {} -- in-memory shop selection (not persisted)

-- (player, info) — fired after any cosmetic change.
CosmeticService.Changed = Signal.new()

local changedRE: RemoteEvent

local function defaults(): CosmeticData
	return { cc = 0, owned = { [DEFAULT_SKIN] = true }, equipped = DEFAULT_SKIN }
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

-- Grant a skin outright (no CC cost) and equip it — used by the Robux fallback product.
function CosmeticService.GrantSkin(player: Player, skinId: string): boolean
	local d = data[player.UserId]
	if not d or not BallSkins.Get(skinId) then
		return false
	end
	d.owned[skinId] = true
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
		d.owned[skinId] = true
		d.equipped = skinId
		announce(player)
		return { ok = true, bought = true }
	end
	return { ok = false, reason = "insufficient_cc" }
end

--------------------------------------------------------------------------------
-- Ball spawn paint
--------------------------------------------------------------------------------
local function onBallSpawn(ball: BasePart, ballInfo: BallService.BallInfo)
	local ownerId = ballInfo.ownerUserId
	local d = if ownerId then data[ownerId] else nil
	CosmeticService.ApplySkin(ball, if d then d.equipped else DEFAULT_SKIN)
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
	end
	d.owned[DEFAULT_SKIN] = true -- the default skin is always owned
	data[player.UserId] = d
	selected[player.UserId] = d.equipped
	announce(player)
end

function CosmeticService.SerializeData(player: Player): CosmeticData
	return get(player.UserId)
end

function CosmeticService.Clear(player: Player)
	data[player.UserId] = nil
	selected[player.UserId] = nil
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

	-- The Signal fires LIFO, and Services bootstrap inits CosmeticService BEFORE BallEffects — so
	-- this handler (connected first) runs LAST, painting the equipped skin's colour over BallEffects'
	-- default base colour rather than being overwritten by it.
	BallService.BallSpawned:Connect(onBallSpawn)
	Players.PlayerRemoving:Connect(function(player: Player)
		selected[player.UserId] = nil
	end)
end

return CosmeticService
