--!strict

local Players: Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local ProfileStats = require(RS.Shared.ProfileStats)

local player: Player = Players.LocalPlayer :: Player
local PlayerGui: PlayerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local ShopGui = PlayerGui:WaitForChild("ShopGui") :: any

local BalanceChangedRE: RemoteEvent = RS.Remote.BalanceChanged
local GetUpgradeInfoRF: RemoteFunction = RS.Remote.GetUpgradeInfo
local PurchaseUpgradeRF: RemoteFunction = RS.Remote.PurchaseUpgrade

local UI = {
	name = ShopGui.ShopFrame.Head.NameStack.ShopName, -- TextLabel
	icon = ShopGui.ShopFrame.Head.Icon.TextLabel, -- TextLabel
	desc = ShopGui.ShopFrame.Head.NameStack.ShopDesc, -- TextLabel
	tiers = ShopGui.ShopFrame.Head.TierBadge.BadgeStack.TierNumber, -- TextLabel
	price = ShopGui.ShopFrame.BuyButton.BuyInner.PriceChip.PriceLabel, -- TextLabel
	purchaseBtn = ShopGui.ShopFrame.BuyButton, -- ImageButton
	curValue = ShopGui.ShopFrame.Effect.CurrentCell.Frame.Value, -- TextLabel
	nextValue = ShopGui.ShopFrame.Effect.NextCell.Frame.Value, -- TextLabel
	track = ShopGui.ShopFrame.Track -- Frame
}

-- Types copied from UpgradeService
export type Info = {
	track: string,
	name: string,
	desc: string,
	icon: string,
	tier: number,
	maxTier: number?, -- nil = unbounded
	maxed: boolean,
	price: number?,   -- nil if maxed
	canAfford: boolean,
}
export type PurchaseResult = {
	ok: boolean,
	reason: string?,               -- "invalid_track" | "maxed" | "cannot_afford"
}

export type Upgrades = { [string]: number }

local MAGENTA      = Color3.fromRGB(236, 63, 212)   -- #ec3fd4  borders / accent
local PIP_BORDER   = Color3.fromRGB(234, 220, 240)  -- #eadcf0  empty pip border
local CHIP         = Color3.fromRGB(244, 238, 248)  -- #f4eef8  chip / empty pip

local loadedTrack: string? = nil

