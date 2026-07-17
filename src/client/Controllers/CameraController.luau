--!strict
-- Client camera controller. Switches between Roblox's default character camera and
-- fixed scripted shots defined in Config (each { Position, Orientation, FieldOfView }):
--   * board view  — a nicer angle on the marble board (CameraConfig.BoardView), toggled by UI.
--   * tuning view  — CameraConfig.BallTuning, shown while the ball-tuning menu is open.
--
-- Both are independent requests; the tuning view takes priority while active, and
-- closing it falls back to the board view (if on) or the default Custom camera.

local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local CameraConfig = require(RS.Shared.Config.Camera)
local CameraController = {}

local DEFAULT_FOV = 70
local TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local boardView = false
local tuningView = false
local activeTween: Tween? = nil

type Shot = { Position: Vector3, Orientation: Vector3, FieldOfView: number? }

-- An explicit one-off shot (e.g. a tutorial step) that overrides board/tuning while set.
local tutorialShot: Shot? = nil

-- A configured shot as a CFrame. Orientation is in degrees, applied in the same
-- Y,X,Z order as a Part's Orientation property (CFrame.fromOrientation).
local function cframeFor(shot: Shot): CFrame
	local o = shot.Orientation
	return CFrame.new(shot.Position)
		* CFrame.fromOrientation(math.rad(o.X), math.rad(o.Y), math.rad(o.Z))
end

-- The shot that should currently be showing (tutorial wins over tuning over board), or nil
-- for the default Custom camera.
local function activeShot(): Shot?
	if tutorialShot then
		return tutorialShot
	elseif tuningView then
		return CameraConfig.BallTuning
	elseif boardView then
		return CameraConfig.BoardView
	end
	return nil
end

-- Apply whichever shot is active (or hand back to the Custom camera).
local function refresh()
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end

	local shot = activeShot()
	if shot then
		-- Must be Scriptable before tweening CFrame, or Custom would fight the tween.
		cam.CameraType = Enum.CameraType.Scriptable
		activeTween = TweenService:Create(cam, TWEEN_INFO, {
			CFrame = cframeFor(shot),
			FieldOfView = shot.FieldOfView or DEFAULT_FOV,
		})
		activeTween:Play()
	else
		-- Handing back to Custom snaps to the character; restore the default FOV too.
		cam.FieldOfView = DEFAULT_FOV
		cam.CameraType = Enum.CameraType.Custom
	end
end

-- Switch the board view on or off.
function CameraController.SetBoardView(enabled: boolean)
	boardView = enabled
	refresh()
end

-- Switch the ball-tuning view on or off (driven by the tuning menu open/close).
function CameraController.SetTuningView(enabled: boolean)
	tuningView = enabled
	refresh()
end

-- Set (or clear, with nil) a one-off scripted shot that overrides the other views while
-- active. Smoothly tweens like the rest; nil falls back to tuning/board/Custom. Used by the
-- tutorial to move the camera per step.
function CameraController.SetTutorialView(shot: Shot?)
	tutorialShot = shot
	refresh()
end

-- Flip the board view. Returns the new state.
function CameraController.Toggle(): boolean
	boardView = not boardView
	refresh()
	return boardView
end

function CameraController.IsBoardView(): boolean
	return boardView
end

function CameraController.Init()
	-- A CurrentCamera swap (e.g. respawn) resets to Custom, so drop our view state.
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		boardView = false
		tuningView = false
		tutorialShot = nil
	end)
end

return CameraController
