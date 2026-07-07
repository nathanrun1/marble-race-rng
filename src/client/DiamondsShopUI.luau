--!strict
-- Diamonds purchase menu (StarterGui.DiamondsShopGui, Studio-authored via MCP; the Panel
-- carries the AutoScale tag). Four packs from Config.DiamondPacks — bigger packs pay more
-- Diamonds per Robux — each card filled from config here so tuning amounts/products never
-- needs a Studio edit. Opened from the "+" on the Diamonds balance (LeftBar) and by
-- CosmeticsShop when a crate roll fails on insufficient Diamonds.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local Config = require(RS.Shared.Config)
local ProductService = require(RS.Shared.ProductService)
local StringUtils = require(RS.Shared.StringUtils)
local WarnUI = require(RS.Shared.WarnUI)
local PolicyGate = require(RS.Shared.PolicyGate)

local DiamondsShopUI = {}

local player = Players.LocalPlayer
local PlayerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local screenGui: ScreenGui? = nil

-- Paid-random-items policy: Diamonds exist to buy crates (paid random items), so for
-- restricted players this whole menu is off — Open() no-ops and the "+" button hides.
local policyBlocked = false
local plusButton: GuiButton? = nil

function DiamondsShopUI.IsOpen(): boolean
	return screenGui ~= nil and (screenGui :: ScreenGui).Enabled
end

function DiamondsShopUI.Open()
	if screenGui and not policyBlocked then
		screenGui.Enabled = true
	end
end

function DiamondsShopUI.Close()
	if screenGui then
		screenGui.Enabled = false
	end
end

local function fillCard(card: Instance, pack: any)
	local icon = card:FindFirstChild("Icon") :: TextLabel?
	local nameL = card:FindFirstChild("PackName") :: TextLabel?
	local amountL = card:FindFirstChild("Amount") :: TextLabel?
	local valueL = card:FindFirstChild("Value") :: TextLabel?
	local buy = card:FindFirstChild("BuyButton") :: TextButton?
	if icon then
		icon.Text = pack.Icon or "💎"
	end
	if nameL then
		nameL.Text = pack.Name or pack.Id
	end
	if amountL then
		amountL.Text = "💎 " .. StringUtils.FormatShort(pack.Diamonds)
	end

	local productId = tonumber(pack.Product)
	if productId == 0 then
		productId = nil
	end

	-- Price on the button: live product price when the id is real, RobuxHint as the
	-- display-only fallback while it's still a placeholder.
	local function setPrice(robux: number?)
		if buy then
			buy.Text = if robux then "R$ " .. robux else "R$ BUY"
		end
		if valueL and robux and robux > 0 then
			valueL.Text = StringUtils.FormatShort(pack.Diamonds / robux, false, 1) .. " 💎/R$"
		end
	end
	setPrice(pack.RobuxHint)
	if productId then
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(productId :: number, Enum.InfoType.Product)
			end)
			if ok and info and type(info.PriceInRobux) == "number" then
				setPrice(info.PriceInRobux)
			end
		end)
	end

	if buy then
		buy.Activated:Connect(function()
			if productId then
				ProductService.Prompt(productId)
			else
				WarnUI.WarnLocal("Coming soon!", nil, 2)
			end
		end)
	end
end

function DiamondsShopUI.Init()
	local gui = PlayerGui:WaitForChild("DiamondsShopGui") :: ScreenGui
	gui.Enabled = false -- clean closed state regardless of how it was saved
	screenGui = gui
	local panel = gui:WaitForChild("Panel")

	;(panel:WaitForChild("CloseButton") :: GuiButton).Activated:Connect(DiamondsShopUI.Close)

	local packsFrame = panel:WaitForChild("Packs")
	for _, pack in Config.DiamondPacks do
		local card = packsFrame:FindFirstChild(pack.Id)
		if card then
			fillCard(card, pack)
		else
			warn("DiamondsShopUI: no authored card for pack " .. tostring(pack.Id))
		end
	end

	-- The "+" on the Diamonds balance opens the shop.
	task.spawn(function()
		local mainGui = PlayerGui:WaitForChild("MainGui")
		local leftBar = mainGui:WaitForChild("LeftBar")
		local diamonds = leftBar:WaitForChild("Diamonds", 10)
		local plus = diamonds and diamonds:FindFirstChild("PlusButton")
		if plus and plus:IsA("GuiButton") then
			plusButton = plus
			plus.Visible = not policyBlocked -- policy may have resolved first
			plus.Activated:Connect(function()
				if DiamondsShopUI.IsOpen() then
					DiamondsShopUI.Close()
				else
					DiamondsShopUI.Open()
				end
			end)
		else
			warn("DiamondsShopUI: PlusButton not found on the Diamonds balance")
		end
	end)

	-- Paid-random-items policy: restricted players never see this menu at all. Applied
	-- from the async fetch AND re-applied on dev /policy toggles (OnChanged).
	local function applyPolicy(restricted: boolean)
		policyBlocked = restricted
		if restricted then
			DiamondsShopUI.Close()
		end
		if plusButton then
			plusButton.Visible = not restricted
		end
	end
	PolicyGate.OnChanged(applyPolicy)
	task.spawn(function()
		applyPolicy(PolicyGate.PaidRandomItemsRestricted())
	end)
end

return DiamondsShopUI
