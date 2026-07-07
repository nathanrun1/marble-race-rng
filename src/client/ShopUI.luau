--!strict

local ShopUI = {}

local Players: Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ProfileStats = require(RS.Shared.ProfileStats)
local UpgradeInfo = require(RS.Shared.UpgradeInfo)
local StringUtils = require(RS.Shared.StringUtils)
local SoundService = require(RS.Shared.SoundService)
local ProductService = require(RS.Shared.ProductService)
local UIButton = require(RS.Shared.UIButton)
local Config = require(RS.Shared.Config)

local player: Player = Players.LocalPlayer :: Player
local PlayerGui: PlayerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local ShopGui = PlayerGui:WaitForChild("ShopGui") :: any
local ShopFrame: Frame = ShopGui.ShopFrame :: Frame

-- The lock view (a world UpgradeLock's purchase screen) hides the Effect/Track/3x
-- sections (see loadLock), which would otherwise leave dead space below the buy
-- button. Fixed heights (X/position untouched) rather than AutomaticSize, so the two
-- states are exactly as tall as their content is meant to be.
local UNLOCKED_SIZE_Y = 437
local LOCKED_SIZE_Y = 300

-- Capture the studio-authored center position; off-screen-right is +1 X scale.
local POS_OPEN  = ShopFrame.Position
local POS_RIGHT = UDim2.new(
	POS_OPEN.X.Scale + 1, POS_OPEN.X.Offset,
	POS_OPEN.Y.Scale,     POS_OPEN.Y.Offset
)
local TWEEN_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local activeTween: Tween? = nil

local BalanceChangedRE: RemoteEvent = RS.Remote.BalanceChanged
local PurchaseUpgradeRF: RemoteFunction = RS.Remote.PurchaseUpgrade
local RequestUpgradeBoostRF: RemoteFunction = RS.Remote:WaitForChild("RequestUpgradeBoost")
local PurchaseUpgradeLockRF: RemoteFunction = RS.Remote:WaitForChild("PurchaseUpgradeLock")

local UI = {
	name = ShopGui.ShopFrame.Head.NameStack.ShopName, -- TextLabel
	icon = ShopGui.ShopFrame.Head.Icon.TextLabel, -- TextLabel
	desc = ShopGui.ShopFrame.Head.NameStack.ShopDesc, -- TextLabel
	tiers = ShopGui.ShopFrame.Head.TierBadge.BadgeStack.TierNumber, -- TextLabel
	price = ShopGui.ShopFrame.BuyButton.BuyInner.PriceChip.PriceLabel, -- TextLabel
	purchaseBtn = ShopGui.ShopFrame.BuyButton, -- ImageButton
	word = ShopGui.ShopFrame.BuyButton.BuyInner.Word, -- TextLabel ("UPGRADE" / "Unlock")
	curValue = ShopGui.ShopFrame.Effect.CurrentCell.Frame.Value, -- TextLabel
	nextValue = ShopGui.ShopFrame.Effect.NextCell.Frame.Value, -- TextLabel
	track = ShopGui.ShopFrame.Track, -- Frame
	effect = ShopGui.ShopFrame.Effect, -- Frame
	effectSpacer = ShopGui.ShopFrame:FindFirstChild("EffectSpacer") :: GuiObject?,
	boostHost = ShopGui.ShopFrame:FindFirstChild("3xButtonHost") :: GuiObject?,
	frameStroke = ShopGui.ShopFrame:FindFirstChildOfClass("UIStroke") :: UIStroke?,
	iconStroke = ShopGui.ShopFrame.Head.Icon:FindFirstChildOfClass("UIStroke") :: UIStroke?,
	tierStroke = ShopGui.ShopFrame.Head.TierBadge:FindFirstChildOfClass("UIStroke") :: UIStroke?,
    closeBtn = ShopGui.ShopFrame.UIListIgnore.CloseButton
}

export type Info = UpgradeInfo.Info
export type PurchaseResult = {
	ok: boolean,
	reason: string?,               -- "invalid_track" | "maxed" | "cannot_afford"
	upgrades: { [string]: Info }?, -- fresh authoritative snapshot from the server
}

-- LOCAL source of truth for rendering: the server already pushes tiers (ProfileChanged)
-- and cash (BalanceChanged) to this client, and pricing is pure Config math (shared
-- UpgradeInfo). So the shop renders synchronously from these caches — no InvokeServer
-- per render, which is what used to make the open shop flicker between two kiosks
-- (overlapping in-flight loads racing to repaint). Purchases stay server-authoritative.
local cachedUpgrades: { [string]: number } = {}
local cachedBalance = 0
local seededUpgrades = false -- pushes beat the initial pull; don't let the pull regress them
local seededBalance = false

export type Upgrades = { [string]: number }

local MAGENTA      = Color3.fromRGB(236, 63, 212)   -- #ec3fd4  borders / accent
local PIP_BORDER   = Color3.fromRGB(234, 220, 240)  -- #eadcf0  empty pip border
local CHIP         = Color3.fromRGB(244, 238, 248)  -- #f4eef8  chip / empty pip

-- Lock-view styling: a world UpgradeLock's purchase screen shows a "???" placeholder
-- in a grey/black theme instead of a track's real name/desc/values, with the buy
-- button reading "Unlock" instead of "UPGRADE" (see ShopUI.OpenLock).
local LOCK_STROKE   = Color3.fromRGB(70, 70, 78)   -- grey/black border
local LOCK_ICON     = "❓"
local LOCK_DESC     = "???"
local LOCK_TIER     = "?"
local LOCK_WORD     = "Unlock"

-- Original (unlocked) styling, captured once so a locked track can be restored exactly
-- when re-rendered after unlocking.
local ORIGINAL_FRAME_STROKE = UI.frameStroke and UI.frameStroke.Color
local ORIGINAL_ICON_STROKE = UI.iconStroke and UI.iconStroke.Color
local ORIGINAL_TIER_STROKE = UI.tierStroke and UI.tierStroke.Color
local ORIGINAL_WORD = UI.word.Text

local loadedTrack: string? = nil
-- The Info the shop is currently rendering (kept fresh by the BalanceChanged/ProfileChanged
-- reloads below). Drives the optimistic buy in onBuyPressed: its canAfford is the client's
-- best guess at whether the purchase will succeed.
local loadedInfo: Info? = nil

-- A world UpgradeLock being offered instead of a track (see ShopUI.OpenLock); mutually
-- exclusive with loadedTrack.
export type LockView = { id: string, price: number, tracks: { string } }
local loadedLock: LockView? = nil

-- The 3× boost grants 3 tiers, so it's only offered when at least 3 tiers remain.
-- `boostButton` is bound at the bottom; loadShop captures it as a forward ref.
local BOOST_TIERS = 3
local BOOST_GLOW_GOLD = Color3.fromRGB(255, 200, 40)
local BOOST_GLOW_WHITE = Color3.fromRGB(255, 255, 255)
local boostButton: UIButton.Handle? = nil
local boostAvailable = true

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

-- Celebratory pop on a successful purchase (same feel as the prestige button):
-- scale up quick, then settle back with a slight overshoot. Pops *relative* to the
-- UIScale's resting value (whatever AutoScale set it to) rather than snapping to 1,
-- and rebases only when idle so rapid (auto-buy) pops don't drift.
local PUNCH_FACTOR = 1.04
local shopScale: any = ShopFrame:FindFirstChildOfClass("UIScale") or f("UIScale", { Scale = 1 }, ShopFrame)
local punchRest: number? = nil
local punchTweens: { Tween } = {}
local function punch()
	for _, t in punchTweens do t:Cancel() end
	-- Capture the resting scale only when not mid-pop; if AutoScale changed it since
	-- the last settle, the fresh read picks that up.
	local base = punchRest or shopScale.Scale
	punchRest = base
	local up = TweenService:Create(shopScale, TweenInfo.new(0.1), { Scale = base * PUNCH_FACTOR })
	local down = TweenService:Create(shopScale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = base })
	punchTweens = { up, down }
	up.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then down:Play() end
	end)
	down.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then punchRest = nil end
	end)
	up:Play()
