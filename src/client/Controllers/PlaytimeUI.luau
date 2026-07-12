--!strict
-- Playtime menu: the PlaytimeTriggerHost button on MainGui.LeftBar opens the LeftBar.Playtime
-- panel (and hides itself); the panel's UIListIgnore.CloseButton closes it. Mirrors
-- BallTuningUI's TuneTriggerHost open/close (a UIScale grow/shrink so the left bar reflows).
--
-- The panel holds a scrolling list of bonus rows — one per PlaytimeBonusesConfig rung — driven
-- by PlaytimeBonusService (GetPlaytimeInfo / ClaimPlaytimeBonus / PlaytimeChanged). Each row
-- shows the reward, the playtime needed, and a claim button that's enabled + glowing when
-- claimable and greyed when locked/claimed. The trigger button itself glows (brighter colour +
-- pulsing stroke) whenever any reward is available, so players notice it from the HUD.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UIButton = require(RS.Shared.Utility.UIButton)
local StringUtils = require(RS.Shared.Utility.StringUtils)
local PlaytimeBonusesConfig = require(RS.Shared.Config.PlaytimeBonuses)
local SoundsConfig = require(RS.Shared.Config.Sounds)
local PlaytimeUI = {}

local player = Players.LocalPlayer
local CurrencyFlyUI = require(script.Parent.CurrencyFlyUI)
local PlaytimeNet = require(RS.Shared.Remote.PlaytimeNet)

-- Mirrors PlaytimeBonusService.Info / RungInfo (server-computed).
type RungInfo = { time: number, reward: number, reached: boolean, claimed: boolean }
type Info = {
	total: number,
	claimedCount: number,
	availableCount: number,
	availableReward: number,
	nextTime: number?,
	rungs: { RungInfo },
}

export type ItemState = "claimable" | "locked" | "claimed"
export type ItemOptions = {
	layoutOrder: number?,
	reward: number,
	time: number,
	state: ItemState?,
	onClaim: (() -> ())?,
}
export type ItemHandle = {
	frame: Frame,
	setState: (state: ItemState) -> (),
}

local OPEN_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- open/close state
local isOpen = false
local openTween: Tween? = nil
local restScale = 1
local closeBound = false

-- content / service state
local bonusList: ScrollingFrame? = nil
local itemHandles: { ItemHandle } = {}
local itemsBuilt = false
local latestInfo: Info? = nil
local triggerBtn: UIButton.Handle? = nil
local defaultTriggerColor: Color3? = nil
local leftBarRef: Instance? = nil
local triggerHostRef: GuiObject? = nil

-- reached[i] mirrors "reached and not claimed" (i.e. rungState == "claimable") for rung i as
-- of the last onInfo call, so a fresh unlock (not-claimable -> claimable) can be told apart
-- from "still sitting claimable, already saw it" — same edge-detection shape QuestUI uses for
-- daily quests, just keyed by the rung's stable index instead of a quest key.
local prevReached: { [number]: boolean } = {}
local sawFirstInfo = false

-- Forward-declared: onInfo (defined below, before buildItems exists) auto-opens the panel on
-- a fresh unlock, but the real definition needs buildItems, defined further down — same
-- forward-decl shape as QuestUI's openPanel/ProfileService's reclampLoadout.
local openPlaytimePanel: () -> ()

-- remotes (resolved in Init)
local getInfoRF: RemoteFunction
local claimRF: RemoteFunction
local changedRE: RemoteEvent

