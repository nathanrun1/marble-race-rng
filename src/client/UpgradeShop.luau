--!strict

local UpgradeShop = {}

local UpgradesShopRoot = game.Workspace:WaitForChild("UpgradesShop")

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local PlayerScripts = player:WaitForChild("PlayerScripts")
local ShopUI = require(PlayerScripts:WaitForChild("ShopUI"))

local TRACK_ATTR = "Track"

local function setupShopAt(part: BasePart)
	local track: string? = part:GetAttribute(TRACK_ATTR) :: string?
	if not track then return end
	(part :: BasePart).Touched:Connect(function(obj: Instance)
		print("Loading shop: "..track)
		if not obj:IsDescendantOf(player.Character) then return end
		if ShopUI.IsOpen() then
			ShopUI.LoadTrack(track)
			return
		end
		ShopUI.OpenShop(track)
	end)
end

function UpgradeShop.Init()
	for _, child in UpgradesShopRoot:GetChildren() do
		setupShopAt(child)
	end
	UpgradesShopRoot.ChildAdded:Connect(setupShopAt)
end

return UpgradeShop