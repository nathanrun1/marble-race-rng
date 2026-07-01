--!strict
-- Cosmetics shop, built into the world SurfaceGui tagged Config.Tags.CosmeticsGui. Lists every ball
-- skin (shared/BallSkins) as a selectable row showing name, rarity and CC price; shows the player's
-- CC balance (yellow) and a "earn CC by rebirthing" note; and a buy/equip button for the selected
-- skin. Buying spends CC (server-authoritative, CosmeticService); if the player can't afford it, the
-- button prompts the Robux fallback — one dev product per rarity (Config.Cosmetics.RarityProducts).
--
-- Built locally into the shared surface, so each player sees their own CC/owned state.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")

local Config = require(RS.Shared.Config)
local BallSkins = require(RS.Shared.BallSkins)
local StringUtils = require(RS.Shared.StringUtils)
local ProductService = require(RS.Shared.ProductService)

local CosmeticsShop = {}

local YELLOW      = Color3.fromRGB(255, 210, 60)   -- CC currency theme
local PANEL_BG    = Color3.fromRGB(26, 28, 38)
local ROW_BG      = Color3.fromRGB(40, 43, 56)
local ROW_SELECT  = Color3.fromRGB(58, 63, 84)
local TEXT        = Color3.fromRGB(235, 238, 248)
local SUBTLE      = Color3.fromRGB(150, 156, 172)
local GREEN       = Color3.fromRGB(96, 224, 120)

local Remote = RS:WaitForChild("Remote")
local getInfoRF = Remote:WaitForChild("GetCosmeticInfo") :: RemoteFunction
local purchaseRF = Remote:WaitForChild("PurchaseCosmetic") :: RemoteFunction
local selectRE = Remote:WaitForChild("SelectCosmetic") :: RemoteEvent
local changedRE = Remote:WaitForChild("CosmeticChanged") :: RemoteEvent

type Info = { cc: number, equipped: string, selected: string, owned: { [string]: boolean } }

-- Skins listed by rarity then price then name (stable display order).
local orderedSkins: { { id: string, skin: BallSkins.BallSkin } } = {}
do
	for id, skin in BallSkins.GetAll() do
		table.insert(orderedSkins, { id = id, skin = skin })
	end
	table.sort(orderedSkins, function(a, b)
		if a.skin.rarity ~= b.skin.rarity then
			return a.skin.rarity < b.skin.rarity
		end
		if a.skin.price ~= b.skin.price then
			return a.skin.price < b.skin.price
		end
		return a.skin.name < b.skin.name
	end)
end

local info: Info = { cc = 0, equipped = BallSkins.GetDefaultId(), selected = BallSkins.GetDefaultId(), owned = {} }
local rows: { [string]: TextButton } = {}
local ccLabel: TextLabel? = nil
local buyButton: TextButton? = nil
local selectedNameLabel: TextLabel? = nil

-- Forward-declared: refresh() is defined further down, but fetchRobuxPrices (below) needs to
-- call it once a price resolves, and it fires from a task.spawn callback that runs after the
-- whole module (including the real refresh definition) has loaded.
local refresh: () -> ()

-- Robux price (per rarity, from Config.Cosmetics.RarityProducts) so the buy button can show
-- both ways to afford a skin. GetProductInfo yields, so this is fetched once up front and
-- cached — never called from refresh(), which runs often (e.g. every CosmeticChanged).
local robuxPriceByRarity: { [number]: number } = {}

local function fetchRobuxPrices()
	for rarity, idStr in Config.Cosmetics.RarityProducts do
		local productId = tonumber(idStr)
		if productId and productId ~= 0 then
			task.spawn(function()
				local ok, productInfo = pcall(function()
					return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
				end)
				if ok and productInfo and type(productInfo.PriceInRobux) == "number" then
					robuxPriceByRarity[rarity] = productInfo.PriceInRobux
					refresh()
				end
			end)
		end
	end
end

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
end

