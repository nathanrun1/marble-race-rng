--!strict
-- Shared sound playback. Required by both server and client.
--
-- A sound is described by a SoundSpec; `position` decides 2D vs 3D:
--   * position == nil  → global 2D sound (same volume everywhere).
--   * position ~= nil  → positional 3D sound, audible/attenuated from that world
--                        point (parented to a throwaway Attachment there).
--
-- Playback always happens on a CLIENT (Roblox renders 3D audio per-listener).
--   * Client: SoundService.Play(spec)                 — play for myself.
--   * Server: SoundService.PlayForClient(player, spec) — play on one client.
--             SoundService.PlayForAll(spec)            — play on every client.
-- The server calls fan out over a RemoteEvent; each client runs Play(spec).
--
-- Fire-and-forget: the Sound (and any positional holder) is cleaned up once it
-- finishes, so callers never manage instances.

local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local SoundSrv = game:GetService("SoundService")

local Config = require(RS.Shared.Config)

local SoundService = {}

-- One sound to play. soundId is a "rbxassetid://..." (or asset URL) string.
export type SoundSpec = {
	soundId: string,
	position: Vector3?,    -- nil = global 2D; else a world position for 3D audio
	volume: number?,       -- default 0.5
	pitch: number?,        -- PlaybackSpeed, default 1
	rollOffMinDistance: number?, -- 3D only: full volume within this radius
	rollOffMaxDistance: number?, -- 3D only: inaudible beyond this radius
	offset: number?,       -- Sound start offset in seconds
	jitter: number?,       -- random ±fraction applied to pitch (e.g. 0.06 = ±3%);
	                       -- keeps rapid retriggers of the same sound audibly distinct
	loop: boolean?         -- play on repeat; the returned Sound must be stopped by the
	                       -- caller (it never auto-recycles). nil/false = one-shot.
}

local DEFAULT_VOLUME = 0.5
-- Safety net: if a sound never fires Ended (e.g. the asset fails to load), reclaim
-- it anyway. Comfortably longer than any SFX we play.
local MAX_LIFETIME = 60

-- When true, every Play() sound is forced to volume 0 (the "mute SFX" toggle).
-- Background music goes through SetBackgroundMusic, not Play(), so it's unaffected.
local sfxMuted = false

-- Idle sounds are pooled and reused rather than destroyed after each play. Once
-- the last instance of a SoundId is destroyed, Roblox can evict its audio data, so
-- the next fresh instance has to reload it — that reload latency is what makes a
-- spammed sound stutter (some plays land late, others on time). Keeping pooled
-- instances alive holds the asset resident and keeps latency flat. Overlap still
-- works: concurrent plays each take or create their own instance.
local MAX_POOL_PER_ID = 16
local POOL_HOLDER = Instance.new("Folder")
POOL_HOLDER.Name = "SoundPool"
POOL_HOLDER.Parent = SoundSrv

-- soundId -> stack of idle (stopped, resident) Sound instances available for reuse
local idle: { [string]: { Sound } } = {}

----------------------------------------------------------------------------------
-- Local playback (runs in the calling context; meant for the client)
----------------------------------------------------------------------------------

-- Take an idle instance for this id, or make one. New instances are parented to
-- the pool holder and keep their SoundId, so the asset stays loaded for reuse.
local function acquire(soundId: string): Sound
	local bucket = idle[soundId]
	if bucket then
		local pooled = table.remove(bucket)
		if pooled then
			return pooled
		end
	end
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Parent = POOL_HOLDER
	return sound
end

-- Stop and return an instance to its idle pool (or destroy it if the pool is full).
local function release(sound: Sound)
	sound:Stop()
	sound.Parent = POOL_HOLDER
	local bucket = idle[sound.SoundId]
	if not bucket then
		bucket = {}
		idle[sound.SoundId] = bucket
	end
	if #bucket < MAX_POOL_PER_ID then
		table.insert(bucket, sound)
	else
		sound:Destroy()
	end
end

-- Apply the per-play (transient) properties. SoundId is owned by acquire and never
-- reassigned here — reassigning would re-trigger a load on a reused instance.
local function applyCommon(sound: Sound, spec: SoundSpec)
	sound.Volume = if sfxMuted then 0 else (spec.volume or DEFAULT_VOLUME)
	local pitch = spec.pitch or 1
	if spec.jitter then
		-- ±jitter fraction around the base pitch, so overlapping copies of the same
		-- sound don't land sample-aligned (which reads as not stacking).
		pitch *= 1 + (math.random() * 2 - 1) * spec.jitter
	end
	sound.PlaybackSpeed = pitch
	sound.TimePosition = spec.offset or 0
end

