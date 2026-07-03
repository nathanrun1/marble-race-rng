--!strict
-- Daily quests panel (client of QuestService: GetQuestInfo / ClaimQuest / QuestsChanged).
-- The primary roots are Studio-authored on MainGui.LeftBar: QuestTriggerHost (UIButton
-- contract, same structure as PlaytimeTriggerHost/TuneTriggerHost) opens LeftBar.QuestPanel
-- and hides itself, mirroring PlaytimeUI's open/close (a UIScale grow/shrink so the left bar
-- reflows). This module binds the trigger, fills the panel — title, reset countdown, one
-- row per quest with a progress bar and claim button — and keeps it live. Panel children
-- (Title/Reset/Close/Rows) are resolved by name and created when missing, so a panel
-- copied from a previous runtime build keeps working.
--
-- A second, always-visible presentation is built into any world SurfaceGui tagged
-- Config.Tags.QuestUI (same CollectionService tag-discovery template as CosmeticsShop) —
-- a physical kiosk showing the same live quest data, no open/close/trigger, just always on.
-- Both presentations are "views" sharing the same row-building/update logic; onInfo drives
-- every view from one QuestsChanged/GetQuestInfo payload.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local UIButton = require(RS.Shared.UIButton)
local StringUtils = require(RS.Shared.StringUtils)
local Config = require(RS.Shared.Config)

local QuestUI = {}

local player = Players.LocalPlayer

-- Mirrors QuestService.Info / QuestInfo (server-computed).
type QuestInfo = {
	key: string,
	text: string,
	icon: string,
	target: number,
	progress: number,
	completed: boolean,
	claimed: boolean,
	reward: number,
}
type Info = {
	day: number,
	resetIn: number,
	quests: { QuestInfo },
}

-- Light theme, matching the playtime panel rows.
local ITEM_BG      = Color3.fromRGB(238, 240, 248)
local ITEM_STROKE  = Color3.fromRGB(202, 207, 224)
local TEXT_DARK    = Color3.fromRGB(45, 48, 60)
local TEXT_FAINT   = Color3.fromRGB(120, 125, 142)
local REWARD_AMBER = "#d89c18" -- rich-text hex for the reward suffix
local BAR_BG       = Color3.fromRGB(214, 218, 232)
local BAR_FILL     = Color3.fromRGB(64, 200, 99)
local BAR_DONE     = Color3.fromRGB(255, 196, 40)
local CLAIM_GREEN  = Color3.fromRGB(64, 200, 99)
local GLOW_GOLD    = Color3.fromRGB(255, 220, 120)
local GLOW_WHITE   = Color3.fromRGB(255, 255, 255)
local PANEL_BG     = Color3.fromRGB(255, 255, 255) -- world-surface view background

local ROW_HEIGHT = 66
local OPEN_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

type Row = {
	frame: Frame,
	text: TextLabel,
	barFill: Frame,
	counter: TextLabel,
	button: TextButton,
	handle: UIButton.Handle,
}

-- One row-rendering target: the LeftBar panel is one View, and every world SurfaceGui
-- tagged Config.Tags.QuestUI is another. alwaysVisible marks the world-surface kind (always
-- ticks its countdown; the LeftBar panel only ticks while open).
type View = {
	resetLabel: TextLabel?,
	rowsHolder: Frame,
	rows: { Row },
	signature: string, -- day + quest keys/targets; rows rebuild only when this changes
	alwaysVisible: boolean,
}

local views: { View } = {}

local triggerHost: GuiObject? = nil
local triggerHandle: UIButton.Handle? = nil
local panel: GuiObject? = nil

local latestInfo: Info? = nil
local resetAt = 0 -- os.clock() of the next UTC-day reset (from info.resetIn)
local isOpen = false
local openTween: Tween? = nil
local restScale = 1 -- the panel UIScale's authored rest value (captured at open)

-- Forward-declared: onInfo (below) auto-opens the panel on a fresh completion, but
-- openPanel's real definition lives further down in the Open/Close section.
local openPanel: () -> ()

-- claimable[key] mirrors "completed and not claimed" as of the last onInfo call, so a
-- completed->claimed or not-completed->completed edge can be told apart from "still
-- sitting completed, already saw it" (which must NOT keep re-opening the panel).
local prevClaimable: { [string]: boolean } = {}
local sawFirstInfo = false -- first onInfo call only seeds prevClaimable, never auto-opens

