--[[
  PrestigeUI.lua  —  Marble RNG "Prestige" screen generator (LocalScript)
  =================================================================
  Builds, in code, BOTH parts of the prestige feature:
    • the top-left TRIGGER badge  (violet star + current multiplier)
    • the full PRESTIGE MODAL     (hero multiplier, PP progress bar,
      stat chips, the big PRESTIGE button, close X)

  Everything style-wise is Lua — Fredoka font, navy/magenta/violet
  palette, candy 3D buttons (hard drop-shadow base + press tween),
  UIStroke vector borders, cartoon text outlines, gradient fills,
  device-agnostic UIScale. The ONLY images are the two things Roblox
  can't draw cleanly:
        prestige-star.png   the gold star (trigger + modal header)
        button-close.png    the pink candy close-X (already generated)

  THE MATH (single source of truth — matches the web prototype)
        PP        = floor( (lifetimeBanked / scale) ^ exp )
        cost(N)   = ceil( costBase * costGrowth ^ (N-1) )
        mult(N)   = multPer ^ N
  Points persist through a prestige; cost rises each time; the multiplier
  scales all banked. The run (balance + upgrades) is what gets wiped —
  do that on the SERVER and push the new state back via applyState().

  SETUP
    1. Upload prestige-star.png + button-close.png; paste ids in ASSETS.
    2. Drop this LocalScript in StarterGui, press Play.
    3. Wire the 4 integration seams at the bottom to your remotes.
]]

local Players          = game:GetService("Players")
local TweenService     = game:GetService("TweenService")
local player           = Players.LocalPlayer
local gui              = player:WaitForChild("PlayerGui")
local camera           = workspace.CurrentCamera

----------------------------------------------------------------
-- ASSET IDS (replace the zeros)
----------------------------------------------------------------
local ASSETS = {
	star  = "rbxassetid://0000000000", -- prestige-star.png
	close = "rbxassetid://0000000000", -- button-close.png
}

----------------------------------------------------------------
-- PALETTE
----------------------------------------------------------------
local INK        = Color3.fromRGB(22, 34, 63)
local MAGENTA    = Color3.fromRGB(236, 63, 212)
local SUB        = Color3.fromRGB(199, 154, 208)
local WHITE      = Color3.new(1, 1, 1)
local VIOLET     = Color3.fromRGB(124, 58, 237)   -- #7c3aed
local VIOLET_LT  = Color3.fromRGB(179, 136, 255)  -- #b388ff
local VIOLET_MD  = Color3.fromRGB(139, 92, 246)   -- #8b5cf6
local VIOLET_DK  = Color3.fromRGB(91, 33, 182)    -- #5b21b6  (3D base)
local TRACK_BG   = Color3.fromRGB(239, 230, 247)  -- #efe6f7
local TRACK_BD   = Color3.fromRGB(221, 201, 239)  -- #ddc9ef
local CHIP_BG    = Color3.fromRGB(250, 246, 252)  -- #faf6fc
local CHIP_BD    = Color3.fromRGB(240, 226, 244)  -- #f0e2f4
local LOCK_FACE  = Color3.fromRGB(199, 191, 216)
local LOCK_BASE  = Color3.fromRGB(156, 143, 179)  -- #9c8fb3
local FONT       = Enum.Font.FredokaOne

----------------------------------------------------------------
-- PRESTIGE MATH
----------------------------------------------------------------
local CFG = { scale = 10000, exp = 0.45, costBase = 10, costGrowth = 1.40, multPer = 1.25 }
local function ppFromLifetime(lb) return math.floor((math.max(0, lb) / CFG.scale) ^ CFG.exp) end
local function prestigeCost(n)    return math.ceil(CFG.costBase * CFG.costGrowth ^ (n - 1)) end
local function prestigeMult(n)    return CFG.multPer ^ n end

local function commas(n)
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end
local function fmtShort(n)
	n = math.max(0, n)
	if n >= 1e12 then return ("$%.2fT"):format(n / 1e12) end
	if n >= 1e9  then return ("$%.2fB"):format(n / 1e9)  end
	if n >= 1e6  then return ("$%.2fM"):format(n / 1e6)  end
	if n >= 1e3  then return ("$%.1fK"):format(n / 1e3)  end
	return "$" .. commas(n)
end

-- live state (seeded by fetchPrestigeState in init)
local state = { prestigeCount = 2, lifetimeBanked = 8000000 }

----------------------------------------------------------------
-- helpers
----------------------------------------------------------------
local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props or {}) do o[k] = v end
	if parent then o.Parent = parent end
	return o