end

-- Rising fade-out flare announcing the purchased tier. The authored label is kept
-- hidden as a template; each call clones it so spammed upgrades animate
-- independently (no shared tween to interrupt). The clone drifts up while fading
-- text (+ outline) out, then dies. Style left as authored.
local flareTemplate: any = ShopGui:FindFirstChild("UpgradeFlare")
local flareBasePos: UDim2 = flareTemplate and flareTemplate.Position
local FLARE_RISE = UDim2.fromOffset(0, -60)
local FLARE_INFO = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
if flareTemplate then flareTemplate.Visible = false end
local function playFlare(text: string)
	if not flareTemplate then return end

	local flare = flareTemplate:Clone()
	flare.Text = text
	flare.Position = flareBasePos
	flare.TextTransparency = 0
	flare.Visible = true
	local flareStroke = flare:FindFirstChildOfClass("UIStroke")
	if flareStroke then flareStroke.Transparency = 0 end
	flare.Parent = flareTemplate.Parent

	local move = TweenService:Create(flare, FLARE_INFO, { Position = flareBasePos + FLARE_RISE, TextTransparency = 1 })
	move.Completed:Once(function()
		flare:Destroy()
	end)
	move:Play()
	if flareStroke then
		TweenService:Create(flareStroke, FLARE_INFO, { Transparency = 1 }):Play()
	end
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

