--!strict
-- Bet UI: LaunchBtn / RaiseBtn / LowerBtn / AutoBtn (all in MainGui, all UIButton-driven).
--
-- Bet size is no longer a free-typed number — it's a discrete ladder rung the player
-- steps through with Raise/Lower (ProfileStats.GetBetSizeAtTier), matching the
-- server-authoritative tier stored on the profile (ProfileService.SetBetTier). Raise can
-- go one rung PAST the player's owned MaxBet tier as a locked preview — LaunchBtn then
-- reads "UNLOCK ZONE" and, when pressed, runs the same PurchaseUpgrade("MaxBet") flow the
-- upgrade shop uses. That locked preview rung is purely client-local: it's never sent to
-- the server (SetBetTier would just clamp it back down to the owned tier anyway).

local Players: Players = game:GetService("Players")
local RS               = game:GetService("ReplicatedStorage")

local ProfileStats = require(RS.Shared.ProfileStats)
local Signal = require(RS.Shared.Utility.Signal)
local SoundService = require(RS.Shared.SoundService)
local StringUtils = require(RS.Shared.Utility.StringUtils)
local UIButton = require(RS.Shared.Utility.UIButton)
local ProductService = require(RS.Shared.ProductService)
local MonetizationConfig = require(RS.Shared.Config.Monetization)
local SoundsConfig = require(RS.Shared.Config.Sounds)
local WarnUI = require(RS.Shared.WarnUI)
local LaunchNet = require(RS.Shared.Remote.LaunchNet)
local LoadoutNet = require(RS.Shared.Remote.LoadoutNet)
local ProfileNet = require(RS.Shared.Remote.ProfileNet)
local UpgradeNet = require(RS.Shared.Remote.UpgradeNet)

local player = Players.LocalPlayer

local GetProfileRF          = ProfileNet.GetProfile :: RemoteFunction
local SetBetTierRF          = ProfileNet.SetBetTier :: RemoteFunction
local RequestLaunchRE       = LaunchNet.RequestLaunch :: RemoteEvent
local SlotLaunchedRE        = LaunchNet.SlotLaunched :: RemoteEvent
local ProfileChangedRE      = ProfileNet.ProfileChanged :: RemoteEvent
local PurchaseUpgradeRF     = UpgradeNet.PurchaseUpgrade :: RemoteFunction
local RequestUpgradeBoostRF = UpgradeNet.RequestUpgradeBoost :: RemoteFunction
local GetUpgradeInfoRF      = UpgradeNet.GetUpgradeInfo :: RemoteFunction

local MainGui = player.PlayerGui:WaitForChild("MainGui")
local BottomBar = MainGui:WaitForChild("BottomBar")

local Controller = {}

local LAUNCH_WORD = "LAUNCH"
local UNLOCK_WORD = "UNLOCK ZONE"
-- "UNLOCK ZONE" overflows the authored 88px word size (TextWrapped wraps it and the
-- second line clips outside the button), so the locked state drops to this size; the
-- authored size is cached below and restored alongside LAUNCH_WORD.
local UNLOCK_WORD_TEXT_SIZE = 64
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
local ORIGINAL_WORD_TEXT_SIZE = launchWordLabel.TextSize
local ORIGINAL_LAUNCH_COLOR = launchButton.BackgroundColor3

local raiseHost = BottomBar:WaitForChild("RaiseBtn")
local lowerHost = BottomBar:WaitForChild("LowerBtn")

-- AutoBtn shares LaunchBtn's parent and the same Host>{Shadow,Button>{Hover}} UIButton
-- layout, but its shadow is nested UNDER Button inside a UIListIgnore folder rather than
-- as a Host-level sibling — so UIButton's own SetColor (which darkens a Host>Shadow
-- sibling) can't reach it. Both are painted manually instead, in lockstep.
local autoHost = BottomBar:WaitForChild("AutoBtn")
local autoButton = autoHost:WaitForChild("Button") :: GuiButton
local autoShadow = autoHost:WaitForChild("Shadow") :: GuiObject

-- ownedTier: the player's purchased MaxBet tier (server truth). selectedTier: the
-- currently displayed/selected rung, 0 .. ownedTier + 1 (the "+1" is the locked preview).
local ownedTier = 0
local selectedTier = 0

-- The locked-preview selection is client-local, but other surfaces render off it too
-- (SlotInteract greys its launch pads to "Zone Locked"): exposed as a getter + a Signal
-- fired with (locked: boolean) whenever render() sees the state flip.
Controller.ZoneLockedChanged = Signal.new()
local lastZoneLocked = false

function Controller.IsZoneLocked(): boolean
	return selectedTier > ownedTier
end
-- The latest profile.upgrades pushed by the server (ProfileChanged / the Init pull) —
-- lets launch clicks compute their countdown locally instead of a GetProfile round trip.
local latestUpgrades: any = {}

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
	launchWordLabel.TextSize = if locked then UNLOCK_WORD_TEXT_SIZE else ORIGINAL_WORD_TEXT_SIZE
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
	-- After painting, so subscribers re-rendering off the signal observe consistent state.
	if locked ~= lastZoneLocked then
		lastZoneLocked = locked
		Controller.ZoneLockedChanged:Fire(locked)
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
	latestUpgrades = profile.upgrades or {}
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