local getInfoRF: RemoteFunction
local claimRF: RemoteFunction

----------------------------------------------------------------
-- Construction helpers
----------------------------------------------------------------

local function makeCorner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

-- A UIButton-contract button (Host > { Shadow, Button > Hover }) sized by the caller.
local function makeButton(parent: Instance, size: UDim2, position: UDim2, anchor: Vector2, text: string, textSize: number, onClick: () -> ()): (Frame, TextButton, UIButton.Handle)
	local host = Instance.new("Frame")
	host.Name = "ButtonHost"
	host.AnchorPoint = anchor
	host.Position = position
	host.Size = size
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
	makeCorner(shadow, 8)

	local button = Instance.new("TextButton")
	button.Name = "Button"
	button.Size = UDim2.fromScale(1, 1)
	button.BackgroundColor3 = CLAIM_GREEN
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.TextSize = textSize
	button.Text = text
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.TextStrokeColor3 = Color3.new(0, 0, 0)
	button.TextStrokeTransparency = 0.6
	button.ZIndex = 2
	button.Parent = host
	makeCorner(button, 8)

	local hover = Instance.new("Frame")
	hover.Name = "Hover"
	hover.Size = UDim2.fromScale(1, 1)
	hover.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	hover.BackgroundTransparency = 1
	hover.BorderSizePixel = 0
	hover.ZIndex = 3
	hover.Parent = button
	makeCorner(hover, 8)

	local handle = UIButton.bind(host, { onClick = onClick, pressOffset = 3, clickSound = Config.Sounds.Upgrade })
	return host, button, handle
end

local function buildRow(parent: Instance, index: number, onClaim: () -> ()): Row
	local frame = Instance.new("Frame")
	frame.Name = "QuestRow"
	frame.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	frame.BackgroundColor3 = ITEM_BG
	frame.BorderSizePixel = 0
	frame.LayoutOrder = index
	frame.Parent = parent
	makeCorner(frame, 8)
	local stroke = Instance.new("UIStroke")
	stroke.Color = ITEM_STROKE
	stroke.Transparency = 0.1
	stroke.Thickness = 1.5
	stroke.Parent = frame
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 10)
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.Parent = frame

	-- Quest text + reward (rich text so the reward suffix reads amber).
	local text = Instance.new("TextLabel")
	text.Name = "Text"
	text.BackgroundTransparency = 1
	text.Position = UDim2.fromScale(0, 0)
	text.Size = UDim2.new(1, -100, 0, 20)
	text.Font = Enum.Font.GothamBold
	text.TextSize = 15
	text.RichText = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextTruncate = Enum.TextTruncate.AtEnd
	text.TextColor3 = TEXT_DARK
	text.TextStrokeTransparency = 1
	text.Text = ""
	text.Parent = frame

	-- Progress bar (bottom-left), with the x/y counter to its right.
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.new(0, 0, 1, -4)
	bar.Size = UDim2.new(1, -180, 0, 12)
	bar.BackgroundColor3 = BAR_BG
	bar.BorderSizePixel = 0
	bar.Parent = frame
	makeCorner(bar, 6)

	local barFill = Instance.new("Frame")
	barFill.Name = "Fill"
	barFill.Size = UDim2.fromScale(0, 1)
	barFill.BackgroundColor3 = BAR_FILL
	barFill.BorderSizePixel = 0
	barFill.Parent = bar
	makeCorner(barFill, 6)

	local counter = Instance.new("TextLabel")
	counter.Name = "Counter"
	counter.BackgroundTransparency = 1
	counter.AnchorPoint = Vector2.new(0, 1)
	counter.Position = UDim2.new(1, -172, 1, -2)
	counter.Size = UDim2.fromOffset(70, 16)
	counter.Font = Enum.Font.GothamMedium
	counter.TextSize = 12
	counter.TextXAlignment = Enum.TextXAlignment.Left
	counter.TextColor3 = TEXT_FAINT
	counter.TextStrokeTransparency = 1
	counter.Text = ""
	counter.Parent = frame

	local _, button, handle = makeButton(
		frame,
		UDim2.fromOffset(88, 32),
		UDim2.new(1, 0, 0.5, 0),
		Vector2.new(1, 0.5),
		"CLAIM",
		14,
		onClaim
	)

	return { frame = frame, text = text, barFill = barFill, counter = counter, button = button, handle = handle }
