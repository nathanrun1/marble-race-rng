--[[
  BallTuningController  (ModuleScript)
  =================================================================
  Owns ALL dynamic behaviour for the Ball-Tuning sliders:
    • builds the moving parts (fill, locked-hatch zones, handle)
    • drag math (mouse + touch), clamped to the unlocked band
    • the 4 integration seams to your game code (see "INTEGRATION")

  It drives the GUI through a single reference: Controller.root — point
  it at the panel the builder created (or your pre-built Studio frame),
  then call Controller.init().

      local C = require(path.to.BallTuningController)
      C.root = myPanel            -- ← the GUI root (placeholder ref)
      C.init()

  The STATIC chrome (panel, labels, track background, Lv pill) is built
  by the companion "BallTuning" LocalScript. This module only creates /
  moves the parts that change.
]]

local Players: Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")

local player = Players.LocalPlayer

local Controller = {}

----------------------------------------------------------------
-- ASSET IDS  (replace the zeros — single source of truth)
----------------------------------------------------------------
Controller.ASSETS = {
	handle = "rbxassetid://0000000000", -- slider-handle.png
	hatch  = "rbxassetid://0000000000", -- lock-hatch.png
}

----------------------------------------------------------------
-- STYLE  (shared with the builder; the builder reads this table)
----------------------------------------------------------------
Controller.STYLE = {
	INK          = Color3.fromRGB(22, 34, 63),
	MAGENTA      = Color3.fromRGB(236, 63, 212),
	SUB          = Color3.fromRGB(199, 154, 208),
	WHITE        = Color3.new(1, 1, 1),
	TRACK_BG     = Color3.fromRGB(247, 233, 246),
	TRACK_BORDER = Color3.fromRGB(239, 201, 234),
	FILL_TOP     = Color3.fromRGB(251, 182, 239),
	FILL_BOT     = Color3.fromRGB(236, 63, 212),
	PILL_BG      = Color3.fromRGB(241, 232, 246),
	PILL_BORDER  = Color3.fromRGB(227, 211, 236),
	PILL_TEXT    = Color3.fromRGB(169, 143, 182),
	FONT         = Enum.Font.FredokaOne,
	HANDLE_SIZE  = 40,  -- handle PNG circle ≈72% of frame → ~28px on-track
	HATCH_TILE   = 14,  -- logical px per hatch tile (matches the web)
}

----------------------------------------------------------------
-- AXES  (config + live state). min/max/maxTier are DEFAULTS — they get
-- overwritten by fetchMaxRanges() on init from the authoritative source.
--   twoSided  → unlocks symmetrically outward from center (Angle)
--   else      → unlocks from the low end up to a tier cap (Size, Bounce)
----------------------------------------------------------------
Controller.AXES = {
	{ key="angle",  name="Angle",      min=-60, max=60,  step=1,   tier=2, maxTier=5, value=0,   twoSided=true,
	  fmt=function(v) return (v>0 and "+" or "")..math.round(v).."°" end },
	{ key="size",   name="Size",       min=0.5, max=4,   step=0.1, tier=3, maxTier=5, value=1.0,
	  fmt=function(v) return string.format("%.1f×", v) end },
	{ key="bounce", name="Bounciness", min=0,   max=100, step=1,   tier=1, maxTier=4, value=12,
	  fmt=function(v) return math.round(v).."%" end },
}

-- placeholder reference to the GUI root (set this before init)
Controller.root = player.PlayerGui.MainGui.BallTuning

----------------------------------------------------------------
-- helpers
----------------------------------------------------------------
local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props or {}) do o[k] = v end
	if parent then o.Parent = parent end
	return o
end

local byKey = {}
for _, a in ipairs(Controller.AXES) do byKey[a.key] = a end

local function uRange(a)
	if a.twoSided then
		local center = (a.min + a.max) / 2
		local half   = (a.max - a.min) / 2
		local span   = half * (a.tier / a.maxTier)
		return center - span, center + span
	end
	return a.min, a.min + (a.max - a.min) * (a.tier / a.maxTier)
