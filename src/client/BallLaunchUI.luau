--!strict
-- Bet UI: LaunchBtn / RaiseBtn / LowerBtn / AutoBtn (all in MainGui, all UIButton-driven).
--
-- Bet size is no longer a free-typed number — it's a discrete ladder rung the player
-- steps through with Raise/Lower (ProfileStats.GetBetSizeAtTier), matching the
-- server-authoritative tier stored on the profile (ProfileService.SetBetTier). Raise can
-- go one rung PAST the player's owned MaxBet tier as a locked preview — LaunchBtn then
-- reads "UNLOCK" and, when pressed, runs the same PurchaseUpgrade("MaxBet") flow the
-- upgrade shop uses. That locked preview rung is purely client-local: it's never sent to
-- the server (SetBetTier would just clamp it back down to the owned tier anyway).

local Players: Players = game:GetService("Players")
local RunService       = game:GetService("RunService")
local RS               = game:GetService("ReplicatedStorage")

local ProfileStats = require(RS.Shared.ProfileStats)
local SoundService = require(RS.Shared.SoundService)
local StringUtils = require(RS.Shared.StringUtils)
local UIButton = require(RS.Shared.UIButton)
local ProductService = require(RS.Shared.ProductService)
local Config = require(RS.Shared.Config)

local player = Players.LocalPlayer

local Remote                = RS:WaitForChild("Remote")
local GetProfileRF          = Remote:WaitForChild("GetProfile") :: RemoteFunction
local SetBetTierRF          = Remote:WaitForChild("SetBetTier") :: RemoteFunction
local RequestLaunchRE       = Remote:WaitForChild("RequestLaunch") :: RemoteEvent
local ProfileChangedRE      = Remote:WaitForChild("ProfileChanged") :: RemoteEvent
local PurchaseUpgradeRF     = Remote:WaitForChild("PurchaseUpgrade") :: RemoteFunction
local RequestUpgradeBoostRF = Remote:WaitForChild("RequestUpgradeBoost") :: RemoteFunction
local GetUpgradeInfoRF      = Remote:WaitForChild("GetUpgradeInfo") :: RemoteFunction

local MainGui = player.PlayerGui:WaitForChild("MainGui")
local BottomBar = MainGui:WaitForChild("BottomBar")

local Controller = {}

local LAUNCH_WORD = "LAUNCH"
local UNLOCK_WORD = "UNLOCK"
-- Same grey UIButton uses for a true SetDisabled — LaunchBtn stays clickable while
-- "locked" (pressing it attempts the Unlock purchase), so it's tinted via SetColor
-- rather than actually disabled.
local LOCKED_COLOR = Color3.fromRGB(130, 130, 130)
local PRICE_GREEN = Color3.fromRGB(96, 224, 120) -- matches the $/marble green used elsewhere

Controller.STYLE = {
	autoOffColor = Color3.fromRGB(255, 120, 120),
	autoOnColor = Color3.fromRGB(4, 255, 0),
}

local launchHost = BottomBar:WaitForChild("LaunchBtn")
local launchButton = launchHost:WaitForChild("Button") :: GuiButton
local betSizeLabel = launchButton:WaitForChild("BetSize") :: TextLabel
local ORIGINAL_BETSIZE_COLOR = betSizeLabel.TextColor3
-- "Text" is a CHILD TextLabel (same sibling pattern as BetSize), NOT launchButton's own
-- native .Text property — dot-indexing a same-named property always wins over a child of
-- that name, so `launchButton.Text = ...` silently writes to the (invisible/unused) native
-- property instead of this label. Must go through WaitForChild, which isn't fooled by that.
local launchWordLabel = launchButton:WaitForChild("Text") :: TextLabel
local ORIGINAL_LAUNCH_COLOR = launchButton.BackgroundColor3

local raiseHost = BottomBar:WaitForChild("RaiseBtn")
local lowerHost = BottomBar:WaitForChild("LowerBtn")