----------------------------------------------------------------
-- Open / close (mirrors BallTuningUI's tuning menu)
----------------------------------------------------------------
local function panelScale(panel: GuiObject): UIScale
	local s = panel:FindFirstChildOfClass("UIScale")
	if not s then
		s = Instance.new("UIScale")
		s.Parent = panel
	end
	return s
end

local function openMenu(triggerHost: GuiObject, panel: GuiObject)
	if isOpen then return end
	isOpen = true
	if openTween then openTween:Cancel() end

	-- The open panel replaces the whole 2×2 trigger quad on the left, not just this button.
	;(triggerHost:FindFirstAncestor("TriggerQuad") :: GuiObject).Visible = false
	panel.Visible = true

	local scale = panelScale(panel)
	restScale = scale.Scale
	scale.Scale = 0
	openTween = TweenService:Create(scale, OPEN_TWEEN, { Scale = restScale })
	openTween:Play()
end

local function closeMenu(triggerHost: GuiObject, panel: GuiObject)
	if not isOpen then return end
	isOpen = false
	if openTween then
		openTween:Cancel()
		openTween = nil
	end

	panelScale(panel).Scale = restScale
	panel.Visible = false
	;(triggerHost:FindFirstAncestor("TriggerQuad") :: GuiObject).Visible = true
end

----------------------------------------------------------------
-- Bonus rows
----------------------------------------------------------------
local ITEM_HEIGHT  = 48
-- Light theme for the rows (panel is white).
local ITEM_BG      = Color3.fromRGB(238, 240, 248)
local ITEM_STROKE  = Color3.fromRGB(202, 207, 224)
local AMOUNT_COLOR = Color3.fromRGB(216, 156, 24) -- amber, readable on light
local TIME_COLOR   = Color3.fromRGB(120, 125, 142)
local ZONE_STROKE  = Color3.fromRGB(198, 203, 222) -- border around the scroll zone
local CLAIM_GREEN  = Color3.fromRGB(64, 200, 99)
local GLOW_GOLD    = Color3.fromRGB(255, 220, 120)
local GLOW_WHITE   = Color3.fromRGB(255, 255, 255)

local function formatDuration(seconds: number): string
	local mins = math.floor(seconds / 60)
	local hrs = math.floor(mins / 60)
	local rem = mins % 60
	if hrs <= 0 then
		return string.format("%d min", mins)
	elseif rem == 0 then
		return string.format("%d hr", hrs)
	end
	return string.format("%d hr %d min", hrs, rem)
end

-- A UIButton-structured claim button (Host > { Shadow, Button > Hover }), anchored right.
-- Returns the host, the TextButton (to retitle it), and the UIButton handle.
local function makeClaimButton(parent: Instance, onClick: () -> ()): (Frame, TextButton, UIButton.Handle)
	local host = Instance.new("Frame")
	host.Name = "Claim"
	host.AnchorPoint = Vector2.new(1, 0.5)
	host.Position = UDim2.new(1, 0, 0.5, 0)
	host.Size = UDim2.fromOffset(100, 34)
	host.BackgroundTransparency = 1
	host.Parent = parent

	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.Size = UDim2.fromScale(1, 1)
	shadow.Position = UDim2.fromOffset(0, 3)
	shadow.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	shadow.BorderSizePixel = 0
	shadow.ZIndex = 1
	shadow.Parent = host
	local shadowCorner = Instance.new("UICorner")
	shadowCorner.CornerRadius = UDim.new(0, 7)
	shadowCorner.Parent = shadow

	local button = Instance.new("TextButton")
	button.Name = "Button"
	button.Size = UDim2.fromScale(1, 1)
	button.BackgroundColor3 = CLAIM_GREEN
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.TextSize = 15
	button.Text = "CLAIM"
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.TextStrokeColor3 = Color3.new(0, 0, 0)
	button.TextStrokeTransparency = 0.6
	button.ZIndex = 2
	button.Parent = host
	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 7)
	buttonCorner.Parent = button

	local hover = Instance.new("Frame")
	hover.Name = "Hover"
	hover.Size = UDim2.fromScale(1, 1)
	hover.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	hover.BackgroundTransparency = 1
	hover.BorderSizePixel = 0
	hover.ZIndex = 3
	hover.Parent = button
	local hoverCorner = Instance.new("UICorner")
	hoverCorner.CornerRadius = UDim.new(0, 7)
	hoverCorner.Parent = hover

	local handle = UIButton.bind(host, { onClick = onClick, pressOffset = 3, clickSound = SoundsConfig.Upgrade })
	return host, button, handle