end

----------------------------------------------------------------
-- View content: Title/Reset/Rows, shared by the LeftBar panel and every world QuestUI
-- SurfaceGui. wantClose only applies to the LeftBar panel (a toggleable overlay); world
-- surfaces are always-on physical geometry with nothing to close.
----------------------------------------------------------------

local function ensureLabel(parent: Instance, name: string, build: () -> TextLabel): TextLabel
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("TextLabel") then
		return existing
	end
	return build()
end

local function buildTitleResetRows(p: GuiObject, wantClose: boolean, alwaysVisible: boolean): View
	local reset = ensureLabel(p, "Reset", function()
		local r = Instance.new("TextLabel")
		r.Name = "Reset"
		r.BackgroundTransparency = 1
		r.Position = UDim2.fromOffset(14, 28)
		r.Size = UDim2.new(1, -50, 0, 16)
		r.Font = Enum.Font.GothamMedium
		r.TextSize = 13
		r.TextXAlignment = Enum.TextXAlignment.Left
		r.TextColor3 = TEXT_FAINT
		r.TextStrokeTransparency = 1
		r.Text = ""
		r.Parent = p
		return r
	end)

	ensureLabel(p, "Title", function()
		local title = Instance.new("TextLabel")
		title.Name = "Title"
		title.BackgroundTransparency = 1
		title.Position = UDim2.fromOffset(14, 0)
		title.Size = UDim2.new(1, -50, 0, 28)
		title.Font = Enum.Font.GothamBold
		title.TextSize = 20
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextColor3 = TEXT_DARK
		title.TextStrokeTransparency = 1
		title.Text = "📜 Daily Quests"
		title.Parent = p
		return title
	end)

	if wantClose then
		-- Close: the panel's own Close button, a playtime-style UIListIgnore.CloseButton, or —
		-- when the authored panel has neither — one built here, so the panel is always closable.
		local close = p:FindFirstChild("Close")
		if not close then
			local ignore = p:FindFirstChild("UIListIgnore")
			close = ignore and ignore:FindFirstChild("CloseButton")
		end
		if not (close and close:IsA("GuiButton")) then
			local btn = Instance.new("TextButton")
			btn.Name = "Close"
			btn.AnchorPoint = Vector2.new(1, 0)
			btn.Position = UDim2.new(1, -8, 0, 8)
			btn.Size = UDim2.fromOffset(30, 30)
			btn.BackgroundColor3 = Color3.fromRGB(232, 76, 92)
			btn.AutoButtonColor = true
			btn.Font = Enum.Font.GothamBold
			btn.TextSize = 16
			btn.Text = "✕"
			btn.TextColor3 = Color3.new(1, 1, 1)
			btn.ZIndex = 5
			btn.Parent = p
			makeCorner(btn, 8)
			close = btn
		end
		local closeBtn = close :: GuiButton
		closeBtn.Activated:Connect(function()
			QuestUI.Close()
		end)
	end

	local holder = p:FindFirstChild("Rows")
	if not (holder and holder:IsA("Frame")) then
		holder = Instance.new("Frame")
		local h = holder :: Frame
		h.Name = "Rows"
		h.BackgroundTransparency = 1
		h.Position = UDim2.fromOffset(10, 50)
		h.Size = UDim2.new(1, -20, 1, -58)
		h.Parent = p
	end
	local h = holder :: Frame
	if not h:FindFirstChildOfClass("UIListLayout") then
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Vertical
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 8)
		layout.Parent = h
	end
	-- Purge rows copied in from a previous runtime build; ours are rebuilt from live info.
	for _, c in h:GetChildren() do
		if c.Name == "QuestRow" then
			c:Destroy()
		end
	end

	return { resetLabel = reset, rowsHolder = h, rows = {}, signature = "", alwaysVisible = alwaysVisible }
end

