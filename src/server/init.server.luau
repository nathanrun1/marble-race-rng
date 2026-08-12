--!strict
-- Server bootstrap: the ONLY server Script. Requires every service and starts them in
-- two phases — Init() (synchronous wiring; remotes already exist via the shared *Net
-- modules, created at require time) then Start() (spawned; services with long-running
-- loops live there and may never return).
--
-- The Init ORDER below is load-bearing; each comment says what an entry must follow.

local RS = game:GetService("ReplicatedStorage")

local ScoringService = require(script.Services.ScoringService)
local CurrencyService = require(script.Services.CurrencyService)
local LeaderboardService = require(script.Services.LeaderboardService)
local ProfileService = require(script.Services.ProfileService)
local BallService = require(script.Services.BallService)
local CollisionService = require(script.Services.CollisionService)
local BallLaunchService = require(script.Services.BallLaunchService)
local PegService = require(script.Services.PegService)
local UpgradeService = require(script.Services.UpgradeService)
local UpgradeLockService = require(script.Services.UpgradeLockService)
local PrestigeService = require(script.Services.PrestigeService)
local StatsService = require(script.Services.StatsService)
local PlaytimeBonusService = require(script.Services.PlaytimeBonusService)
local DataService = require(script.Services.DataService)
local CosmeticService = require(script.Services.CosmeticService)
local MonetizationService = require(script.Services.MonetizationService)
local ObbyService = require(script.Services.ObbyService)
local GroupRewardService = require(script.Services.GroupRewardService)
local CoinService = require(script.Services.CoinService)
local DestroyTargetService = require(script.Services.DestroyTargetService)
local DevService = require(script.Services.DevService)
local QuestService = require(script.Services.QuestService)
local StarterQuestService = require(script.Services.StarterQuestService)
local GoldenPegService = require(script.Services.GoldenPegService)
local DailyRewardService = require(script.Services.DailyRewardService)
local MetricsService = require(script.Services.MetricsService)
local LoadoutService = require(script.Services.LoadoutService)
local DayNightService = require(script.Services.DayNightService)
local WeatherService = require(script.Services.WeatherService)
local ObstacleService = require(script.Services.ObstacleService)
local TeleportService = require(script.Services.TeleportService)
local OverheadStatsService = require(script.Services.OverheadStatsService)
local PhysicalLeaderboardService = require(script.Services.PhysicalLeaderboardService)

local BallEffects = require(RS.Shared.BallEffects)
local ScoreUI = require(RS.Shared.ScoreUI)
local AnnounceUI = require(RS.Shared.AnnounceUI)
local WarnUI = require(RS.Shared.WarnUI)
local SoundService = require(RS.Shared.SoundService)
local ProductService = require(RS.Shared.ProductService)
local BallPlotService = require(RS.Shared.BallPlotService)

