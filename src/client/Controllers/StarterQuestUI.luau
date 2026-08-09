--!strict
-- "Getting Started" mission panel (client of StarterQuestService): wires and fills the
-- Studio-AUTHORED panel — a ScreenGui tagged TagsConfig.StarterQuestGui (cloned from
-- StarterGui into PlayerGui by the engine; discovered here via CollectionService, same
-- tag-discovery template as QuestUI's world surfaces). This module builds NO static UI:
-- look/layout live on the authored instances (StarterQuestHUD > HeaderHost/Missions/
-- CardTemplate; the HUD carries the AutoScale tag), and mission cards are clones of the
-- authored CardTemplate. Card geometry (height, side padding, panel width) is read off
-- the authored template so Studio edits don't need matching code edits.
--
-- Rendering is purely info-driven: the server's ChainInfo carries the live mission
-- window (up to Config/StarterQuests.ActiveCount missions, ALL progressable at once,
-- pre-formatted text/targets/rewards), and cards mirror it — no ladder copy here. The
-- header button compacts the stack (clipped height tween) and re-expands on click; a
-- completion while compacted auto-expands first. Completion choreography (rewards +
-- WarnUI are server-side): whichever card's mission completed lights up purple/white,
-- holds, slides off-screen left, the cards below it tween up a slot, and the next
-- mission (if any) slides in at the bottom; completions queue and play one at a time.
-- Finishing the whole chain slides the panel out for good; a player who already
-- finished it never sees the panel.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local StringUtils = require(RS.Shared.Utility.StringUtils)
local UIButton = require(RS.Shared.Utility.UIButton)
local TagsConfig = require(RS.Shared.Config.Tags)
local StarterQuestNet = require(RS.Shared.Remote.StarterQuestNet)

local StarterQuestUI = {}

-- Mirror StarterQuestService.MissionInfo / ChainInfo (server-computed).
type MissionInfo = {
	index: number, -- ladder position: the stable identity matching cards to missions
	text: string,
	target: number,
	progress: number,
	reward: number,
}
type ChainInfo = {
	missions: { MissionInfo },
	completed: number,
	total: number,
	done: boolean,
}

----------------------------------------------------------------
-- Tunables. The steady-state card look is authored on the CardTemplate; these colors
-- only drive the completion flash.
----------------------------------------------------------------

local GAP = 10 -- px between mission cards (sized to match the authored card metrics)

local PURPLE = Color3.fromRGB(148, 92, 235) -- lit-card fill (matches the authored accents)
local WHITE = Color3.new(1, 1, 1)

local HOLD_LIT = 1.2 -- seconds the completed card stays lit before sliding out
local TWEEN_FLASH = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_EXIT = TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.In)
local TWEEN_SHIFT = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_OPEN = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TWEEN_CLOSE = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local TWEEN_BAR = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

----------------------------------------------------------------
-- State
----------------------------------------------------------------

type Card = {
	frame: Frame,
	scale: UIScale,
	stroke: UIStroke,
	title: TextLabel,
	reward: TextLabel,
	bar: Frame,
	barFill: Frame,
	counter: TextLabel,
	stepIndex: number, -- MissionInfo.index this card is showing
}

-- Authored instances, resolved by wire().
local root: Frame? = nil
local rowsFrame: Frame? = nil
local cardTemplate: Frame? = nil
local headerLabel: TextLabel? = nil
local chevron: TextLabel? = nil
local restPos = UDim2.fromOffset(0, 0) -- the HUD's authored Position (hidePanel slides from it)

-- Geometry read off the authored instances at wire time.
local panelWidth = 330
local cardH = 56
local stackPad = 4 -- card side inset; also keeps card strokes clear of the clip

local cards: { Card } = {} -- top-to-bottom card stack
local wired = false -- authored panel found and bound
local built = false -- cards constructed from the first ChainInfo
local latestInfo: ChainInfo? = nil
local pumping = false -- the completion queue is draining
local expanded = true
local rowsTween: Tween? = nil

