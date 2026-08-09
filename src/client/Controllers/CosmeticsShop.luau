--!strict
-- Marble shop, built into the world SurfaceGui tagged TagsConfig.CosmeticsGui.
-- Two tabs (left column):
--   LUCK (primary) — the Luck upgrade card: the rebirth-persistent Luck track
--     (Config/Upgrades) that biases every roll toward rarer marbles. A barrier ladder:
--     cash-priced + sub-tiers, with a Diamond-priced barrier into each next display
--     tier (the card goes red-locked at a barrier). The free roll
--     (the main way to get skins) is claimed at its WORLD pad (TagsConfig.FreeCratePad,
--     billboard/countdown below), not from a shop card; the purchasable crates are
--     retired — skins are a core bet-multiplier mechanic now, not loot to sell.
--   INDEX — every marble in the collection grid. Locked ones render as a dark silhouette
--     with a "???" name; owned ones read brighter (as before) and show their ★ star from
--     duplicate copies. The footer wears an owned marble (visual) or jumps to the LUCK
--     tab for a locked one — rolling is the only unlock path. Can't-afford Luck buys open
--     the Diamonds shop. EXCEPTION: paid-random-items-restricted players (PolicyGate)
--     get the deterministic per-rarity R$ direct buy in the index footer.
--
-- Built locally into the shared surface, so each player sees their own Diamonds/owned state.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local MarketplaceService = game:GetService("MarketplaceService")

local CosmeticsConfig = require(RS.Shared.Config.Cosmetics)
local CratesConfig = require(RS.Shared.Config.Crates)
local SoundsConfig = require(RS.Shared.Config.Sounds)
local TagsConfig = require(RS.Shared.Config.Tags)
local BallSkins = require(RS.Shared.BallSkins)
local CosmeticBonus = require(RS.Shared.CosmeticBonus)
local ProfileStats = require(RS.Shared.ProfileStats)
local UpgradeInfo = require(RS.Shared.UpgradeInfo)
local StringUtils = require(RS.Shared.Utility.StringUtils)
local WeightedRandom = require(RS.Shared.Utility.WeightedRandom)
local ProductService = require(RS.Shared.ProductService)
local WarnUI = require(RS.Shared.WarnUI)
local SoundService = require(RS.Shared.SoundService)
local PolicyGate = require(RS.Shared.PolicyGate)
local CrateRollUI = require(script.Parent.CrateRollUI)
local DiamondsShopUI = require(script.Parent.DiamondsShopUI)
local CurrencyFlyUI = require(script.Parent.CurrencyFlyUI)
local FreeRollBallSample = require(script.Parent.FreeRollBallSample)
local CosmeticsNet = require(RS.Shared.Remote.CosmeticsNet)
local CurrencyNet = require(RS.Shared.Remote.CurrencyNet)
local ProfileNet = require(RS.Shared.Remote.ProfileNet)
local UpgradeNet = require(RS.Shared.Remote.UpgradeNet)

local CosmeticsShop = {}

local YELLOW      = Color3.fromRGB(255, 210, 60)   -- Diamonds currency theme
local PANEL_BG    = Color3.fromRGB(26, 28, 38)
local ROW_BG      = Color3.fromRGB(40, 43, 56)
local ROW_SELECT  = Color3.fromRGB(58, 63, 84)
local TEXT        = Color3.fromRGB(235, 238, 248)
local SUBTLE      = Color3.fromRGB(150, 156, 172)
local GREEN       = Color3.fromRGB(96, 224, 120)
local BLUE        = Color3.fromRGB(70, 130, 240)
local LOCKED_SWATCH = Color3.fromRGB(22, 23, 30)   -- silhouette fill for unowned skins
local GOLD        = Color3.fromRGB(255, 200, 40)
local RED         = Color3.fromRGB(235, 70, 70)    -- Luck card's barrier-locked highlight

local getInfoRF = CosmeticsNet.GetCosmeticInfo :: RemoteFunction
local selectRE = CosmeticsNet.SelectCosmetic :: RemoteEvent
local changedRE = CosmeticsNet.CosmeticChanged :: RemoteEvent
local claimFreeRF = CosmeticsNet.ClaimFreeCrate :: RemoteFunction
local equipRE = CosmeticsNet.EquipCosmetic :: RemoteEvent
local finishRollRE = CosmeticsNet.FinishCrateRoll :: RemoteEvent

-- FinishCrateRoll fires this long after the reveal banner, covering the marble-fly
-- flight (CurrencyFlyUI FLY_TIME + jitter) so the inventory commit lands with it.
local ROLL_COMMIT_DELAY = 0.7
local purchaseUpgradeRF = UpgradeNet.PurchaseUpgrade :: RemoteFunction

type Info = {
	cc: number,
	equipped: string,
	selected: string,
	owned: { [string]: boolean },
	copies: { [string]: number },
	pity: { [string]: number },
	boxes: { [string]: number },
	freeCrateIn: number,
}

type RollResult = {
	ok: boolean,
	reason: string?,
	skinId: string?,
	rarity: number?,
	copies: number?,
	star: number?,
	isNew: boolean?,
}

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

local info: Info = {
	cc = 0,
	equipped = BallSkins.GetDefaultId(),
	selected = BallSkins.GetDefaultId(),
	owned = {},
	copies = {},
	pity = {},
	boxes = {},
	freeCrateIn = math.huge,
}