local function makeLabel(parent: Instance, text: string, size: UDim2, pos: UDim2, color: Color3, scaled: boolean?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = pos
	l.Text = text
	l.TextColor3 = color
	l.Font = Enum.Font.GothamBold
	l.TextScaled = scaled or false
	l.TextSize = 22
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

-- Cell background for the current selected + hover state.
local function setCellBg(cell: TextButton, id: string)
	local base = if info.selected == id then ROW_SELECT else ROW_BG
	if cell:GetAttribute("Hover") then
		base = base:Lerp(Color3.new(1, 1, 1), 0.14)
	end
	cell.BackgroundColor3 = base
end

-- One selectable skin cell (grid tile). Scale-based so it reads well at any cell size.
local function buildCell(parent: Instance, id: string, skin: BallSkins.BallSkin)
	local cell = Instance.new("TextButton")
	cell.Name = id
	cell.BackgroundColor3 = ROW_BG -- size is set by the grid layout
	cell.AutoButtonColor = false
	cell.Text = ""
	cell.Parent = parent
	corner(cell, 8)

	local stroke = Instance.new("UIStroke")
	stroke.Color = BallSkins.RarityColor(skin.rarity)
	stroke.Thickness = 0
	stroke.Parent = cell

	-- Colour swatch of the ball (square circle, top-centre).
	local swatch = Instance.new("Frame")
	swatch.Size = UDim2.fromScale(0.46, 0.46)
	swatch.Position = UDim2.fromScale(0.5, 0.06)
	swatch.AnchorPoint = Vector2.new(0.5, 0)
	swatch.BackgroundColor3 = skin.data.color
	swatch.Parent = cell
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = 1
	ar.Parent = swatch
	local sc = Instance.new("UICorner")
	sc.CornerRadius = UDim.new(0.5, 0)
	sc.Parent = swatch
	local swatchStroke = Instance.new("UIStroke")
	swatchStroke.Color = BallSkins.RarityColor(skin.rarity)
	swatchStroke.Thickness = 2
	swatchStroke.Parent = swatch

	local nameL = makeLabel(cell, skin.name, UDim2.fromScale(0.94, 0.15), UDim2.fromScale(0.5, 0.57), TEXT)
	nameL.AnchorPoint = Vector2.new(0.5, 0)
	nameL.TextXAlignment = Enum.TextXAlignment.Center
	nameL.TextScaled = true

	local rarityL = makeLabel(cell, BallSkins.RarityName(skin.rarity), UDim2.fromScale(0.94, 0.11), UDim2.fromScale(0.5, 0.74), BallSkins.RarityColor(skin.rarity))
	rarityL.AnchorPoint = Vector2.new(0.5, 0)
	rarityL.TextXAlignment = Enum.TextXAlignment.Center
	rarityL.TextScaled = true

	local priceL = makeLabel(cell, "", UDim2.fromScale(0.94, 0.14), UDim2.fromScale(0.5, 0.98), YELLOW)
	priceL.Name = "Price"
	priceL.AnchorPoint = Vector2.new(0.5, 1)
	priceL.TextXAlignment = Enum.TextXAlignment.Center
	priceL.TextScaled = true

	cell.MouseEnter:Connect(function()
		cell:SetAttribute("Hover", true)
		setCellBg(cell, id)
	end)
	cell.MouseLeave:Connect(function()
		cell:SetAttribute("Hover", false)
		setCellBg(cell, id)
	end)
	cell.Activated:Connect(function()
		CosmeticsShop.select(id)
	end)
	rows[id] = cell
end

local function refreshRow(id: string, skin: BallSkins.BallSkin)
	local row = rows[id]
	if not row then
		return
	end
	local owned = info.owned[id] == true
	local equipped = info.equipped == id
	local selected = info.selected == id

	local priceL = row:FindFirstChild("Price") :: TextLabel
	if equipped then
		priceL.Text = "EQUIPPED"
		priceL.TextColor3 = GREEN
	elseif owned then
		priceL.Text = "OWNED"
		priceL.TextColor3 = SUBTLE
	else
		priceL.Text = StringUtils.FormatShort(skin.price) .. " CC"
		priceL.TextColor3 = YELLOW
	end

	setCellBg(row, id)
	local stroke = row:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Thickness = if selected then 2.5 else 0
	end
end

function refresh()
	if ccLabel then
		ccLabel.Text = StringUtils.FormatShort(info.cc) .. " CC"
	end
	for _, entry in orderedSkins do
		refreshRow(entry.id, entry.skin)
	end

	local sel = BallSkins.Get(info.selected) or BallSkins.Get(BallSkins.GetDefaultId())
	if selectedNameLabel and sel then
		selectedNameLabel.Text = sel.name .. "  •  " .. BallSkins.RarityName(sel.rarity)
		selectedNameLabel.TextColor3 = BallSkins.RarityColor(sel.rarity)
	end
	if buyButton and sel then
		local owned = info.owned[info.selected] == true
		local equipped = info.equipped == info.selected
		if equipped then
			buyButton.Text = "EQUIPPED"
			buyButton.BackgroundColor3 = Color3.fromRGB(70, 76, 96)
		elseif owned then
			buyButton.Text = "EQUIP"
			buyButton.BackgroundColor3 = GREEN
		else
			local text = "BUY  •  " .. StringUtils.FormatShort(sel.price) .. " CC"
			local robuxPrice = robuxPriceByRarity[sel.rarity]
			if robuxPrice then
				text ..= "  |  R$" .. robuxPrice
			end
			buyButton.Text = text
			buyButton.BackgroundColor3 = YELLOW
		end
	end
end

-- Select a skin: tell the server (drives the sample ball + CC/selected state), and update locally
-- so the highlight is instant.
function CosmeticsShop.select(id: string)
	if not BallSkins.Get(id) then
		return
	end
	info.selected = id
	selectRE:FireServer(id)
	refresh()
end

function CosmeticsShop.purchase()
	local id = info.selected
	local result = purchaseRF:InvokeServer(id)
	if type(result) == "table" and not result.ok and result.reason == "insufficient_cc" then
		-- Can't afford with CC — offer the Robux fallback for this skin's rarity (it grants it).
		local skin = BallSkins.Get(id)
		local productStr = skin and Config.Cosmetics.RarityProducts[skin.rarity]
		local productId = productStr and tonumber(productStr)
		if productId and productId ~= 0 then
			ProductService.Prompt(productId)
		end
	end
	-- Server pushes CosmeticChanged on success; nothing else to do here.
end

local function build(surface: SurfaceGui)
	local existing = surface:FindFirstChild("CosmeticsShop")
	if existing then
		existing:Destroy()
	end

	local root = Instance.new("Frame")
	root.Name = "CosmeticsShop"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = PANEL_BG
	root.BorderSizePixel = 0
	root.Parent = surface

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.03, 0)
	pad.PaddingBottom = UDim.new(0.03, 0)
	pad.PaddingLeft = UDim.new(0.03, 0)
	pad.PaddingRight = UDim.new(0.03, 0)
	pad.Parent = root

	-- Header: title + CC balance (yellow).
	local title = makeLabel(root, "COSMETICS", UDim2.new(0.55, 0, 0.09, 0), UDim2.fromScale(0, 0), TEXT)
	title.TextScaled = true
	local cc = makeLabel(root, "0 CC", UDim2.new(0.42, 0, 0.09, 0), UDim2.new(0.58, 0, 0, 0), YELLOW)
	cc.TextScaled = true
	cc.TextXAlignment = Enum.TextXAlignment.Right
	ccLabel = cc

	-- Notes: earn CC by rebirthing (left), and any skin is also buyable with Robux (right).
	local note = makeLabel(root, "✦ Earn CC by rebirthing!", UDim2.new(0.5, 0, 0.05, 0), UDim2.fromScale(0, 0.10), YELLOW)
	note.TextScaled = true
	note.TextTransparency = 0.15
	local robuxNote = makeLabel(root, "💎 Or buy any skin with Robux", UDim2.new(0.5, 0, 0.05, 0), UDim2.fromScale(0.5, 0.10), Color3.fromRGB(70, 215, 130))
	robuxNote.TextXAlignment = Enum.TextXAlignment.Right
	robuxNote.TextScaled = true
	robuxNote.TextTransparency = 0.15

	-- Skin list.
	local frame = Instance.new("ScrollingFrame")
	frame.Size = UDim2.fromScale(1, 0.63)
	frame.Position = UDim2.fromScale(0, 0.16)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.ScrollBarThickness = 18 -- chunky so it's easy to grab/drag on the world surface
	frame.ScrollBarImageColor3 = Color3.fromRGB(120, 126, 145)
	frame.CanvasSize = UDim2.new()
	frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	frame.Parent = root
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(132, 120)
	grid.CellPadding = UDim2.fromOffset(10, 10)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.Parent = frame

	for _, entry in orderedSkins do
		buildCell(frame, entry.id, entry.skin)
	end

	-- Footer: selected skin + buy/equip button.
	local footer = Instance.new("Frame")
	footer.Size = UDim2.fromScale(1, 0.16)
	footer.Position = UDim2.fromScale(0, 0.82)
	footer.BackgroundTransparency = 1
	footer.Parent = root

	selectedNameLabel = makeLabel(footer, "", UDim2.new(0.5, 0, 0.5, 0), UDim2.fromScale(0, 0.25), TEXT)
	selectedNameLabel.TextScaled = true

	local buy = Instance.new("TextButton")
	buy.Size = UDim2.fromScale(0.48, 0.7)
	buy.Position = UDim2.fromScale(0.50, 0.15)
	buy.BackgroundColor3 = YELLOW
	buy.Text = "BUY"
	buy.TextColor3 = Color3.fromRGB(30, 28, 10)
	buy.Font = Enum.Font.GothamBold
	buy.TextScaled = true
	buy.AutoButtonColor = true
	buy.Parent = footer
	corner(buy, 10)
	local buyPad = Instance.new("UIPadding")
	buyPad.PaddingTop = UDim.new(0.18, 0)
	buyPad.PaddingBottom = UDim.new(0.18, 0)
	buyPad.PaddingLeft = UDim.new(0.05, 0)
	buyPad.PaddingRight = UDim.new(0.05, 0)
	buyPad.Parent = buy
	buy.Activated:Connect(CosmeticsShop.purchase)
	buyButton = buy

	refresh()
end

function CosmeticsShop.Init()
	local function setup(inst: Instance)
		if inst:IsA("SurfaceGui") then
			build(inst)
			refresh()
		end
	end
	for _, inst in CollectionService:GetTagged(Config.Tags.CosmeticsGui) do
		setup(inst)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.CosmeticsGui):Connect(setup)

	changedRE.OnClientEvent:Connect(function(newInfo: Info)
		if newInfo then
			info = newInfo
			refresh()
		end
	end)

	-- Initial state.
	local got = getInfoRF:InvokeServer()
	if got then
		info = got
		refresh()
	end

	fetchRobuxPrices()
end

return CosmeticsShop