local function tw(inst: Instance, info: TweenInfo, props: { [string]: any })
	TweenService:Create(inst, info, props):Play()
end

local function slotY(slot: number): number
	return stackPad + (slot - 1) * (cardH + GAP)
end

-- Card-stack height for the CURRENT card count (shrinks near the end of the chain).
local function rowsHeight(): number
	local n = #cards
	return if n > 0 then n * cardH + (n - 1) * GAP + stackPad * 2 else 0
end

----------------------------------------------------------------
-- Card cloning
----------------------------------------------------------------

local function counterText(m: MissionInfo): string
	return tostring(m.progress) .. "/" .. tostring(m.target)
end

local function buildCard(m: MissionInfo, slot: number): Card
	local frame = (cardTemplate :: Frame):Clone()
	frame.Name = "MissionCard"
	frame.Position = UDim2.fromOffset(stackPad, slotY(slot))
	frame.Visible = true

	local title = frame:FindFirstChild("Title") :: TextLabel
	local reward = frame:FindFirstChild("Reward") :: TextLabel
	local bar = frame:FindFirstChild("Bar") :: Frame
	local barFill = bar:FindFirstChild("Fill") :: Frame
	local counter = frame:FindFirstChild("Counter") :: TextLabel
	title.Text = m.text
	reward.Text = "+" .. StringUtils.FormatShort(m.reward) .. " 💎"
	counter.Text = counterText(m)
	barFill.Size = UDim2.fromScale(if m.target > 0 then math.clamp(m.progress / m.target, 0, 1) else 0, 1)

	frame.Parent = rowsFrame

	return {
		frame = frame,
		scale = frame:FindFirstChildOfClass("UIScale") :: UIScale,
		stroke = frame:FindFirstChildOfClass("UIStroke") :: UIStroke,
		title = title,
		reward = reward,
		bar = bar,
		barFill = barFill,
		counter = counter,
		stepIndex = m.index,
	}
end

----------------------------------------------------------------
-- Expand / compact
----------------------------------------------------------------

local function setExpanded(on: boolean, instant: boolean?)
	-- Chevron is plain ASCII: fancier glyphs (▾/▸) aren't in FredokaOne's glyph set and
	-- render as boxes.
	expanded = on
	if chevron then
		chevron.Text = if on then "v" else ">"
	end
	local rows = rowsFrame
	if not rows then
		return
	end
	local goal = UDim2.new(1, 0, 0, if on then rowsHeight() else 0)
	if rowsTween then
		rowsTween:Cancel()
		rowsTween = nil
	end
	if instant then
		rows.Size = goal
		return
	end
	rowsTween = TweenService:Create(rows, if on then TWEEN_OPEN else TWEEN_CLOSE, { Size = goal })
	;(rowsTween :: Tween):Play()
end

-- Re-tween the stack height after the card count changed (only matters while expanded).
local function refreshRowsHeight()
	if expanded then
		setExpanded(true)
	end
end

----------------------------------------------------------------
-- Info → cards
----------------------------------------------------------------

local function findCard(stepIndex: number): Card?
	for _, card in cards do
		if card.stepIndex == stepIndex then
			return card
		end
	end
	return nil
end

-- Counter/bar refresh for every card that has a matching live mission.
local function refreshProgress(info: ChainInfo)
	for _, m in info.missions do
		local card = findCard(m.index)
		if card then
			card.counter.Text = counterText(m)
			local frac = if m.target > 0 then math.clamp(m.progress / m.target, 0, 1) else 0
			tw(card.barFill, TWEEN_BAR, { Size = UDim2.fromScale(frac, 1) })
		end
	end
end

local function refreshHeader()
	local info = latestInfo
	if headerLabel and info then
		headerLabel.Text = string.format("🎯 Getting Started  %d/%d", info.completed, info.total)
	end