-- Grey/restore the teaser-only chrome (frame border, icon border, tier badge border, buy
-- button word) for a locked vs. unlocked track. Everything else that differs (desc/icon/tier
-- text, effect + track + 3x visibility) is set directly in loadShop since it has no "restore
-- to original" concept — it's just re-populated from the fresh Info every load.
local function applyLockChrome(locked: boolean)
	if UI.frameStroke then
		UI.frameStroke.Color = if locked then LOCK_STROKE else ORIGINAL_FRAME_STROKE
	end
	if UI.iconStroke then
		UI.iconStroke.Color = if locked then LOCK_STROKE else ORIGINAL_ICON_STROKE
	end
	if UI.tierStroke then
		UI.tierStroke.Color = if locked then LOCK_STROKE else ORIGINAL_TIER_STROKE
	end
	UI.word.Text = if locked then LOCK_WORD else ORIGINAL_WORD

	local size = ShopFrame.Size
	local targetY = if locked then LOCKED_SIZE_Y else UNLOCKED_SIZE_Y
	ShopFrame.Size = UDim2.new(size.X.Scale, size.X.Offset, 0, targetY)
end

-- Loads ShopGui contents with the given track, synchronously, from the local caches.
-- Returns the loaded upgrade info.
function loadShop(track: string): Info
	local upgradeInfo = UpgradeInfo.Build(track, cachedUpgrades[track] or 0, cachedBalance) :: Info
	assert(upgradeInfo, "unknown upgrade track: " .. track)

	UI.name.Text = upgradeInfo.name
	applyLockChrome(false)

	UI.desc.Text = upgradeInfo.desc
	UI.icon.Text = upgradeInfo.icon
	if upgradeInfo.maxTier ~= nil then
		UI.tiers.Text = upgradeInfo.tier.." / "..upgradeInfo.maxTier
	else
		UI.tiers.Text = upgradeInfo.tier
	end

    if upgradeInfo.price then
        UI.price.Text = "$"..StringUtils.FormatShort(upgradeInfo.price)
    else
        UI.price.Text = "MAXED"
    end
	adjustButton(upgradeInfo.canAfford)

	UI.effect.Visible = true
	if UI.effectSpacer then
		UI.effectSpacer.Visible = true
	end
	UI.curValue.Text = ProfileStats.GetDisplayString(track, upgradeInfo.tier)
	if not upgradeInfo.maxed then
		UI.nextValue.Text = ProfileStats.GetDisplayString(track, upgradeInfo.tier + 1)
	else
		UI.nextValue.Text = "—"
	end

	UI.track.Visible = true
	createPips(UI.track, upgradeInfo.maxTier, upgradeInfo.tier)

    -- Offer the 3× boost only when at least 3 tiers remain (unbounded tracks always
    -- qualify). Otherwise grey the button out and suppress the can't-afford prompt.
    boostAvailable = upgradeInfo.maxTier == nil
        or (upgradeInfo.maxTier - upgradeInfo.tier) >= BOOST_TIERS
    if UI.boostHost then
        UI.boostHost.Visible = true
    end
    if boostButton then
        boostButton.SetDisabled(not boostAvailable)
        -- Pulse gold↔white to draw the eye while the 3× boost is purchasable.
        boostButton.SetGlowing(boostAvailable, BOOST_GLOW_GOLD, BOOST_GLOW_WHITE)
    end

    loadedTrack = track
    loadedInfo = upgradeInfo
    loadedLock = nil
    return upgradeInfo
end

-- Loads ShopGui as a world-lock purchase screen: grey teaser chrome, "???" placeholder,
-- the lock's flat price, and an "Unlock" buy button. Tier/effect/3× stay hidden — a
-- lock has no progression, it's one flat purchase.
local function loadLock(lock: LockView)
	UI.name.Text = "🔒 LOCKED"
	applyLockChrome(true)
	UI.desc.Text = LOCK_DESC
	UI.icon.Text = LOCK_ICON
	UI.tiers.Text = LOCK_TIER
	UI.price.Text = "$" .. StringUtils.FormatShort(lock.price)
	adjustButton(cachedBalance >= lock.price)

	UI.effect.Visible = false
	if UI.effectSpacer then
		UI.effectSpacer.Visible = false
	end
	UI.track.Visible = false
	boostAvailable = false
	if UI.boostHost then
		UI.boostHost.Visible = false
	end
	if boostButton then
		boostButton.SetDisabled(true)
		boostButton.SetGlowing(false, BOOST_GLOW_GOLD, BOOST_GLOW_WHITE)
	end

	loadedLock = lock
	loadedTrack = nil
	loadedInfo = nil