-- Free-box deadline in local clock terms, refreshed from every info push; the 1 Hz ticker
-- renders the countdown from this without more server traffic.
local freeReadyAt = math.huge

local rows: { [string]: TextButton } = {}
local ccLabel: TextLabel? = nil
local buyButton: TextButton? = nil
local selectedNameLabel: TextLabel? = nil
local rolling = false                            -- one roll in flight at a time
local openLuckTab: (() -> ())? = nil             -- set by build(); "UNLOCK FROM ROLLS" jumps there

-- Luck upgrade card state (LUCK tab): the tier comes from ProfileChanged pushes; price/
-- affordability are recomputed locally from UpgradeInfo (same pure math the server prices
-- with). Luck is a barrier ladder now: sub-tier (+) purchases charge CASH (`cashBalance`,
-- from CurrencyNet pushes), the every-4th barrier into the next display tier charges
-- Diamonds (`info.cc`) — UpgradeInfo.CurrencyAt picks per tier.
local luckTier = 0
local luckTierLabel: TextLabel? = nil
local luckEffectLabel: TextLabel? = nil
local luckButton: TextButton? = nil
local luckCardStroke: UIStroke? = nil -- card outline: GREEN normally, RED at a Diamond barrier
local luckBuying = false -- one purchase in flight at a time
local cashBalance = 0 -- CurrencyNet.BalanceChanged mirror, for the cash-priced sub-tiers
local luckOddsRows: { { name: TextLabel, odds: TextLabel } } = {} -- ODDS card, one row per rarity

-- Paid-random-items policy (PolicyGate): nil until the async fetch lands. Restricted
-- players get the deterministic per-rarity direct skin purchase (RarityProducts) in the
-- index footer.
local paidRandomRestricted: boolean? = nil
local robuxBuyButton: TextButton? = nil          -- footer direct-buy (restricted players only)
local robuxBuyProductId: number? = nil           -- product for the currently selected skin's rarity

local refresh: () -> ()

-- Cached live Robux prices (MarketplaceService.GetProductInfo). Returns nil while the
-- fetch is in flight and re-runs refresh() when it lands, so buttons showing a bare
-- "R$ BUY" upgrade themselves to the real price.
local robuxPriceCache: { [number]: number } = {}
local robuxPriceFetching: { [number]: boolean } = {}
local function robuxPrice(id: number): number?
	local cached = robuxPriceCache[id]
	if cached then
		return cached
	end
	if not robuxPriceFetching[id] then
		robuxPriceFetching[id] = true
		task.spawn(function()
			local ok, prodInfo = pcall(function()
				return MarketplaceService:GetProductInfo(id, Enum.InfoType.Product)
			end)
			if ok and prodInfo and type(prodInfo.PriceInRobux) == "number" then
				robuxPriceCache[id] = prodInfo.PriceInRobux
				refresh()
			end
		end)
	end
	return nil
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

--------------------------------------------------------------------------------
-- Index tab: skin cells
--------------------------------------------------------------------------------
-- Cell background for the current owned + selected + hover state.
local function setCellBg(cell: TextButton, id: string)
	local base = if info.selected == id then ROW_SELECT else ROW_BG
	-- Owned skins read brighter, so the collection is scannable at a glance.
	if info.owned[id] == true or info.equipped == id then
		base = base:Lerp(Color3.new(1, 1, 1), 0.18)
	end
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

	-- Colour swatch of the ball (square circle, top-centre). Locked skins render this
	-- as a dark silhouette (refreshRow drives the colour).
	local swatch = Instance.new("Frame")
	swatch.Name = "Swatch"
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
	nameL.Name = "SkinName"
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
	local selectedNow = info.selected == id

	local swatch = row:FindFirstChild("Swatch") :: Frame
	local nameL = row:FindFirstChild("SkinName") :: TextLabel
	local priceL = row:FindFirstChild("Price") :: TextLabel

	-- Locked = silhouette: dark swatch, "???" name. Owned shows the real colours + star.
	swatch.BackgroundColor3 = if owned then skin.data.color else LOCKED_SWATCH
	nameL.Text = if owned then skin.name else "???"

	if equipped then
		priceL.Text = "WEARING"
		priceL.TextColor3 = GREEN
	elseif owned then
		local star = CosmeticBonus.StarOf(info.copies[id] or 1)
		priceL.Text = string.rep("★", star)
		priceL.TextColor3 = GOLD
	else
		priceL.Text = "🔒"
		priceL.TextColor3 = SUBTLE
	end

	setCellBg(row, id)
	local stroke = row:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Thickness = if selectedNow then 2.5 else 0
	end
end

--------------------------------------------------------------------------------
-- Luck tab helpers
--------------------------------------------------------------------------------
-- Announce a roll result (banner colored by rarity) and select the skin so the sample
-- ball + index highlight show what just came out of the box.
local function presentRoll(result: RollResult)
	if not result.ok or not result.skinId then
		if result.reason == "insufficient_cc" then
			WarnUI.WarnLocal("Not enough Diamonds!", Color3.fromRGB(255, 120, 120))
			DiamondsShopUI.Open() -- the fix is one purchase away
		end
		return
	end
	local skin = BallSkins.Get(result.skinId)
	local rarity = result.rarity or (skin and skin.rarity) or 1
	local name = if skin then skin.name else result.skinId
	local text
	if result.isNew then
		text = ("NEW! %s (%s)"):format(name, BallSkins.RarityName(rarity))
	else
		text = ("%s ★%d (%s copy #%d)"):format(name, result.star or 1, BallSkins.RarityName(rarity), result.copies or 1)
	end
	WarnUI.WarnLocal(text, BallSkins.RarityColor(rarity), 4)
	-- Reveal sting scales with the pull's rarity: Common-Rare (1-3), Epic-Mythic (4-6),
	-- Celestial+ (7-9).
	local sting = if rarity >= 7 then SoundsConfig.Confirmation4
		elseif rarity >= 4 then SoundsConfig.Confirmation3
		else SoundsConfig.Confirmation2
	SoundService.Play({ soundId = sting })
	-- The won marble flies home: ONE colour swatch (rarity ring) into LOADOUT — it's a
	-- single marble, not a currency pile.
	if skin then
		CurrencyFlyUI.PlayMarble(skin.data.color, BallSkins.RarityColor(rarity), 1)
	end
	CosmeticsShop.select(result.skinId)
