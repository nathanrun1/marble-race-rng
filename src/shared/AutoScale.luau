--!strict
-- UI autoscaler. Any GuiObject either tagged Config.Tags.AutoScale or passed to
-- AutoScale.Apply gets a UIScale whose Scale tracks the viewport size relative to a
-- 1080p reference, so UI authored at 1080p stays proportional on other resolutions.
--
--   Scale = min(viewport.X / REF.X, viewport.Y / REF.Y)
--
-- The min of the two axis ratios fits the element to the smaller axis (never
-- overflowing either dimension).
--
-- Shared so non-client modules (BallEffects popups, ScoreUI) can call Apply on the
-- UI they build; the scaling itself is driven by the local viewport, so it only does
-- meaningful work on a client (on the server there is no camera and Scale stays 1).

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

-- The current viewport scale factor vs the 1080p reference (same value driven into every
-- tracked UIScale). Lets callers scale their own 1080p-authored offsets to match AutoScaled
-- UI (e.g. the tutorial highlight rect).
function AutoScale.GetScale(): number
	return currentScale()
end

local function untrack(inst: Instance)
	if inst:IsA("GuiObject") then
		tracked[inst] = nil
	end
end

-- Register a UIScale on `inst` and drive it. Cleaned up when the element is
-- destroyed so short-lived UI (popups) doesn't leak into `tracked`.
local function register(inst: GuiObject, uiScale: UIScale)
	uiScale.Scale = currentScale()
	uiScale.Parent = inst
	tracked[inst] = uiScale
	inst.Destroying:Connect(function()
		untrack(inst)
	end)
end

-- Tag-driven tracking: reuse an authored UIScale if present, otherwise insert one.
-- (No error on an existing UIScale here — tagged UI is authored knowing this reuse.)
local function track(inst: Instance)
	if not inst:IsA("GuiObject") then
		return
	end
	if tracked[inst] then
		tracked[inst].Scale = currentScale()
		return
	end
	local uiScale = inst:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	register(inst, uiScale)
end

-- Manually autoscale a single element (for UI built in code, e.g. popups). Unlike
-- the tag path this refuses to clobber an existing UIScale: combining our viewport
-- scale with an author's own UIScale would compound unpredictably, so we surface it
-- loudly and let the caller decide how to handle that (rare) case by hand.
function AutoScale.Apply(inst: GuiObject): UIScale
	if inst:FindFirstChildOfClass("UIScale") then
		error(
			("AutoScale.Apply: %s already has a UIScale; manual autoscale can't safely combine with it")
				:format(inst:GetFullName()),
			2
		)
	end
	local uiScale = Instance.new("UIScale")
	register(inst, uiScale)
	return uiScale
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
	-- Tag handling only makes sense on a client (it drives off the local viewport).
	if not Players.LocalPlayer then
		return
	end

	for _, inst in CollectionService:GetTagged(TAG) do
		track(inst)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(untrack)

	bindCamera()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindCamera)
end

return AutoScale
