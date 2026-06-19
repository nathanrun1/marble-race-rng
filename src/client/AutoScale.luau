--!strict
-- Client UI autoscaler. Any GuiObject tagged Config.Tags.AutoScale gets a UIScale
-- whose Scale tracks the viewport size relative to a 1080p reference, so UI
-- authored at 1080p stays proportional on other resolutions.
--
--   Scale = min(viewport.X / REF.X, viewport.Y / REF.Y)
--
-- The min of the two axis ratios fits the element to the smaller axis (never
-- overflowing either dimension). An existing UIScale on the element is reused and
-- overwritten; otherwise one is inserted.

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local RS = game:GetService("ReplicatedStorage")

local Config = require(RS.Shared.Config)

local AutoScale = {}

-- Reference resolution the UI is authored against (1080p). All scaling is relative
-- to this; at exactly 1920×1080 the scale is 1.
local REF_RESOLUTION = Vector2.new(1920, 1080)
local TAG = Config.Tags.AutoScale

-- element -> the UIScale we drive for it
local tracked: { [GuiObject]: UIScale } = {}

-- The smaller axis ratio vs the 1080p reference (<1 shrinks, >1 grows).
local function currentScale(): number
	local cam = workspace.CurrentCamera
	if not cam then
		return 1
	end
	local vp = cam.ViewportSize
	if vp.X <= 0 or vp.Y <= 0 then
		return 1
	end
	return math.min(vp.X / REF_RESOLUTION.X, vp.Y / REF_RESOLUTION.Y)
end

-- Ensure+drive the element's UIScale (reusing an authored one if present).
local function track(inst: Instance)
	if not inst:IsA("GuiObject") then
		return
	end
	local uiScale = tracked[inst]
	if not uiScale or uiScale.Parent ~= inst then
		uiScale = inst:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
		uiScale.Parent = inst
		tracked[inst] = uiScale
	end
	uiScale.Scale = currentScale()
end

local function untrack(inst: Instance)
	if inst:IsA("GuiObject") then
		tracked[inst] = nil
	end
end

-- Push the current scale to every tracked element (on viewport / camera change).
local function refreshAll()
	local scale = currentScale()
	for _, uiScale in tracked do
		uiScale.Scale = scale
	end
end

-- Viewport changes (and CurrentCamera swaps) drive a full refresh.
local cameraConn: RBXScriptConnection? = nil
local function bindCamera()
	if cameraConn then
		cameraConn:Disconnect()
		cameraConn = nil
	end
	local cam = workspace.CurrentCamera
	if cam then
		cameraConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(refreshAll)
	end
	refreshAll()
end

function AutoScale.Init()
	for _, inst in CollectionService:GetTagged(TAG) do
		track(inst)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(untrack)

	bindCamera()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindCamera)
end

return AutoScale