end

local function boxWeights(boxId: string): { number }?
	for _, box in CratesConfig.Boxes do
		if box.Id == boxId then
			return box.Weights
		end
	end
	return nil
end

-- Shared roll flow: invoke, play a reveal on success (yields until it lands), then banner
-- the result. `rolling` stays held for the whole reveal so a second click can't start a
-- spin over the running one. `reveal` defaults to the CrateRollUI reel; the free box passes
-- its own (the MarbleRoll ball sample rolling in-world instead of a screen overlay).
local function runRoll(weights: { number }?, invoke: () -> RollResult, reveal: ((RollResult) -> ())?)
	if rolling then
		return
	end
	rolling = true
	local ok, result = pcall(invoke)
	if ok and type(result) == "table" then
		if result.ok then
			if reveal then
				reveal(result)
			elseif weights then
				CrateRollUI.Play(weights, result)
			end
		end
		presentRoll(result)
		-- Reveal done, marble-fly in the air: tell the server to commit the rolled skin
		-- (it holds crate rolls out of the inventory until this lands; see
		-- CosmeticService's deferred-commit block).
		if result.ok and result.skinId then
			task.delay(ROLL_COMMIT_DELAY, function()
				finishRollRE:FireServer()
			end)
		end
	end
	rolling = false
end

-- Buy one Luck tier (server-authoritative through the ordinary upgrade purchase
-- remote; the server charges cash for + sub-tiers, Diamonds at barriers). The fresh
-- tier lands via ProfileChanged and the new balances via CosmeticChanged /
-- BalanceChanged, but the tier is applied optimistically from the result snapshot so
-- the card can't render stale between pushes.
function CosmeticsShop.buyLuck()
	if luckBuying then
		return
	end
	local wasBarrier = UpgradeInfo.IsBarrierAt("Luck", luckTier)
	luckBuying = true
	local ok, result = pcall(function()
		return purchaseUpgradeRF:InvokeServer("Luck")
	end)
	luckBuying = false
	if not ok or type(result) ~= "table" then
		return
	end
	if result.ok then
		WarnUI.WarnLocal(if wasBarrier then "🍀 Luck Tier unlocked!" else "🍀 Luck upgraded!", GREEN, 3)
		SoundService.Play({ soundId = SoundsConfig.Upgrade })
	elseif result.reason == "cannot_afford" then
		if wasBarrier then
			WarnUI.WarnLocal("Not enough Diamonds!", Color3.fromRGB(255, 120, 120))
			DiamondsShopUI.Open() -- the fix is one purchase away
		else
			WarnUI.WarnLocal("Not enough Cash!", Color3.fromRGB(255, 120, 120))
		end
	end
	local upgrades = result.upgrades
	if type(upgrades) == "table" and type(upgrades.Luck) == "table" and type(upgrades.Luck.tier) == "number" then
		luckTier = upgrades.Luck.tier
	end
	refresh()
end

function CosmeticsShop.claimFree()
	runRoll(CratesConfig.Free.Weights, function()
		return claimFreeRF:InvokeServer() :: RollResult
	end, FreeRollBallSample.PlayRoll)
end

--------------------------------------------------------------------------------
-- Selection / equip / Robux fallback
--------------------------------------------------------------------------------
-- Select a skin: tell the server (drives the sample ball + selected state), and update
-- locally so the highlight is instant.
function CosmeticsShop.select(id: string)
	if not BallSkins.Get(id) then
		return
	end
	info.selected = id
	selectRE:FireServer(id)
	refresh()
end

-- Footer button on the index tab: equips the selected skin when owned (visual skin;
-- server-validated); on a locked skin it reads "UNLOCK FROM ROLLS" and jumps to the
-- LUCK tab (the Robux product button next to it is the direct-unlock path).
function CosmeticsShop.equipSelected()
	if info.owned[info.selected] == true then
		equipRE:FireServer(info.selected)
	elseif openLuckTab then
		openLuckTab()
	end
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------
local function formatCountdown(seconds: number): string
	local s = math.max(math.ceil(seconds), 0)
	return ("%d:%02d"):format(s // 60, s % 60)
end

-- Timer labels on the world free-crate pads (billboards), updated by the same ticker.
local padTimerLabels: { TextLabel } = {}

-- The pad billboard is ONLY the countdown: visible while the roll is cooling down,
-- hidden entirely once it's ready (the pad itself is the announcement — the roll
-- interval is seconds, so any per-cycle banner would be pure spam).
local function refreshFreeButton()
	local remaining = freeReadyAt - os.clock()
	-- freeReadyAt is math.huge until the first server info lands — treat that as
	-- "not counting down" rather than formatting an infinite countdown.
	local counting = remaining > 0 and remaining ~= math.huge
	for _, label in padTimerLabels do
		label.Visible = counting
		if counting then
			label.Text = formatCountdown(remaining)
		end
	end
end

----------------------------------------------------------------
-- Free-crate pad (TagsConfig.FreeCratePad): billboard + countdown, touch to claim.
-- Mirrors the group-reward pad: the client only renders/asks; the server's free-box
-- timer is what actually gates the claim.
----------------------------------------------------------------
local PAD_TOUCH_DEBOUNCE = 1.5
local padLastTouch: { [Instance]: number } = {}

local function setupFreeCratePad(inst: Instance)
	-- The tagged instance is the "MarbleRoll" part (the ball sample floats above it); the
	-- actual touchable floor part is its child "Pad" — same shape as UpgradeLock's tagged
	-- Model + child "Pad". Check for that child FIRST (MarbleRoll is itself a BasePart, so it
	-- would otherwise short-circuit and never look for Pad); fall back to the tagged instance
	-- itself only if it has no "Pad" child (legacy shape).
	local padChild = inst:FindFirstChild("Pad")
	local pad = if padChild and padChild:IsA("BasePart") then padChild
		elseif inst:IsA("BasePart") then inst
		else nil
	if not pad or padLastTouch[pad] ~= nil then
		return
	end
	padLastTouch[pad] = 0 -- doubles as the "already wired" marker

	-- The billboard SHELL is Studio-authored (Billboard.BillboardGui, positioned in-world by
	-- hand, on either the pad or the tagged instance); this only fills in the countdown.
	local holder = pad:FindFirstChild("Billboard") or inst:FindFirstChild("Billboard")
	local bb = holder and holder:FindFirstChild("BillboardGui")
	if bb and bb:IsA("BillboardGui") then
		-- A copy saved from an older runtime build may carry the retired title label.
		local staleTitle = bb:FindFirstChild("FreeCrateTitle")
		if staleTitle then
			staleTitle:Destroy()
		end
		if not bb:FindFirstChild("FreeCrateTimer") then
			local timer = Instance.new("TextLabel")
			timer.Name = "FreeCrateTimer"
			timer.BackgroundTransparency = 1
			timer.Size = UDim2.fromScale(1, 1)
			timer.Font = Enum.Font.FredokaOne
			timer.TextScaled = true
			timer.TextColor3 = TEXT
			timer.TextStrokeColor3 = Color3.new(0, 0, 0)
			timer.TextStrokeTransparency = 0.5
			timer.Text = ""
			timer.Visible = false -- refreshFreeButton shows it only while cooling down
			timer.Parent = bb
			table.insert(padTimerLabels, timer)
		end
	else
		warn("CosmeticsShop: FreeCratePad has no Billboard.BillboardGui — pad works, but no sign")
	end

	local player = Players.LocalPlayer
	pad.Touched:Connect(function(obj: Instance)
		local char = player.Character
		if not char or not obj:IsDescendantOf(char) then
			return
		end
		local now = os.clock()
		if now - (padLastTouch[pad] or 0) < PAD_TOUCH_DEBOUNCE then
			return
		end
		padLastTouch[pad] = now
		if freeReadyAt - os.clock() <= 0 then
			CosmeticsShop.claimFree()
		end
	end)
end

-- One decimal place normally; two below 0.1% (so a real chance never displays as a flat
-- "0.0%"); "<0.01%" once it's below display resolution.
local function formatPct(p: number): string
	local pct = p * 100
	if pct < 0.01 then
		return "<0.01%"
	elseif pct < 0.1 then
		return string.format("%.2f%%", pct)
	end
	return string.format("%.1f%%", pct)
end

-- ODDS card refresh: per-rarity roll chance at the CURRENT Luck tier, and what the next
-- tier turns it into ("cur% -> next%"; current only when maxed). Uses the free roll's
-- weights (the shop's one roll source) through WeightedRandom.LuckBiasedOdds — the exact
-- distribution of the server's PickIndexLuckBiased, so these numbers can't drift from
-- the real roll.
local function refreshLuckOdds(maxed: boolean)
	if #luckOddsRows == 0 then
		return
	end
	local weights = CratesConfig.Free.Weights
	local cur = WeightedRandom.LuckBiasedOdds(weights, ProfileStats.GetLuckAtTier(luckTier))
	local nxt = if maxed then nil else WeightedRandom.LuckBiasedOdds(weights, ProfileStats.GetLuckAtTier(luckTier + 1))
	for i, row in luckOddsRows do
		local text = formatPct(cur[i] or 0)
		if nxt then
			text ..= "  ->  " .. formatPct(nxt[i] or 0)
		end
		row.odds.Text = text
	end
end

-- Luck card: tier ("Tier 1++" ladder label), current -> next roll-odds multiplier, and
-- the buy button's price/affordability — against the balance of whichever currency the
-- NEXT tier charges (cash for + sub-tiers, Diamonds at a barrier; same UpgradeInfo math
-- the server uses). At a barrier the card locks visually: red outline, red tier label,
-- and the button sells the unlock into the next display tier.
local function refreshLuck()
	local balance = if UpgradeInfo.CurrencyAt("Luck", luckTier) == "Diamonds" then info.cc else cashBalance
	local luckInfo = UpgradeInfo.Build("Luck", luckTier, balance)
	if not luckInfo then
		return
	end
	local atBarrier = luckInfo.barrier and not luckInfo.maxed
	if luckTierLabel then
		luckTierLabel.Text = "Tier " .. UpgradeInfo.TierLabel("Luck", luckInfo.tier)
		luckTierLabel.TextColor3 = if atBarrier then RED else YELLOW
	end
	if luckCardStroke then
		luckCardStroke.Color = if atBarrier then RED else GREEN
	end
	if luckEffectLabel then
		local cur = ProfileStats.GetDisplayString("Luck", luckInfo.tier)
		if luckInfo.maxed then
			luckEffectLabel.Text = "Rare odds " .. cur
			luckEffectLabel.TextColor3 = SUBTLE
		elseif atBarrier then
			luckEffectLabel.Text = ("🔒 Unlock Tier %s with Diamonds"):format(
				UpgradeInfo.TierLabel("Luck", luckInfo.tier + 1))
			luckEffectLabel.TextColor3 = RED
		else
			-- ASCII "->": fancy arrow glyphs aren't in FredokaOne and render as boxes.
			luckEffectLabel.Text = ("Rare odds %s  ->  %s"):format(
				cur, ProfileStats.GetDisplayString("Luck", luckInfo.tier + 1))
			luckEffectLabel.TextColor3 = SUBTLE
		end
	end
	local btn = luckButton
	if btn then
		if luckInfo.maxed then
			btn.Text = "MAXED"
			btn.BackgroundColor3 = Color3.fromRGB(70, 76, 96)
			btn.Active = false
		elseif atBarrier then
			btn.Text = ("UNLOCK  💎 %s"):format(StringUtils.FormatShort(luckInfo.price :: number))
			btn.BackgroundColor3 = if luckInfo.canAfford then GREEN else Color3.fromRGB(70, 76, 96)
			btn.Active = true
		else
			btn.Text = ("UPGRADE  💰 %s"):format(StringUtils.FormatShort(luckInfo.price :: number))
			btn.BackgroundColor3 = if luckInfo.canAfford then GREEN else Color3.fromRGB(70, 76, 96)
			btn.Active = true
		end
	end
	refreshLuckOdds(luckInfo.maxed == true)
end

function refresh()
	if ccLabel then
		ccLabel.Text = "Balance: " .. StringUtils.FormatShort(info.cc) .. " 💎"
	end
	for _, entry in orderedSkins do
		refreshRow(entry.id, entry.skin)
	end
	refreshLuck()
	refreshFreeButton()

	local sel = BallSkins.Get(info.selected) or BallSkins.Get(BallSkins.GetDefaultId())
	local selOwned = info.owned[info.selected] == true
	if selectedNameLabel and sel then
		if selOwned then
			local star = CosmeticBonus.StarOf(info.copies[info.selected] or 1)
			selectedNameLabel.Text = sel.name .. "  •  " .. BallSkins.RarityName(sel.rarity) .. "  " .. string.rep("★", star)
		else
			selectedNameLabel.Text = "???  •  " .. BallSkins.RarityName(sel.rarity)
		end
		selectedNameLabel.TextColor3 = BallSkins.RarityColor(sel.rarity)
	end
	if buyButton and sel then
		local equipped = info.equipped == info.selected
		if equipped then
			buyButton.Text = "WEARING"
			buyButton.BackgroundColor3 = Color3.fromRGB(70, 76, 96)
		elseif selOwned then
			buyButton.Text = "WEAR (LOOKS ONLY)"
			buyButton.BackgroundColor3 = GREEN
		else
			-- Locked: rolling is the ONLY unlock path (direct purchase retired) — except
			-- for paid-random-items-restricted players, who get the R$ direct buy below.
			buyButton.Text = "UNLOCK FROM ROLLS"
			buyButton.BackgroundColor3 = BLUE
		end

		-- Restricted players' direct buy: locked selection + a real product for its rarity.
		local rpId: number? = nil
		if paidRandomRestricted == true and not selOwned then
			rpId = tonumber(CosmeticsConfig.RarityProducts[sel.rarity])
			if rpId == 0 then
				rpId = nil
			end
		end
		robuxBuyProductId = rpId
		if robuxBuyButton then
			robuxBuyButton.Visible = rpId ~= nil
			if rpId then
				local price = robuxPrice(rpId) -- live price; refresh() reruns when it lands
				robuxBuyButton.Text = if price then "R$ " .. price else "R$ BUY"
			end
			buyButton.Size = if rpId then UDim2.fromScale(0.30, 0.7) else UDim2.fromScale(0.48, 0.7)
		end
	end
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------
local function makeTabButton(parent: Instance, text: string, order: number): TextButton
	local btn = Instance.new("TextButton")
	btn.Activated:Connect(SoundService.PlayClick)
	btn.Name = text
	btn.Size = UDim2.new(1, 0, 0, 0)
	btn.AutomaticSize = Enum.AutomaticSize.None
	btn.SizeConstraint = Enum.SizeConstraint.RelativeXY
	btn.Size = UDim2.fromScale(1, 0.14)
	btn.LayoutOrder = order
	btn.BackgroundColor3 = ROW_BG
	btn.AutoButtonColor = false
	btn.Text = text
	btn.TextColor3 = TEXT
	btn.Font = Enum.Font.GothamBold
	btn.TextScaled = true
	btn.Parent = parent
	corner(btn, 10)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.28, 0)
	pad.PaddingBottom = UDim.new(0.28, 0)
	pad.Parent = btn
	local stroke = Instance.new("UIStroke")
	stroke.Color = YELLOW
	stroke.Thickness = 0
	stroke.Parent = btn
	return btn
end

-- Hover pop for the crate cards (same feel as the LeftBar quad's UIButton hoverScale,
-- but cards aren't UIButton-bound — they hold their own ROLL button).
local HOVER_SCALE = 1.04
local HOVER_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function attachHoverScale(card: GuiObject)
	local scale = Instance.new("UIScale")
	scale.Name = "HoverScale"
	scale.Parent = card
	card.MouseEnter:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = HOVER_SCALE }):Play()
	end)
	card.MouseLeave:Connect(function()
		TweenService:Create(scale, HOVER_TWEEN, { Scale = 1 }):Play()
	end)