end
local function corner(r, p) new("UICorner", { CornerRadius = UDim.new(0, r) }, p) end
local function stroke(p, color, thickness)
	return new("UIStroke", { Color = color, Thickness = thickness or 2,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border, LineJoinMode = Enum.LineJoinMode.Round }, p)
end
-- cartoon text: white fill + navy outline (UIStroke on the LABEL is correct here)
local function outlineLabel(props, parent, strokeW)
	local lbl = new("TextLabel", props, parent)
	lbl.BackgroundTransparency = 1
	lbl.TextColor3 = WHITE
	new("UIStroke", { Color = INK, Thickness = strokeW or 4,
		LineJoinMode = Enum.LineJoinMode.Round }, lbl)
	return lbl
end

----------------------------------------------------------------
-- root + device-agnostic scale
----------------------------------------------------------------
local screenGui = new("ScreenGui", { Name = "PrestigeUI", IgnoreGuiInset = true,
	ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 20 }, gui)

-- A 1920×1080 design layer; one UIScale fits it to any viewport (letterbox-free,
-- matches the web stage transform: scale(min(vw/1920, vh/1080))).
local layer = new("Frame", { Name = "Layer", BackgroundTransparency = 1,
	Size = UDim2.fromOffset(1920, 1080), AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5) }, screenGui)
local uiScale = new("UIScale", { Scale = 1 }, layer)
local function refreshScale()
	local vp = camera.ViewportSize
	if vp.X > 0 and vp.Y > 0 then uiScale.Scale = math.min(vp.X / 1920, vp.Y / 1080) end
end
camera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshScale)
refreshScale()

----------------------------------------------------------------
-- candy 3D button helper: dark base frame + face that tweens down on press
----------------------------------------------------------------
local function candyButton(parent, size, pos, faceColors, baseColor, drop)
	drop = drop or 7
	local holder = new("Frame", { BackgroundTransparency = 1, Size = size, Position = pos,
		AnchorPoint = Vector2.new(0, 0) }, parent)
	-- base (hard drop)
	local base = new("Frame", { BackgroundColor3 = baseColor, BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, 0), Position = UDim2.fromOffset(0, drop), ZIndex = 1 }, holder)
	corner(20, base)
	-- face
	local face = new("TextButton", { Text = "", AutoButtonColor = false,
		BackgroundColor3 = faceColors[2], BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, 0), ZIndex = 2 }, holder)
	corner(20, face)
	new("UIGradient", { Rotation = 90,
		Color = ColorSequence.new(faceColors[1], faceColors[2]) }, face)
	stroke(face, INK, 3)
	-- press feedback
	local function down() TweenService:Create(face, TweenInfo.new(0.07), { Position = UDim2.fromOffset(0, drop) }):Play() end
	local function up()   TweenService:Create(face, TweenInfo.new(0.07), { Position = UDim2.fromOffset(0, 0) }):Play() end
	face.MouseButton1Down:Connect(down)
	face.MouseButton1Up:Connect(up)
	face.MouseLeave:Connect(up)
	return holder, face
end

----------------------------------------------------------------
-- 1) TRIGGER badge (top-left)
----------------------------------------------------------------
local trigBase = new("Frame", { BackgroundColor3 = VIOLET_DK, BorderSizePixel = 0,
	AutomaticSize = Enum.AutomaticSize.XY, Position = UDim2.fromOffset(42, 41), ZIndex = 1 }, layer)
corner(18, trigBase)
local trigger = new("TextButton", { Name = "Trigger", Text = "", AutoButtonColor = false,
	BackgroundColor3 = VIOLET, BorderSizePixel = 0, AutomaticSize = Enum.AutomaticSize.XY,
	Position = UDim2.fromOffset(42, 34), ZIndex = 2 }, layer)
corner(18, trigger)
new("UIGradient", { Rotation = 90, Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, VIOLET_LT), ColorSequenceKeypoint.new(0.52, VIOLET_MD),
	ColorSequenceKeypoint.new(1, VIOLET) }) }, trigger)
stroke(trigger, INK, 3)
new("UIPadding", { PaddingTop = UDim.new(0, 11), PaddingBottom = UDim.new(0, 11),
	PaddingLeft = UDim.new(0, 15), PaddingRight = UDim.new(0, 20) }, trigger)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal,
	VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 12),
	SortOrder = Enum.SortOrder.LayoutOrder }, trigger)
new("ImageLabel", { Name = "Star", BackgroundTransparency = 1, Image = ASSETS.star,
	Size = UDim2.fromOffset(34, 34), LayoutOrder = 1 }, trigger)
local trigMeta = new("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.XY,
	LayoutOrder = 2 }, trigger)
