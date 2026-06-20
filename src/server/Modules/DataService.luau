--!strict
-- Persists per-player Currency, Profile, and Prestige to a DataStore, and owns the
-- player-data lifecycle (the data services are passive: ApplyData / SerializeData /
-- Clear, no PlayerAdded/Removing of their own).
--
-- Join:  seed every service with defaults immediately (so nothing observes a player
--        with no data while we load), then async-load the saved blob and overlay it.
-- Leave / shutdown: gather each service's slice and write it back.
--
-- Session locking: each key carries a lock { owner, time }. On load we claim it via
-- UpdateAsync; if another live session holds it we retry, and kick if it never frees
-- (prevents two servers writing the same player and duplicating/clobbering data). A
-- lock older than LOCK_STALE is considered abandoned (crashed server) and reclaimed.
-- Normal leave/shutdown releases the lock; autosave refreshes its timestamp.
--
-- Autosave: every AUTOSAVE_INTERVAL seconds each loaded player is written back (lock
-- kept), so a server crash loses at most that interval of progress.
--
-- Robustness: DataStore calls are pcall-wrapped with retry. A player is only saved
-- once their load succeeded, so a transient failure can't clobber real data with
-- defaults. Studio is skipped by default — flip PERSIST_IN_STUDIO to test.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local SSS = game:GetService("ServerScriptService")

local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local PrestigeService = require(SSS.Scripts.Modules.PrestigeService)

local DataService = {}

local STORE_NAME = "PlayerData_v1"
local KEY_PREFIX = "player_"
local MAX_TRIES = 4               -- retries for a save/release op
local LOCK_STALE = 600            -- seconds before a lock is taken with no handshake (clearly abandoned)
local LOCK_TRIES = 6              -- re-acquire attempts on a DataStore error before giving up
local LOCK_RETRY_WAIT = 4         -- seconds between those error retries
local AUTOSAVE_INTERVAL = 120     -- seconds between background saves
local PERSIST_IN_STUDIO = false
local LOCK_FAIL_MESSAGE = "Couldn't load your save data (the data service is unavailable). Please rejoin in a moment."

-- Crash detection via handshake: a new session asks the current lock owner to
-- release; a live server answers within HANDSHAKE_GRACE, a crashed one can't, so we
-- steal afterwards. Recovers a crashed-server lock in ~grace instead of LOCK_STALE.
local RELEASE_TOPIC = "PlayerDataReleaseRequest"
local HANDSHAKE_GRACE = 8         -- seconds to let a live owner release before stealing
local HANDSHAKE_POLL = 1          -- seconds between re-acquire polls during the grace

-- Unique id for this server instance; owns the locks we hold.
local SESSION_ID = HttpService:GenerateGUID(false)
local persistenceEnabled = (not RunService:IsStudio()) or PERSIST_IN_STUDIO

-- GetDataStore can throw if the DataStore API is unreachable — e.g. Studio with no
-- internet, or "Enable Studio Access to API Services" off. That can't happen for a
-- live server (the API is always present there), so we only tolerate it in Studio:
-- log it and run with persistence off, instead of letting the whole module error out
-- and break every gameplay service that depends on it.
local store: GlobalDataStore? = nil
if persistenceEnabled then
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	elseif RunService:IsStudio() then
		warn("DataService: DataStore unavailable in Studio, running without persistence: " .. tostring(result))
		persistenceEnabled = false
	else
		-- Live server with no DataStore is unexpected; surface it loudly.
		error("DataService: GetDataStore failed on a live server: " .. tostring(result))
	end
end

export type PlayerBlob = {
	currency: number?,
	profile: ProfileService.Profile?,
	prestige: PrestigeService.PrestigeData?,
}

-- Players whose load succeeded (so we may safely save them). A player who never
-- loaded — join in flight, load failed, or lock denied — is never saved, so we
-- don't overwrite a real save with defaults.
local loaded: { [number]: boolean } = {}
-- Per-user save mutex so autosave and leave-save can't run UpdateAsync concurrently.
local saving: { [number]: boolean } = {}

local function keyFor(userId: number): string
	return KEY_PREFIX .. tostring(userId)
end

-- A lock is ours, free, or stale → we may take/keep it.
local function lockIsAvailable(lock: any): boolean
	if not lock then
		return true
	end
	if lock.owner == SESSION_ID then
		return true
	end
	return (os.time() - (lock.time or 0)) >= LOCK_STALE
end

-- Run a yielding DataStore call with bounded exponential-backoff retry.
local function withRetry(fn: () -> any): (boolean, any)
	local attempt = 0
	while true do
		attempt += 1
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		if attempt >= MAX_TRIES then
			warn(("DataService: DataStore op failed after %d tries: %s"):format(attempt, tostring(result)))
			return false, nil
		end
		task.wait(0.2 * 2 ^ attempt)
	end
end

local function applyBlob(player: Player, blob: PlayerBlob?)
	CurrencyService.ApplyData(player, blob and blob.currency)
	ProfileService.ApplyData(player, blob and blob.profile)
	PrestigeService.ApplyData(player, blob and blob.prestige)
end

local function serializeBlob(player: Player): PlayerBlob
	return {
		currency = CurrencyService.SerializeData(player),
		profile = ProfileService.SerializeData(player),
		prestige = PrestigeService.SerializeData(player),
	}
end

