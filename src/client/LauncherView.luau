--!strict
-- Client: rotates the 3D launcher model to match this player's live aim. The launcher
-- swivels aim ± Arc around Angle as the phase runs 0→1 — the same geometry the server
-- fires with (ProfileStats.GetSwivelAngle). Visual only; the authoritative trajectory
-- is still the server's.
--
-- The swivel is rendered smoothly off the local clock, then periodically (and whenever
-- the profile changes, e.g. an upgrade purchase) resynced to the server's current
-- phase + the player's current Arc/Angle, so it stays aligned with real fire timing.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local Config = require(RS.Shared.Config)
local ProfileStats = require(RS.Shared.ProfileStats)

local LauncherView = {}

local Remote = RS:WaitForChild("Remote")
local GetProfileRF = Remote:WaitForChild("GetProfile") :: RemoteFunction
local ProfileChangedRE = Remote:WaitForChild("ProfileChanged") :: RemoteEvent
local GetLauncherPhaseRF = Remote:WaitForChild("GetLauncherPhase") :: RemoteFunction

local cfg = Config.Launcher
local PERIOD: number = cfg.RotationPeriod
local DEFAULT_Y: number = cfg.DefaultOrientation.Y
local MIN_Y: number = math.min(cfg.RightOrientation.Y, cfg.LeftOrientation.Y)
local MAX_Y: number = math.max(cfg.RightOrientation.Y, cfg.LeftOrientation.Y)

-- Live aim params (radians), kept in sync with the player's loadout.
local arc = 0
local aim = 0
-- Added to the local clock so our rendered phase matches the server's.
local phaseOffset = 0

local function applyProfile(profile: any)
	if profile and profile.loadout and profile.loadout.axes then
		arc = profile.loadout.axes.Arc or arc
		aim = profile.loadout.axes.Angle or aim
	end
end

-- Pull the server's current phase and offset our local clock to match it. Cheap RF;
-- the round-trip lag is a small constant the periodic resync keeps in check.
local function syncPhase()
	local ok, serverPhase = pcall(function()
		return GetLauncherPhaseRF:InvokeServer()
	end)
	if ok and type(serverPhase) == "number" then
		phaseOffset = (serverPhase * PERIOD - (os.clock() % PERIOD)) % PERIOD
	end
end

function LauncherView.Init()
	local model = cfg.Model :: Model?
	if not model then
		local functional = workspace:WaitForChild("Functional")
		model = functional:WaitForChild("Launcher") :: Model
	end
	local launcher = model :: Model
	local basePos = launcher:GetPivot().Position

	-- Seed aim + phase from the server, then track profile changes.
	applyProfile(GetProfileRF:InvokeServer())
	syncPhase()
	ProfileChangedRE.OnClientEvent:Connect(function(profile: any)
		-- An upgrade/loadout change: refresh aim and realign to the server's rotation.
		applyProfile(profile)
		syncPhase()
	end)

	-- Periodic resync to correct any drift from the free-running local clock.
	task.spawn(function()
		while true do
			task.wait(cfg.SyncInterval)
			syncPhase()
		end
	end)

	-- Smooth swivel each frame from the (offset-corrected) local clock.
	RunService.RenderStepped:Connect(function()
		local phase = ((os.clock() + phaseOffset) % PERIOD) / PERIOD
		local swivel = ProfileStats.GetSwivelAngle(arc, aim, phase)
		-- Default faces straight (Y = 90); the swivel deflects it. Sign chosen so a
		-- positive swivel aims right (toward Y = 0); flip it here if it reads mirrored.
		local y = math.clamp(DEFAULT_Y + math.deg(swivel), MIN_Y, MAX_Y)
		launcher:PivotTo(CFrame.new(basePos) * CFrame.fromOrientation(0, math.rad(y), 0))
	end)
end

return LauncherView