end

-- Stack position (1 = top) of the first shown card whose mission is no longer live —
-- i.e. it completed — or nil when the cards match the info window.
local function completedCardPos(info: ChainInfo): number?
	for i, card in cards do
		local live = false
		for _, m in info.missions do
			if m.index == card.stepIndex then
				live = true
				break
			end
		end
		if not live then
			return i
		end
	end
	return nil
end

-- First live mission not shown as a card yet (the one that just entered the window).
local function incomingMission(info: ChainInfo): MissionInfo?
	for _, m in info.missions do
		if not findCard(m.index) then
			return m
		end
	end
	return nil
end

----------------------------------------------------------------
-- Completion choreography
----------------------------------------------------------------

-- Light the completed card up (purple/white), hold, slide it off-screen left, shift the
-- cards below it up a slot, and slide the next mission in at the bottom. Blocking
-- (task.wait); the pump drains one completion at a time.
local function animateComplete(pos: number)
	local doneCard = table.remove(cards, pos)
	if not doneCard then
		return
	end

	-- Light up: bg to solid purple, card outline to white, bar full. Text is authored white
	-- with a dark-purple stroke everywhere and stays that way — the flash never recolors it.
	doneCard.counter.Text = "DONE!"
	tw(doneCard.frame, TWEEN_FLASH, { BackgroundColor3 = PURPLE, BackgroundTransparency = 0.05 })
	tw(doneCard.stroke, TWEEN_FLASH, { Color = WHITE, Transparency = 0, Thickness = 2 })
	tw(doneCard.barFill, TWEEN_FLASH, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE })
	tw(doneCard.scale, TWEEN_FLASH, { Scale = 1.05 })
	task.delay(0.22, function()
		tw(doneCard.scale, TWEEN_BAR, { Scale = 1 })
	end)
	task.wait(HOLD_LIT)

	-- Slide out left from its own slot (clipped by the rows frame at the screen edge).
	tw(doneCard.frame, TWEEN_EXIT, { Position = UDim2.fromOffset(-(panelWidth + 80), slotY(pos)) })

	-- Shift the cards that were below it up into their new slots.
	for i, card in cards do
		tw(card.frame, TWEEN_SHIFT, { Position = UDim2.fromOffset(stackPad, slotY(i)) })
	end

	-- Bring the mission that just entered the window in at the bottom, sliding up.
	local info = latestInfo
	local m = if info then incomingMission(info) else nil
	if m then
		local slot = #cards + 1
		local card = buildCard(m, slot)
		card.frame.Position = UDim2.fromOffset(stackPad, slotY(slot) + cardH)
		tw(card.frame, TWEEN_SHIFT, { Position = UDim2.fromOffset(stackPad, slotY(slot)) })
		table.insert(cards, card)
	end

	task.wait(TWEEN_EXIT.Time)
	doneCard.frame:Destroy()
	refreshHeader()
	refreshRowsHeight()
end

-- Slide the whole panel out for good once the chain is done.
local function hidePanel()
	local r = root
	if not r then
		return
	end
	task.wait(0.4)
	tw(r, TWEEN_EXIT, { Position = restPos + UDim2.fromOffset(-(panelWidth + 100), 0) })
	task.delay(TWEEN_EXIT.Time, function()
		r.Visible = false
	end)
end

-- Drain queued completions one at a time, auto-expanding first so the payoff is
-- visible, then settle on the latest progress (or slide out if the chain is done).
local function pump()
	if pumping then
		return
	end
	pumping = true
	task.spawn(function()
		while true do
			local info = latestInfo
			if not (info and built) then
				break
			end
			local pos = completedCardPos(info)
			if not pos then
				break
			end
			if not expanded then
				setExpanded(true)
				task.wait(TWEEN_OPEN.Time)
			end
			animateComplete(pos)
		end
		pumping = false
		local info = latestInfo
		if info then
			if info.done and #cards == 0 then
				hidePanel()
			else
				refreshProgress(info)
			end
		end
	end)
