--!strict
-- Any part tagged Config.Tags.UpgradeShop is an upgrade-shop trigger: touching it opens
-- (or, if already open, switches to) the shop track named by its Track attribute. Tagging
-- replaces the old "must be a child of workspace.UpgradesShop" rule, so a trigger can live
-- anywhere in the workspace.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local Config = require(RS.Shared.Config)

local UpgradeShop = {}

local player = Players.LocalPlayer
local PlayerScripts = player:WaitForChild("PlayerScripts")
local ShopUI = require(PlayerScripts:WaitForChild("ShopUI"))

local TRACK_ATTR = "Track"

-- Track defs live in Config.Upgrades or Config.Axes (axes are purchasable tracks too).
local function iconFor(track: string): string?
	local def = (Config.Upgrades :: any)[track] or (Config.Axes :: any)[track]
	return def and def.Icon
end

-- Paint the part's Icon.SurfaceGui.TextLabel with the track's configured icon, if both
-- the label and an icon exist.
local function applyIcon(inst: Instance, track: string)
	local icon = iconFor(track)
	if not icon then return end
	local container = inst:FindFirstChild("Icon")
	local gui = container and container:FindFirstChild("SurfaceGui")
	local label = gui and gui:FindFirstChild("TextLabel")
	if label and label:IsA("TextLabel") then
		label.Text = icon
	end
end

local function setupShopAt(inst: Instance)
	if not inst:IsA("BasePart") then return end
	local track: string? = inst:GetAttribute(TRACK_ATTR) :: string?
	if not track then return end
	applyIcon(inst, track)
	inst.Touched:Connect(function(obj: Instance)
		if not obj:IsDescendantOf(player.Character) then return end
		if ShopUI.IsOpen() then
			ShopUI.LoadTrack(track)
			return
		end
		ShopUI.OpenShop(track)
	end)
end

function UpgradeShop.Init()
	for _, inst in CollectionService:GetTagged(Config.Tags.UpgradeShop) do
		setupShopAt(inst)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.UpgradeShop):Connect(setupShopAt)
end

return UpgradeShop
