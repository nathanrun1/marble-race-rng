--!strict
-- Client camera controller. Lets the player toggle between Roblox's default
-- character camera and a fixed "board view" — a nicer angle on the marble board,
-- defined by Config.Camera (Position / Orientation / FieldOfView).
--
-- Board view sets the camera Scriptable and tweens to the configured shot; toggling
-- off restores the default Custom camera. Wire a UI button to CameraService.Toggle.

local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(RS.Shared.Config)

local CameraService = {}

local DEFAULT_FOV = 70
local TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local boardView = false
local activeTween: Tween? = nil

-- The configured board shot as a CFrame. Orientation is in degrees, applied in the
-- same Y,X,Z order as a Part's Orientation property (CFrame.fromOrientation).
local function boardCFrame(): CFrame
	local o = Config.Camera.Orientation
	return CFrame.new(Config.Camera.Position)
		* CFrame.fromOrientation(math.rad(o.X), math.rad(o.Y), math.rad(o.Z))
end

-- Switch the board view on or off.
function CameraService.SetBoardView(enabled: boolean)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	boardView = enabled

	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end

	if enabled then
		-- Must be Scriptable before tweening CFrame, or Custom would fight the tween.
		cam.CameraType = Enum.CameraType.Scriptable
		activeTween = TweenService:Create(cam, TWEEN_INFO, {
			CFrame = boardCFrame(),
			FieldOfView = Config.Camera.FieldOfView or DEFAULT_FOV,
		})
		activeTween:Play()
	else
		-- Handing back to Custom snaps to the character; restore the default FOV too.
		cam.FieldOfView = DEFAULT_FOV
		cam.CameraType = Enum.CameraType.Custom
	end
end

-- Flip between board view and default. Returns the new state.
function CameraService.Toggle(): boolean
	CameraService.SetBoardView(not boardView)
	return boardView
end

function CameraService.IsBoardView(): boolean
	return boardView
end

function CameraService.Init()
	-- Nothing to wire yet; the board view is driven by Toggle/SetBoardView from UI.
	-- A CurrentCamera swap (e.g. respawn) resets to Custom, which clears board view.
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		boardView = false
	end)
end

return CameraService