new("UIListLayout", { FillDirection = Enum.FillDirection.Vertical, Padding = UDim.new(0, 4),
	SortOrder = Enum.SortOrder.LayoutOrder }, trigMeta)
new("TextLabel", { Name = "Cap", BackgroundTransparency = 1, Font = FONT, Text = "PRESTIGE",
	TextColor3 = Color3.fromRGB(232, 222, 252), TextSize = 12, AutomaticSize = Enum.AutomaticSize.XY,
	TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 1 }, trigMeta)
local trigMult = outlineLabel({ Name = "Mult", Font = FONT, Text = "×1.56", TextSize = 27,
	AutomaticSize = Enum.AutomaticSize.XY, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 2 }, trigMeta, 4)
-- keep the dark base glued under the face as it auto-sizes
trigger:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	trigBase.Size = UDim2.fromOffset(trigger.AbsoluteSize.X / uiScale.Scale, trigger.AbsoluteSize.Y / uiScale.Scale)
end)
-- press tween for the trigger
do
	local function d() TweenService:Create(trigger, TweenInfo.new(0.07), { Position = UDim2.fromOffset(42, 41) }):Play() end
	local function u() TweenService:Create(trigger, TweenInfo.new(0.07), { Position = UDim2.fromOffset(42, 34) }):Play() end
	trigger.MouseButton1Down:Connect(d); trigger.MouseButton1Up:Connect(u); trigger.MouseLeave:Connect(u)
end
-- "ready" pulse (gold ring) when a prestige is affordable
local readyStroke = new("UIStroke", { Color = Color3.fromRGB(255, 211, 77), Thickness = 0,
	Transparency = 0, LineJoinMode = Enum.LineJoinMode.Round }, trigger)
local readyTween
local function setReady(on)
	if readyTween then readyTween:Cancel() end
	if on then
		readyStroke.Thickness = 4
		readyTween = TweenService:Create(readyStroke,
			TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Transparency = 1 })
		readyTween:Play()
	else
		readyStroke.Thickness = 0
	end
end

----------------------------------------------------------------
-- 2) MODAL (overlay + panel)
----------------------------------------------------------------
local overlay = new("TextButton", { Name = "Overlay", Text = "", AutoButtonColor = false, Modal = true,
	BackgroundColor3 = Color3.fromRGB(6, 18, 60), BackgroundTransparency = 0.5,
	Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 50 }, layer)

local panel = new("Frame", { Name = "Panel", BackgroundColor3 = WHITE, BorderSizePixel = 0,
	Size = UDim2.fromOffset(620, 0), AutomaticSize = Enum.AutomaticSize.Y,
	AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
	ClipsDescendants = false, ZIndex = 51 }, overlay)
corner(18, panel)
stroke(panel, MAGENTA, 3)
new("UIPadding", { PaddingTop = UDim.new(0, 32), PaddingBottom = UDim.new(0, 30),
	PaddingLeft = UDim.new(0, 40), PaddingRight = UDim.new(0, 40) }, panel)
new("UIListLayout", { FillDirection = Enum.FillDirection.Vertical, Padding = UDim.new(0, 18),
	HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, panel)

-- close X (candy circle PNG)
local closeBtn = new("ImageButton", { Name = "Close", BackgroundTransparency = 1, Image = ASSETS.close,
	Size = UDim2.fromOffset(56, 56), AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(1, -2, 0, 2), ZIndex = 53 }, panel)

-- header (star + titles)
local head = new("Frame", { Name = "Head", BackgroundTransparency = 1, LayoutOrder = 1,
	Size = UDim2.new(1, 0, 0, 52), ZIndex = 52 }, panel)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal,
	VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 14),
	SortOrder = Enum.SortOrder.LayoutOrder }, head)
new("ImageLabel", { BackgroundTransparency = 1, Image = ASSETS.star, Size = UDim2.fromOffset(52, 52),
	LayoutOrder = 1, ZIndex = 52 }, head)
local titleWrap = new("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y,
	Size = UDim2.new(0, 420, 0, 0), LayoutOrder = 2, ZIndex = 52 }, head)
new("TextLabel", { BackgroundTransparency = 1, Font = FONT, Text = "PRESTIGE", TextColor3 = INK,
	TextSize = 30, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 32), ZIndex = 52 }, titleWrap)
new("TextLabel", { BackgroundTransparency = 1, Font = FONT, Text = "Reset your run to climb higher",
	TextColor3 = SUB, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left,
	Position = UDim2.fromOffset(0, 33), Size = UDim2.new(1, 0, 0, 18), ZIndex = 52 }, titleWrap)

