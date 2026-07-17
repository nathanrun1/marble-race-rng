--!strict
-- Cached PolicyService wrapper for ArePaidRandomItemsRestricted. Crates are paid random
-- items, and Diamonds exist mainly to buy crates — so for restricted players every
-- Robux purchase path to them is hidden client-side (DiamondsShopUI, CosmeticsShop) and
-- refused server-side (CosmeticService receipt handlers); the per-rarity direct skin
-- products are their compliant alternative.
--
-- Fail-CLOSED: if the policy lookup errors, the player counts as restricted — offering
-- paid random items to a restricted player is the compliance risk; the reverse just
-- hides some buy buttons until a rejoin.
--
-- Dev testing: /policy (DevService) forces the answer per player. The server sets its
-- own override and mirrors it to that player's client over the DevPolicyOverride
-- remote; client consumers re-apply their UI via PolicyGate.OnChanged.

local PolicyService = game:GetService("PolicyService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local DevNet = require(RS.Shared.Remote.DevNet)

local PolicyGate = {}

local cache: { [number]: boolean } = {}
local overrides: { [number]: boolean } = {} -- dev-only forced answers (/policy)
local listeners: { (boolean) -> () } = {}

-- Yields on a player's first call (live policy fetch); cached for the session after.
-- `player` defaults to the LocalPlayer (the usual client call).
function PolicyGate.PaidRandomItemsRestricted(player: Player?): boolean
	local p = player or Players.LocalPlayer
	if not p then
		return true
	end
	local forced = overrides[p.UserId]
	if forced ~= nil then
		return forced
	end
	local hit = cache[p.UserId]
	if hit ~= nil then
		return hit
	end
	local ok, info = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(p)
	end)
	local restricted = true
	if ok and type(info) == "table" then
		restricted = (info :: any).ArePaidRandomItemsRestricted == true
	end
	cache[p.UserId] = restricted
	return restricted
end

-- Client-side: fn(restricted) runs whenever the LOCAL player's effective answer is
-- re-forced by a dev override — consumers re-show/hide their purchase UI from it.
function PolicyGate.OnChanged(fn: (restricted: boolean) -> ())
	table.insert(listeners, fn)
end

-- Dev-only: force the answer for a player on THIS VM (nil clears back to the real
-- policy). Fires OnChanged listeners when it changes the local player's answer.
function PolicyGate.SetOverride(player: Player, restricted: boolean?)
	overrides[player.UserId] = restricted
	if RunService:IsClient() and player == Players.LocalPlayer then
		local effective = PolicyGate.PaidRandomItemsRestricted(player)
		for _, fn in listeners do
			task.spawn(fn, effective)
		end
	end
end

-- Receive the server's /policy override mirror (DevNet; fired by DevService).
if RunService:IsClient() then
	DevNet.DevPolicyOverride.OnClientEvent:Connect(function(restricted: any)
		PolicyGate.SetOverride(
			Players.LocalPlayer,
			if type(restricted) == "boolean" then restricted else nil
		)
	end)
end

Players.PlayerRemoving:Connect(function(player: Player)
	cache[player.UserId] = nil
	overrides[player.UserId] = nil
end)

return PolicyGate