-- Move to `tier`. Client-authored, like ShopUI's optimistic buy: the client knows the
-- clamp rule (0 .. ownedTier, +1 as the local-only locked preview), so the selection
-- renders immediately and the SetBetTier round trip reconciles in the background —
-- re-rendering only if the server clamps to something else (ownedTier changed under us).
local selectToken = 0
local function selectTier(tier: number)
	selectToken += 1
	local myToken = selectToken
	if tier <= ownedTier then
		selectedTier = math.max(tier, 0)
		render()
		task.spawn(function()
			local confirmed = SetBetTierRF:InvokeServer(tier)
			-- Only the LATEST selection reconciles; a stale (out-of-order) response
			-- rubber-banding an already-superseded rung would look like a glitch.
			if myToken == selectToken and type(confirmed) == "number" and confirmed ~= selectedTier then
				selectedTier = confirmed
				render()
			end
		end)
	else
		selectedTier = math.min(tier, ownedTier + 1)
		render()
	end
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
		SoundService.Play({ soundId = SoundsConfig.Upgrade })
		local info = result.upgrades and result.upgrades.MaxBet
		local newOwnedTier = if info then info.tier else ownedTier + 1
		ownedTier = newOwnedTier
		selectTier(newOwnedTier) -- optimistic render + background SetBetTier reconcile
		refreshPrice() -- also renders; the newly-unlocked tier needs its OWN next price cached
	elseif result.reason == "cannot_afford" then
		local productId = RequestUpgradeBoostRF:InvokeServer("MaxBet")
		if productId then
			-- Throttled (shared cooldown with ShopUI's promptBoost, keyed by productId) so
			-- clicking LAUNCH/UNLOCK repeatedly while broke doesn't reopen the Robux dialog
			-- on every click.
			ProductService.PromptThrottled(productId, MonetizationConfig.UpgradeBoostPromptCooldown)
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

	-- No press sound here: SlotInteract plays the launch sound at each pad that actually
	-- fires (driven by the server's SlotLaunched push), covering manual, HUD, and auto.
	RequestLaunchRE:FireServer() -- no slot arg = every READY slot fires

	-- Client-authored countdown, mirroring the server's per-slot cooldown (PER-SLOT LAUNCH
	-- REWORK: this button fires every READY slot; the countdown shows the Frequency-scaled
	-- delay after which the slots just fired become ready again).
	local delay = ProfileStats.GetLaunchDelay(latestUpgrades)
	local start = os.clock()
	while os.clock() - start < delay do
		launchWordLabel.Text = string.format("%.1f", delay - (os.clock() - start))
		task.wait(0.1)
	end

	render() -- restores LAUNCH/UNLOCK text (and everything else) correctly
	launchBtnActive = true
end

-- Auto-launch never fires while the selection is parked on the locked preview rung (it
-- would spam Unlock attempts); say WHY nothing is launching instead of silently idling
-- (throttled — WarnUI queues).
local LOCKED_WARN_INTERVAL = 3
local lastLockedWarn = 0
local function warnLockedThrottled()
	local now = os.clock()
	if now - lastLockedWarn >= LOCKED_WARN_INTERVAL then
		lastLockedWarn = now
		WarnUI.WarnLocal("Bet size locked!")
	end
end

-- AUTO is event-driven, not a polling loop: kicking it fires every ready slot, and each
-- SlotLaunched push from the server schedules that slot's relaunch for the moment its
-- cooldown lapses (see Init). Also re-kicked on profile/loadout changes, which is what
-- brings newly unlocked/newly equipped slots into the cycle.
local function autoKick()
	if not doAutoLaunch then
		return
	end
	if selectedTier > ownedTier then
		warnLockedThrottled()
		return
	end
	RequestLaunchRE:FireServer()
end

-- Fired slightly AFTER the server-reported cooldown, never at it: relaunching a hair early
-- gets silently rejected server-side, which would break that slot's auto chain.
local RELAUNCH_BUFFER = 0.1

local function onSlotLaunched(slot: unknown, cooldown: unknown)
	if type(slot) ~= "number" or type(cooldown) ~= "number" then
		return
	end
	-- Scheduled even while AUTO is off (checked at fire time), so toggling AUTO on during
	-- a cooldown still picks the slot up when it lapses (plus the toggle's own kick).
	task.delay(cooldown + RELAUNCH_BUFFER, function()
		if not doAutoLaunch then
			return
		end
		if selectedTier > ownedTier then
			warnLockedThrottled()
			return
		end
		RequestLaunchRE:FireServer(slot)
	end)
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
				autoKick() -- launch everything ready right away; SlotLaunched chains the rest
			end,
		},
		onRender = function(button: GuiButton, active: boolean)
			local color = if active then Controller.STYLE.autoOnColor else Controller.STYLE.autoOffColor
			button.BackgroundColor3 = color
			autoShadow.BackgroundColor3 = color
		end,
	})

	SlotLaunchedRE.OnClientEvent:Connect(onSlotLaunched)
	ProfileChangedRE.OnClientEvent:Connect(function(profile: any)
		onProfileChanged(profile)
		autoKick() -- a new slot/tier may be ready to join the auto cycle
	end)
	-- Equipping a skin into a previously empty slot has no SlotLaunched chain yet — the
	-- loadout push is what brings it into the cycle.
	;(LoadoutNet.LoadoutChanged :: RemoteEvent).OnClientEvent:Connect(function()
		autoKick()
	end)

	refreshFromProfile()
end

return Controller