--------------------------------------------------------------------------------
-- Phase 1: Init (synchronous, ordered)
--------------------------------------------------------------------------------
-- ProfileService before gameplay services that read upgrade/loadout state.
CurrencyService.Init()
ProfileService.Init()
-- UpgradeLockService before UpgradeService's first purchase can arrive (UpgradeService
-- checks IsTrackLocked through it); scans the workspace UpgradeLock models.
UpgradeLockService.Init()
-- UpgradeService after Currency + Profile (it spends/sets through them).
UpgradeService.Init()
-- PrestigeService after Profile (it resets through it).
PrestigeService.Init()
-- StatsService (cash multiplier / starter-pack ownership / upgrade count) before
-- DataService: it's a passive data service DataService loads + saves, and its state
-- must exist before the first ApplyData pushes initial stats.
StatsService.Init()
-- PlaytimeBonusService before DataService (it's a passive data service DataService loads/saves
-- via ApplyData/SerializeData): starts the playtime tracker.
PlaytimeBonusService.Init()
-- QuestService before DataService (another passive data service): connects its metric hooks
-- so quest progress starts counting from the first ApplyData.
QuestService.Init()
-- StarterQuestService (the one-time Getting Started chain): same before-DataService ordering
-- as QuestService, for the same reason — its hooks must exist before the first ApplyData.
StarterQuestService.Init()
-- DailyRewardService before DataService (another passive data service).
DailyRewardService.Init()
-- DataService after the data services are set up: it owns the player-data lifecycle
-- (seeds defaults, loads/saves persistence) and drives their ApplyData.
DataService.Init()
-- ProductService after DataService: ProcessReceipt grants through it (it needs
-- DataService.IsLoaded / SaveNow to fulfil purchases durably).
ProductService.Init()
-- MonetizationService after ProductService: registers the cash-multiplier and
-- starter-pack grant handlers with it.
MonetizationService.Init()
-- LeaderboardService after data is loading: it seeds leaderstats from current state
-- and mirrors Currency/Prestige Changed signals (so it corrects once data loads).
LeaderboardService.Init()
-- DevService: Studio-only chat commands for testing tiers/loadout (inert in live).
DevService.Init()
ScoringService.Init()
-- DestroyTargetService after ScoringService, before launches: stamps each slot's PointMul /
-- JackpotTarget tag + display label from ScoringConfig.DestroyTargets, so scoring reads the
-- right multipliers from the first ball.
DestroyTargetService.Init()
-- PegService after ScoringService: tagging pegs ScoreTarget fires the
-- now-connected added-signal, so the overlap filter picks them up.
PegService.Init()
-- GoldenPegService after PegService (both walk Workspace.Pegs): owns each player's golden-peg
-- set (grown per rebirth via PrestigeService.Changed) and the clone spawn; the per-hit trigger
-- lives in ScoreHandler.
GoldenPegService.Init()
BallService.Init()
-- Ball spawn paint is EXPLICIT (BallService.Spawn calls BallEffects.ApplySpawnDefaults +
-- ApplyAppearance directly) — no signal-order dependence between these two anymore.
CosmeticService.Init()
-- LoadoutService after CosmeticService: it depends on CosmeticService.IsOwned/GetCopies
-- (both need CosmeticService's state set up first).
LoadoutService.Init()
BallEffects.Init()
ScoreUI.Init()
AnnounceUI.Init()
WarnUI.Init()
SoundService.Init()
-- CollisionService before launches start: it self-connects to BallSpawned to put
-- each ball in the right gate-collision group from its first frame.
CollisionService.Init()
BallLaunchService.Init()
-- ObbyService: auto-wires an ObbyZone for every workspace model tagged Obby.
ObbyService.Init()
-- GroupRewardService after Currency/Stats: auto-wires the group-reward pads and owns
-- the claim + cooldown (reads balance/stats, grants through Currency).
GroupRewardService.Init()
-- CoinService after Currency/WarnUI/Sound: owns per-player collectible-coin availability and
-- claiming (grants through Currency, announces via WarnUI, plays a collect SFX).
CoinService.Init()
-- BallPlotService.InitServer after Currency: hooks ScoreHandler.BallBanked (fired from within
-- ScoringService's collision loop) and validates plot-ball claims through Currency.
BallPlotService.InitServer()
-- MetricsService is standalone (own DataStore, PlayerAdded/Removing hooks only); order-
-- independent. Records on live servers; /metrics prints the report.
MetricsService.Init()
-- World-behaviour services (independent of the gameplay pipeline above).
DayNightService.Init()
-- WeatherService: captures the authored Lighting/Atmosphere baseline for its "Clear" restore
-- target, so it must run after the place's Lighting is in its normal resting state (true by
-- this point — nothing before it touches Lighting/Atmosphere).
WeatherService.Init()
ObstacleService.Init()
TeleportService.Init()
-- OverheadStatsService after Stats/Prestige/Cosmetic (it renders their signals).
OverheadStatsService.Init()
-- PhysicalLeaderboardService after Currency/Data/Prestige/Stats (it renders their signals;
-- board resolution + wiring happens in its Start).
PhysicalLeaderboardService.Init()

--------------------------------------------------------------------------------
-- Phase 2: Start (spawned; long-running loops live here)
--------------------------------------------------------------------------------
for _, service in {
	DayNightService.Start,
	ObstacleService.Start,
	OverheadStatsService.Start,
	PhysicalLeaderboardService.Start,
	BallLaunchService.Start, -- per-slot AUTO launch sweep (Config/SlotAuto)
} do
	task.spawn(service)
end