end

-- Render just the tier-advance bits (tier badge, pips, current/next effect values) as if a
-- purchase of `info`'s next tier already succeeded. Deliberately partial: price/afford/boost
-- state need server truth, and the loadShop that follows the purchase response re-renders
-- everything from it either way.
local function applyPredictedTier(track: string, info: Info)
	local newTier = info.tier + 1
	if info.maxTier ~= nil then
		UI.tiers.Text = newTier .. " / " .. info.maxTier
	else
		UI.tiers.Text = tostring(newTier)
	end
	local maxedNow = info.maxTier ~= nil and newTier >= info.maxTier
	UI.curValue.Text = ProfileStats.GetDisplayString(track, newTier)
	UI.nextValue.Text = if maxedNow then "—" else ProfileStats.GetDisplayString(track, newTier + 1)
	createPips(UI.track, info.maxTier, newTier)
end

-- Ask the server to start the instant-tiers (3×) purchase for a track, then prompt
-- the dev product. The server records which track to grant and hands back the id;
-- fulfilment happens in UpgradeService's ProcessReceipt handler. Throttled so mashing
-- Buy while unaffordable doesn't reopen the Robux dialog on every click.
local function promptBoost(track: string?)
    if track == nil then
        return
    end
    local productId: number? = RequestUpgradeBoostRF:InvokeServer(track)
    if productId then
        ProductService.PromptThrottled(productId, Config.UpgradeBoostPromptCooldown)
    end
end

-- Invoked when purchase button pressed. OPTIMISTIC: when the last-rendered Info says the
-- purchase should succeed, the success presentation (tier text/pips/values, pop, flare,
-- sound) plays immediately instead of waiting out the server round trip; the response then
-- re-renders from server truth either way, so a wrong guess (balance changed since the
-- last render) simply snaps back rather than staying granted.
function onBuyPressed()
    -- Lock view: one flat server-validated purchase, no optimistic tier prediction.
    local lock = loadedLock
    if lock then
        local res = PurchaseUpgradeLockRF:InvokeServer(lock.id)
        if type(res) == "table" and res.ok then
            SoundService.Play({ soundId = Config.Sounds.Upgrade })
            punch()
            playFlare("Unlocked!")
            ShopUI.CloseShop() -- the world model fades out (UpgradeLocks); nothing left to show
        end
        return
    end

    local track = loadedTrack
    if track == nil then
        return
    end

    local info = loadedInfo
    local predicted = info ~= nil and info.canAfford and not info.maxed
    if predicted then
        -- Cleared until the response reconciles, so mashing Buy mid-flight falls back to
        -- the non-optimistic path instead of re-predicting from the same stale tier.
        loadedInfo = nil
        SoundService.Play({ soundId = Config.Sounds.Upgrade })
        applyPredictedTier(track, info :: Info)
        punch()
        playFlare("Tier " .. ((info :: Info).tier + 1))
    end

	local purchaseResult: PurchaseResult = PurchaseUpgradeRF:InvokeServer(track)
    -- Adopt the authoritative tiers the server returned (the ProfileChanged push usually
    -- landed already, but this makes the re-render below correct regardless of ordering).
    if purchaseResult.upgrades then
        for t, i in purchaseResult.upgrades :: { [string]: Info } do
            cachedUpgrades[t] = i.tier
        end
    end
    if purchaseResult.ok then
        local upgradeInfo = loadShop(track)
        if not predicted then
            SoundService.Play({ soundId = Config.Sounds.Upgrade })
            punch()
            playFlare("Tier " .. upgradeInfo.tier)
        end
    else
        if predicted then
            loadShop(track) -- prediction was wrong: revert to server truth
        end
        if purchaseResult.reason == "cannot_afford" and boostAvailable then
            -- Can't afford with cash → offer the instant-tiers dev product instead
            -- (only when the boost is actually available, i.e. ≥3 tiers remain).
            promptBoost(track)
        end
    end
end

