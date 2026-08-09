--!strict
-- "Currency fly" celebration: a burst of 💰/💎 emoji labels pops in around the middle of the
-- screen at random offsets, then each one accelerates into the matching HUD balance icon
-- (MainGui.LeftBar.Cash.ImageLabel / MainGui.LeftBar.Diamonds.ImageLabel), which pulses as
-- they land.
--
--   CurrencyFlyUI.Play("Cash" | "Diamonds", count?, amount?)  -- count defaults to a random 7-11
--
-- With an `amount`, the flight DRIVES the balance readout: the grant is split across the
-- icons (integer chunks, remainder on the last) and each landing bumps
-- BalanceUIController's cosmetic live sum, which the labels show while any fly holds the
-- currency (multiple concurrent flights stack holds; the last release snaps back to the
-- authentic balance). For that seeding to be right the hold must begin BEFORE the grant's
-- BalanceChanged repaints the label — server granters fire the FxNet fly ahead of the
-- grant, and client claim flows wrap their invoke in HoldBalance below.
--
-- Safe to call before Init or if the LeftBar icons aren't present (warns once, no-op) — a
-- missed celebration must never break a claim flow.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RS = game:GetService("ReplicatedStorage")

local AutoScale = require(RS.Shared.Utility.AutoScale)
local SoundsConfig = require(RS.Shared.Config.Sounds)
local SoundService = require(RS.Shared.SoundService)
local BalanceUIController = require(script.Parent.BalanceUIController)
local FxNet = require(RS.Shared.Remote.FxNet)

local CurrencyFlyUI = {}

export type Kind = "Cash" | "Diamonds" | "Crate"

local EMOJI: { [string]: string } = {
	Cash = "💰",
	Diamonds = "💎",
	Crate = "📦",
}