local function f(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	if parent then o.Parent = parent end
	return o
end

local function corner(r, parent)
	f("UICorner", { CornerRadius = UDim.new(0, r) }, parent)
end

-- box border (vector, constant thickness at any size) — parent to a FRAME
local function stroke(parent, color, thickness)
	return f("UIStroke", {
		Color           = color,
		Thickness       = thickness or 3,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode    = Enum.LineJoinMode.Round,
	}, parent)
end


-- Colour one pip for a given state: "fill" | "empty" | "next"
local function stylePip(pip: Frame, state: string)
	local s: UIStroke = pip:FindFirstChildOfClass("UIStroke") :: UIStroke
	if state == "fill" then
		pip.BackgroundColor3 = MAGENTA
		s.Color = MAGENTA
		s.LineJoinMode = Enum.LineJoinMode.Round
	elseif state == "next" then
		pip.BackgroundColor3 = CHIP
		s.Color = MAGENTA          -- "up next" — magenta edge on empty fill
	else -- empty
		pip.BackgroundColor3 = CHIP
		s.Color = PIP_BORDER
	end
end

-- Build the pips for a shop. Pass currentTier to colour them in one shot.
-- filled = tiers you own, next = the one you're buying, empty = the rest.
local function createPips(trackFrame: Instance, maxTier: number?, currentTier: number)
	currentTier = currentTier or 0
	for _, child in ipairs(trackFrame:GetChildren()) do
		if child:IsA("Frame") and child.Name == "Pip" then child:Destroy() end
	end

    if maxTier == nil then
        return -- No pips if no max tier
    end

	for i = 1, maxTier do
		local pip: Frame = f("Frame", {
			Name           = "Pip",
			Size           = UDim2.new(1 / maxTier, -6, 1, 0), -- -6 absorbs the 6px gap
			BackgroundColor3 = CHIP,
			BorderSizePixel = 0,
			LayoutOrder    = i,
		}, trackFrame) :: Frame
		corner(7, pip)
		stroke(pip, PIP_BORDER, 2)
		local state = (i <= currentTier) and "fill"
			or (i == currentTier + 1 and currentTier < maxTier) and "next"
			or "empty"
		stylePip(pip, state)
	end
end

-- Adjust the purchase button based on whether the upgrade can be afforded
function adjustButton(canAfford: boolean)
	local ACTIVE_COLOR = Color3.new(1.0, 1.0, 1.0)
	local INACTIVE_COLOR = Color3.new(130/255, 130/255, 130/255)
	local INACTIVE_COLOR2 = Color3.new(169/255, 169/255, 169/255)
    local PRICE_CHIP_TEXT_ACTIVE = Color3.new(236/255, 63/255, 212/255)
	
	local purchaseBtn: any = UI.purchaseBtn
	if canAfford then
		purchaseBtn.ImageColor3 = ACTIVE_COLOR
        purchaseBtn.BuyInner.Word.TextColor3 = ACTIVE_COLOR
        purchaseBtn.BuyInner.PriceChip.BackgroundColor3 = ACTIVE_COLOR
        purchaseBtn.BuyInner.PriceChip.PriceLabel.TextColor3 = PRICE_CHIP_TEXT_ACTIVE
	else
		purchaseBtn.ImageColor3 = INACTIVE_COLOR
        purchaseBtn.BuyInner.Word.TextColor3 = INACTIVE_COLOR
        purchaseBtn.BuyInner.PriceChip.BackgroundColor3 = INACTIVE_COLOR2
        purchaseBtn.BuyInner.PriceChip.PriceLabel.TextColor3 = INACTIVE_COLOR
	end
end

-- Loads ShopGui contents with the given track
function loadShop(track: string)
	local allUpgradeInfo: { [string]: Info } = GetUpgradeInfoRF:InvokeServer()
	local upgradeInfo: Info = allUpgradeInfo[track]
	assert(upgradeInfo)
	
	UI.name.Text = upgradeInfo.name
	UI.desc.Text = upgradeInfo.desc
	UI.icon.Text = upgradeInfo.icon
	if upgradeInfo.maxTier ~= nil then
		UI.tiers.Text = upgradeInfo.tier.." / "..upgradeInfo.maxTier
	else
		UI.tiers.Text = upgradeInfo.tier
	end
    if upgradeInfo.price then
        UI.price.Text = "$"..tostring(upgradeInfo.price)
    else
        UI.price.Text = "MAXED"
    end
	adjustButton(upgradeInfo.canAfford)
	
	UI.curValue.Text = ProfileStats.GetDisplayString(track, upgradeInfo.tier)
	if not upgradeInfo.maxed then
		UI.nextValue.Text = ProfileStats.GetDisplayString(track, upgradeInfo.tier + 1)
	else
		UI.nextValue.Text = "—"
	end
	
	createPips(UI.track, upgradeInfo.maxTier, upgradeInfo.tier)
    
    loadedTrack = track
end

-- Invoked when purchase button pressed
function onBuyPressed()
    if loadedTrack == nil then
        return
    end

	local purchaseResult: PurchaseResult = PurchaseUpgradeRF:InvokeServer(loadedTrack)
    if purchaseResult.ok then
        -- TODO: if purchase good, trigger +tier animation
        loadShop(loadedTrack :: string)
    end
end

BalanceChangedRE.OnClientEvent:Connect(function()
    if ShopGui.Enabled and loadedTrack then
        loadShop(loadedTrack)
    end
end)

UI.purchaseBtn.Activated:Connect(onBuyPressed)

loadShop("Frequency")
