-- ServerScriptService/BallLaunchService (ModuleScript)
--!strict
-- Authority over launches. The server owns timing and trajectory; the client only
-- configures its loadout (Arc, Angle, ...) via ProfileService. The launcher swivels
-- continuously (aim ± Arc) driven by the clock; each ball is aimed by the swivel's
-- phase at fire time, around the player's Angle (aim center).
--
-- PER-SLOT LAUNCH REWORK: each loadout slot launches independently (the world slot
-- Interact pads / the HUD LAUNCH button = every ready slot at once). Each slot has its
-- own cooldown, ProfileStats.GetLaunchDelay (the Frequency upgrade lowers it for all
-- slots). A ball's value = the player's selected bet size (BetTier ladder) × its skin's
-- rarity bet multiplier (CosmeticBonus.RarityBetMult); launching itself is free.

local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local BallService = require(SSS.Scripts.Services.BallService)
local ProfileService = require(SSS.Scripts.Services.ProfileService)
local ProfileStats = require(RS.Shared.ProfileStats)
local CosmeticService = require(SSS.Scripts.Services.CosmeticService)
local LoadoutService = require(SSS.Scripts.Services.LoadoutService)
local BallSkins = require(RS.Shared.BallSkins)
local CosmeticBonus = require(RS.Shared.CosmeticBonus)
local CurrencyService = require(SSS.Scripts.Services.CurrencyService)
local BallConfig = require(RS.Shared.Config.Ball)
local LauncherConfig = require(RS.Shared.Config.Launcher)
local SlotAutoConfig = require(RS.Shared.Config.SlotAuto)
local LaunchNet = require(RS.Shared.Remote.LaunchNet)
local requestLaunch = LaunchNet.RequestLaunch

local BallLaunchService = {}

-- Server-chosen trajectory constants. The client never touches these. (Spawn origin
-- and base aim live in LauncherConfig, shared with the client aim-line preview.)
local MAX_BALLS_PER_PLAYER = BallConfig.MaxPerPlayer -- concurrency ceiling (well above max N)
local LAUNCHER_ROT_PERIOD = LauncherConfig.RotationPeriod  -- full swivel period (shared w/ client)

-- Launcher geometry — TUNE to the actual ramp. BASE_LAUNCH_DIR is the launcher's
-- neutral direction (aim 0, mid-phase), i.e. straight down the ramp; the swivel
-- rotates it left/right about the vertical axis. Two per-player loadout axes shape
-- the aim: Arc (swivel half-width) and Angle (the center the launcher swivels
-- around, default 0 = straight down). Both are passed into deriveLaunchVelocity.
local BASE_LAUNCH_DIR = LauncherConfig.BaseDirection   -- down-ramp; shared w/ client preview
local LAUNCH_SPEED = 60                          -- studs/s initial speed
local LAUNCH_SPEED_VARIATION = 0.2              -- Launch speed can vary by up to this portion
local LAUNCH_DIR_VARIATION = math.rad(10)                -- Launch angle can vary by up to this angle

-- os.clock() timestamp each slot may fire again: userId -> slot -> ready time
-- (missing = ready now). Cleared on leave.
local slotReadyTime: { [number]: { [number]: number } } = {}

local function genLaunchSpeed(): number
	local variation = LAUNCH_SPEED * LAUNCH_SPEED_VARIATION
	return math.random(LAUNCH_SPEED - variation, LAUNCH_SPEED + variation)
end

local function genSpawnPos(): Vector3
	-- Shared with the client aim-line preview so they originate from the same point.
	return LauncherConfig.LaunchOrigin
end

-- Launcher swivels continuously: as phase runs 0→1 the aim sweeps aim ± arcWidth
-- (phase 0/0.5/1 = aim, 0.25 = +arcWidth, 0.75 = −arcWidth). The deterministic
-- swivel angle is ProfileStats.GetSwivelAngle; we add a small random jitter, then
-- rotate the base down-ramp vector about the vertical axis by the total angle.
local function deriveLaunchVelocity(phase: number, arcWidth: number, aimAngle: number): Vector3
	local angle = ProfileStats.GetSwivelAngle(arcWidth, aimAngle, phase)
		+ (math.random() * 2 - 1) * LAUNCH_DIR_VARIATION
	local dir = CFrame.fromAxisAngle(Vector3.yAxis, angle):VectorToWorldSpace(BASE_LAUNCH_DIR)
	return dir.Unit * genLaunchSpeed()
end

