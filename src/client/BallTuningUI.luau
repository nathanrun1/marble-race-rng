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
local RS               = game:GetService("ReplicatedStorage")

-- Shared, pure derivation + config — the same source the server clamps against, so
-- the client computes identical axis ranges locally (no extra "get ranges" remote).
local Config       = require(RS.Shared.Config)
local ProfileStats = require(RS.Shared.ProfileStats)
local UIButton     = require(RS.Shared.UIButton)
local CameraService = require(script.Parent:WaitForChild("CameraService"))
local BallTuningPreview = require(script.Parent:WaitForChild("BallTuningPreview"))

local player = Players.LocalPlayer

-- Loadout remotes (see ProfileService): SetAxis is the submit RF (returns whether
-- the change was accepted), ProfileChanged pushes the authoritative profile after
-- any mutation, GetProfile is the initial pull.
local Remote           = RS:WaitForChild("Remote")
local SetAxisRF        = Remote:WaitForChild("SetAxis")        :: RemoteFunction
local ProfileChangedRE = Remote:WaitForChild("ProfileChanged") :: RemoteEvent
local GetProfileRF     = Remote:WaitForChild("GetProfile")     :: RemoteFunction

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
-- AXES  (config + live state).
--   serverAxis  → the Config.Axes key this row maps to (ProfileService.SetAxis).
--   toServer/fromServer → unit conversion between display units (what the handle
--      shows) and stored units (what the server keeps). Angle/Arc: deg↔rad. Size: ×
--      identity. Bounciness: percent↔0-1 (server axis "Elasticity").
--   twoSided  → fill anchors at the track center (the aim point) rather than the
--      low end. Pure cosmetic; the unlocked band itself comes from the server.
--
--   name is taken from Config.Axes[serverAxis].Name (single source) just below.
--   min/max/uMin/uMax/tier/maxTier/value are filled from the authoritative profile
--   (applyProfile) — and seeded from Config at tier 0 so the UI renders pre-fetch.
----------------------------------------------------------------
Controller.AXES = {
	{ key="angle",  serverAxis="Angle",      step=1,    value=0,   twoSided=true,
	  toServer=math.rad, fromServer=math.deg,
	  fmt=function(v) return (v>0 and "+" or "")..math.round(v).."°" end },
	{ key="arc",    serverAxis="Arc",        step=1,    value=15,
	  toServer=math.rad, fromServer=math.deg,
	  fmt=function(v) return math.round(v).."°" end },
	{ key="size",   serverAxis="Size",       step=0.05, value=1.0,
	  toServer=function(v) return v end, fromServer=function(v) return v end,
	  fmt=function(v) return string.format("%.2f×", v) end },
	{ key="bounce", serverAxis="Elasticity", step=1,    value=50,
	  toServer=function(v) return v / 100 end, fromServer=function(v) return v * 100 end,
	  fmt=function(v) return math.round(v).."%" end },
}

-- Display names come straight from Config (the same labels the shop uses), so the
-- two never drift. A fallback to the key keeps a new axis from rendering blank.
for _, a in ipairs(Controller.AXES) do
	a.name = Config.Axes[a.serverAxis].Name or a.key
end

-- placeholder reference to the GUI root (set this before init)
Controller.root = player.PlayerGui.MainGui.LeftBar.BallTuning

----------------------------------------------------------------
-- helpers
----------------------------------------------------------------
local byKey = {}
for _, a in ipairs(Controller.AXES) do byKey[a.key] = a end

-- Resolve a UI axis's bounds (in display units) from a raw upgrades/tiers map, the
-- same way the server does — full track is the widest unlockable extent across all
-- tiers; the unlocked band is the current tier's range (ProfileStats.GetAxisRange).
-- Returns { min, max, uMin, uMax, tier, maxTier }. All conversions here (deg, ×100)
-- are monotonic increasing, so Min/Max ordering is preserved.
local function rangeDataFor(a, upgrades)
	local def = Config.Axes[a.serverAxis]
	local tier = upgrades[a.serverAxis] or 0
	local fullMin, fullMax = math.huge, -math.huge
	for _, r in def.Ranges do
		fullMin = math.min(fullMin, r.Min)
		fullMax = math.max(fullMax, r.Max)
	end
	local uMin, uMax = ProfileStats.GetAxisRange(upgrades, a.serverAxis)
	return {
		min     = a.fromServer(fullMin),
		max     = a.fromServer(fullMax),
		uMin    = a.fromServer(uMin),
		uMax    = a.fromServer(uMax),
		tier    = tier,
		maxTier = #def.Ranges - 1,
	}
end

-- Push resolved bounds onto the axis (handle bounds + pill source).
local function applyRangeData(a, rd)
	a.min, a.max     = rd.min, rd.max
	a._uMin, a._uMax = rd.uMin, rd.uMax
	a.tier, a.maxTier = rd.tier, rd.maxTier
	a.anchor = a.twoSided and (a.min + a.max) / 2 or a.min
end

local function fracOf(a, v)
	if a.max == a.min then return 0 end
	return (v - a.min) / (a.max - a.min)