-- Invoked when close button pressed
function ShopUI.CloseShop()
	if activeTween then activeTween:Cancel() end
	local t = TweenService:Create(ShopFrame, TWEEN_INFO, { Position = POS_RIGHT })
	activeTween = t
	t.Completed:Connect(function(state: Enum.PlaybackState)
		if state == Enum.PlaybackState.Completed then
			ShopGui.Enabled = false
			ShopFrame.Position = POS_OPEN
		end
	end)
	t:Play()
end

-- Enable the shop for the given track, sliding it in from the right.
function ShopUI.OpenShop(track: string)
	if activeTween then activeTween:Cancel() end
	loadShop(track)
	ShopFrame.Position = POS_RIGHT
	ShopGui.Enabled = true
	local t = TweenService:Create(ShopFrame, TWEEN_INFO, { Position = POS_OPEN })
	activeTween = t
	t:Play()
end

-- Enable the shop as a world-lock purchase screen (UpgradeLocks pads open this).
function ShopUI.OpenLock(lock: LockView)
	if activeTween then activeTween:Cancel() end
	loadLock(lock)
	ShopFrame.Position = POS_RIGHT
	ShopGui.Enabled = true
	local t = TweenService:Create(ShopFrame, TWEEN_INFO, { Position = POS_OPEN })
	activeTween = t
	t:Play()
end

-- Determines if the Shop UI is open
function ShopUI.IsOpen(): boolean
	return ShopGui.Enabled
end

-- Fetches currently loaded track
function ShopUI.GetLoadedTrack(): string?
	return loadedTrack
end

-- Loads the given track
function ShopUI.LoadTrack(track: string)
	if track == loadedTrack and ShopGui.Enabled then
		return -- already showing it; balance/tier refreshes re-render via the pushes below
	end
	loadShop(track)
end

-- Whole-shop snapshot computed from the local caches — same shape the server's
-- GetUpgradeInfo returns. UpgradeShop renders its pad billboards from this.
function ShopUI.GetAllInfoLocal(): { [string]: Info }
	return UpgradeInfo.BuildAll(cachedUpgrades, cachedBalance)
end

BalanceChangedRE.OnClientEvent:Connect(function(newBalance: number)
    cachedBalance = newBalance
    seededBalance = true
    if ShopGui.Enabled then
        if loadedTrack then
            loadShop(loadedTrack)
        elseif loadedLock then
            loadLock(loadedLock) -- re-colour the Unlock button's affordability
        end
    end
end)

-- Tier changes (e.g. the 3× boost granting instant tiers) push ProfileChanged rather
-- than BalanceChanged, so refresh the open shop on that too.
local ProfileChangedRE: RemoteEvent = RS.Remote:WaitForChild("ProfileChanged")
ProfileChangedRE.OnClientEvent:Connect(function(profile: any)
    cachedUpgrades = (profile and profile.upgrades) or {}
    seededUpgrades = true
    if ShopGui.Enabled and loadedTrack then
        loadShop(loadedTrack)
    end
end)

-- Seed the caches once on startup (the pushes above only arrive on CHANGES, and the shop
-- can be opened before the first one). A push that lands before the pull returns wins.
task.spawn(function()
    local GetProfileRF = RS.Remote:WaitForChild("GetProfile") :: RemoteFunction
    local GetBalanceRF = RS.Remote:WaitForChild("GetBalance") :: RemoteFunction
    local okP, profile = pcall(function()
        return GetProfileRF:InvokeServer()
    end)
    if okP and not seededUpgrades and type(profile) == "table" and type(profile.upgrades) == "table" then
        cachedUpgrades = profile.upgrades
    end
    local okB, balance = pcall(function()
        return GetBalanceRF:InvokeServer()
    end)
    if okB and not seededBalance and type(balance) == "number" then
        cachedBalance = balance
    end
    -- If the shop somehow opened before the seed finished, repaint it with real numbers.
    if ShopGui.Enabled and loadedTrack then
        loadShop(loadedTrack)
    end
end)

UI.purchaseBtn.Activated:Connect(function()
	SoundService.PlayClick()
	onBuyPressed()
end)
UI.closeBtn.Activated:Connect(function()
	SoundService.PlayClick()
	ShopUI.CloseShop()
end)

-- 3× instant-tiers button: same host structure as the tool buttons (no MuteIcon).
-- Momentary — hover lift + press squash, click prompts the boost for the loaded track.
-- Disabled (greyed + pressed) whenever fewer than 3 tiers remain (see loadShop).
boostButton = UIButton.bind(ShopFrame:WaitForChild("3xButtonHost"), {
    onClick = function()
        promptBoost(loadedTrack)
    end,
    disabled = not boostAvailable,
})

return ShopUI