-- Build (or rebuild) the always-on world-surface presentation into one tagged SurfaceGui.
-- Same dark-panel-with-padding shell CosmeticsShop.luau uses for its own tagged surface.
local function buildSurfaceView(surface: SurfaceGui)
	local existing = surface:FindFirstChild("QuestUISurface")
	if existing then
		existing:Destroy()
	end

	local root = Instance.new("Frame")
	root.Name = "QuestUISurface"
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

	local view = buildTitleResetRows(root, false, true)
	table.insert(views, view)
	return view
end

----------------------------------------------------------------
-- Data → UI
----------------------------------------------------------------

local function claim(index: number)
	local res = claimRF:InvokeServer(index)
	if res and res.info then
		QuestUI.onInfo(res.info :: Info)
	end
end

local function signatureOf(info: Info): string
	local parts = { tostring(info.day) }
	for _, q in info.quests do
		table.insert(parts, q.key .. ":" .. tostring(q.target))
	end
	return table.concat(parts, "|")
end

local function updateRow(row: Row, q: QuestInfo)
	-- Rewards pay Diamonds (the cosmetics currency, "cc" internally), amber to match the shop theme.
	row.text.Text = string.format(
		'%s %s  <font color="%s">+%s Diamonds</font>',
		q.icon,
		q.text,
		REWARD_AMBER,
		StringUtils.FormatShort(q.reward)
	)
	local frac = if q.target > 0 then math.clamp(q.progress / q.target, 0, 1) else 0
	row.barFill.Size = UDim2.fromScale(frac, 1)
	row.barFill.BackgroundColor3 = if q.completed then BAR_DONE else BAR_FILL
	row.counter.Text = tostring(q.progress) .. "/" .. tostring(q.target)

	if q.claimed then
		row.handle.SetGlowing(false)
		row.handle.SetDisabled(true)
		row.button.Text = "CLAIMED"
	elseif q.completed then
		row.handle.SetDisabled(false)
		row.handle.SetColor(CLAIM_GREEN)
		row.handle.SetGlowing(true, GLOW_GOLD)
		row.button.Text = "CLAIM"
	else
		row.handle.SetGlowing(false)
		row.handle.SetDisabled(true)
		row.button.Text = "CLAIM"
	end
end

-- Rebuild (if the day/quest set changed) and refresh one view's rows from live info.
local function renderView(view: View, info: Info)
	local sig = signatureOf(info)
	if sig ~= view.signature then
		view.signature = sig
		for _, row in view.rows do
			row.handle.Destroy()
			row.frame:Destroy()
		end
		table.clear(view.rows)
		for i in info.quests do
			local index = i
			view.rows[i] = buildRow(view.rowsHolder, i, function()
				claim(index)
			end)
		end
	end
	for i, row in view.rows do
		local q = info.quests[i]
		if q then
			updateRow(row, q)
		end
	end
end

local function anyClaimable(info: Info): boolean
	for _, q in info.quests do
		if q.completed and not q.claimed then
			return true
		end
	end
	return false
end