end

-- Build one bonus row under `parent`. setState flips the claim button between claimable
-- (enabled + glowing), claimed, and locked (both disabled/greyed).
function PlaytimeUI.buildItem(parent: Instance, opts: ItemOptions): ItemHandle
	local item = Instance.new("Frame")
	item.Name = "BonusItem"
	item.Size = UDim2.new(1, 0, 0, ITEM_HEIGHT)
	item.BackgroundColor3 = ITEM_BG
	item.BorderSizePixel = 0
	item.LayoutOrder = opts.layoutOrder or 0
	item.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = item
	local stroke = Instance.new("UIStroke")
	stroke.Color = ITEM_STROKE
	stroke.Transparency = 0.1
	stroke.Thickness = 1.5
	stroke.Parent = item
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = item

	local amount = Instance.new("TextLabel")
	amount.Name = "Amount"
	amount.BackgroundTransparency = 1
	amount.AnchorPoint = Vector2.new(0, 0)
	amount.Position = UDim2.fromScale(0, 0)
	amount.Size = UDim2.new(1, -108, 0, 20)
	amount.Font = Enum.Font.GothamBold
	amount.TextSize = 17
	amount.TextXAlignment = Enum.TextXAlignment.Left
	amount.TextColor3 = AMOUNT_COLOR
	amount.TextStrokeTransparency = 1 -- dark text on a light row needs no stroke
	amount.Text = "$" .. StringUtils.FormatShort(opts.reward)
	amount.Parent = item

	local timeLabel = Instance.new("TextLabel")
	timeLabel.Name = "Time"
	timeLabel.BackgroundTransparency = 1
	timeLabel.AnchorPoint = Vector2.new(0, 1)
	timeLabel.Position = UDim2.fromScale(0, 1)
	timeLabel.Size = UDim2.new(1, -108, 0, 14)
	timeLabel.Font = Enum.Font.GothamMedium
	timeLabel.TextSize = 12
	timeLabel.TextXAlignment = Enum.TextXAlignment.Left
	timeLabel.TextColor3 = TIME_COLOR
	timeLabel.TextStrokeTransparency = 1
	timeLabel.Text = "⏱ " .. formatDuration(opts.time)
	timeLabel.Parent = item

	local _, button, handle = makeClaimButton(item, function()
		if opts.onClaim then
			opts.onClaim()
		end
	end)

	local function setState(state: ItemState)
		if state == "claimable" then
			handle.SetDisabled(false)
			handle.SetColor(CLAIM_GREEN)
			button.Text = "CLAIM"
			handle.SetGlowing(true, GLOW_GOLD)
		elseif state == "claimed" then
			handle.SetGlowing(false)
			button.Text = "CLAIMED"
			handle.SetDisabled(true)
		else -- "locked"
			handle.SetGlowing(false)
			button.Text = "LOCKED"
			handle.SetDisabled(true)
		end
	end

	setState(opts.state or "locked")
	return { frame = item, setState = setState }
end