end
local function fracOf(a, v) return (v - a.min) / (a.max - a.min) end
local function clampStep(a, v)
	v = math.clamp(v, a._uMin, a._uMax)
	v = math.floor((v - a.min) / a.step + 0.5) * a.step + a.min
	return math.clamp(v, a._uMin, a._uMax)
end

local function updateAxis(a)
	local vf = fracOf(a, a.value)
	local af = fracOf(a, a.anchor)
	local lo, hi = math.min(vf, af), math.max(vf, af)
	a._fill.Position   = UDim2.new(lo, 0, 0.5, 0)
	a._fill.Size       = UDim2.new(hi - lo, 0, 1, 4)
	a._handle.Position = UDim2.new(vf, 0, 0.5, 0)
	a._read.Text       = a.fmt(a.value)
end

local function setPill(a)
	if a._pill then a._pill.Text = "Lv "..a.tier.."/"..a.maxTier end
end

local function corner(r, p) new("UICorner", { CornerRadius = UDim.new(0, r) }, p) end

-- (re)build the locked-hatch zones for an axis from its current tier
local function rebuildLocks(a)
	local S = Controller.STYLE
	for _, c in ipairs(a._track:GetChildren()) do
		if c.Name == "Lock" then c:Destroy() end
	end
	local umnF, umxF = fracOf(a, a._uMin), fracOf(a, a._uMax)
	local function zone(xScale, wScale)
		if wScale <= 1e-4 then return end
		local lz = new("ImageLabel", { Name = "Lock", BackgroundTransparency = 1,
			Image = Controller.ASSETS.hatch, ScaleType = Enum.ScaleType.Tile,
			TileSize = UDim2.fromOffset(S.HATCH_TILE, S.HATCH_TILE),
			AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(xScale, 0, 0.5, 0),
			Size = UDim2.new(wScale, 0, 1, 4), ZIndex = 3 }, a._track)
		corner(9, lz)
	end
	if a.twoSided then zone(0, umnF) end   -- left locked band
	zone(umxF, 1 - umxF)                    -- right locked band
end

-- shake a row when the player taps a locked zone
local function shake(a)
	local t = a._track
	local base = t.Position
	task.spawn(function()
		for _, dx in ipairs({6, -6, 4, -4, 0}) do
			TweenService:Create(t, TweenInfo.new(0.05), { Position = base + UDim2.fromOffset(dx, 0) }):Play()
			task.wait(0.05)
		end
		t.Position = base
	end)
end