-- Visual tuning (this is HUD juice, not gameplay — so it lives here, like CoinPickups' bob/spin).
local EMOJI_SIZE  = 44   -- px square per label
local SPREAD_X    = 140  -- max random offset from screen center, px
local SPREAD_Y    = 95
local POP_TIME    = 0.16 -- grow-in at the spawn point
local HOLD_MIN    = 0.12 -- pause between popping in and flying off (randomized per label...)
local HOLD_JITTER = 0.22 -- ...up to HOLD_MIN + HOLD_JITTER, so the flock streams, not marches
local FLY_TIME    = 0.45
local FLY_JITTER  = 0.12
local FLY_END_SCALE = 0.35 -- labels shrink to this fraction as they reach the icon
local PULSE_SCALE = 1.25   -- balance-icon pop on arrival
local MAX_COUNT   = 20

local POP_TWEEN = TweenInfo.new(POP_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
-- Upper bound on one visual's whole life (pop + hold + fly + jitters); the live-sum
-- safety net trues-up and releases this long after launch if landings went missing
-- (destroyed GUI, skipped tweens) so a hold can never leak.
local FLIGHT_MAX = POP_TIME + HOLD_MIN + HOLD_JITTER + FLY_TIME + FLY_JITTER + 0.5

local player = Players.LocalPlayer

local screenGui: ScreenGui? = nil
local container: Frame? = nil

-- Lazily-resolved HUD icons (LeftBar is Studio-authored and static, but resolving at Play
-- time instead of a blocking WaitForChild in Init keeps a missing/renamed icon from hanging
-- the Bootstrap init chain — it just warns once and skips the effect).
local targetIcon: { [string]: GuiObject } = {}
local warnedMissing: { [string]: boolean } = {}

local function resolveTarget(kind: Kind): GuiObject?
	local cached = targetIcon[kind]
	if cached and cached:IsDescendantOf(game) then
		return cached
	end
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local mainGui = playerGui and playerGui:FindFirstChild("MainGui")
	local leftBar = mainGui and mainGui:FindFirstChild("LeftBar")
	-- Crates have no balance readout; bought boxes fly to the LOADOUT trigger instead
	-- (that's where marbles end up mattering), so the flock still lands somewhere real.
	local icon: Instance? = nil
	if kind == "Crate" then
		local quad = if leftBar then leftBar:FindFirstChild("TriggerQuad") else nil
		icon = if quad then quad:FindFirstChild("LoadoutTriggerHost", true) else nil
	else
		local holder = if leftBar then leftBar:FindFirstChild(kind) else nil
		icon = if holder then holder:FindFirstChild("ImageLabel") else nil
	end
	if icon and icon:IsA("GuiObject") then
		targetIcon[kind] = icon
		return icon
	end
	if not warnedMissing[kind] then
		warnedMissing[kind] = true
		warn(("CurrencyFlyUI: no HUD target found for %s — skipping fly effect"):format(kind))
	end
	return nil
end

-- Pop the balance icon as emojis land — via a UIScale child (never touching the authored
-- Size), one pulse at a time per icon so a stream of arrivals doesn't stack tweens.
local pulsing: { [GuiObject]: boolean } = {}

local function pulseTarget(icon: GuiObject)
	if pulsing[icon] then
		return
	end
	pulsing[icon] = true
	local scale = icon:FindFirstChild("CurrencyFlyPulse")
	if not (scale and scale:IsA("UIScale")) then
		local s = Instance.new("UIScale")
		s.Name = "CurrencyFlyPulse"
		s.Parent = icon
		scale = s
	end
	local uiScale = scale :: UIScale
	local up = TweenService:Create(uiScale, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = PULSE_SCALE })
	up.Completed:Once(function()
		local down = TweenService:Create(uiScale, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 1 })
		down.Completed:Once(function()
			pulsing[icon] = nil
		end)
		down:Play()
	end)
	up:Play()
end

-- One flying visual (an emoji label or a marble swatch): pop in at (spawnX, spawnY) —
-- absolute screen coords, which ARE this container's offset coords (the container sits
-- at absolute (0, 0)) — hold, then fly into the icon.
local function flyOne(parent: Frame, icon: GuiObject, visual: GuiObject, spawnX: number, spawnY: number, holdDelay: number, onLand: (() -> ())?)
	-- The container works in raw AbsolutePosition coords (no UIScale — the flight targets
	-- are absolute screen positions), so the visual's SIZE scales by the viewport factor.
	local vs = AutoScale.GetScale()
	visual.AnchorPoint = Vector2.new(0.5, 0.5)
	visual.Position = UDim2.fromOffset(spawnX, spawnY)
	visual.Size = UDim2.fromOffset(0, 0) -- grows to full via the pop tween
	visual.Rotation = (math.random() - 0.5) * 50
	visual.Parent = parent

	TweenService:Create(visual, POP_TWEEN, { Size = UDim2.fromOffset(math.floor(EMOJI_SIZE * vs + 0.5), math.floor(EMOJI_SIZE * vs + 0.5)) }):Play()

	task.delay(holdDelay, function()
		if not visual:IsDescendantOf(game) then
			return
		end
		-- Target position read at takeoff (not spawn), so a reflowing LeftBar still gets hit.
		local center = icon.AbsolutePosition + icon.AbsoluteSize * 0.5
		local endSize = math.floor(EMOJI_SIZE * vs * FLY_END_SCALE + 0.5)
		local fly = TweenService:Create(
			visual,
			TweenInfo.new(FLY_TIME + math.random() * FLY_JITTER, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{
				Position = UDim2.fromOffset(center.X, center.Y),
				Size = UDim2.fromOffset(endSize, endSize),
				Rotation = 0,
			}
		)
		fly.Completed:Once(function()
			visual:Destroy()
			-- One collect ding PER landing visual. SoundService pools instances per sound id
			-- (the ball-SFX system), so each play gets its own Sound and overlapping dings
			-- stack instead of restarting each other; the pitch jitter keeps the stacked
			-- copies from landing sample-aligned (which would read as one louder ding).
			SoundService.Play({ soundId = SoundsConfig.Collect3, volume = 0.4, jitter = 0.06 })
			pulseTarget(icon)
			if onLand then
				onLand()
			end
		end)
		fly:Play()
	end)
end

local function newEmojiVisual(emoji: string): GuiObject
	local label = Instance.new("TextLabel")
	label.Name = "FlyEmoji"
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = emoji
	return label
end

-- A marble swatch in the shared UI style (colour-filled circle with a rarity ring),
-- matching the cosmetics shop / overhead billboard swatches.
local function newSwatchVisual(color: Color3, ringColor: Color3): GuiObject
	local swatch = Instance.new("Frame")
	swatch.Name = "FlySwatch"
	swatch.BackgroundColor3 = color
	swatch.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = swatch
	local ring = Instance.new("UIStroke")
	ring.Color = ringColor
	ring.Thickness = 2
	ring.Parent = swatch
	return swatch
end

-- The concrete flock size for a requested count (default random 7-11, clamped).
local function resolveCount(count: number?): number
	return math.clamp(count or math.random(7, 11), 1, MAX_COUNT)
end

-- Shared spawn loop: makes exactly n visuals popping around screen centre, flying into
-- `icon`; onLand (optional) fires once per visual that reaches it.
local function playVisuals(icon: GuiObject, n: number, makeVisual: () -> GuiObject, onLand: (() -> ())?)
	local parent = container
	if not parent then
		return -- Init hasn't run; a claim should still just work without the flourish
	end
	local centerX = parent.AbsoluteSize.X * 0.5
	local centerY = parent.AbsoluteSize.Y * 0.5
	local vs = AutoScale.GetScale() -- spread scales with the viewport like the visual size
	for _ = 1, n do
		local spawnX = centerX + (math.random() - 0.5) * 2 * SPREAD_X * vs
		local spawnY = centerY + (math.random() - 0.5) * 2 * SPREAD_Y * vs
		local holdDelay = POP_TIME + HOLD_MIN + math.random() * HOLD_JITTER
		flyOne(parent, icon, makeVisual(), spawnX, spawnY, holdDelay, onLand)
	end
end

-- Fire the celebration toward `kind`'s balance icon. count defaults to a random 7-11.
-- With `amount` (Cash/Diamonds only), the flight also drives the balance readout: a
-- live-sum hold begins NOW, the amount splits across the icons (floor-integer chunks,
-- remainder on the last), each landing bumps the live sum, and the hold releases once
-- every chunk is delivered (a timeout trues-up whatever went missing first).
function CurrencyFlyUI.Play(kind: Kind, count: number?, amount: number?)
	local icon = resolveTarget(kind)
	if not icon then
		return
	end
	local emoji = EMOJI[kind]
	local heldKind: BalanceUIController.FlyKind? = if kind == "Cash" or kind == "Diamonds"
		then kind :: BalanceUIController.FlyKind
		else nil
	if not (heldKind and amount and amount > 0) then
		playVisuals(icon, resolveCount(count), function()
			return newEmojiVisual(emoji)
		end)
		return
	end
	local balKind = heldKind :: BalanceUIController.FlyKind
	local total = amount :: number

	BalanceUIController.BeginFlyHold(balKind)
	local n = resolveCount(count)
	local base = math.floor(total / n)
	local delivered = 0 -- how much of `total` has been added to the live sum so far
	local landed = 0
	local finished = false
	local function finish()
		if finished then
			return
		end
		finished = true
		if delivered < total then
			BalanceUIController.AddFlyAmount(balKind, total - delivered)
			delivered = total
		end
		BalanceUIController.ReleaseFlyHold(balKind)
	end
	playVisuals(icon, n, function()
		return newEmojiVisual(emoji)
	end, function()
		if finished then
			return
		end
		landed += 1
		local chunk = if landed >= n then total - delivered else base
		delivered += chunk
		BalanceUIController.AddFlyAmount(balKind, chunk)
		if landed >= n then
			finish()
		end
	end)
	task.delay(FLIGHT_MAX, finish)
end

-- Pre-claim flicker guard for client-invoked grants: take a live-sum hold BEFORE the
-- claim invoke (whose grant lands via BalanceChanged before the invoke even returns), so
-- the label can't repaint — and the live sum can't mis-seed from the post-grant value —
-- ahead of the Play call. Returns a one-shot release: call it right after Play on
-- success (Play's own hold carries on from there) or immediately on failure.
function CurrencyFlyUI.HoldBalance(kind: Kind): () -> ()
	if kind ~= "Cash" and kind ~= "Diamonds" then
		return function() end
	end
	local balKind = kind :: BalanceUIController.FlyKind
	BalanceUIController.BeginFlyHold(balKind)
	local released = false
	return function()
		if not released then
			released = true
			BalanceUIController.ReleaseFlyHold(balKind)
		end
	end
end

-- A rolled marble flying home: circular colour swatches (the skin's colour, ringed in
-- its rarity colour) stream into the LOADOUT trigger — where a new marble matters.
function CurrencyFlyUI.PlayMarble(color: Color3, ringColor: Color3, count: number?)
	local icon = resolveTarget("Crate") -- the LOADOUT trigger (same home as bought boxes)
	if not icon then
		return
	end
	playVisuals(icon, resolveCount(count), function()
		return newSwatchVisual(color, ringColor)
	end)
end

function CurrencyFlyUI.Init()
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	local gui = Instance.new("ScreenGui")
	gui.Name = "CurrencyFlyUI"
	gui.ResetOnSpawn = false
	-- IgnoreGuiInset stays FALSE: then a child's offset coords equal AbsolutePosition coords,
	-- so the LeftBar icons' AbsolutePosition can be used as tween targets directly.
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 60 -- above the daily-reward modal (45), so flights draw over its dim
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Container"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.Parent = gui

	screenGui = gui
	container = frame

	-- Server-granted rewards (obby prize, plot claims, Robux packs) fire PlayCurrencyFly
	-- with (kind, count?, amount?); anything unknown is ignored. Servers fire it BEFORE
	-- the grant itself so the live-sum hold starts from the pre-grant balance (remote
	-- delivery is ordered). Soft-waited: the remote only exists once a server granter
	-- that wants the flourish has created it.
	task.spawn(function()
		local re = FxNet.PlayCurrencyFly
		if re and re:IsA("RemoteEvent") then
			re.OnClientEvent:Connect(function(kind: any, count: any, amount: any)
				if type(kind) == "string" and EMOJI[kind] then
					CurrencyFlyUI.Play(
						kind :: Kind,
						if type(count) == "number" then count else nil,
						if type(amount) == "number" then amount else nil
					)
				end
			end)
		end
	end)
end

return CurrencyFlyUI