end
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

-- Reposition the authored lock zones over the currently-locked bands
-- [min..uMin] and [uMax..max]. Up to two zones; any spare authored Lock is
-- hidden. Never creates or destroys — the chrome owns the instances.
local function rebuildLocks(a)
	local umnF, umxF = fracOf(a, a._uMin), fracOf(a, a._uMax)
	local zones = {}
	if umnF > 1e-4 then table.insert(zones, { x = 0, w = umnF }) end          -- left  [min..uMin]
	if (1 - umxF) > 1e-4 then table.insert(zones, { x = umxF, w = 1 - umxF }) end -- right [uMax..max]
	for i, lock in ipairs(a._locks) do
		local z = zones[i]
		if z then
			lock.Position = UDim2.new(z.x, 0, 0.5, 0)
			lock.Size = UDim2.new(z.w, 0, 1, 4)
			lock.Visible = true
		else
			lock.Visible = false
		end
	end
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
-- bind the authored dynamic parts for one axis + wire drag
----------------------------------------------------------------
local function buildDynamic(a)
	-- The chrome (Track.Fill, Track.Handle, Track.Lock×N) is authored in Studio;
	-- the controller only positions/sizes it. Bounds (a._uMin/_uMax, a.anchor) are
	-- already set by applyRangeData before the first build and on every update.
	local track = a._track
	a._fill   = track:WaitForChild("Fill")
	a._handle = track:WaitForChild("Handle")
	a._locks  = {}
	for _, c in ipairs(track:GetChildren()) do
		if c.Name == "Lock" then table.insert(a._locks, c) end
	end
	-- An interior unlocked band locks both ends, so each row needs two Lock zones.
	-- If only one is authored, clone it (same styling) to cover the right side too.
	while #a._locks > 0 and #a._locks < 2 do
		local clone = a._locks[1]:Clone()
		clone.Parent = track
		table.insert(a._locks, clone)
	end

	-- Anchor conventions the positioning math (updateAxis / rebuildLocks) assumes.
	a._fill.AnchorPoint   = Vector2.new(0, 0.5)
	a._handle.AnchorPoint = Vector2.new(0.5, 0.5)
	for _, lock in ipairs(a._locks) do
		lock.AnchorPoint = Vector2.new(0, 0.5)
	end

	rebuildLocks(a)
	updateAxis(a)

	-- drag (AbsolutePosition/Size already include UIScale → device-agnostic)
	local dragging, startVal = false, nil
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
			a._dragging = true           -- suppress authoritative snaps mid-drag
			a._preDrag = startVal        -- value to restore if the submit is rejected
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
			a._dragging = false
			if a.value ~= startVal then
				Controller.submitAxisChange(a.key, a.value)   -- ① submit on release
			end
		end
	end)
end

----------------------------------------------------------------
-- INTEGRATION  (wired to ProfileService's loadout remotes)
----------------------------------------------------------------

-- Refresh one axis's visuals from its current numeric state (band + pill + handle).
-- No-op if the row hasn't been built yet (pre-init authoritative push).
local function redrawAxis(a)
	if not a._track then return end
	rebuildLocks(a)
	setPill(a)
	updateAxis(a)
end

-- ① SUBMIT axis change — fired once the handle STOPS moving. Send the chosen value
--    (converted to server units) to ProfileService.SetAxis. The server clamps to
--    the unlocked band and pushes the authoritative profile back over
--    ProfileChanged, which snaps the handle to the value it actually kept — so an
--    out-of-band or rejected change "puts the handle back" on its own. A hard
--    failure (SetAxis returns false, no push) is reverted here from a._preDrag.
function Controller.submitAxisChange(key, value)
	local a = byKey[key]; if not a then return end
	local ok = SetAxisRF:InvokeServer(a.serverAxis, a.toServer(value))
	if not ok then
		Controller.applyAuthoritativeValue(key, a._preDrag or a.value)
	end
end

-- ② RECEIVE new tier — grows the unlocked band, shrinks the locked hatch, updates
--    the "Lv x/y" pill, and re-clamps the current value. Driven by applyProfile,
--    but exposed for direct use too: Controller.applyTier("size", 4).
function Controller.applyTier(key, tier)
	local a = byKey[key]; if not a then return end
	applyRangeData(a, rangeDataFor(a, { [a.serverAxis] = math.clamp(tier, 0, a.maxTier) }))
	a.value = clampStep(a, a.value)   -- pull value back into the unlocked band
	redrawAxis(a)
end

-- ③ RECEIVE authoritative value — overrides whatever the local handle shows and
--    snaps the handle to match. Used by the ProfileChanged push and the rejected-
--    submit revert. Call: Controller.applyAuthoritativeValue("angle", 0).
function Controller.applyAuthoritativeValue(key, value)
	local a = byKey[key]; if not a then return end
	a.value = clampStep(a, value)
	redrawAxis(a)
end

-- Apply a whole authoritative profile (from GetProfile / ProfileChanged): refresh
-- each axis's unlocked band from its upgrade tier and snap its handle to the stored
-- loadout value. Skips the value snap for an axis being dragged so a stray push
-- (e.g. a concurrent tier purchase) can't yank the handle out from under the user.
local function applyProfile(profile)
	if not profile then return end
	for _, a in ipairs(Controller.AXES) do
		applyRangeData(a, rangeDataFor(a, profile.upgrades))
		if not a._dragging then
			local stored = profile.loadout.axes[a.serverAxis]
			if stored ~= nil then
				a.value = a.fromServer(stored)
			end
		end
		a.value = clampStep(a, a.value)
		redrawAxis(a)
	end
end

-- ④ FETCH the authoritative profile on initial load. Returns the Profile table
--    ({ upgrades, loadout }) or nil if the server didn't answer (keeps Config
--    tier-0 seeds). pcall'd so a missing/erroring remote can't break the UI.
function Controller.fetchProfile()
	local ok, profile = pcall(function()
		return GetProfileRF:InvokeServer()
	end)
	return ok and profile or nil