end

-- One SQUARE card in the LUCK tab's grid: name on top, big emoji logo, then caller-built
-- body content. Returns the card and its full-width bottom action button.
local function buildLuckTabCard(parent: Instance, order: number, name: string, logoText: string, themeColor: Color3): (Frame, TextButton, (text: string, y: number, h: number, color: Color3) -> TextLabel)
	local card = Instance.new("Frame")
	card.Name = name
	card.LayoutOrder = order -- size comes from the page's UIGridLayout
	card.BackgroundColor3 = ROW_BG:Lerp(themeColor, 0.10)
	card.Parent = parent
	corner(card, 10)
	local cardStroke = Instance.new("UIStroke")
	cardStroke.Color = themeColor
	cardStroke.Thickness = 2.5
	cardStroke.Parent = card
	attachHoverScale(card)

	local function centered(text: string, y: number, h: number, color: Color3): TextLabel
		local l = makeLabel(card, text, UDim2.fromScale(0.92, h), UDim2.fromScale(0.04, y), color)
		l.TextScaled = true
		l.TextXAlignment = Enum.TextXAlignment.Center
		return l
	end

	centered(name, 0.03, 0.12, TEXT)
	centered(logoText, 0.15, 0.28, themeColor)

	local btn = Instance.new("TextButton")
	btn.Activated:Connect(SoundService.PlayClick) -- the game's default click, on top of per-action stings
	btn.Size = UDim2.fromScale(0.6, 0.18)
	btn.Position = UDim2.fromScale(0.2, 0.76)
	btn.BackgroundColor3 = BLUE
	btn.Text = ""
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.Font = Enum.Font.GothamBold
	btn.TextScaled = true
	btn.AutoButtonColor = true
	btn.Parent = card
	corner(btn, 10)
	local bpad = Instance.new("UIPadding")
	bpad.PaddingTop = UDim.new(0.18, 0)
	bpad.PaddingBottom = UDim.new(0.18, 0)
	bpad.Parent = btn

	return card, btn, centered