-- The scrolling list that holds the rows, created once. Pinned-size panel + a flex-filled
-- ScrollingFrame keeps the menu at its authored size while the rows scroll inside.
local function ensureBonusList(panel: GuiObject): ScrollingFrame
	if bonusList then
		return bonusList
	end
	panel.AutomaticSize = Enum.AutomaticSize.None -- keep the menu at its authored size

	-- Make the head/list ordering deterministic: head pinned first, list (order 10) after.
	local panelLayout = panel:FindFirstChildOfClass("UIListLayout")
	if panelLayout then
		panelLayout.SortOrder = Enum.SortOrder.LayoutOrder
	end
	local head = panel:FindFirstChild("head")
	if head and head:IsA("GuiObject") then
		head.LayoutOrder = 0
	end

	local sf = Instance.new("ScrollingFrame")
	sf.Name = "BonusList"
	sf.BackgroundTransparency = 1
	sf.BorderSizePixel = 0
	sf.Size = UDim2.fromScale(1, 1) -- width fills; height is taken over by the UIFlexItem
	sf.LayoutOrder = 10             -- after the head
	sf.ScrollBarThickness = 6
	sf.ScrollBarImageTransparency = 0.35
	sf.ScrollingDirection = Enum.ScrollingDirection.Y
	sf.CanvasSize = UDim2.new()
	sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
	sf.ClipsDescendants = true
	sf.Parent = panel

	-- Border around the scroll zone (rounded, faint outline).
	local zoneCorner = Instance.new("UICorner")
	zoneCorner.CornerRadius = UDim.new(0, 10)
	zoneCorner.Parent = sf
	local zoneStroke = Instance.new("UIStroke")
	zoneStroke.Color = ZONE_STROKE
	zoneStroke.Thickness = 1.5
	zoneStroke.Transparency = 0.05
	zoneStroke.Parent = sf

	-- Fill whatever vertical space is left under the head, within the fixed panel.
	local flex = Instance.new("UIFlexItem")
	flex.FlexMode = Enum.UIFlexMode.Fill
	flex.Parent = sf

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, 6)
	layout.Parent = sf

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 2)
	pad.PaddingBottom = UDim.new(0, 2)
	pad.PaddingRight = UDim.new(0, 6) -- clear the scrollbar
	pad.Parent = sf

	bonusList = sf
	return sf
end

----------------------------------------------------------------
-- Service binding (GetPlaytimeInfo / ClaimPlaytimeBonus / PlaytimeChanged)
----------------------------------------------------------------
local function rungState(rung: RungInfo): ItemState
	if rung.claimed then
		return "claimed"
	elseif rung.reached then
		return "claimable"
	end
	return "locked"
end

local function refreshRows(info: Info)
	for i, handle in itemHandles do
		local rung = info.rungs[i]
		if rung then
			handle.setState(rungState(rung))
		end
	end
end

-- Trigger button glows (brighter colour + pulsing gold/white stroke) when any reward is ready.
local function updateTriggerGlow(info: Info?)
	if not triggerBtn then
		return
	end
	local available = info ~= nil and info.availableCount > 0
	triggerBtn.SetGlowing(available, GLOW_GOLD, GLOW_WHITE)
	if defaultTriggerColor then
		triggerBtn.SetColor(if available then defaultTriggerColor:Lerp(Color3.new(1, 1, 1), 0.3) else defaultTriggerColor)
	end
end

