--!strict

local UpgradeShop = {}

local UpgradesShopRoot = game.Workspace:WaitForChild("UpgradesShop")

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local PlayerScripts = player:WaitForChild("PlayerScripts")
local ShopUI = require(PlayerScripts:WaitForChild("ShopUI"))

local TRACK_ATTR = "Track"

function UpgradeShop.Init()
	for _, child in UpgradesShopRoot:GetChildren() do
		local track: string? = child:GetAttribute(TRACK_ATTR) :: string?
		if not track then return end
		print("Linked "..child.Name.." to track: "..track);
		(child :: BasePart).Touched:Connect(function(obj: Instance)
			print("Loading shop for track: "..track)
			if ShopUI.IsOpen() then
				ShopUI.LoadTrack(track)
				return
			end
			if not obj:IsDescendantOf(player.Character) then return end
			ShopUI.OpenShop(track)
		end)
	end	
end

return UpgradeShop