end

-- The Luck upgrade card: tier, current -> next odds multiplier, Diamond-priced UPGRADE
-- button (refreshLuck fills all three). Luck persists through rebirth — say so on the card.
local function buildLuckCard(parent: Instance, order: number)
	local card, btn, centered = buildLuckTabCard(parent, order, "LUCK", "🍀", GREEN)
	luckCardStroke = card:FindFirstChildOfClass("UIStroke")
	luckTierLabel = centered("Tier 1", 0.45, 0.10, YELLOW)
	luckEffectLabel = centered("", 0.56, 0.07, SUBTLE)
	local keepL = centered("Boosts every roll • kept through Rebirth", 0.64, 0.07, Color3.fromRGB(140, 200, 255))
	keepL.TextWrapped = true
	btn.Activated:Connect(CosmeticsShop.buyLuck)
	luckButton = btn
end

-- The ODDS card next to LUCK: one row per rarity, "current% -> next-tier%" (refreshLuckOdds
-- fills the numbers). Rows adapt to however many rarities the free roll's weights define.
local function buildOddsCard(parent: Instance, order: number)
	local card = Instance.new("Frame")
	card.Name = "ODDS"
	card.LayoutOrder = order -- size comes from the page's UIGridLayout
	card.BackgroundColor3 = ROW_BG:Lerp(GREEN, 0.05)
	card.Parent = parent
	corner(card, 10)
	local stroke = Instance.new("UIStroke")
	stroke.Color = GREEN
	stroke.Thickness = 2.5
	stroke.Parent = card
	attachHoverScale(card)

	local title = makeLabel(card, "ROLL ODDS", UDim2.fromScale(0.92, 0.11), UDim2.fromScale(0.04, 0.02), TEXT)
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Center
	local sub = makeLabel(card, "this Luck tier  ->  next tier", UDim2.fromScale(0.92, 0.06), UDim2.fromScale(0.04, 0.13), SUBTLE)
	sub.TextScaled = true
	sub.TextXAlignment = Enum.TextXAlignment.Center

	table.clear(luckOddsRows)
	local count = #CratesConfig.Free.Weights
	local top, height = 0.21, 0.77
	local rowH = height / count
	for i = 1, count do
		local y = top + (i - 1) * rowH
		local name = makeLabel(card, BallSkins.RarityName(i), UDim2.fromScale(0.42, rowH * 0.9), UDim2.fromScale(0.05, y), BallSkins.RarityColor(i))
		name.TextScaled = true
		local odds = makeLabel(card, "", UDim2.fromScale(0.5, rowH * 0.9), UDim2.fromScale(0.47, y), TEXT)
		odds.TextScaled = true
		odds.TextXAlignment = Enum.TextXAlignment.Right
		luckOddsRows[i] = { name = name, odds = odds }
	end