-- Updates prevReached from this info and reports whether any rung just crossed
-- not-claimable -> claimable since the LAST call. Always false on the first call (a rung
-- already sitting claimable from a previous session shouldn't auto-open on join).
local function detectFreshlyReached(info: Info): boolean
	local any = false
	for i, rung in info.rungs do
		local isNow = rung.reached and not rung.claimed
		if sawFirstInfo and isNow and not prevReached[i] then
			any = true
		end
		prevReached[i] = isNow
	end
	sawFirstInfo = true
	return any
end

local function onInfo(info: Info)
	local freshlyReached = detectFreshlyReached(info)

	latestInfo = info
	updateTriggerGlow(info)
	if itemsBuilt then
		refreshRows(info)
	end

	-- Auto-open on a fresh unlock (not on every refresh while it just sits claimable — the
	-- trigger's persistent glow already carries "until claimed"). Don't fight the player if
	-- it's already open.
	if freshlyReached and not isOpen then
		openPlaytimePanel()
	end
end

-- Claim one specific rung by index.
local function claim(index: number)
	local res = claimRF:InvokeServer(index)
	if res and res.granted then
		CurrencyFlyUI.Play("Cash") -- playtime rungs pay cash
	end
	if res and res.info then
		onInfo(res.info)
	end
end

local function buildItems(panel: GuiObject)
	local list = ensureBonusList(panel)
	for _, c in list:GetChildren() do
		if c.Name == "BonusItem" then
			c:Destroy()
		end
	end
	table.clear(itemHandles)
	for i, rung in PlaytimeBonusesConfig.Rungs do
		itemHandles[i] = PlaytimeUI.buildItem(list, {
			layoutOrder = i,
			reward = rung.Reward,
			time = rung.Time,
			onClaim = function()
				claim(i)
			end,
		})
	end
	itemsBuilt = true
end

-- Open the panel (lazily resolving it, binding its Close button, and building/refreshing rows
-- the first time), reused by both the trigger button's onClick and onInfo's auto-open.
function openPlaytimePanel()
	local leftBar = leftBarRef
	local triggerHost = triggerHostRef
	if not leftBar or not triggerHost then
		return
	end
	local panel = leftBar:FindFirstChild("Playtime") :: GuiObject?
	if not panel then
		warn("PlaytimeUI: LeftBar.Playtime not present yet — nothing to open")
		return
	end
	if not closeBound then
		local ignore = panel:FindFirstChild("UIListIgnore")
		local closeBtn = ignore and ignore:FindFirstChild("CloseButton")
		if closeBtn and closeBtn:IsA("GuiButton") then
			closeBtn.Activated:Connect(function()
				closeMenu(triggerHost, panel)
			end)
			closeBound = true
		end
	end
	if not itemsBuilt then
		buildItems(panel)
	end
	if latestInfo then
		refreshRows(latestInfo)
	end
	if not isOpen then
		panel.Visible = false -- clean closed state before the grow tween
		openMenu(triggerHost, panel)
	end
end

-- Public open/close query, mirroring LoadoutUI.IsOpen/Close — lets other systems (the
-- Loadout tutorial step) force this panel shut when it would otherwise sit on top of the
-- LoadoutTriggerHost it shares TriggerQuad with.
function PlaytimeUI.IsOpen(): boolean
	return isOpen
end

function PlaytimeUI.Close()
	if isOpen and leftBarRef and triggerHostRef then
		local panel = leftBarRef:FindFirstChild("Playtime") :: GuiObject?
		if panel then
			closeMenu(triggerHostRef, panel)
		end
	end
end

----------------------------------------------------------------
-- Init
----------------------------------------------------------------
local function triggerButtonOf(host: Instance): GuiButton?
	if host:IsA("GuiButton") then
		return host
	end
	local b = host:FindFirstChild("Button")
	if b and b:IsA("GuiButton") then
		return b
	end
	return nil
end

function PlaytimeUI.Init()
	getInfoRF = PlaytimeNet.GetPlaytimeInfo :: RemoteFunction
	claimRF = PlaytimeNet.ClaimPlaytimeBonus :: RemoteFunction
	changedRE = PlaytimeNet.PlaytimeChanged :: RemoteEvent

	local playerGui = player:WaitForChild("PlayerGui")
	local mainGui = playerGui:WaitForChild("MainGui")
	local leftBar = mainGui:WaitForChild("LeftBar")
	local triggerHost = (leftBar:WaitForChild("TriggerQuad") :: Instance):FindFirstChild("PlaytimeTriggerHost", true) :: GuiObject
	triggerHost.Visible = true
	leftBarRef = leftBar
	triggerHostRef = triggerHost

	local tbtn = triggerButtonOf(triggerHost)
	if tbtn then
		defaultTriggerColor = tbtn.BackgroundColor3
	end

	triggerBtn = UIButton.bind(triggerHost, { onClick = openPlaytimePanel, hoverScale = 1.08 })

	-- Live updates: the service pushes on load, on a rung becoming available, and on claim.
	changedRE.OnClientEvent:Connect(function(info)
		onInfo(info :: Info)
	end)
	-- Initial snapshot (may be nil if data isn't loaded yet; PlaytimeChanged will follow).
	task.spawn(function()
		local info = getInfoRF:InvokeServer()
		if info then
			onInfo(info :: Info)
		end
	end)
end

return PlaytimeUI
