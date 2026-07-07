--!strict
-- Attaches the standard "juicy button" behaviour to an authored button host: hover
-- brightness lift, press squash toward the shadow, optional gradient state changes,
-- optional click sound, and either a momentary onClick or a two-state toggle. It can
-- also be DISABLED: button + shadow both grey out (no press-down), ignoring all interaction.
--
-- It DECORATES existing Studio-authored UI (the usual shape is
-- Host > { Shadow, Button > { Hover, Icon, ... } }); it does not build any UI. Point
-- it at the host (or a GuiButton directly) and hand it a config:
--
--   UIButton.bind(host, { onClick = function() ... end })           -- momentary
--
--   UIButton.bind(host, {                                           -- toggle
--       toggle = { initial = false, onChange = function(active) ... end },
--       idleGradient = BLUE, activeGradient = GOLD,
--       onRender = function(button, active) ... end,                -- extra visuals
--   })
--
-- Missing optional children (Hover overlay, UIGradient) are skipped, so it's safe on
-- hosts that don't have them. Returns a handle: SetActive / IsActive (toggle),
-- SetDisabled / IsDisabled, and Destroy (disconnects everything).

local TweenService = game:GetService("TweenService")
local RS = game:GetService("ReplicatedStorage")

local SoundService = require(RS.Shared.SoundService)

local UIButton = {}

-- A 3-stop vertical gradient (top → mid → bot), applied to the button's UIGradient.
export type Gradient = { top: Color3, mid: Color3, bot: Color3 }

export type Config = {
	pressOffset: number?,          -- px the button drops on press (default 4)
	hoverTransparency: number?,    -- Hover overlay transparency on hover (default 0.86)
	hoverScale: number?,           -- host enlarges to this on hover (e.g. 1.07); off when nil
	feelTween: TweenInfo?,         -- tween for hover/press (default a quick quad-out)
	clickSound: string?,           -- click sound id; nil = the default click (SoundService.PlayClick), "" = silent
	onClick: (() -> ())?,          -- momentary action (ignored when `toggle` is set)
	toggle: {
		initial: boolean?,
		onChange: (active: boolean) -> (),
	}?,
	idleGradient: Gradient?,       -- gradient while inactive (toggle only)
	activeGradient: Gradient?,     -- gradient while active (toggle only)
	disabledColor: Color3?,        -- BackgroundColor3 while disabled (default grey)
	disabled: boolean?,            -- start disabled
	glowColor: Color3?,            -- default colour for the pulsing glow (SetGlowing)
	onRender: ((button: GuiButton, active: boolean) -> ())?, -- extra per-state visuals
}

export type Handle = {
	SetActive: (active: boolean, fireChange: boolean?) -> (),
	IsActive: () -> boolean,
	SetDisabled: (disabled: boolean) -> (),
	IsDisabled: () -> boolean,
	-- Toggle a pulsing glow (a pulsing UIStroke). `color` overrides the configured one;
	-- pass `color2` to also breathe the stroke colour between `color` and `color2`.
	SetGlowing: (on: boolean, color: Color3?, color2: Color3?) -> (),
	-- Set the button's BackgroundColor3 (and darken the host's Shadow to match).
	SetColor: (color: Color3) -> (),
	Destroy: () -> (),
}

local DEFAULT_FEEL = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DEFAULT_PRESS_OFFSET = 4
local DEFAULT_HOVER_TRANSPARENCY = 0.86
local DEFAULT_DISABLED_COLOR = Color3.fromRGB(130, 130, 130)
local DEFAULT_GLOW_COLOR = Color3.fromRGB(255, 255, 255)
local GLOW_THICKNESS = 4
local GLOW_TWEEN = TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local SHADOW_DARKEN = 0.75 -- Shadow colour = button colour × this

local function setGradient(button: GuiObject, g: Gradient)
	local grad = button:FindFirstChildOfClass("UIGradient")
	if grad then
		grad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0.00, g.top),
			ColorSequenceKeypoint.new(0.52, g.mid),
			ColorSequenceKeypoint.new(1.00, g.bot),
		})
	end
end

-- The clickable button: the host itself if it's a GuiButton, else its "Button" child
-- (or the first GuiButton under it).
local function resolveButton(host: Instance): GuiButton
	if host:IsA("GuiButton") then
		return host
	end
	local found = host:FindFirstChild("Button") or host:FindFirstChildWhichIsA("GuiButton")
	if found and found:IsA("GuiButton") then
		return found
	end
	error("UIButton.bind: no GuiButton found under " .. host:GetFullName())