end

local function build(surface: SurfaceGui)
	local existing = surface:FindFirstChild("CosmeticsShop")
	if existing then
		existing:Destroy()
	end
	table.clear(rows)

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

	-- Header: title + Diamonds balance.
	local title = makeLabel(root, "MARBLES", UDim2.new(0.55, 0, 0.09, 0), UDim2.fromScale(0, 0), TEXT)
	title.TextScaled = true
	local cc = makeLabel(root, "Balance: 0 💎", UDim2.new(0.42, 0, 0.09, 0), UDim2.new(0.58, 0, 0, 0), YELLOW)
	cc.TextScaled = true
	cc.TextXAlignment = Enum.TextXAlignment.Right
	ccLabel = cc

	-- Left tab column.
	local tabs = Instance.new("Frame")
	tabs.Size = UDim2.fromScale(0.13, 0.86)
	tabs.Position = UDim2.fromScale(0, 0.12)
	tabs.BackgroundTransparency = 1
	tabs.Parent = root
	local tabsLayout = Instance.new("UIListLayout")
	tabsLayout.FillDirection = Enum.FillDirection.Vertical
	tabsLayout.Padding = UDim.new(0.02, 0)
	tabsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabsLayout.Parent = tabs

	local luckTabBtn = makeTabButton(tabs, "LUCK", 1)
	local indexTabBtn = makeTabButton(tabs, "INDEX", 2)

	-- Pages.
	local luckPage = Instance.new("Frame")
	luckPage.Name = "LuckPage"
	luckPage.Size = UDim2.fromScale(0.845, 0.86)
	luckPage.Position = UDim2.fromScale(0.155, 0.12)
	luckPage.BackgroundTransparency = 1
	luckPage.Parent = root

	local indexPage = Instance.new("Frame")
	indexPage.Name = "IndexPage"
	indexPage.Size = UDim2.fromScale(0.845, 0.86)
	indexPage.Position = UDim2.fromScale(0.155, 0.12)
	indexPage.BackgroundTransparency = 1
	indexPage.Visible = false
	indexPage.Parent = root

	local function selectTab(luck: boolean)
		luckPage.Visible = luck
		indexPage.Visible = not luck
		local ls = luckTabBtn:FindFirstChildOfClass("UIStroke") :: UIStroke
		local is = indexTabBtn:FindFirstChildOfClass("UIStroke") :: UIStroke
		ls.Thickness = if luck then 2.5 else 0
		is.Thickness = if luck then 0 else 2.5
		luckTabBtn.BackgroundColor3 = if luck then ROW_SELECT else ROW_BG
		indexTabBtn.BackgroundColor3 = if luck then ROW_BG else ROW_SELECT
	end
	luckTabBtn.Activated:Connect(function() selectTab(true) end)
	indexTabBtn.Activated:Connect(function() selectTab(false) end)
	openLuckTab = function()
		selectTab(true)
	end

	------------------------------------------------------------------
	-- Luck page: the single Luck upgrade card, centered (the free roll lives at its
	-- world pad; the purchasable crates are retired — see the header comment).
	------------------------------------------------------------------
	local cardsGrid = Instance.new("UIGridLayout")
	cardsGrid.CellSize = UDim2.fromScale(0.48, 0.47)
	cardsGrid.CellPadding = UDim2.fromScale(0.028, 0.05)
	cardsGrid.SortOrder = Enum.SortOrder.LayoutOrder
	cardsGrid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	cardsGrid.Parent = luckPage

	buildLuckCard(luckPage, 1)
	buildOddsCard(luckPage, 2)

	------------------------------------------------------------------
	-- Index page: the collection grid + equip footer.
	------------------------------------------------------------------
	local frame = Instance.new("ScrollingFrame")
	frame.Size = UDim2.fromScale(1, 0.8)
	frame.Position = UDim2.fromScale(0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.ScrollBarThickness = 18 -- chunky so it's easy to grab/drag on the world surface
	frame.ScrollBarImageColor3 = Color3.fromRGB(120, 126, 145)
	frame.CanvasSize = UDim2.new()
	frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	frame.Parent = indexPage
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(132, 120)
	grid.CellPadding = UDim2.fromOffset(10, 10)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.Parent = frame

	for _, entry in orderedSkins do
		buildCell(frame, entry.id, entry.skin)
	end

	local footer = Instance.new("Frame")
	footer.Size = UDim2.fromScale(1, 0.18)
	footer.Position = UDim2.fromScale(0, 0.82)
	footer.BackgroundTransparency = 1
	footer.Parent = indexPage

	selectedNameLabel = makeLabel(footer, "", UDim2.new(0.5, 0, 0.42, 0), UDim2.fromScale(0, 0.12), TEXT)
	selectedNameLabel.TextScaled = true


	local function makeFooterButton(): TextButton
		local btn = Instance.new("TextButton")
		btn.Activated:Connect(SoundService.PlayClick)
		btn.Size = UDim2.fromScale(0.48, 0.7)
		btn.Position = UDim2.fromScale(0.50, 0.15)
		btn.Text = ""
		btn.TextColor3 = Color3.new(1, 1, 1)
		btn.Font = Enum.Font.GothamBold
		btn.TextScaled = true
		btn.AutoButtonColor = true
		btn.Parent = footer
		corner(btn, 10)
		local bpad = Instance.new("UIPadding")
		bpad.PaddingTop = UDim.new(0.18, 0)
		bpad.PaddingBottom = UDim.new(0.18, 0)
		bpad.PaddingLeft = UDim.new(0.05, 0)
		bpad.PaddingRight = UDim.new(0.05, 0)
		bpad.Parent = btn
		return btn
	end

	local buy = makeFooterButton()
	buy.Activated:Connect(CosmeticsShop.equipSelected)
	buyButton = buy

	-- Direct skin purchase (per-rarity dev product) for paid-random-items-restricted
	-- players — their compliant, deterministic alternative to crate Robux buys. Hidden
	-- for everyone else; refresh() shows it on locked selections and squeezes the main
	-- footer button to make room.
	local robuxBuy = makeFooterButton()
	robuxBuy.Size = UDim2.fromScale(0.16, 0.7)
	robuxBuy.Position = UDim2.fromScale(0.82, 0.15)
	robuxBuy.Text = "R$ BUY"
	robuxBuy.BackgroundColor3 = GREEN
	robuxBuy.Visible = false
	robuxBuy.Activated:Connect(function()
		if robuxBuyProductId then
			ProductService.Prompt(robuxBuyProductId)
		end
	end)
	robuxBuyButton = robuxBuy

	selectTab(true)
	refresh()
end

function CosmeticsShop.Init()
	-- Paid-random-items policy: applied from the async fetch AND re-applied both ways on
	-- dev /policy toggles. refresh() re-decides the footer direct-buy from it.
	local function applyPolicy(restricted: boolean)
		paidRandomRestricted = restricted
		refresh()
	end
	PolicyGate.OnChanged(applyPolicy)
	task.spawn(function()
		applyPolicy(PolicyGate.PaidRandomItemsRestricted())
	end)

	local function setup(inst: Instance)
		if inst:IsA("SurfaceGui") then
			build(inst)
			refresh()
		end
	end
	for _, inst in CollectionService:GetTagged(TagsConfig.CosmeticsGui) do
		setup(inst)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.CosmeticsGui):Connect(setup)

	-- Free-crate claim pads (world).
	for _, inst in CollectionService:GetTagged(TagsConfig.FreeCratePad) do
		setupFreeCratePad(inst)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.FreeCratePad):Connect(setupFreeCratePad)

	changedRE.OnClientEvent:Connect(function(newInfo: Info)
		if newInfo then
			info = newInfo
			freeReadyAt = os.clock() + (newInfo.freeCrateIn or math.huge)
			refresh()
		end
	end)

	-- Luck tier for the LUCK tab's upgrade card, kept fresh from ProfileChanged (same
	-- source FreeRollBallSample reads its tease tier from).
	local function setLuckFromProfile(profile: any)
		if type(profile) == "table" and type(profile.upgrades) == "table" and type(profile.upgrades.Luck) == "number" then
			if profile.upgrades.Luck ~= luckTier then
				luckTier = profile.upgrades.Luck
				refreshLuck()
			end
		end
	end
	local profileChangedRE = ProfileNet.ProfileChanged :: RemoteEvent
	profileChangedRE.OnClientEvent:Connect(setLuckFromProfile)

	-- Cash balance for the Luck card's cash-priced sub-tiers (mirrors what
	-- BalanceUIController listens to; the server stays the pricing authority).
	local balanceChangedRE = CurrencyNet.BalanceChanged :: RemoteEvent
	balanceChangedRE.OnClientEvent:Connect(function(newBalance: number)
		if type(newBalance) == "number" then
			cashBalance = newBalance
			refreshLuck()
		end
	end)
	task.spawn(function()
		local getBalanceRF = CurrencyNet.GetBalance :: RemoteFunction
		local ok, balance = pcall(function()
			return getBalanceRF:InvokeServer()
		end)
		if ok and type(balance) == "number" then
			cashBalance = balance
			refreshLuck()
		end
	end)
	task.spawn(function()
		local getProfileRF = ProfileNet.GetProfile :: RemoteFunction
		local ok, profile = pcall(function()
			return getProfileRF:InvokeServer()
		end)
		if ok then
			setLuckFromProfile(profile)
		end
	end)

	-- Robux crate purchases land via receipt processing (no invoke to return through),
	-- so the server pushes the roll result here; present it like any other roll. If a
	-- reel is already running, skip straight to the banner rather than queueing spins.
	local crateRolledRE = CosmeticsNet.CrateRolled :: RemoteEvent
	crateRolledRE.OnClientEvent:Connect(function(boxId: string, result: RollResult)
		if type(result) ~= "table" then
			return
		end
		task.spawn(function()
			local weights = boxWeights(boxId)
			if not rolling and result.ok and weights then
				rolling = true
				CrateRollUI.Play(weights, result)
				rolling = false
			end
			presentRoll(result)
			-- Same deferred-commit report as runRoll's (server-pushed rolls queue too).
			if result.ok and result.skinId then
				task.delay(ROLL_COMMIT_DELAY, function()
					finishRollRE:FireServer()
				end)
			end
		end)
	end)

	-- Initial state.
	local got = getInfoRF:InvokeServer()
	if got then
		info = got
		freeReadyAt = os.clock() + (got.freeCrateIn or math.huge)
		refresh()
	end

	-- 1 Hz countdown for the free box (purely cosmetic; the server re-validates on claim).
	task.spawn(function()
		while true do
			task.wait(1)
			refreshFreeButton()
		end
	end)

end

return CosmeticsShop