-- Updates prevClaimable from this info and reports whether any quest just crossed
-- not-claimable -> claimable since the LAST call (i.e. a fresh completion this tick, not
-- one we already knew about). Always returns false on the very first call (there's nothing
-- to compare against yet — a quest already sitting completed from a previous session
-- shouldn't auto-open the panel on join).
local function detectFreshCompletion(info: Info): boolean
	local any = false
	for _, q in info.quests do
		local isNow = q.completed and not q.claimed
		if sawFirstInfo and isNow and not prevClaimable[q.key] then
			any = true
		end
		prevClaimable[q.key] = isNow
	end
	sawFirstInfo = true
	return any
end

function QuestUI.onInfo(info: Info)
	local freshlyCompleted = detectFreshCompletion(info)

	latestInfo = info
	resetAt = os.clock() + info.resetIn

	-- Prune views whose instances are gone (a streamed-out world kiosk) so one dead view
	-- can't error the whole refresh, then render the rest.
	for i = #views, 1, -1 do
		local view = views[i]
		if view.rowsHolder:IsDescendantOf(game) then
			renderView(view, info)
		else
			table.remove(views, i)
		end
	end

	if triggerHandle then
		triggerHandle.SetGlowing(anyClaimable(info), GLOW_GOLD, GLOW_WHITE)
	end

	-- Auto-open on a fresh completion (not on every refresh while it just sits claimable —
	-- the trigger/row glow above already carries "until claimed" persistently). Don't
	-- fight the player if they've already got it open, or already closed it back up.
	if freshlyCompleted and not isOpen then
		openPanel()
	end
end

----------------------------------------------------------------
-- Open / close (mirrors PlaytimeUI: trigger hides, panel grows via its UIScale)
----------------------------------------------------------------

local function panelScale(p: GuiObject): UIScale
	local s = p:FindFirstChildOfClass("UIScale")
	if not s then
		s = Instance.new("UIScale")
		s.Parent = p
	end
	return s
end

local function formatCountdown(seconds: number): string
	seconds = math.max(math.floor(seconds), 0)
	local h = seconds // 3600
	local m = (seconds % 3600) // 60
	if h > 0 then
		return string.format("Resets in %dh %02dm", h, m)
	end
	return string.format("Resets in %dm %02ds", m, seconds % 60)
end

function openPanel()
	local p, t = panel, triggerHost
	if not p or not t or isOpen then
		return
	end
	isOpen = true
	if openTween then
		openTween:Cancel()
	end

	t.Visible = false
	p.Visible = true

	local scale = panelScale(p)
	restScale = scale.Scale
	if restScale <= 0.01 then
		restScale = 1 -- guard against a scale saved mid-tween
	end
	scale.Scale = 0
	openTween = TweenService:Create(scale, OPEN_TWEEN, { Scale = restScale })
	;(openTween :: Tween):Play()
end

function QuestUI.Close()
	local p, t = panel, triggerHost
	if not p or not t or not isOpen then
		return
	end
	isOpen = false
	if openTween then
		openTween:Cancel()
		openTween = nil
	end
	panelScale(p).Scale = restScale
	p.Visible = false
	t.Visible = true
end

----------------------------------------------------------------
-- Init
----------------------------------------------------------------

function QuestUI.Init()
	getInfoRF = RS.Remote:WaitForChild("GetQuestInfo") :: RemoteFunction
	claimRF = RS.Remote:WaitForChild("ClaimQuest") :: RemoteFunction
	local changedRE = RS.Remote:WaitForChild("QuestsChanged") :: RemoteEvent

	local playerGui = player:WaitForChild("PlayerGui")
	local mainGui = playerGui:WaitForChild("MainGui")
	local leftBar = mainGui:WaitForChild("LeftBar")
	local t = leftBar:WaitForChild("QuestTriggerHost") :: GuiObject
	local p = leftBar:WaitForChild("QuestPanel") :: GuiObject

	-- Clean closed state regardless of how the instances were saved in Studio.
	p.Visible = false
	t.Visible = true
	triggerHost = t
	panel = p

	table.insert(views, buildTitleResetRows(p, true, false))
	triggerHandle = UIButton.bind(t, { onClick = openPanel, clickSound = Config.Sounds.Upgrade })

	-- Alternative always-on presentation: any world SurfaceGui tagged QuestUI (same
	-- CollectionService discovery template as CosmeticsShop).
	local function setupSurface(inst: Instance)
		if inst:IsA("SurfaceGui") then
			local view = buildSurfaceView(inst)
			if latestInfo then
				renderView(view, latestInfo)
			end
		end
	end
	for _, inst in CollectionService:GetTagged(Config.Tags.QuestUI) do
		setupSurface(inst)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.QuestUI):Connect(setupSurface)

	changedRE.OnClientEvent:Connect(function(info)
		QuestUI.onInfo(info :: Info)
	end)
	-- Initial snapshot (may be nil pre-load; QuestsChanged follows once data applies).
	task.spawn(function()
		local ok, info = pcall(function()
			return getInfoRF:InvokeServer()
		end)
		if ok and info then
			QuestUI.onInfo(info :: Info)
		end
	end)

	-- Reset countdown: the LeftBar panel only ticks while open, world-surface views always.
	task.spawn(function()
		while true do
			task.wait(1)
			if latestInfo then
				local text = formatCountdown(resetAt - os.clock())
				for _, view in views do
					if view.resetLabel and (view.alwaysVisible or isOpen) then
						view.resetLabel.Text = text
					end
				end
			end
		end
	end)
end

return QuestUI