----------------------------------------------------------------
-- build the dynamic parts for one axis + wire drag
----------------------------------------------------------------
local function buildDynamic(a)
	local S = Controller.STYLE
	a._uMin, a._uMax = uRange(a)
	a.anchor = a.twoSided and (a.min + a.max) / 2 or a.min

	-- fill (magenta gradient, anchor → value)
	a._fill = new("Frame", { Name = "Fill", BackgroundColor3 = S.WHITE,
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(0, 0, 1, 4), BorderSizePixel = 0, ZIndex = 2 }, a._track)
	corner(9, a._fill)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(S.FILL_TOP, S.FILL_BOT) }, a._fill)

	-- locked zones
	rebuildLocks(a)

	-- handle (candy circle PNG)
	a._handle = new("ImageLabel", { Name = "Handle", BackgroundTransparency = 1,
		Image = Controller.ASSETS.handle, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(S.HANDLE_SIZE, S.HANDLE_SIZE),
		ZIndex = 4 }, a._track)

	updateAxis(a)

	-- drag (AbsolutePosition/Size already include UIScale → device-agnostic)
	local dragging, startVal = false, nil
	local track = a._track
	local function setFromX(px)
		local f = math.clamp((px - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
		a.value = clampStep(a, a.min + f * (a.max - a.min))
		updateAxis(a)
	end
	track.Active = true
	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			local f = (input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X
			local v = a.min + f * (a.max - a.min)
			if v < a._uMin - 1e-6 or v > a._uMax + 1e-6 then shake(a) end
			dragging, startVal = true, a.value
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			if a.value ~= startVal then
				Controller.submitAxisChange(a.key, a.value)   -- ① submit on release
			end
		end
	end)
end

----------------------------------------------------------------
-- INTEGRATION SEAMS  (wire these to your RemoteEvents / RemoteFunctions)
----------------------------------------------------------------

-- ① SUBMIT axis change — fired once the handle STOPS moving.
--    Send the chosen value to the server for validation / persistence.
function Controller.submitAxisChange(key, value)
	-- TODO: replace with your remote, e.g.
	--   ReplicatedStorage.Remotes.SetAxis:FireServer(key, value)
	print(("[BallTuning] submit %s = %s"):format(key, tostring(value)))
end

-- ② RECEIVE new tier — grows the unlocked band, shrinks the locked hatch,
--    updates the "Lv x/y" pill, and re-clamps the current value.
--    Call from your tier/shop remote: Controller.applyTier("size", 4)
function Controller.applyTier(key, tier)
	local a = byKey[key]; if not a then return end
	a.tier = math.clamp(tier, 0, a.maxTier)
	a._uMin, a._uMax = uRange(a)
	rebuildLocks(a)
	setPill(a)
	a.value = clampStep(a, a.value)   -- pull value back into the unlocked band
	updateAxis(a)
end

-- ③ RECEIVE authoritative value — overrides whatever the local handle shows
--    and snaps the handle to match. Use for server pushes AND for a REJECTED
--    submit (server replies with the value it actually kept).
--    Call: Controller.applyAuthoritativeValue("angle", 0)
function Controller.applyAuthoritativeValue(key, value)
	local a = byKey[key]; if not a then return end
	a.value = clampStep(a, value)
	updateAxis(a)
end

-- ④ FETCH max ranges on initial load — return per-axis {min,max,maxTier,tier}.
--    Replace the body with a server fetch (InvokeServer). Returning nil keeps
--    the defaults baked into Controller.AXES.
function Controller.fetchMaxRanges()
	-- TODO: e.g.
	--   return ReplicatedStorage.Remotes.GetAxisRanges:InvokeServer()
	return nil
end

-- Connect server → client pushes here (placeholder).
function Controller._connectRemotes()
	-- TODO: e.g.
	--   ReplicatedStorage.Remotes.AxisTier.OnClientEvent:Connect(Controller.applyTier)
	--   ReplicatedStorage.Remotes.AxisValue.OnClientEvent:Connect(Controller.applyAuthoritativeValue)
end

----------------------------------------------------------------
-- init — resolve chrome refs under root, apply ranges, build moving parts
----------------------------------------------------------------
function Controller.init()
	assert(Controller.root, "BallTuningController.root must be set to the panel before init()")

	local ranges = Controller.fetchMaxRanges()
	for _, a in ipairs(Controller.AXES) do
		local r = ranges and ranges[a.key]
		if r then
			a.min     = r.min or a.min
			a.max     = r.max or a.max
			a.maxTier = r.maxTier or a.maxTier
			if r.tier   then a.tier  = r.tier end
			if r.value  then a.value = r.value end
		end
		-- resolve the static chrome the builder created
		a._row    = Controller.root:WaitForChild(a.key)
		a._track  = a._row:WaitForChild("Track")
		a._read   = a._row.Top:WaitForChild("Read")
		a._pill   = a._row.Top.NameRow.Lv:WaitForChild("LvText")

		buildDynamic(a)
		setPill(a)
	end

	Controller._connectRemotes()
end

-- read the current chosen value any time: Controller.get("angle")
function Controller.get(key) local a = byKey[key]; return a and a.value end

return Controller
