local SSS = game:GetService('ServerScriptService')
local RS = game:GetService("ReplicatedStorage")

local ScoringService = require(SSS.Scripts.Modules.ScoringService)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local BallService = require(SSS.Scripts.Modules.BallService)
local CollisionService = require(SSS.Scripts.Modules.CollisionService)
local BallLaunchService = require(SSS.Scripts.Modules.BallLaunchService)
local PegService = require(SSS.Scripts.Modules.PegService)
local UpgradeService = require(SSS.Scripts.Modules.UpgradeService)
local PrestigeService = require(SSS.Scripts.Modules.PrestigeService)
local BallEffects = require(RS.Shared.BallEffects)
local ScoreUI = require(RS.Shared.ScoreUI)
local SoundService = require(RS.Shared.SoundService)
local DevService = require(SSS.Scripts.Modules.DevService)

-- ProfileService before gameplay services that read upgrade/loadout state.
CurrencyService.Init()
ProfileService.Init()
-- UpgradeService after Currency + Profile (it spends/sets through them).
UpgradeService.Init()
-- PrestigeService after Profile (it resets through it).
PrestigeService.Init()
-- DevService: Studio-only chat commands for testing tiers/loadout (inert in live).
DevService.Init()
ScoringService.Init()
-- PegService after ScoringService: tagging pegs ScoreTarget fires the
-- now-connected added-signal, so the overlap filter picks them up.
PegService.Init()
BallService.Init()
-- BallEffects before launches start: it self-connects to BallSpawned to paint
-- each ball from its owner's profile.
BallEffects.Init()
ScoreUI.Init()
-- SoundService: creates the PlaySound remote so clients can receive server-driven SFX.
SoundService.Init()
-- CollisionService before launches start: it self-connects to BallSpawned to put
-- each ball in the right gate-collision group from its first frame.
CollisionService.Init()
BallLaunchService.Init()
