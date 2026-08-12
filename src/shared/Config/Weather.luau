--!strict
-- Weather presets (WeatherService.SetWeather): each is a mood — a light Atmosphere/Lighting
-- fog/ambient touch (server-applied, tweened, replicates to every client for free since
-- Lighting and its children are networked instances), the ACTUAL skybox to show (see
-- Skyboxes below), and an optional falling-particle look the client renders overhead of the
-- local camera (WeatherController).
--
-- Atmosphere/Lighting deltas are deliberately subtle — nearly Clear — because the skybox
-- swap is what carries "the sky changed" now: Atmosphere is a volumetric 3D fog effect, so
-- cranking it up to visibly recolor the zenith also fogs out the ground at ground level,
-- which read as "impossible to see". A real Sky texture swap doesn't have that trade-off.
--
-- There is no "Clear" entry in Presets: WeatherService captures whatever's actually
-- authored in Lighting/Atmosphere at server startup as the Clear Atmosphere/Lighting
-- baseline, so this config never has to duplicate/guess the artist's mood tuning —
-- SetWeather("Clear") (or nil) just tweens back to that captured snapshot. The SKYBOX for
-- Clear, unlike the mood, IS an explicit reference (Skyboxes.Clear below) — Sky properties
-- (texture ids) aren't meaningfully "the current authored state to restore to" the way a
-- Brightness/Color number is; they're either the Clear skybox or a weather one.
--
-- PLACEHOLDER magnitudes — eyeballed against the currently-authored sky, not measured; tune
-- in playtest. Not wired to any gameplay trigger yet (see WeatherService's header).

export type AtmospherePreset = {
	Density: number,
	Offset: number,
	Color: Color3,
	Decay: Color3,
	Glare: number,
	Haze: number,
}

export type LightingPreset = {
	Brightness: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
	FogColor: Color3,
	FogStart: number,
	FogEnd: number,
}

export type ParticlePreset = {
	-- A real rbxasset:// id — a blank Texture renders as fully INVISIBLE (not a default dot,
	-- despite that being the intuitive assumption), so this must never be "".
	Texture: string,
	Color: Color3,
	Size: number, -- studs, base
	SizeVariance: number, -- +/- random spread around Size
	Speed: number, -- studs/sec falling
	SpeedVariance: number,
	Rate: number, -- particles/sec, tuned for the rig's footprint (see WeatherController)
	Lifetime: number, -- seconds; roughly RigHeight / Speed so particles despawn near the ground
	RotSpeed: number, -- degrees/sec tumble, 0 for none
	Transparency: number, -- base transparency (0 = opaque)
	Wind: Vector3?, -- constant sideways acceleration (studs/sec^2), nil = none
}

export type Preset = {
	Atmosphere: AtmospherePreset,
	Lighting: LightingPreset,
	Particle: ParticlePreset?, -- nil = no falling particles (fog/mood only)
}

local Weather = {
	-- Seconds to tween Atmosphere/Lighting between the current look and a newly-set preset
	-- (including back to Clear). The skybox swap itself is NOT tweened (Sky's texture ids
	-- aren't numeric — there's no in-between two skybox images — so WeatherService snaps it).
	TransitionTime = 5,

	-- Overhead particle rig (client-only geometry, shared by every preset that has a
	-- Particle look): a flat plane centered above the local CAMERA that continuously follows
	-- it, so falling weather always fills whatever's actually on screen without needing
	-- world-sized emitters. See WeatherController.
	RigHeight = 45, -- studs above the camera the emission plane sits
	RigSpan = 140, -- studs square the emission plane covers

	-- preset key -> the Sky instance under ServerStorage.Skyboxes to copy onto Lighting.Sky
	-- (WeatherService reads that instance's properties live, so re-authoring one of these in
	-- Studio needs no code change). Clear is listed explicitly too — see the header above for
	-- why the skybox doesn't use the same "capture the current state" trick Atmosphere/
	-- Lighting do.
	Skyboxes = {
		Clear = "Clear",
		Rain = "Rain",
		Snow = "Snow",
		AutumnLeaves = "Autumn",
	} :: { [string]: string },

	Presets = {
		Rain = {
			-- Barely off Clear (see header) — a faint cool damp cast, not a fog wall.
			Atmosphere = {
				Density = 0.35, Offset = 0.2,
				Color = Color3.fromRGB(160, 165, 175), Decay = Color3.fromRGB(90, 95, 105),
				Glare = 0, Haze = 0.5,
			},
			Lighting = {
				Brightness = 1.8,
				Ambient = Color3.fromRGB(8, 8, 10), OutdoorAmbient = Color3.fromRGB(60, 62, 68),
				FogColor = Color3.fromRGB(140, 144, 152), FogStart = 0, FogEnd = 6000,
			},
			Particle = {
				Texture = "rbxasset://textures/particles/sparkles_main.dds",
				Color = Color3.fromRGB(165, 185, 205),
				Size = 0.18, SizeVariance = 0.05,
				Speed = 95, SpeedVariance = 10,
				Rate = 760, -- 2x doubled (was 380)
				Lifetime = 1.1,
				RotSpeed = 0,
				Transparency = 0.3,
				Wind = nil,
			},
		} :: Preset,

		Snow = {
			Atmosphere = {
				Density = 0.38, Offset = 0.28,
				Color = Color3.fromRGB(210, 213, 220), Decay = Color3.fromRGB(120, 125, 135),
				Glare = 0.05, Haze = 0.8,
			},
			Lighting = {
				Brightness = 2.2,
				Ambient = Color3.fromRGB(12, 13, 15), OutdoorAmbient = Color3.fromRGB(90, 92, 98),
				FogColor = Color3.fromRGB(190, 194, 202), FogStart = 0, FogEnd = 5000,
			},
			Particle = {
				Texture = "rbxasset://textures/particles/sparkles_main.dds",
				Color = Color3.fromRGB(255, 255, 255),
				Size = 0.28, SizeVariance = 0.12,
				Speed = 14, SpeedVariance = 6,
				Rate = 260,
				Lifetime = 4.5,
				RotSpeed = 40,
				Transparency = 0.1,
				Wind = Vector3.new(3, 0, 1.5),
			},
		} :: Preset,

		AutumnLeaves = {
			Atmosphere = {
				Density = 0.34, Offset = 0.22,
				Color = Color3.fromRGB(205, 190, 165), Decay = Color3.fromRGB(120, 105, 80),
				Glare = 0.03, Haze = 0.4,
			},
			Lighting = {
				Brightness = 2.05,
				Ambient = Color3.fromRGB(15, 10, 5), OutdoorAmbient = Color3.fromRGB(85, 78, 65),
				FogColor = Color3.fromRGB(180, 165, 135), FogStart = 0, FogEnd = 6000,
			},
			Particle = {
				Texture = "rbxasset://textures/particles/sparkles_main.dds",
				Color = Color3.fromRGB(196, 120, 50),
				Size = 0.35, SizeVariance = 0.15,
				Speed = 8, SpeedVariance = 4,
				Rate = 140,
				Lifetime = 6,
				RotSpeed = 90,
				Transparency = 0.05,
				Wind = Vector3.new(4, 0, 2.5),
			},
		} :: Preset,
	} :: { [string]: Preset },
}

for _, preset in (Weather.Presets :: { [string]: Preset }) do
	table.freeze(preset.Atmosphere)
	table.freeze(preset.Lighting)
	if preset.Particle then
		table.freeze(preset.Particle :: ParticlePreset)
	end
	table.freeze(preset)
end
table.freeze(Weather.Presets)
table.freeze(Weather.Skyboxes)
table.freeze(Weather)

return Weather
