--!strict
-- Client: while the ball-tuning menu is open, previews the player's aim and ball.
--   * Three semi-transparent aim lines from the launch origin — green for the centre
--     aim, blue for the two arc extremes (aim ± Arc).
--   * An appearance-only ball to the right of the launcher that reflects the Size and
--     Elasticity axes (size scales it; elasticity drives the weight-based material via
--     BallEffects).
-- Everything updates live on profile (tuning) changes. Driven show/hide by BallTuningUI.
--
-- Launch geometry (origin + base aim direction) is shared with the server via
-- LauncherConfig, so the lines point exactly where balls actually launch.

local RS = game:GetService("ReplicatedStorage")

local BallConfig = require(RS.Shared.Config.Ball)
local BallTuningPreviewConfig = require(RS.Shared.Config.BallTuningPreview)
local LauncherConfig = require(RS.Shared.Config.Launcher)
local TagsConfig = require(RS.Shared.Config.Tags)
local BallEffects = require(RS.Shared.BallEffects)
local BallSkins = require(RS.Shared.BallSkins)
local CosmeticsNet = require(RS.Shared.Remote.CosmeticsNet)
local ProfileNet = require(RS.Shared.Remote.ProfileNet)

local BallTuningPreview = {}

local GetProfileRF = ProfileNet.GetProfile :: RemoteFunction
local ProfileChangedRE = ProfileNet.ProfileChanged :: RemoteEvent

local cfg = BallTuningPreviewConfig
local launcherCfg = LauncherConfig

-- Live axis values from the profile (radians for Arc/Angle).
local arc = 0
local aim = 0
local size = 1
local elasticity = 0.5
local equippedSkinId = BallSkins.GetDefaultId()  -- cosmetic shown on the preview ball

local visible = false

-- Built lazily; held in a folder we parent into / out of workspace to show / hide.
local container: Folder? = nil
local centerLine: BasePart? = nil
local leftLine: BasePart? = nil
local rightLine: BasePart? = nil
local previewBall: BasePart? = nil
local baseBallSize: Vector3 = Vector3.one

-- Down-ramp base aim rotated about +Y by `swivel` — the same op the server fires with.
local function dirFor(swivel: number): Vector3
	return CFrame.fromAxisAngle(Vector3.yAxis, swivel):VectorToWorldSpace(launcherCfg.BaseDirection).Unit
end

local function makeLine(color: Color3): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = cfg.LineTransparency
	p.Size = Vector3.new(cfg.LineThickness, cfg.LineThickness, cfg.LineLength)
	return p
end

-- Lay a line from the launch origin out along `dir`. The part's length is its Z; we
-- look down `dir` and push forward half the length, so it spans origin → origin+dir·L.
local function positionLine(line: BasePart, dir: Vector3)
	local origin = launcherCfg.LaunchOrigin
	line.CFrame = CFrame.lookAt(origin, origin + dir) * CFrame.new(0, 0, -cfg.LineLength / 2)
end

local function build()
	if container then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "BallTuningPreview"

	centerLine = makeLine(cfg.CenterColor)
	leftLine = makeLine(cfg.SideColor)
	rightLine = makeLine(cfg.SideColor)
	;(centerLine :: BasePart).Parent = folder
	;(leftLine :: BasePart).Parent = folder
	;(rightLine :: BasePart).Parent = folder

	local ball = BallConfig.Prefab:Clone() :: BasePart
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball:RemoveTag(TagsConfig.Ball) -- appearance only; never a real (scored/hideable) ball
	baseBallSize = ball.Size
	ball.Parent = folder
	previewBall = ball

	container = folder
end

local function updateLines()
	local c, l, r = centerLine, leftLine, rightLine
	if not (c and l and r) then
		return
	end
	positionLine(c, dirFor(aim))
	positionLine(r, dirFor(aim + arc))
	positionLine(l, dirFor(aim - arc))
end

local function updateBall()
	local ball = previewBall
	if not ball then
		return
	end
	ball.CFrame = CFrame.new(cfg.BallPosition)
	-- One shared path for size, elasticity→material, and the equipped cosmetic (skin + particles).
	BallEffects.ApplyAppearance(ball, {
		skinId = equippedSkinId,
		weight = 1 - elasticity,
		sizeScale = size,
		baseSize = baseBallSize,
		heat = 0,
	})
end

local function refresh()
	if not visible then
		return
	end
	updateLines()
	updateBall()
end

local function applyProfile(profile: any)
	if not (profile and profile.loadout and profile.loadout.axes) then
		return
	end
	local axes = profile.loadout.axes
	arc = axes.Arc or arc
	aim = -(axes.Angle or aim)
	size = axes.Size or size
	elasticity = axes.Elasticity or elasticity
	refresh()
end

-- Show / hide the preview (called by the tuning menu).
function BallTuningPreview.SetVisible(show: boolean)
	visible = show
	if show then
		build()
		;(container :: Folder).Parent = workspace
		refresh()
	elseif container then
		container.Parent = nil
	end
end

function BallTuningPreview.Init()
	applyProfile(GetProfileRF:InvokeServer())
	ProfileChangedRE.OnClientEvent:Connect(applyProfile)

	-- Show the equipped cosmetic on the preview ball too, kept in sync with the cosmetics shop.
	local cosmeticChanged = CosmeticsNet.CosmeticChanged
	if cosmeticChanged and cosmeticChanged:IsA("RemoteEvent") then
		cosmeticChanged.OnClientEvent:Connect(function(info: any)
			if info and type(info.equipped) == "string" then
				equippedSkinId = info.equipped
				refresh()
			end
		end)
	end
	local getInfo = CosmeticsNet.GetCosmeticInfo
	if getInfo and getInfo:IsA("RemoteFunction") then
		local info = getInfo:InvokeServer()
		if info and type(info.equipped) == "string" then
			equippedSkinId = info.equipped
			refresh()
		end
	end
end

return BallTuningPreview