-- hero multiplier row (×now → ×next) + label
local heroGroup = new("Frame", { Name = "HeroGroup", BackgroundTransparency = 1, LayoutOrder = 2,
	Size = UDim2.new(1, 0, 0, 92), ZIndex = 52 }, panel)
local hero = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 66), ZIndex = 52 }, heroGroup)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 22), SortOrder = Enum.SortOrder.LayoutOrder }, hero)
local heroNow = outlineLabel({ Name = "Now", Font = FONT, Text = "×1.56", TextSize = 62,
	AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 1, 0), TextTransparency = 0.4,
	LayoutOrder = 1, ZIndex = 52 }, hero, 5)
new("TextLabel", { BackgroundTransparency = 1, Font = FONT, Text = "→", TextColor3 = VIOLET_MD,
	TextSize = 40, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 1, 0), LayoutOrder = 2, ZIndex = 52 }, hero)
local heroNext = outlineLabel({ Name = "Next", Font = FONT, Text = "×1.95", TextSize = 62,
	AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 1, 0), LayoutOrder = 3, ZIndex = 52 }, hero, 5)
new("TextLabel", { BackgroundTransparency = 1, Font = FONT, Text = "GLOBAL WINNINGS MULTIPLIER",
	TextColor3 = SUB, TextSize = 14, Position = UDim2.fromOffset(0, 70), Size = UDim2.new(1, 0, 0, 18),
	ZIndex = 52 }, heroGroup)

-- progress (PP toward cost)
local prog = new("Frame", { Name = "Prog", BackgroundTransparency = 1, LayoutOrder = 3,
	Size = UDim2.new(1, 0, 0, 51), ZIndex = 52 }, panel)
new("TextLabel", { BackgroundTransparency = 1, Font = FONT, Text = "PRESTIGE POINTS", TextColor3 = SUB,
	TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(0.6, 0, 0, 20), ZIndex = 52 }, prog)
local ptsVal = new("TextLabel", { Name = "Pts", BackgroundTransparency = 1, Font = FONT, Text = "20 / 20",
	TextColor3 = INK, TextSize = 18, TextXAlignment = Enum.TextXAlignment.Right,
	AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0.4, 0, 0, 22), ZIndex = 52 }, prog)
local pgTrack = new("Frame", { BackgroundColor3 = TRACK_BG, BorderSizePixel = 0,
	Position = UDim2.fromOffset(0, 31), Size = UDim2.new(1, 0, 0, 20), ClipsDescendants = true, ZIndex = 52 }, prog)
corner(11, pgTrack); stroke(pgTrack, TRACK_BD, 2)
local pgFill = new("Frame", { Name = "Fill", BackgroundColor3 = VIOLET, BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 1, 0), ZIndex = 53 }, pgTrack)
corner(11, pgFill)
new("UIGradient", { Rotation = 90, Color = ColorSequence.new(VIOLET_LT, VIOLET) }, pgFill)

-- stat chips (lifetime / cost / prestige #)
local stats = new("Frame", { Name = "Stats", BackgroundTransparency = 1, LayoutOrder = 4,
	Size = UDim2.new(1, 0, 0, 64), ZIndex = 52 }, panel)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 10),
	SortOrder = Enum.SortOrder.LayoutOrder }, stats)
local function statChip(order, cap)
	local chip = new("Frame", { BackgroundColor3 = CHIP_BG, BorderSizePixel = 0,
		Size = UDim2.new(1/3, -7, 1, 0), LayoutOrder = order, ZIndex = 52 }, stats)
	corner(14, chip); stroke(chip, CHIP_BD, 2)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Vertical, Padding = UDim.new(0, 6),
		HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder }, chip)
	new("TextLabel", { BackgroundTransparency = 1, Font = FONT, Text = cap, TextColor3 = SUB, TextSize = 11,
		AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 0, 12), LayoutOrder = 1, ZIndex = 52 }, chip)
	local val = new("TextLabel", { Name = "Val", BackgroundTransparency = 1, Font = FONT, Text = "—",
		TextColor3 = INK, TextSize = 22, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 0, 24),
		LayoutOrder = 2, ZIndex = 52 }, chip)
	return val
end
local statLife = statChip(1, "LIFETIME BANKED")
local statCost = statChip(2, "NEXT COST")
local statNum  = statChip(3, "PRESTIGE")

-- PRESTIGE button (candy violet) + lock state
local goHolder, goFace = candyButton(panel, UDim2.new(1, 0, 0, 74), UDim2.new(), { VIOLET_LT, VIOLET }, VIOLET_DK)
goHolder.LayoutOrder = 5
goHolder.ZIndex = 52
local goLabel = outlineLabel({ Name = "Go", Font = FONT, Text = "PRESTIGE", TextSize = 32,
	Size = UDim2.fromScale(1, 1), ZIndex = 53 }, goFace, 5)