-- AutoBtn shares LaunchBtn's parent and the same Host>{Shadow,Button>{Hover}} UIButton
-- layout, but its shadow is nested UNDER Button inside a UIListIgnore folder rather than
-- as a Host-level sibling — so UIButton's own SetColor (which darkens a Host>Shadow
-- sibling) can't reach it. Both are painted manually instead, in lockstep.
local autoHost = BottomBar:WaitForChild("AutoBtn")
local autoButton = autoHost:WaitForChild("Button") :: GuiButton
local autoShadow = autoButton:WaitForChild("UIListIgnore"):WaitForChild("Shadow") :: GuiObject

-- ownedTier: the player's purchased MaxBet tier (server truth). selectedTier: the
-- currently displayed/selected rung, 0 .. ownedTier + 1 (the "+1" is the locked preview).
local ownedTier = 0
local selectedTier = 0

-- Bound inside Controller.Init (assigned before render()/onRaise()/onLower() can ever
-- actually run — they're only reachable via button clicks or the heartbeat, both wired
-- up at the end of Init), but typed optional since Luau can't see that ordering.
local launchHandle: UIButton.Handle? = nil
local raiseHandle: UIButton.Handle? = nil
local lowerHandle: UIButton.Handle? = nil

local doAutoLaunch = false
local launchBtnActive = true

-- The price to buy ownedTier -> ownedTier+1 (shown in place of the bet size while
-- locked/previewing that rung). Only re-fetched when ownedTier actually changes (see
-- onProfileChanged/attemptUnlock), not on every render — refreshPrice calls render()
-- itself once the fetch resolves.
local lastPricedTier: number? = nil
local nextTierPrice: number? = nil

local function render()
	local locked = selectedTier > ownedTier
	if locked and nextTierPrice then
		-- Previewing the locked rung: show what it costs to unlock, in green, instead of
		-- the (inaccessible) bet size.
		betSizeLabel.Text = StringUtils.FormatMoney(nextTierPrice)
		betSizeLabel.TextColor3 = PRICE_GREEN
	else
		betSizeLabel.Text = StringUtils.FormatMoney(ProfileStats.GetBetSizeAtTier(selectedTier))
		betSizeLabel.TextColor3 = ORIGINAL_BETSIZE_COLOR
	end
	launchWordLabel.Text = if locked then UNLOCK_WORD else LAUNCH_WORD
	-- LaunchBtn stays CLICKABLE while locked (pressing it attempts the Unlock purchase),
	-- so it's tinted via SetColor rather than SetDisabled. Raise/Lower actually should do
	-- nothing at their respective edges, so they use the real UIButton.SetDisabled (which
	-- greys both the button and its shadow, and blocks clicks, without pressing it down).
	if launchHandle then
		launchHandle.SetColor(if locked then LOCKED_COLOR else ORIGINAL_LAUNCH_COLOR)
	end
	if raiseHandle then
		raiseHandle.SetDisabled(locked) -- never more than one rung past owned
	end
	if lowerHandle then
		lowerHandle.SetDisabled(selectedTier <= 0) -- floor: tier 0 (bet 10) has nothing below it
	end
end

-- Pull the price to unlock the next MaxBet tier (for the locked-preview display) and
-- re-render once it resolves. Called whenever ownedTier changes.
local function refreshPrice()
	lastPricedTier = ownedTier
	local ok, info = pcall(function()
		return GetUpgradeInfoRF:InvokeServer()
	end)
	if ok and type(info) == "table" and type(info.MaxBet) == "table" then
		nextTierPrice = info.MaxBet.price
	end
	render()
end

-- Adopt the server-authoritative profile wholesale: ownedTier from upgrades.MaxBet,
-- selectedTier from loadout.BetTier (never above ownedTier — the locked preview only
-- ever exists client-side, so the server never reports it).
local function onProfileChanged(profile: any)
	ownedTier = (profile.upgrades and profile.upgrades.MaxBet) or 0
	selectedTier = (profile.loadout and profile.loadout.BetTier) or ownedTier
	if ownedTier ~= lastPricedTier then
		refreshPrice() -- also renders
	else
		render()
	end
