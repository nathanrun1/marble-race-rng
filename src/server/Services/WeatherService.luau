--!strict
-- Global weather system: swaps Lighting/Atmosphere between mood presets (Config/Weather),
-- snaps Lighting.Sky to match a real pre-authored skybox (ServerStorage.Skyboxes), and tells
-- clients which preset is active so they can render the matching falling-particle look
-- (WeatherController). Server-authoritative and global (one weather for the whole server,
-- like DayNightService's ClockTime) — Lighting and its children are networked instances, so
-- setting them here replicates to every client for free; WeatherNet only carries the preset
-- NAME (needed for the particle look, which isn't an instance property).
--
-- STANDALONE FOR NOW: nothing calls WeatherService.SetWeather yet — this just stands the
-- system up (baseline capture, tween machinery, replication) so a future trigger (a zone, a
-- time-of-day hook, a random event, an ops lever) can flip the weather with one call. A
-- `/weather <name|clear>` dev command is wired for manual testing in the meantime
-- (DevService) — that's a debug pathway, not a gameplay integration.

local RS = game:GetService("ReplicatedStorage")
local SS = game:GetService("ServerStorage")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local WeatherConfig = require(RS.Shared.Config.Weather)
local WeatherNet = require(RS.Shared.Remote.WeatherNet)

local WeatherService = {}

-- Sky properties copied wholesale from a ServerStorage.Skyboxes reference onto Lighting.Sky.
-- Snapped, never tweened — texture ids aren't numeric, so there's no in-between look.
local SKY_PROPS = {
	"SkyboxBk", "SkyboxDn", "SkyboxFt", "SkyboxLf", "SkyboxRt", "SkyboxUp",
	"SkyboxOrientation",
	"SunAngularSize", "SunTextureId",
	"MoonAngularSize", "MoonTextureId",
	"StarCount", "CelestialBodiesShown",
}

local atmosphere: Atmosphere? = nil
local sky: Sky? = nil
local skyboxesFolder: Instance? = nil
local current: string? = nil -- nil = Clear
local changedRE: RemoteEvent? = nil

-- Captured from whatever's actually authored in Lighting/Atmosphere at Init — the restore
-- target for "Clear" (see Config/Weather's header for why the SKYBOX doesn't use this same
-- capture trick — that's an explicit ServerStorage.Skyboxes.Clear reference instead).
local baseline: {
	Atmosphere: WeatherConfig.AtmospherePreset,
	Lighting: WeatherConfig.LightingPreset,
}? = nil

-- Every tween from the transition currently in flight; cancelled (not snapped) by the next
-- SetWeather, so back-to-back changes blend from wherever the sky actually is.
local activeTweens: { Tween } = {}

local function stopActiveTweens()
	for _, tw in activeTweens do
		tw:Cancel()
	end
	table.clear(activeTweens)
end

local function tweenTo(atmo: WeatherConfig.AtmospherePreset, light: WeatherConfig.LightingPreset)
	stopActiveTweens()
	local info = TweenInfo.new(WeatherConfig.TransitionTime, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	if atmosphere then
		local tw = TweenService:Create(atmosphere, info, {
			Density = atmo.Density,
			Offset = atmo.Offset,
			Color = atmo.Color,
			Decay = atmo.Decay,
			Glare = atmo.Glare,
			Haze = atmo.Haze,
		})
		table.insert(activeTweens, tw)
		tw:Play()
	end
	local lightTw = TweenService:Create(Lighting, info, {
		Brightness = light.Brightness,
		Ambient = light.Ambient,
		OutdoorAmbient = light.OutdoorAmbient,
		FogColor = light.FogColor,
		FogStart = light.FogStart,
		FogEnd = light.FogEnd,
	})
	table.insert(activeTweens, lightTw)
	lightTw:Play()
end

-- Copy every SKY_PROPS field from ServerStorage.Skyboxes[boxName] onto the live Lighting.Sky.
-- A missing reference (folder or the named child) just no-ops — better a stale skybox than an
-- error, and it's easy to notice/fix by adding the missing Sky in Studio.
local function applySkybox(boxName: string)
	local s = sky
	local folder = skyboxesFolder
	if not (s and folder) then
		return
	end
	local source = folder:FindFirstChild(boxName)
	if not (source and source:IsA("Sky")) then
		warn("WeatherService: ServerStorage.Skyboxes." .. boxName .. " is missing or not a Sky — skybox unchanged")
		return
	end
	for _, prop in SKY_PROPS do
		(s :: any)[prop] = (source :: any)[prop]
	end
end

-- Switch the whole server to `name` (a Config/Weather.Presets key), or nil/"Clear" to tween
-- the mood back to the baseline captured at Init and snap the skybox to
-- ServerStorage.Skyboxes.Clear. Returns false for an unknown name (no-op, current weather
-- unchanged).
function WeatherService.SetWeather(name: string?): boolean
	local key = if name and name ~= "Clear" then name else nil
	if key and not WeatherConfig.Presets[key] then
		return false
	end
	current = key
	local boxName = WeatherConfig.Skyboxes[key or "Clear"]
	if boxName then
		applySkybox(boxName)
	end
	if key then
		local preset = WeatherConfig.Presets[key]
		tweenTo(preset.Atmosphere, preset.Lighting)
	elseif baseline then
		tweenTo(baseline.Atmosphere, baseline.Lighting)
	end
	if changedRE then
		changedRE:FireAllClients(current)
	end
	return true
end

-- nil means Clear.
function WeatherService.GetWeather(): string?
	return current
end

function WeatherService.Init()
	changedRE = WeatherNet.WeatherChanged
	;WeatherNet.GetWeather.OnServerInvoke = function(_player: Player)
		return WeatherService.GetWeather()
	end

	skyboxesFolder = SS:FindFirstChild("Skyboxes")

	-- Reuse the authored Atmosphere/Sky (both exist in this place — see Config/Weather's
	-- header); create either otherwise so every preset has something to apply onto.
	local existingAtmo = Lighting:FindFirstChildOfClass("Atmosphere")
	if not existingAtmo then
		existingAtmo = Instance.new("Atmosphere")
		existingAtmo.Parent = Lighting
	end
	atmosphere = existingAtmo

	local existingSky = Lighting:FindFirstChildOfClass("Sky")
	if not existingSky then
		existingSky = Instance.new("Sky")
		existingSky.Parent = Lighting
	end
	sky = existingSky

	baseline = {
		Atmosphere = {
			Density = existingAtmo.Density,
			Offset = existingAtmo.Offset,
			Color = existingAtmo.Color,
			Decay = existingAtmo.Decay,
			Glare = existingAtmo.Glare,
			Haze = existingAtmo.Haze,
		},
		Lighting = {
			Brightness = Lighting.Brightness,
			Ambient = Lighting.Ambient,
			OutdoorAmbient = Lighting.OutdoorAmbient,
			FogColor = Lighting.FogColor,
			FogStart = Lighting.FogStart,
			FogEnd = Lighting.FogEnd,
		},
	}
end

return WeatherService