-- $ value a launched ball carries (PER-SLOT LAUNCH REWORK): the player's selected bet size
-- (their BetTier ladder rung) × the skin's rarity bet multiplier — rarity scales the bet,
-- it is no longer a standalone value table.
local function ballValueForSkin(player: Player, skinId: string): number
	local skin = BallSkins.Get(skinId)
	local rarity = if skin then skin.rarity else 1
	local betSize = ProfileStats.GetBetSizeAtTier(ProfileService.GetLoadout(player).BetTier)
	return betSize * CosmeticBonus.RarityBetMult(rarity)
end

-- Spawn one ball for this player wearing `skinId`, valued at that skin's rarity. This is the
-- trajectory core of a launch with no guards or currency side effects — launchSlot wraps it
-- with those; the dev launch test reuses it raw. Phase is the launcher's continuous swivel
-- position at call time, derived from the clock and the rotation period; Arc (swivel width)
-- and Angle (aim center) are loadout axes.
local function spawnBall(player: Player, skinId: string): BasePart
	local loadout = ProfileService.GetLoadout(player)
	local arcWidth = loadout.axes.Arc
	local aimAngle = loadout.axes.Angle
	local phase = (os.clock() % LAUNCHER_ROT_PERIOD) / LAUNCHER_ROT_PERIOD
	return BallService.Spawn(genSpawnPos(), {
		ownerUserId = player.UserId,
		velocity = deriveLaunchVelocity(phase, arcWidth, aimAngle),
		initialValue = ballValueForSkin(player, skinId),
		weight = 1 - loadout.axes.Elasticity,
		size = loadout.axes.Size,
		skinId = skinId,
	})
end

-- Fire ONE slot, if it can: the slot must be unlocked (≤ GetMaxSlots), hold an equipped
-- skin, and be off cooldown. On fire, the slot cools down for the player's Frequency-scaled
-- launch delay and the owning client is told (SlotLaunched) so its pad renders the countdown.
local function launchSlot(player: Player, slot: number)
	if slot ~= math.floor(slot) or slot < 1 or slot > LoadoutService.GetMaxSlots(player) then
		return
	end
	local skinId = LoadoutService.GetInfo(player).loadout[tostring(slot)]
	if not skinId then
		return -- empty slot
	end

	local userId = player.UserId
	local ready = slotReadyTime[userId]
	if not ready then
		ready = {}
		slotReadyTime[userId] = ready
	end
	local now = os.clock()
	if ready[slot] and now < ready[slot] then
		return -- still cooling down
	end
	if BallService.GetLiveCount(userId) >= MAX_BALLS_PER_PLAYER then
		return
	end

	local cooldown = ProfileStats.GetLaunchDelay(ProfileService.GetUpgrades(player))
	ready[slot] = now + cooldown
	spawnBall(player, skinId)
	LaunchNet.SlotLaunched:FireClient(player, slot, cooldown)
end

-- The HUD LAUNCH button / auto-launch: fire every slot that is currently ready.
local function launchAllReady(player: Player)
	for slot = 1, LoadoutService.GetMaxSlots(player) do
		launchSlot(player, slot)
	end
end

export type TestLaunchOptions = {
	phase: number?,   -- 0..1 swivel phase; nil = clock-derived
	weight: number?,  -- overrides loadout Elasticity-derived weight
	size: number?,    -- overrides loadout Size axis
	skinId: string?,  -- which skin's rarity values the ball; nil = the default (Classic) skin
}

-- Dev/test only: fire one ball immediately, bypassing the batch cooldown and the
-- concurrency cap. Returns the ball so the caller can match it against
-- ScoringService.BallScored.
function BallLaunchService.LaunchTest(player: Player, opts: TestLaunchOptions?): BasePart
	local o: TestLaunchOptions = opts or {}
	local loadout = ProfileService.GetLoadout(player)
	local phase = o.phase or (os.clock() % LAUNCHER_ROT_PERIOD) / LAUNCHER_ROT_PERIOD
	return BallService.Spawn(genSpawnPos(), {
		ownerUserId = player.UserId,
		velocity = deriveLaunchVelocity(phase, loadout.axes.Arc, loadout.axes.Angle),
		initialValue = ballValueForSkin(player, o.skinId or BallSkins.GetDefaultId()),
		weight = o.weight or (1 - loadout.axes.Elasticity),
		size = o.size or loadout.axes.Size,
		skinId = o.skinId or CosmeticService.GetEquipped(player), -- test balls wear the equipped visual by default
	})
end

-- Seconds between each ball in LaunchMaxBetBatch, so a dropped batch doesn't all spawn stacked
-- on the exact same point in the same instant.
local BALL_DROP_STAGGER = 0.12