end

local function refreshFromProfile()
	local profile = GetProfileRF:InvokeServer()
	if profile then
		onProfileChanged(profile)
	end
end

-- Move to `tier`. An owned rung round-trips through the server (the single source of
-- truth for loadout.Bet); the one-rung-ahead locked preview is local-only.
local function selectTier(tier: number)
	if tier <= ownedTier then
		selectedTier = SetBetTierRF:InvokeServer(tier)
	else
		selectedTier = math.min(tier, ownedTier + 1)
	end
	render()
end

-- No manual "already at the edge" guard needed here — RaiseBtn/LowerBtn are actually
-- SetDisabled(true) at those edges (see render()), which blocks Activated at the engine
-- level, so these never fire while grayed out.
local function onRaise()
	selectTier(math.min(selectedTier + 1, ownedTier + 1))
end

local function onLower()
	selectTier(math.max(selectedTier - 1, 0))
end

-- Same purchase flow as the upgrade shop's buy button (src/client/ShopUI.luau
-- onBuyPressed): buy tier -> jump the selection straight to the newly owned rung
-- (matching the old "just click max after upgrading" habit); can't-afford -> offer the
-- instant-tiers dev product, same as the shop.
local function attemptUnlock()
	local result = PurchaseUpgradeRF:InvokeServer("MaxBet")
	if type(result) ~= "table" then
		return
	end
	if result.ok then
		SoundService.Play({ soundId = Config.Sounds.Upgrade })
		local info = result.upgrades and result.upgrades.MaxBet
		local newOwnedTier = if info then info.tier else ownedTier + 1
		ownedTier = newOwnedTier
		selectedTier = SetBetTierRF:InvokeServer(newOwnedTier)
		refreshPrice() -- also renders; the newly-unlocked tier needs its OWN next price cached
	elseif result.reason == "cannot_afford" then
		local productId = RequestUpgradeBoostRF:InvokeServer("MaxBet")
		if productId then
			ProductService.Prompt(productId)
		end
	end
end

local function onLaunchClicked()
	if selectedTier > ownedTier then
		attemptUnlock()
		return
	end
	if not launchBtnActive then
		return
	end
	launchBtnActive = false

	if not doAutoLaunch then
		SoundService.Play({ soundId = Config.Sounds.Launch, volume = 1.0 })
	end
	RequestLaunchRE:FireServer()

	local upgrades = GetProfileRF:InvokeServer().upgrades
	local delay = ProfileStats.GetLaunchDelay(upgrades)
	local start = os.clock()
	while os.clock() - start < delay do
		launchWordLabel.Text = string.format("%.1f", delay - (os.clock() - start))
		task.wait(0.1)
	end

	render() -- restores LAUNCH/UNLOCK text (and everything else) correctly
	launchBtnActive = true
end

-- Auto-launch only fires real launches — never spam Unlock purchase attempts every
-- heartbeat if the player parks the selection on the locked preview rung with auto on.
local function onHeartbeat()
	if doAutoLaunch and selectedTier <= ownedTier then
		onLaunchClicked()
	end
end

function Controller.Init()
	launchHandle = UIButton.bind(launchHost, { onClick = onLaunchClicked })
	raiseHandle = UIButton.bind(raiseHost, { onClick = onRaise })
	lowerHandle = UIButton.bind(lowerHost, { onClick = onLower })
	UIButton.bind(autoHost, {
		toggle = {
			initial = false,
			onChange = function(active: boolean)
				doAutoLaunch = active
			end,
		},
		onRender = function(button: GuiButton, active: boolean)
			local color = if active then Controller.STYLE.autoOnColor else Controller.STYLE.autoOffColor
			button.BackgroundColor3 = color
			autoShadow.BackgroundColor3 = color
		end,
	})

	RunService.Heartbeat:Connect(onHeartbeat)
	ProfileChangedRE.OnClientEvent:Connect(onProfileChanged)

	refreshFromProfile()
end

return Controller
