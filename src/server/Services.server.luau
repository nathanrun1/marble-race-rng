local SSS = game:GetService('ServerScriptService')
local RS = game:GetService("ReplicatedStorage")

local ScoringService = require(SSS.Scripts.Modules.ScoringService)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local LeaderboardService = require(SSS.Scripts.Modules.LeaderboardService)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local BallService = require(SSS.Scripts.Modules.BallService)
local CollisionService = require(SSS.Scripts.Modules.CollisionService)
local BallLaunchService = require(SSS.Scripts.Modules.BallLaunchService)
local PegService = require(SSS.Scripts.Modules.PegService)
local UpgradeService = require(SSS.Scripts.Modules.UpgradeService)
local PrestigeService = require(SSS.Scripts.Modules.PrestigeService)
local StatsService = require(SSS.Scripts.Modules.StatsService)
local PlaytimeBonusService = require(SSS.Scripts.Modules.PlaytimeBonusService)
local DataService = require(SSS.Scripts.Modules.DataService)
local CosmeticService = require(SSS.Scripts.Modules.CosmeticService)
local BallEffects = require(RS.Shared.BallEffects)
local ScoreUI = require(RS.Shared.ScoreUI)
local AnnounceUI = require(RS.Shared.AnnounceUI)
local WarnUI = require(RS.Shared.WarnUI)
local SoundService = require(RS.Shared.SoundService)
local ProductService = require(RS.Shared.ProductService)
local MonetizationService = require(SSS.Scripts.Modules.MonetizationService)
local ObbyService = require(SSS.Scripts.Modules.ObbyService)
local GroupRewardService = require(SSS.Scripts.Modules.GroupRewardService)
local CoinService = require(SSS.Scripts.Modules.CoinService)
local DestroyTargetService = require(SSS.Scripts.Modules.DestroyTargetService)
local DevService = require(SSS.Scripts.Modules.DevService)

-- ProfileService before gameplay services that read upgrade/loadout state.
CurrencyService.Init()
ProfileService.Init()
-- UpgradeService after Currency + Profile (it spends/sets through them).
UpgradeService.Init()
-- PrestigeService after Profile (it resets through it).
PrestigeService.Init()
-- StatsService (cash multiplier / starter-pack ownership / upgrade count) before
-- DataService: it's a passive data service DataService loads + saves, and its remotes
-- must exist before the first ApplyData pushes initial stats.
StatsService.Init()
-- PlaytimeBonusService before DataService (it's a passive data service DataService loads/saves
-- via ApplyData/SerializeData): creates its remotes + starts the playtime tracker.
PlaytimeBonusService.Init()
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
-- JackpotTarget tag + display label from Config.DestroyTargets, so scoring reads the right
-- multipliers from the first ball.
DestroyTargetService.Init()
-- PegService after ScoringService: tagging pegs ScoreTarget fires the
-- now-connected added-signal, so the overlap filter picks them up.
PegService.Init()
BallService.Init()
-- CosmeticService BEFORE BallEffects on purpose: Signal fires handlers LIFO (most-recently-connected
-- runs FIRST), so connecting CosmeticService first makes its equipped-skin paint run LAST — winning
-- over BallEffects' default base colour instead of being overwritten by it.
CosmeticService.Init()
-- BallEffects self-connects to BallSpawned to paint each ball (heat/material + default base colour).
BallEffects.Init()
ScoreUI.Init()
-- AnnounceUI: creates the AnnounceMessage remote for large centered banner messages.
AnnounceUI.Init()
-- WarnUI: creates the WarnMessage remote for small lower-screen warning banners.
WarnUI.Init()
-- SoundService: creates the PlaySound remote so clients can receive server-driven SFX.
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