end

-- Connect server → client pushes: every profile mutation re-syncs the sliders.
function Controller._connectRemotes()
	ProfileChangedRE.OnClientEvent:Connect(applyProfile)
end

----------------------------------------------------------------
-- Menu open/close. The panel (Controller.root) is closed by default; the
-- TuneTriggerHost button on the left bar opens it (and hides itself), and
-- root.UIListIgnore.CloseButton closes it again, restoring the trigger.
----------------------------------------------------------------

-- Pop-open: grow the panel from collapsed to its resting size. With the left bar's
-- list layout, the growing panel shoves the elements above it upward as it opens.
local TUNE_OPEN_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local tuningOpen = false
local tuningTween: Tween? = nil
local tuningRestScale = 1   -- resting Scale captured at open (AutoScale-driven, or 1)

-- The panel's UIScale — reuse AutoScale's if present, else make one. We animate this
-- on open rather than the panel's Size so the list layout reflows with the growth.
local function tuningScale(): UIScale
	local panel = Controller.root
	local s = panel:FindFirstChildOfClass("UIScale")
	if not s then
		s = Instance.new("UIScale")
		s.Parent = panel
	end
	return s
end

local function openTuning(triggerHost: GuiObject)
	if tuningOpen then return end
	tuningOpen = true
	if tuningTween then tuningTween:Cancel() end

	triggerHost.Visible = false
	Controller.root.Visible = true
	CameraService.SetTuningView(true) -- swing to the ball-tuning camera while open
	BallTuningPreview.SetVisible(true) -- aim lines + preview ball

	local scale = tuningScale()
	tuningRestScale = scale.Scale   -- whatever it normally rests at (AutoScale or 1)
	scale.Scale = 0                 -- collapse, then grow into place
	tuningTween = TweenService:Create(scale, TUNE_OPEN_TWEEN, { Scale = tuningRestScale })
	tuningTween:Play()
end

local function closeTuning(triggerHost: GuiObject)
	if not tuningOpen then return end
	tuningOpen = false
	if tuningTween then
		tuningTween:Cancel()
		tuningTween = nil
	end

	tuningScale().Scale = tuningRestScale   -- restore resting size for the next open
	Controller.root.Visible = false
	triggerHost.Visible = true
	CameraService.SetTuningView(false) -- back to board view / default camera
	BallTuningPreview.SetVisible(false)
end

local function initTuningMenu()
	local leftBar = Controller.root.Parent
	local triggerHost = leftBar:WaitForChild("TuneTriggerHost") :: GuiObject
	local closeBtn = Controller.root:WaitForChild("UIListIgnore"):WaitForChild("CloseButton") :: GuiButton

	Controller.root.Visible = false   -- closed by default
	triggerHost.Visible = true
	UIButton.bind(triggerHost, { onClick = function() openTuning(triggerHost) end })
	closeBtn.Activated:Connect(function() closeTuning(triggerHost) end)
end

----------------------------------------------------------------
-- init — resolve chrome refs under root, seed from Config, build, then sync
----------------------------------------------------------------
function Controller.init()
	assert(Controller.root, "BallTuningController.root must be set to the panel before init()")

	initTuningMenu()

	for _, a in ipairs(Controller.AXES) do
		-- Seed bounds from Config at tier 0 so the row renders before the fetch.
		applyRangeData(a, rangeDataFor(a, {}))
		a.value = clampStep(a, a.value)

		-- Resolve the authored chrome for this row.
		a._row    = Controller.root:WaitForChild(a.key)
		a._track  = a._row:WaitForChild("Track")
		a._read   = a._row.Top:WaitForChild("Read")
		a._pill   = a._row.Top.NameRow.Lv:WaitForChild("LvText")
		a._row.Top.NameRow:WaitForChild("Name").Text = a.name  -- title from Config

		buildDynamic(a)
		setPill(a)
	end

	Controller._connectRemotes()
	applyProfile(Controller.fetchProfile()) -- authoritative pull (no-op if nil)
end

-- read the current chosen value any time: Controller.get("angle")
function Controller.get(key) local a = byKey[key]; return a and a.value end

return Controller