-- Play a single sound described by `spec`, reusing a pooled instance. Positional
-- sounds ride a temporary Attachment at `spec.position`; global sounds play flat
-- 2D from the pool holder. The instance returns to the pool when it finishes.
function SoundService.Play(spec: SoundSpec): Sound
	local sound = acquire(spec.soundId)
	applyCommon(sound, spec)
	sound.Looped = spec.loop or false

	local attachment: Attachment? = nil
	if spec.position then
		attachment = Instance.new("Attachment")
		attachment.WorldPosition = spec.position
		attachment.Parent = workspace.Terrain
		sound.RollOffMinDistance = spec.rollOffMinDistance or 10
		sound.RollOffMaxDistance = spec.rollOffMaxDistance or 10000
		sound.Parent = attachment
	else
		sound.Parent = POOL_HOLDER
	end

	-- Looped sounds never end, so they don't auto-recycle: the caller owns the
	-- returned instance and stops it (which recycles it via release()). One-shots
	-- recycle themselves on Ended, with MAX_LIFETIME as a load-failure fallback.
	if not spec.loop then
		local finished = false
		local function finish()
			if finished then
				return
			end
			finished = true
			release(sound)               -- reparents out of the attachment first
			if attachment then
				attachment:Destroy()
			end
		end

		sound.Ended:Once(finish)
		task.delay(MAX_LIFETIME, finish) -- fallback if Ended never fires
	end

	sound:Play()
	return sound
end

-- Optional: warm the audio cache (and seed the pool) for a set of sound ids so the
-- very first play has no load latency. Yields; call on the CLIENT from a
-- non-critical path (e.g. right after Init).
function SoundService.Preload(soundIds: { string })
	local ContentProvider = game:GetService("ContentProvider")
	local sounds = {}
	for _, id in soundIds do
		table.insert(sounds, acquire(id))
	end
	ContentProvider:PreloadAsync(sounds)
	for _, sound in sounds do
		release(sound)
	end
end

----------------------------------------------------------------------------------
-- Background music + mute toggles (run in the calling context; meant for the client)
----------------------------------------------------------------------------------

local MUSIC_VOLUME = 0.2
-- The single looping background track, managed independently of the SFX pool so it
-- can be replaced/stopped and muted separately from one-shot sounds.
local backgroundMusic: Sound? = nil
local musicMuted = false

-- Play `soundId` on loop as the background track, replacing whatever SetBackgroundMusic
-- was already playing. Self-contained (not routed through Play), so the SFX mute never
-- touches it. An empty id just clears the current track (e.g. unset Config.Sounds.Music).
function SoundService.SetBackgroundMusic(soundId: string)
	SoundService.StopBackgroundMusic()
	if soundId == "" then
		return
	end
	local sound = Instance.new("Sound")
	sound.Name = "BackgroundMusic"
	sound.SoundId = soundId
	sound.Looped = true
	sound.Volume = if musicMuted then 0 else MUSIC_VOLUME
	sound.Parent = POOL_HOLDER
	backgroundMusic = sound
	sound:Play()
end

-- Stop and clear the current background track (no-op if none is playing).
function SoundService.StopBackgroundMusic()
	if backgroundMusic then
		backgroundMusic:Stop()
		backgroundMusic:Destroy()
		backgroundMusic = nil
	end
end

-- Music mute toggle: silences the background track in place (keeps it playing/in sync
-- so unmuting resumes seamlessly), rather than stopping it. For the music mute button.
function SoundService.SetMusicMuted(muted: boolean)
	musicMuted = muted
	if backgroundMusic then
		backgroundMusic.Volume = if muted then 0 else MUSIC_VOLUME
	end
end

function SoundService.IsMusicMuted(): boolean
	return musicMuted
end

-- SFX mute toggle: forces every Play() sound to volume 0 (see applyCommon). Does not
-- affect background music. For the (ball-effects / SFX) sound mute button.
function SoundService.SetSFXMuted(muted: boolean)
	sfxMuted = muted
end

function SoundService.IsSFXMuted(): boolean
	return sfxMuted
end

----------------------------------------------------------------------------------
-- Server-only: fan a Play(spec) out to clients over a RemoteEvent
----------------------------------------------------------------------------------
if RunService:IsServer() then
	local soundRemote: RemoteEvent? = nil

	-- Play `spec` on a single client.
	function SoundService.PlayForClient(player: Player, spec: SoundSpec)
		(soundRemote :: RemoteEvent):FireClient(player, spec)
	end

	-- Play `spec` on every client.
	function SoundService.PlayForAll(spec: SoundSpec)
		(soundRemote :: RemoteEvent):FireAllClients(spec)
	end

	function SoundService.Init()
		local re = Instance.new("RemoteEvent")
		re.Name = "PlaySound"
		re.Parent = RS.Remote
		soundRemote = re
	end
end

----------------------------------------------------------------------------------
-- Client-only: receive server play requests and run them locally
----------------------------------------------------------------------------------
if RunService:IsClient() then
	function SoundService.Init()
		local remote = RS.Remote:WaitForChild("PlaySound") :: RemoteEvent
		remote.OnClientEvent:Connect(function(spec: SoundSpec)
			SoundService.Play(spec)
		end)

		-- Warm the cache + seed the pool for every Config.Sounds entry so the first
		-- play of each is latency-free. PreloadAsync yields, so do it off-thread.
		task.spawn(function()
			local ids = {}
			for _, soundId in Config.Sounds do
				table.insert(ids, soundId)
			end
			SoundService.Preload(ids)
		end)
	end
end

return SoundService
