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
--
-- LaunchBtn is dual-purpose, switching on Controller.IsZoneLocked(): previewing a locked
-- rung, it's the real "UNLOCK ZONE" purchase button (unchanged). Sitting on an owned
-- (unlocked) rung — the normal-play state — it stops being a button at all: it's a
-- disabled "ZONE <roman numeral>" readout styled with that zone's own board colors
-- (Config/BoardAppearance, via Utility/BoardColors — the SAME ramp the board itself
-- repaints from, so this can't drift from what the player is standing on). Firing marbles
-- in that state is entirely the slot pads' / AUTO's job now.

local Players: Players = game:GetService("Players")
local RS               = game:GetService("ReplicatedStorage")

local ProfileStats = require(RS.Shared.ProfileStats)
local Signal = require(RS.Shared.Utility.Signal)
local SoundService = require(RS.Shared.SoundService)
local StringUtils = require(RS.Shared.Utility.StringUtils)
local UIButton = require(RS.Shared.Utility.UIButton)
local ProductService = require(RS.Shared.ProductService)
local BoardAppearanceConfig = require(RS.Shared.Config.BoardAppearance)
local BoardColors = require(RS.Shared.Utility.BoardColors)
local MonetizationConfig = require(RS.Shared.Config.Monetization)
local SoundsConfig = require(RS.Shared.Config.Sounds)
local WarnUI = require(RS.Shared.WarnUI)
local LaunchNet = require(RS.Shared.Remote.LaunchNet)
local LoadoutNet = require(RS.Shared.Remote.LoadoutNet)
local ProfileNet = require(RS.Shared.Remote.ProfileNet)
local UpgradeNet = require(RS.Shared.Remote.UpgradeNet)

local player = Players.LocalPlayer

local ShopUI = require(script.Parent.ShopUI)

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

local UNLOCK_WORD = "UNLOCK ZONE"
local ZONE_WORD_PREFIX = "ZONE " -- + roman numeral of the currently selected (owned) rung
-- Both words overflow the authored 88px word size (TextWrapped wraps them and the
-- second line clips outside the button), so both states drop to this size.
local WORD_TEXT_SIZE = 64
-- Same grey UIButton uses for a true SetDisabled — LaunchBtn stays clickable while
-- "locked" (pressing it attempts the Unlock purchase), so it's tinted via SetColor
-- rather than actually disabled.
local LOCKED_COLOR = Color3.fromRGB(130, 130, 130)
local PRICE_GREEN = Color3.fromRGB(96, 224, 120) -- matches the $/marble green used elsewhere

-- Standard subtractive-notation Roman numerals for the "ZONE <n>" readout. The zone ladder
-- starts at 1 (tier 0 = Zone I) and only grows, so no need to handle 0/negatives.
type RomanEntry = { value: number, numeral: string }
local ROMAN_TABLE: { RomanEntry } = {
	{ value = 1000, numeral = "M" }, { value = 900, numeral = "CM" },
	{ value = 500, numeral = "D" }, { value = 400, numeral = "CD" },
	{ value = 100, numeral = "C" }, { value = 90, numeral = "XC" },
	{ value = 50, numeral = "L" }, { value = 40, numeral = "XL" },
	{ value = 10, numeral = "X" }, { value = 9, numeral = "IX" },
	{ value = 5, numeral = "V" }, { value = 4, numeral = "IV" },
	{ value = 1, numeral = "I" },
}
local function toRoman(n: number): string
	local out = {}
	for _, entry in ROMAN_TABLE do
		while n >= entry.value do
			table.insert(out, entry.numeral)
			n -= entry.value
		end
	end
	return table.concat(out)
end

Controller.STYLE = {
	autoOffColor = Color3.fromRGB(255, 120, 120),
	autoOnColor = Color3.fromRGB(4, 255, 0),
}

local launchHost = BottomBar:WaitForChild("LaunchBtn")
local launchButton = launchHost:WaitForChild("Button") :: GuiButton
local launchShadow = launchHost:WaitForChild("Shadow") :: GuiObject
local launchStroke = launchButton:WaitForChild("UIStroke") :: UIStroke
local betSizeLabel = launchButton:WaitForChild("BetSize") :: TextLabel
local ORIGINAL_BETSIZE_COLOR = betSizeLabel.TextColor3
-- "Text" is a CHILD TextLabel (same sibling pattern as BetSize), NOT launchButton's own
-- native .Text property — dot-indexing a same-named property always wins over a child of
-- that name, so `launchButton.Text = ...` silently writes to the (invisible/unused) native
-- property instead of this label. Must go through WaitForChild, which isn't fooled by that.
local launchWordLabel = launchButton:WaitForChild("Text") :: TextLabel
local ORIGINAL_SHADOW_VISIBLE = launchShadow.Visible
-- Authored Transparency = 1 (invisible) — both branches now paint the stroke themselves
-- (locked: solid white; unlocked: the zone's wall color), so nothing reads it as "off".
local UNLOCK_STROKE_COLOR = Color3.new(1, 1, 1)

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
-- Launch slots the player owns (ProfileStats.GetMaxSlots off the NumSlots upgrade tier) —
-- what the "N x $P" line counts now, regardless of each slot's live cooldown/AUTO state.
local ownedSlots = 0

-- The locked-preview selection is client-local, but other surfaces render off it too
-- (SlotInteract greys its launch pads to "Zone Locked"): exposed as a getter + a Signal
-- fired with (locked: boolean) whenever render() sees the state flip.
Controller.ZoneLockedChanged = Signal.new()
local lastZoneLocked = false

function Controller.IsZoneLocked(): boolean
	return selectedTier > ownedTier
end
-- Bound inside Controller.Init (assigned before render()/onRaise()/onLower() can ever
-- actually run — they're only reachable via button clicks or the heartbeat, both wired
-- up at the end of Init), but typed optional since Luau can't see that ordering.
local launchHandle: UIButton.Handle? = nil
local raiseHandle: UIButton.Handle? = nil
local lowerHandle: UIButton.Handle? = nil

local doAutoLaunch = false

-- The price to buy ownedTier -> ownedTier+1 (shown in place of the bet size while
-- locked/previewing that rung). Only re-fetched when ownedTier actually changes (see
-- onProfileChanged/attemptUnlock), not on every render — refreshPrice calls render()
-- itself once the fetch resolves.
local lastPricedTier: number? = nil
local nextTierPrice: number? = nil

-- Slots this button would actually fire RIGHT NOW: equipped (in the server-pushed
-- loadout), not running its per-slot server AUTO (those fire themselves), and off its
-- client-mirrored cooldown (slotReadyAt, fed by SlotLaunched). All client-side state. Only
-- feeds onLaunchClicked's no-op guard now — the "N x $P" line counts ownedSlots instead
-- (LaunchBtn is Interactable=false whenever this guard would matter anyway, since it only
-- stays a real button while previewing a locked rung).
local latestLoadout: { [string]: string } = {}
local autoSlots: { [string]: boolean } = {} -- profile.autoSlots: value true = AUTO running
local slotReadyAt: { [number]: number } = {} -- os.clock() when a launched slot is ready again

local function availableCount(): number
	local n = 0
	local now = os.clock()
	for slotStr in latestLoadout do
		local slot = tonumber(slotStr)
		if slot and autoSlots[slotStr] ~= true and (slotReadyAt[slot] or 0) <= now then
			n += 1
		end
	end
	return n
end

local function render()
	local locked = selectedTier > ownedTier
	if locked then
		-- Previewing the locked rung: the real "UNLOCK ZONE" button, unchanged — stays
		-- CLICKABLE (pressing it attempts the Unlock purchase), tinted via SetColor rather
		-- than SetDisabled, restores the shadow, and gives it a solid white outline (the
		-- authored stroke is Transparency 1 — invisible — since nothing painted it before
		-- the zone-color feature existed).
		if nextTierPrice then
			-- Show what it costs to unlock, in green, instead of the (inaccessible) launch cost.
			betSizeLabel.Text = StringUtils.FormatMoney(nextTierPrice)
			betSizeLabel.TextColor3 = PRICE_GREEN
		else
			betSizeLabel.Text = ("%d x %s"):format(
				ownedSlots,
				StringUtils.FormatMoney(ProfileStats.GetBetSizeAtTier(selectedTier))
			)
			betSizeLabel.TextColor3 = ORIGINAL_BETSIZE_COLOR
		end
		launchWordLabel.Text = UNLOCK_WORD
		launchWordLabel.TextSize = WORD_TEXT_SIZE
		launchButton.Interactable = true
		launchShadow.Visible = ORIGINAL_SHADOW_VISIBLE
		launchStroke.Color = UNLOCK_STROKE_COLOR
		launchStroke.Transparency = 0
		if launchHandle then
			launchHandle.SetColor(LOCKED_COLOR)
		end
	else
		-- Owned rung selected — the normal-play state: LaunchBtn is no longer a button at
		-- all, just a "ZONE <n>" readout painted with THIS zone's own board colors (floor
		-- -> bg, wall -> stroke), so it reads as "you're here" rather than a control.
		-- Firing marbles is entirely the slot pads'/AUTO's job now.
		betSizeLabel.Text = ("%d x %s"):format(
			ownedSlots,
			StringUtils.FormatMoney(ProfileStats.GetBetSizeAtTier(selectedTier))
		)
		betSizeLabel.TextColor3 = ORIGINAL_BETSIZE_COLOR
		launchWordLabel.Text = ZONE_WORD_PREFIX .. toRoman(selectedTier + 1)
		launchWordLabel.TextSize = WORD_TEXT_SIZE
		launchButton.Interactable = false
		launchShadow.Visible = false
		local floorColor = BoardColors.Lookup(BoardAppearanceConfig.Floor, selectedTier, BoardAppearanceConfig.MaxTier)
		local wallColor = BoardColors.Lookup(BoardAppearanceConfig.Side, selectedTier, BoardAppearanceConfig.MaxTier)
		if launchHandle then
			launchHandle.SetColor(floorColor)
		end
		launchStroke.Color = wallColor
		launchStroke.Transparency = 0
	end
	-- Raise/Lower actually should do nothing at their respective edges, so they use the
	-- real UIButton.SetDisabled (which greys both the button and its shadow, and blocks
	-- clicks, without pressing it down).
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
	ownedTier = (profile.upgrades and profile.upgrades.MaxBet) or 0
	selectedTier = (profile.loadout and profile.loadout.BetTier) or ownedTier
	if type(profile.autoSlots) == "table" then
		autoSlots = profile.autoSlots -- AUTO-running slots are excluded from availableCount()
	end
	ownedSlots = ProfileStats.GetMaxSlots(if type(profile.upgrades) == "table" then profile.upgrades else {})
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
	ShopUI.OpenShop("MaxBet")
	-- local result = PurchaseUpgradeRF:InvokeServer("MaxBet")
	-- if type(result) ~= "table" then
	-- 	return
	-- end
	-- if result.ok then
	-- 	SoundService.Play({ soundId = SoundsConfig.Upgrade })
	-- 	local info = result.upgrades and result.upgrades.MaxBet
	-- 	local newOwnedTier = if info then info.tier else ownedTier + 1
	-- 	ownedTier = newOwnedTier
	-- 	selectTier(newOwnedTier) -- optimistic render + background SetBetTier reconcile
	-- 	refreshPrice() -- also renders; the newly-unlocked tier needs its OWN next price cached
	-- elseif result.reason == "cannot_afford" then
	-- 	local productId = RequestUpgradeBoostRF:InvokeServer("MaxBet")
	-- 	if productId then
	-- 		-- Throttled (shared cooldown with ShopUI's promptBoost, keyed by productId) so
	-- 		-- clicking LAUNCH/UNLOCK repeatedly while broke doesn't reopen the Robux dialog
	-- 		-- on every click.
	-- 		ProductService.PromptThrottled(productId, MonetizationConfig.UpgradeBoostPromptCooldown)
	-- 	end
	-- end
end

-- Bound as LaunchBtn's onClick, but only reachable while previewing a locked rung —
-- render() sets Button.Interactable = false on every owned/unlocked rung, so Activated
-- (and this whole function) never fires in that state; the launch fallthrough below is a
-- defensive leftover from when this button also fired ready slots directly.
local function onLaunchClicked()
	if selectedTier > ownedTier then
		attemptUnlock()
		return
	end
	if availableCount() == 0 then
		return -- greyed out: nothing this button could fire (auto slots fire themselves)
	end
	-- No press sound here: SlotInteract plays the launch sound at each pad that actually
	-- fires (driven by the server's SlotLaunched push), covering manual, HUD, and auto.
	-- No countdown either — the "N x $P" line drops as SlotLaunched pushes arrive and
	-- recovers as the mirrored cooldowns lapse.
	RequestLaunchRE:FireServer() -- no slot arg = every READY slot fires
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
	-- Mirror the slot's cooldown into slotReadyAt (availableCount()'s source — still feeds
	-- onLaunchClicked's no-op guard even though the "N x $P" line itself no longer counts
	-- it); re-render when it lapses (only if this entry is still the latest for the slot —
	-- a newer launch supersedes the pending re-render).
	local readyAt = os.clock() + cooldown
	slotReadyAt[slot] = readyAt
	render()
	task.delay(cooldown + 0.05, function()
		if slotReadyAt[slot] == readyAt then
			render()
		end
	end)
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
	-- loadout push is what brings it into the cycle. It also carries the equipped-slot
	-- map availableCount() reads from.
	local function applyLoadout(info: any)
		if type(info) == "table" and type(info.loadout) == "table" then
			latestLoadout = info.loadout
			render()
		end
	end
	;(LoadoutNet.LoadoutChanged :: RemoteEvent).OnClientEvent:Connect(function(info: any)
		applyLoadout(info)
		autoKick()
	end)
	-- Seed once on startup (pushes only arrive on changes) — same pattern SlotInteract uses.
	task.spawn(function()
		local ok, info = pcall(function()
			return (LoadoutNet.GetLoadoutInfo :: RemoteFunction):InvokeServer()
		end)
		if ok then
			applyLoadout(info)
		end
	end)

	refreshFromProfile()
end

return Controller