-- One attempt to claim the lock and read the data. With `steal`, takes the lock
-- regardless of who holds it (used only after a crashed owner fails the handshake).
-- Returns:
--   "ok"     + the stored blob (lock now held by us)
--   "locked" (another live session holds it; not stealing)
--   "error"  (DataStore threw)
local function attemptAcquire(userId: number, steal: boolean): (string, PlayerBlob?)
	local denied = false
	local ok, result = pcall(function()
		return (store :: GlobalDataStore):UpdateAsync(keyFor(userId), function(record)
			record = record or {}
			if not (steal or lockIsAvailable(record.lock)) then
				denied = true
				return nil -- abort: leave the existing record untouched
			end
			record.lock = { owner = SESSION_ID, time = os.time() }
			return record
		end)
	end)
	if not ok then
		return "error", nil
	end
	if denied then
		return "locked", nil
	end
	return "ok", result and result.data
end

-- Ask whichever server currently holds this player's lock to release it. A live
-- owner handles this (saves, releases, kicks the stale session); a crashed one
-- can't respond, which is how we tell the two apart.
local function publishRelease(userId: number)
	pcall(function()
		MessagingService:PublishAsync(RELEASE_TOPIC, userId)
	end)
end

local function loadAndLock(userId: number): (boolean, PlayerBlob?)
	-- Fast path: lock is free, ours, or already stale-by-time.
	local status, data = attemptAcquire(userId, false)
	if status == "ok" then
		return true, data
	end

	if status == "locked" then
		-- Held by another session. Ask it to release, then poll for the handoff.
		publishRelease(userId)
		local deadline = os.clock() + HANDSHAKE_GRACE
		while os.clock() < deadline do
			task.wait(HANDSHAKE_POLL)
			local s, d = attemptAcquire(userId, false)
			if s == "ok" then
				return true, d -- owner released: clean handoff
			end
		end
		-- No release within the grace window → owner is unresponsive (crashed). Steal.
		local s, d = attemptAcquire(userId, true)
		if s == "ok" then
			return true, d
		end
		return false, nil
	end

	-- DataStore error: a few plain retries before giving up.
	for _ = 1, LOCK_TRIES do
		task.wait(LOCK_RETRY_WAIT)
		local s, d = attemptAcquire(userId, false)
		if s == "ok" then
			return true, d
		end
	end
	return false, nil
end

-- Write the player's current data. Keeps the lock (refreshing its time) unless
-- `release` is set (leave/shutdown). Aborts if another session has taken the lock,
-- so we never clobber a server that legitimately stole an abandoned slot.
local function writeData(userId: number, blob: PlayerBlob, release: boolean)
	withRetry(function()
		return (store :: GlobalDataStore):UpdateAsync(keyFor(userId), function(record)
			record = record or {}
			if not lockIsAvailable(record.lock) then
				return nil -- someone else owns it now; don't overwrite
			end
			record.data = blob
			record.lock = if release then nil else { owner = SESSION_ID, time = os.time() }
			return record
		end)
	end)
end

local function releaseLock(userId: number)
	withRetry(function()
		return (store :: GlobalDataStore):UpdateAsync(keyFor(userId), function(record)
			if record and record.lock and record.lock.owner == SESSION_ID then
				record.lock = nil
			end
			return record
		end)
	end)
end

local function savePlayer(player: Player, release: boolean)
	local userId = player.UserId
	if not loaded[userId] then
		return -- never loaded — don't risk clobbering a real save
	end
	while saving[userId] do
		task.wait()
	end
	saving[userId] = true
	local blob = serializeBlob(player)
	writeData(userId, blob, release)
	saving[userId] = nil
end

-- Another server is taking over this player (they joined elsewhere, or are rejoining
-- after we were slow). If we still hold them, hand off cleanly: save + release our
-- lock and kick the stale session so two servers never run the same player.
local function onReleaseRequest(message: { Data: any })
	local userId = message.Data
	if type(userId) ~= "number" or not loaded[userId] then
		return
	end
	local player = Players:GetPlayerByUserId(userId)
	if player then
		savePlayer(player, true) -- writes + releases our lock
		loaded[userId] = nil
		player:Kick("You joined another server — your progress was handed off.")
	else
		loaded[userId] = nil
		releaseLock(userId)
	end
end

local function onPlayerAdded(player: Player)
	-- Defaults first, synchronously, before any yield: guarantees data exists.
	applyBlob(player, nil)

	if not persistenceEnabled then
		return
	end

	local ok, data = loadAndLock(player.UserId)

	if not player.Parent then
		-- Left during load; release the lock we may have claimed so they can rejoin.
		if ok then
			releaseLock(player.UserId)
		end
		return
	end
	if not ok then
		player:Kick(LOCK_FAIL_MESSAGE)
		return
	end
	if data then
		applyBlob(player, data)
	end
	loaded[player.UserId] = true
end

local function onPlayerRemoving(player: Player)
	savePlayer(player, true)
	loaded[player.UserId] = nil
	CurrencyService.Clear(player)
	ProfileService.Clear(player)
	PrestigeService.Clear(player)
end

function DataService.Init()
	-- Listen for other servers asking us to release a player's lock (crash handshake).
	if persistenceEnabled then
		pcall(function()
			MessagingService:SubscribeAsync(RELEASE_TOPIC, onReleaseRequest)
		end)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	-- Players already present (Studio start / hot reload).
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end

	-- Periodic autosave: write every loaded player back, keeping their lock.
	if persistenceEnabled then
		task.spawn(function()
			while true do
				task.wait(AUTOSAVE_INTERVAL)
				for _, p in Players:GetPlayers() do
					if loaded[p.UserId] then
						task.spawn(savePlayer, p, false)
					end
				end
			end
		end)
	end

	-- Flush + release every loaded player before the server closes; wait for all.
	game:BindToClose(function()
		local pending = 0
		for _, p in Players:GetPlayers() do
			pending += 1
			task.spawn(function()
				savePlayer(p, true)
				pending -= 1
			end)
		end
		while pending > 0 do
			task.wait()
		end
	end)
end

return DataService