-- Robux perk (MonetizationConfig.BallDrop): instantly fire `count` balls, free and bypassing the launch
-- cooldown, same spirit as LaunchTest. NOT updated for the core-loop rework (ball value now
-- comes from rarity, not a bet ceiling) — still values balls at the player's frozen MaxBet tier
-- (ProfileStats.GetMaxBet), since MaxBet purchases are gated but existing tiers/derivation are
-- untouched. Revisit once this Robux perk's value source is decided. Fires the balls in the
-- background (staggered) so the caller (the dev-product grant handler) can return immediately.
function BallLaunchService.LaunchMaxBetBatch(player: Player, count: number)
	local upgrades = ProfileService.GetUpgrades(player)
	local loadout = ProfileService.GetLoadout(player)
	local maxBet = ProfileStats.GetMaxBet(upgrades)
	task.spawn(function()
		for _ = 1, count do
			if not player.Parent then
				return -- player left mid-drop
			end
			if BallService.GetLiveCount(player.UserId) < MAX_BALLS_PER_PLAYER then
				local phase = (os.clock() % LAUNCHER_ROT_PERIOD) / LAUNCHER_ROT_PERIOD
				BallService.Spawn(genSpawnPos(), {
					ownerUserId = player.UserId,
					velocity = deriveLaunchVelocity(phase, loadout.axes.Arc, loadout.axes.Angle),
					initialValue = maxBet,
					weight = 1 - loadout.axes.Elasticity,
					size = loadout.axes.Size,
					skinId = CosmeticService.GetEquipped(player), -- perk balls wear the equipped visual
				})
			end
			task.wait(BALL_DROP_STAGGER)
		end
	end)
end

-- Current launcher swivel phase (0..1). The client renders its own smooth swivel and
-- periodically resyncs to this so the visual matches the server's actual fire timing.
function BallLaunchService.GetPhase(): number
	return (os.clock() % LAUNCHER_ROT_PERIOD) / LAUNCHER_ROT_PERIOD
end

-- Buy the one-time AUTO launch for a slot (the world AutoSign's click). Server-
-- authoritative: slot validity, unlock state, prior ownership, and funds are all checked
-- here; no yield between the funds check and the deduct, so it's atomic against
-- concurrent requests. Ownership lands in the profile (autoSlots), which replicates via
-- ProfileChanged and is swept by Start's auto loop below.
local function purchaseSlotAuto(player: Player, slot: unknown): { ok: boolean, reason: string? }
	if type(slot) ~= "number" or slot ~= math.floor(slot) or slot < 1 then
		return { ok = false, reason = "invalid_slot" }
	end
	if slot > LoadoutService.GetMaxSlots(player) then
		return { ok = false, reason = "locked" }
	end
	if ProfileService.GetAutoSlots(player)[tostring(slot)] then
		return { ok = false, reason = "owned" }
	end
	local price = SlotAutoConfig.PriceFor(slot)
	if CurrencyService.GetPoints(player) < price then
		return { ok = false, reason = "cannot_afford" }
	end
	CurrencyService.AddPoints(player, -price, "SlotAuto: " .. slot)
	ProfileService.SetSlotAuto(player, slot)
	return { ok = true }
end

-- Request a launch: a numbered slot from its world Interact pad, or no arg = every ready
-- slot (HUD LAUNCH/auto). Only the slot NUMBER is trusted from the client — skin, value,
-- cooldown, and unlock state are all derived server-side.
local function onRequest(player: Player, slot: unknown)
	if type(slot) == "number" then
		launchSlot(player, slot)
	else
		launchAllReady(player)
	end
end

function BallLaunchService.Init()
	requestLaunch.OnServerEvent:Connect(onRequest)
	Players.PlayerRemoving:Connect(function(player: Player)
		slotReadyTime[player.UserId] = nil
	end)

	-- Lets the client sync its visual launcher rotation to the server's phase.
	LaunchNet.GetLauncherPhase.OnServerInvoke = function()
		return BallLaunchService.GetPhase()
	end

	LaunchNet.PurchaseSlotAuto.OnServerInvoke = purchaseSlotAuto
end

-- Auto-launch sweep: every SweepInterval, fire each AUTO-owned slot that's ready.
-- launchSlot's own guards (unlock, equip, cooldown, ball cap) are the real gate — the
-- sweep just asks. pcall around the profile read: a player can be in Players before
-- DataService has seeded their profile (join race), and GetAutoSlots asserts on that.
function BallLaunchService.Start()
	while true do
		task.wait(SlotAutoConfig.SweepInterval)
		for _, player in Players:GetPlayers() do
			local ok, autoSlots = pcall(ProfileService.GetAutoSlots, player)
			if ok then
				for slotStr in autoSlots do
					local slot = tonumber(slotStr)
					if slot then
						launchSlot(player, slot)
					end
				end
			end
		end
	end
end

return BallLaunchService