-- warning
new("TextLabel", { BackgroundTransparency = 1, Font = FONT, LayoutOrder = 6, ZIndex = 52,
	Text = "Resets all upgrades & current balance · Prestige points are kept",
	TextColor3 = SUB, TextSize = 13, Size = UDim2.new(1, 0, 0, 18) }, panel)

----------------------------------------------------------------
-- render — push `state` into every dynamic element
----------------------------------------------------------------
local function compute()
	local pc   = state.prestigeCount
	local pp   = ppFromLifetime(state.lifetimeBanked)
	local cost = prestigeCost(pc + 1)
	return pc, pp, cost, prestigeMult(pc), prestigeMult(pc + 1), pp >= cost
end

local function render()
	local pc, pp, cost, now, nxt, can = compute()
	trigMult.Text  = ("×%.2f"):format(now)
	heroNow.Text   = ("×%.2f"):format(now)
	heroNext.Text  = ("×%.2f"):format(nxt)
	ptsVal.Text    = commas(pp) .. " / " .. commas(cost)
	statLife.Text  = fmtShort(state.lifetimeBanked)
	statCost.Text  = commas(cost) .. " PP"
	statNum.Text   = pc .. " → " .. (pc + 1)
	local frac = math.clamp(cost > 0 and pp / cost or 0, 0, 1)
	TweenService:Create(pgFill, TweenInfo.new(0.4, Enum.EasingStyle.Quad), { Size = UDim2.new(frac, 0, 1, 0) }):Play()
	setReady(can)
	-- button affordance
	for _, g in ipairs(goFace:GetChildren()) do if g:IsA("UIGradient") then
		g.Color = can and ColorSequence.new(VIOLET_LT, VIOLET) or ColorSequence.new(LOCK_FACE, LOCK_BASE)
	end end
	goLabel.Text = can and "PRESTIGE" or ("NEED " .. commas(cost - pp) .. " MORE PP")
	goLabel.TextSize = can and 32 or 23
	goFace.Active = can
end

----------------------------------------------------------------
-- open / close
----------------------------------------------------------------
local function open()  render(); overlay.Visible = true end
local function close() overlay.Visible = false end
trigger.MouseButton1Click:Connect(open)
closeBtn.MouseButton1Click:Connect(close)
overlay.MouseButton1Click:Connect(close) -- click backdrop to dismiss

----------------------------------------------------------------
-- INTEGRATION SEAMS  (wire to your RemoteEvents / RemoteFunctions)
----------------------------------------------------------------

-- ① FETCH initial prestige state on load (prestigeCount + lifetimeBanked).
function fetchPrestigeState()
	-- TODO: return ReplicatedStorage.Remotes.GetPrestige:InvokeServer()
	return { prestigeCount = 2, lifetimeBanked = 8000000 }
end

-- ② SUBMIT a prestige (player tapped the button). Server validates PP>=cost,
--    wipes the run (balance + upgrades), bumps prestigeCount, and pushes the
--    new state back via applyState(). Do NOT mutate state locally here — let
--    the authoritative push update the UI so a rejected prestige can't desync.
function submitPrestige()
	local _, _, _, _, _, can = compute()
	if not can then return end
	-- TODO: ReplicatedStorage.Remotes.DoPrestige:FireServer()
	-- celebrate locally; the real state arrives via applyState()
	TweenService:Create(panel, TweenInfo.new(0.18, Enum.EasingStyle.Back), { Size = UDim2.fromOffset(620, panel.AbsoluteSize.Y / uiScale.Scale) }):Play()
	print("[Prestige] submit requested")
end
goFace.MouseButton1Click:Connect(submitPrestige)

-- ③ APPLY authoritative state (initial load, server push, post-prestige, or a
--    rejected submit). Overrides local state and re-renders everything.
function applyState(s)
	if s.prestigeCount  ~= nil then state.prestigeCount  = s.prestigeCount end
	if s.lifetimeBanked ~= nil then state.lifetimeBanked = s.lifetimeBanked end
	render()
end

-- ④ CONNECT server→client pushes (lifetime ticks, prestige confirmations).
function connectRemotes()
	-- TODO:
	-- ReplicatedStorage.Remotes.PrestigeState.OnClientEvent:Connect(applyState)
end

----------------------------------------------------------------
-- init
----------------------------------------------------------------
applyState(fetchPrestigeState())
connectRemotes()
print("[PrestigeUI] Built. Set ASSETS.star + ASSETS.close ids.")