end

----------------------------------------------------------------
-- Server info → UI
----------------------------------------------------------------

local function buildInitial(info: ChainInfo)
	built = true
	if info.done then
		return -- already finished in a prior session: never show the panel
	end
	for slot, m in info.missions do
		table.insert(cards, buildCard(m, slot))
	end
	refreshHeader()
	setExpanded(true, true)
	if root then
		root.Visible = true
	end
end

local function onInfo(info: any)
	if type(info) ~= "table" or type(info.missions) ~= "table" then
		return
	end
	local chain = info :: ChainInfo
	latestInfo = chain
	if not wired then
		return -- wire() replays latestInfo once the authored panel arrives
	end
	if not built then
		buildInitial(chain)
	else
		pump() -- animates completions if any, then settles on the latest progress
	end
end

----------------------------------------------------------------
-- Authored-panel discovery & wiring
----------------------------------------------------------------

-- Resolve the authored structure and bind behavior. Warns and leaves the panel inert if
-- the authored tree doesn't match (fix the Studio-side GUI, not this resolver).
local function wire(gui: ScreenGui): boolean
	local hud = gui:FindFirstChild("StarterQuestHUD")
	local host = hud and hud:FindFirstChild("HeaderHost")
	local button = host and host:FindFirstChild("Button")
	local header = button and button:FindFirstChild("Header")
	local chev = button and button:FindFirstChild("Chevron")
	local rows = hud and hud:FindFirstChild("Missions")
	local template = hud and hud:FindFirstChild("CardTemplate")
	if not (hud and hud:IsA("Frame") and host and header and header:IsA("TextLabel")
		and chev and chev:IsA("TextLabel") and rows and rows:IsA("Frame")
		and template and template:IsA("Frame")) then
		warn("StarterQuestUI: authored StarterQuestGui is missing expected children; panel disabled")
		return false
	end

	root = hud
	rowsFrame = rows
	cardTemplate = template
	headerLabel = header
	chevron = chev
	restPos = hud.Position
	panelWidth = hud.Size.X.Offset
	cardH = template.Size.Y.Offset
	stackPad = math.max(math.floor(-template.Size.X.Offset / 2), 0)

	-- Clean slate regardless of how the GUI was saved in Studio (e.g. copied from a
	-- play-session snapshot): no stale cards, hidden until the first ChainInfo.
	for _, c in rows:GetChildren() do
		if c.Name == "MissionCard" then
			c:Destroy()
		end
	end
	hud.Visible = false
	hud.Position = restPos

	UIButton.bind(host, {
		hoverScale = 1.06,
		pressOffset = 2,
		onClick = function()
			setExpanded(not expanded)
		end,
	})

	return true
end

function StarterQuestUI.Init()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	-- The authored ScreenGui is discovered by tag ONCE it lands in PlayerGui (the engine
	-- clones it from StarterGui on first spawn — usually after controllers Init).
	local function tryWire(inst: Instance)
		if wired or not (inst:IsA("ScreenGui") and inst:IsDescendantOf(playerGui)) then
			return
		end
		wired = wire(inst)
		if wired and latestInfo then
			onInfo(latestInfo)
		end
	end
	for _, inst in CollectionService:GetTagged(TagsConfig.StarterQuestGui) do
		tryWire(inst)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.StarterQuestGui):Connect(tryWire)

	local changedRE = StarterQuestNet.StarterQuestChanged :: RemoteEvent
	changedRE.OnClientEvent:Connect(onInfo)

	local getInfoRF = StarterQuestNet.GetStarterQuestInfo :: RemoteFunction
	task.spawn(function()
		local ok, info = pcall(function()
			return getInfoRF:InvokeServer()
		end)
		if ok then
			onInfo(info)
		end
	end)
end

return StarterQuestUI
