--!strict
-- Floating chevron trail: a chain of BillboardGui triangles from the local player's center to
-- a live target position, each pointing along the trail (screen-space rotated so it reads
-- correctly from any camera angle) and fading from large/NearColor (by the player) to
-- small/FarColor (by the target). Chevrons sit a fixed Spacing (studs) apart — the count
-- scales with distance (capped at MaxSegments) and the chain divides the distance evenly, so
-- the trail is equally dense whether the target is near or far — Config.Tutorial.Arrow tunes
-- spacing/colors/sizes.
-- Orthogonal to any specific feature — a caller just hands it a `() -> Vector3?` getter
-- (re-evaluated every frame, so the target can move) and Show/Hide it; nothing here knows
-- about tutorials, quests, or anything else that might want a directional trail.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local Config = require(RS.Shared.Config)

local WorldArrow = {}

local player = Players.LocalPlayer
local A = Config.Tutorial.Arrow

type Segment = {
	carrier: BasePart,
	gui: BillboardGui,
	glyph: TextLabel,
}

-- Pooled: segments[1..activeCount] are enabled and laid along the trail; anything past
-- activeCount is kept but hidden, so the count tracking a moving player/target doesn't
-- churn instances every frame.
local segments: { Segment } = {}
local activeCount = 0
local getTarget: (() -> Vector3?)? = nil
local heartbeatConn: RBXScriptConnection? = nil

-- One chevron: an invisible anchored "carrier" part (moved every frame to its point along the
-- trail) holding a BillboardGui with a triangle glyph. Size/color are per-position along the
-- chain, so they're applied by setGradient whenever the active count changes.
local function buildSegment(): Segment
	local carrier = Instance.new("Part")
	carrier.Name = "WorldArrowSegment"
	carrier.Size = Vector3.new(0.2, 0.2, 0.2)
	carrier.Transparency = 1
	carrier.Anchored = true
	carrier.CanCollide = false
	carrier.CanQuery = false
	carrier.CastShadow = false
	carrier.Parent = workspace

	local gui = Instance.new("BillboardGui")
	gui.Name = "WorldArrowSegmentGui"
	gui.Adornee = carrier
	gui.AlwaysOnTop = true
	gui.Enabled = false
	gui.Parent = carrier

	local glyph = Instance.new("TextLabel")
	glyph.Name = "Glyph"
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.fromScale(1, 1)
	glyph.Font = Enum.Font.GothamBold
	glyph.Text = "▲"
	glyph.TextScaled = true
	glyph.TextStrokeTransparency = 0.5
	glyph.Parent = gui

	return { carrier = carrier, gui = gui, glyph = glyph }
end

-- Size/color fade over the ACTIVE chain (0 = at the player, 1 = at the target), reapplied
-- whenever the count changes so the gradient always spans the whole trail.
local function setGradient(count: number)
	for i = 1, count do
		local t = (i - 1) / (count - 1)
		local seg = segments[i]
		local size = A.NearSize + (A.FarSize - A.NearSize) * t
		seg.gui.Size = UDim2.fromOffset(size, size)
		seg.glyph.TextColor3 = A.NearColor:Lerp(A.FarColor, t)
	end
end

-- Grow the pool to `count` and enable exactly the first `count` segments.
local function setActiveCount(count: number)
	if count == activeCount then
		return
	end
	for i = #segments + 1, count do
		segments[i] = buildSegment()
	end
	for i, seg in segments do
		seg.gui.Enabled = i <= count
	end
	setGradient(count)
	activeCount = count
end

-- Screen-space rotation (clockwise degrees) that points a default "▲" (pointing up) glyph
-- from posA toward posB, as seen on screen right now — recomputed every frame since the
-- camera moves. nil if either point is behind the camera / degenerate (posA == posB on screen).
local function screenAngle(camera: Camera, posA: Vector3, posB: Vector3): number?
	local screenA, onScreenA = camera:WorldToViewportPoint(posA)
	local screenB, onScreenB = camera:WorldToViewportPoint(posB)
	if not onScreenA or not onScreenB then
		return nil
	end
	local dx = screenB.X - screenA.X
	local dy = screenB.Y - screenA.Y
	if math.abs(dx) < 0.01 and math.abs(dy) < 0.01 then
		return nil
	end
	-- Screen Y grows downward; "▲" points up (-Y) at Rotation 0, and GuiObject.Rotation is
	-- clockwise degrees, so this maps (dx, dy) to the angle that turns "up" onto that vector.
	return math.deg(math.atan2(dx, -dy))
end

local function update()
	local target = getTarget
	if not target then
		return
	end
	local char = player.Character
	local root = char and (char:FindFirstChild("HumanoidRootPart") :: BasePart?)
	local camera = workspace.CurrentCamera
	if not root or not camera then
		return
	end
	local targetPos = target()
	if not targetPos then
		return
	end

	local origin = root.Position
	local dest = targetPos + Vector3.new(0, A.TargetHeightOffset, 0)

	-- One chevron every ~Spacing studs (the distance divides evenly across them), at least a
	-- pair so there's always a direction to read, capped so a far target can't spawn hundreds.
	local distance = (dest - origin).Magnitude
	local count = math.clamp(math.floor(distance / A.Spacing) + 1, 2, A.MaxSegments)
	setActiveCount(count)

	local positions: { Vector3 } = table.create(count)
	for i = 1, count do
		local t = (i - 1) / (count - 1)
		local pos = origin:Lerp(dest, t)
		positions[i] = pos
		segments[i].carrier.Position = pos
	end
	for i = 1, count do
		local nextPos = positions[i + 1] or dest
		local angle = screenAngle(camera, positions[i], nextPos)
		if angle then
			segments[i].glyph.Rotation = angle
		end
	end
end

-- Show the trail, (re)pointing at whatever `target()` returns each frame. Calling this again
-- while already shown just swaps the target getter — no flicker/rebuild.
function WorldArrow.Show(target: () -> Vector3?)
	getTarget = target
	if not heartbeatConn then
		heartbeatConn = RunService.Heartbeat:Connect(update)
	end
end

function WorldArrow.Hide()
	getTarget = nil
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
	for _, seg in segments do
		seg.carrier:Destroy()
	end
	table.clear(segments)
	activeCount = 0
end

function WorldArrow.IsShowing(): boolean
	return heartbeatConn ~= nil
end

return WorldArrow