end

function UIButton.bind(host: Instance, config: Config): Handle
	local button = resolveButton(host)
	local feel = config.feelTween or DEFAULT_FEEL
	local pressOffset = config.pressOffset or DEFAULT_PRESS_OFFSET
	local hoverTransparency = config.hoverTransparency or DEFAULT_HOVER_TRANSPARENCY
	local disabledColor = config.disabledColor or DEFAULT_DISABLED_COLOR

	local conns: { RBXScriptConnection } = {}
	local function track(c: RBXScriptConnection)
		table.insert(conns, c)
	end

	local hoverChild = button:FindFirstChild("Hover")
	local hover = if hoverChild and hoverChild:IsA("GuiObject") then hoverChild else nil
	local uiListIgnore = button:FindFirstChild("UIListIgnore")
	-- Shadow is a sibling of Button under the host; SetColor keeps it a darker match.
	local shadowChild = host:FindFirstChild("Shadow") or (if uiListIgnore then uiListIgnore:FindFirstChild("Shadow") else nil)
	local shadow = if shadowChild and shadowChild:IsA("GuiObject") then shadowChild else nil
	local restPos = button.Position
	local pressPos = restPos + UDim2.fromOffset(0, pressOffset)

	-- Remember the authored BackgroundColor3 so disable can grey the button and enable
	-- can restore it (the gradient multiplies this colour, so greying the colour — not
	-- the gradient — is what actually reads as disabled).
	local defaultBg = button.BackgroundColor3
	local hasGradient = config.activeGradient ~= nil or config.idleGradient ~= nil

	local active = if config.toggle then (config.toggle.initial or false) else false
	local disabled = false

	-- One tween at a time drives Position, so a disable can cancel an in-flight feel
	-- tween and snap cleanly rather than getting overridden by it.
	local posTween: Tween? = nil
	local function tweenPos(goal: UDim2)
		if posTween then
			posTween:Cancel()
		end
		posTween = TweenService:Create(button, feel, { Position = goal })
		posTween:Play()
	end

	-- Enabled visual for the current `active` state.
	local function renderEnabled()
		if config.toggle then
			local g = if active then config.activeGradient else config.idleGradient
			if g then
				setGradient(button, g)
			end
		end
		-- A UIGradient multiplies BackgroundColor3, so show it over white when this is a
		-- gradient toggle that's active; otherwise use the authored colour. Either way
		-- this restores the colour after a disable greyed it.
		button.BackgroundColor3 = if hasGradient and active then Color3.new(1, 1, 1) else defaultBg
		if config.onRender then
			config.onRender(button, active)
		end
	end

	local function shadowShade(color: Color3): Color3
		return Color3.new(color.R * SHADOW_DARKEN, color.G * SHADOW_DARKEN, color.B * SHADOW_DARKEN)
	end

	-- Disabled visual: grey the button AND the shadow; stays at rest position (no
	-- press-down — disabled should read as "off", not "held").
	local function renderDisabled()
		if posTween then
			posTween:Cancel()
			posTween = nil
		end
		if hostScale then
			hostScale.Scale = 1
		end
		if hover then
			hover.BackgroundTransparency = 1
		end
		button.BackgroundColor3 = disabledColor
		button.Position = restPos
		if shadow then
			shadow.BackgroundColor3 = shadowShade(disabledColor)
		end
	end

	-- Optional hover enlarge: a UIScale on the HOST (so the shadow grows too), created
	-- lazily. Scale pops over grid/list neighbours, which is the point.
	local hostScale: UIScale? = nil
	local function tweenHoverScale(goal: number)
		if not config.hoverScale then
			return
		end
		if not hostScale then
			local s = Instance.new("UIScale")
			s.Name = "HoverScale"
			s.Parent = if host:IsA("GuiObject") then host else button
			hostScale = s
		end
		TweenService:Create(hostScale :: UIScale, feel, { Scale = goal }):Play()
	end

	track(button.MouseEnter:Connect(function()
		if disabled then
			return
		end
		tweenHoverScale(config.hoverScale or 1)
		if hover then
			TweenService:Create(hover, feel, { BackgroundTransparency = hoverTransparency }):Play()
		end
	end))
	track(button.MouseLeave:Connect(function()
		if disabled then
			return
		end
		tweenHoverScale(1)
		if hover then
			TweenService:Create(hover, feel, { BackgroundTransparency = 1 }):Play()
		end
		tweenPos(restPos)
	end))
	track(button.MouseButton1Down:Connect(function()
		if disabled then
			return
		end
		tweenPos(pressPos)
	end))
	track(button.MouseButton1Up:Connect(function()
		if disabled then
			return
		end
		tweenPos(restPos)
	end))

	local function playClickSound()
		-- nil = the game's default click (SoundService.PlayClick); "" = explicitly
		-- silent; anything else = this button's own sound id.
		if config.clickSound == nil then
			SoundService.PlayClick()
		elseif config.clickSound ~= "" then
			SoundService.Play({ soundId = config.clickSound })
		end
	end

	track(button.Activated:Connect(function()
		if disabled then
			return
		end
		if config.toggle then
			active = not active
			renderEnabled()
			playClickSound()
			config.toggle.onChange(active)
		else
			playClickSound()
			if config.onClick then
				config.onClick()
			end
		end
	end))

	local function setActive(value: boolean, fireChange: boolean?)
		if not config.toggle or value == active then
			return
		end
		active = value
		if not disabled then
			renderEnabled()
		end
		if fireChange then
			config.toggle.onChange(active)
		end
	end

	local function setDisabled(value: boolean)
		if value == disabled then
			return
		end
		disabled = value
		button.Active = not value -- engine-level: no Activated / AutoButtonColor while off
		if value then
			renderDisabled()
		else
			button.Position = restPos
			renderEnabled()
			if shadow then
				shadow.BackgroundColor3 = shadowShade(defaultBg)
			end
		end
	end

	-- Set the button's background colour (the gradient multiplies this) and darken the
	-- Shadow to a matching shade. Updates the remembered colour so disable/enable and
	-- the toggle idle state restore the new colour.
	local function setColor(color: Color3)
		defaultBg = color
		if not disabled then
			button.BackgroundColor3 = color
		end
		if shadow then
			shadow.BackgroundColor3 = shadowShade(color)
		end
	end

	-- Pulsing glow: a UIStroke whose transparency breathes 0 ↔ ~1. Created lazily on
	-- first use so buttons that never glow pay nothing.
	local glowStroke: UIStroke? = nil
	local glowTween: Tween? = nil
	local glowColorTween: Tween? = nil
	local function setGlowing(on: boolean, color: Color3?, color2: Color3?)
		if not on then
			if glowTween then
				glowTween:Cancel()
				glowTween = nil
			end
			if glowColorTween then
				glowColorTween:Cancel()
				glowColorTween = nil
			end
			if glowStroke then
				glowStroke.Enabled = false
			end
			return
		end
		if not glowStroke then
			local s = Instance.new("UIStroke")
			s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			s.LineJoinMode = Enum.LineJoinMode.Round
			s.Parent = button
			glowStroke = s
		end
		local stroke = glowStroke :: UIStroke
		stroke.Enabled = true
		stroke.Color = color or config.glowColor or DEFAULT_GLOW_COLOR
		stroke.Thickness = GLOW_THICKNESS
		stroke.Transparency = 0
		if glowTween then
			glowTween:Cancel()
		end
		glowTween = TweenService:Create(stroke, GLOW_TWEEN, { Transparency = 0.85 })
		glowTween:Play()
		-- Optional two-colour pulse: breathe Color between `color` and `color2`.
		if glowColorTween then
			glowColorTween:Cancel()
			glowColorTween = nil
		end
		if color2 then
			glowColorTween = TweenService:Create(stroke, GLOW_TWEEN, { Color = color2 })
			glowColorTween:Play()
		end
	end

	-- Initial paint.
	renderEnabled()
	if config.disabled then
		setDisabled(true)
	end

	return {
		SetActive = setActive,
		IsActive = function(): boolean
			return active
		end,
		SetDisabled = setDisabled,
		IsDisabled = function(): boolean
			return disabled
		end,
		SetGlowing = setGlowing,
		SetColor = setColor,
		Destroy = function()
			if glowTween then
				glowTween:Cancel()
			end
			if glowColorTween then
				glowColorTween:Cancel()
			end
			for _, c in conns do
				c:Disconnect()
			end
			table.clear(conns)
		end,
	}
end

return UIButton
