--!strict
-- "Currency fly" celebration: a burst of 💰/💎 emoji labels pops in around the middle of the
-- screen at random offsets, then each one accelerates into the matching HUD balance icon
-- (MainGui.LeftBar.Cash.ImageLabel / MainGui.LeftBar.Diamonds.ImageLabel), which pulses as
-- they land. Purely visual — callers fire it when a grant is confirmed (quest / daily reward /
-- playtime claims) or optimistically alongside one (CoinPickups' optimistic hide); the actual
-- balance number is driven separately by BalanceUIController.
--
--   CurrencyFlyUI.Play("Cash" | "Diamonds", count?)  -- count defaults to a random 7-11
--
-- Safe to call before Init or if the LeftBar icons aren't present (warns once, no-op) — a
-- missed celebration must never break a claim flow.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RS = game:GetService("ReplicatedStorage")

local AutoScale = require(RS.Shared.AutoScale)
local Config = require(RS.Shared.Config)
local SoundService = require(RS.Shared.SoundService)

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

-- One emoji: pop in at (spawnX, spawnY) — absolute screen coords, which ARE this container's
-- offset coords (the container sits at absolute (0, 0)) — hold, then fly into the icon.
local function flyOne(parent: Frame, icon: GuiObject, emoji: string, spawnX: number, spawnY: number, holdDelay: number)
	-- The container works in raw AbsolutePosition coords (no UIScale — the flight targets
	-- are absolute screen positions), so the emoji SIZE scales by the viewport factor.
	local vs = AutoScale.GetScale()
	local label = Instance.new("TextLabel")
	label.Name = "FlyEmoji"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromOffset(spawnX, spawnY)
	label.Size = UDim2.fromOffset(0, 0) -- grows to full via the pop tween
	label.Rotation = (math.random() - 0.5) * 50
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = emoji
	label.Parent = parent

	TweenService:Create(label, POP_TWEEN, { Size = UDim2.fromOffset(math.floor(EMOJI_SIZE * vs + 0.5), math.floor(EMOJI_SIZE * vs + 0.5)) }):Play()

	task.delay(holdDelay, function()
		if not label:IsDescendantOf(game) then
			return
		end
		-- Target position read at takeoff (not spawn), so a reflowing LeftBar still gets hit.
		local center = icon.AbsolutePosition + icon.AbsoluteSize * 0.5
		local endSize = math.floor(EMOJI_SIZE * vs * FLY_END_SCALE + 0.5)
		local fly = TweenService:Create(
			label,
			TweenInfo.new(FLY_TIME + math.random() * FLY_JITTER, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{
				Position = UDim2.fromOffset(center.X, center.Y),
				Size = UDim2.fromOffset(endSize, endSize),
				Rotation = 0,
			}
		)
		fly.Completed:Once(function()
			label:Destroy()
			-- One collect ding PER landing emoji. SoundService pools instances per sound id
			-- (the ball-SFX system), so each play gets its own Sound and overlapping dings
			-- stack instead of restarting each other; the pitch jitter keeps the stacked
			-- copies from landing sample-aligned (which would read as one louder ding).
			SoundService.Play({ soundId = Config.Sounds.Collect3, volume = 0.4, jitter = 0.06 })
			pulseTarget(icon)
		end)
		fly:Play()
	end)
end

-- Fire the celebration toward `kind`'s balance icon. count defaults to a random 7-11.
function CurrencyFlyUI.Play(kind: Kind, count: number?)
	local parent = container
	if not parent then
		return -- Init hasn't run; a claim should still just work without the flourish
	end
	local icon = resolveTarget(kind)
	if not icon then
		return
	end
	local emoji = EMOJI[kind]
	local n = math.clamp(count or math.random(7, 11), 1, MAX_COUNT)

	local centerX = parent.AbsoluteSize.X * 0.5
	local centerY = parent.AbsoluteSize.Y * 0.5
	local vs = AutoScale.GetScale() -- spread scales with the viewport like the emoji size
	for _ = 1, n do
		local spawnX = centerX + (math.random() - 0.5) * 2 * SPREAD_X * vs
		local spawnY = centerY + (math.random() - 0.5) * 2 * SPREAD_Y * vs
		local holdDelay = POP_TIME + HOLD_MIN + math.random() * HOLD_JITTER
		flyOne(parent, icon, emoji, spawnX, spawnY, holdDelay)
	end
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
end

return CurrencyFlyUI
