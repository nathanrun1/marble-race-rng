--!strict
-- Plot balls: when a dropped marble banks at a destroy target, a claimable "ghost" copy of it
-- (same appearance, same final value) spawns at the player's plot for them to walk over and
-- collect. PLACEHOLDER: everyone's plot balls spawn at the single part tagged
-- Config.Tags.TestPlotSpawn for now (no real per-player plots yet).
--
-- Split (one file, two entry points — call the one matching context):
--   BallPlotService.InitServer() — hooks ScoreHandler.BallBanked, tracks each player's currently
--     claimable balls (id -> {value, skinId}), and validates claims. The server is the sole
--     source of truth: it never trusts a value/skin from the client, only an id.
--   BallPlotService.InitClient() — spawns the actual ghost ball INSTANCE. Spawning happens only
--     on the client (never replicated) — each client renders its own plot balls locally, with
--     real physics (CanCollide with the world, but not with other plot balls or players).
--     Touching one plays a claim VFX + destroys it locally immediately (optimistic), THEN asks
--     the server to actually credit it; a rejected/duplicate claim just does nothing serverside
--     (the ball is already gone from that client's perspective either way).
--
-- IDs: a single incrementing counter shared across all players (simpler than per-player
-- counters — the server's claimable table is keyed by Player first anyway, so ids only need to
-- be unique WITHIN a player, not globally), wrapping well below float precision limits.

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")

local Config = require(RS.Shared.Config)
local BallSkins = require(RS.Shared.BallSkins)
local BallEffects = require(RS.Shared.BallEffects)
local SoundService = require(RS.Shared.SoundService)

local BallPlotService = {}

local ID_WRAP = 2 ^ 31
local SPAWN_VEL_RANGE = 8  -- How much spawned plot ball velocity can very from 0 in both x & y
local PLOT_VALUE_FRACTION = 1 / 3 -- a plot ball is only worth a third of what it actually banked

-- Same non-collidable-with-players group shape as CollisionService's "Player" group for real
-- balls; plot balls additionally don't collide with each other.
local PLOT_BALL_GROUP = "PlotBall"
local PLAYER_GROUP = "Player" -- matches CollisionService.luau's PLAYER_GROUP string

local function getRemote(name: string, class: string): Instance
	local remoteFolder = RS:WaitForChild("Remote")
	local existing = remoteFolder:FindFirstChild(name)
	if existing then
		return existing
	end
	local r = Instance.new(class)
	r.Name = name
	r.Parent = remoteFolder
	return r
end

--------------------------------------------------------------------------------
-- Server
--------------------------------------------------------------------------------
function BallPlotService.InitServer()
	local SSS = game:GetService("ServerScriptService")
	local ScoreHandler = require(SSS.Scripts.Modules.ScoreHandler)
	local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)

	-- Collision group registration/rules are a server-only API (they're part of the shared
	-- physics rules, which replicate to every client automatically — same reason
	-- CollisionService registers its own groups server-side only). The client just assigns
	-- ball.CollisionGroup = PLOT_BALL_GROUP on its own locally-created balls; it never needs to
	-- (and isn't allowed to) touch the group's registration/rules itself.
	if not PhysicsService:IsCollisionGroupRegistered(PLOT_BALL_GROUP) then
		PhysicsService:RegisterCollisionGroup(PLOT_BALL_GROUP)
	end
	PhysicsService:CollisionGroupSetCollidable(PLOT_BALL_GROUP, PLOT_BALL_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(PLOT_BALL_GROUP, PLAYER_GROUP, false)

	local spawnRE = getRemote("SpawnPlotBall", "RemoteEvent") :: RemoteEvent
	local claimRE = getRemote("ClaimPlotBall", "RemoteEvent") :: RemoteEvent

	-- Per-player claimable balls: id -> what it's actually worth/wearing. The server never
	-- re-derives this from the client; a claim either matches an entry here or it's ignored.
	local claimable: { [Player]: { [number]: { value: number, skinId: string } } } = {}
	local nextId = 0

	local function onBallBanked(player: Player, ball: BasePart, amount: number)
		if amount <= 0 then
			return
		end
		local rawSkinId = ball:GetAttribute(Config.Attributes.SkinId)
		local skinId: string = if type(rawSkinId) == "string" and BallSkins.Get(rawSkinId)
			then rawSkinId
			else BallSkins.GetDefaultId()
		local plotValue = amount * PLOT_VALUE_FRACTION

		local id = nextId
		nextId = (nextId + 1) % ID_WRAP

		local perPlayer = claimable[player]
		if not perPlayer then
			perPlayer = {}
			claimable[player] = perPlayer
		end
		perPlayer[id] = { value = plotValue, skinId = skinId }

		spawnRE:FireClient(player, id, skinId, plotValue)
	end

	-- ids: a list, since a client-combined plot ball claims every id merged into it at once
	-- rather than firing one remote per merged ball. Each id is validated independently —
	-- unknown/already-claimed ids in the batch are silently skipped, not a failure of the batch.
	local function onClaim(player: Player, ids: unknown)
		if type(ids) ~= "table" then
			return
		end
		local perPlayer = claimable[player]
		if not perPlayer then
			return
		end
		local total = 0
		for _, id in ids :: { unknown } do
			if type(id) == "number" then
				local entry = perPlayer[id]
				if entry then
					perPlayer[id] = nil
					total += entry.value
				end
			end
		end
		if total <= 0 then
			return
		end
		CurrencyService.AddPoints(player, total, "Plot ball claimed")
		local flyRE = RS.Remote:FindFirstChild("PlayCurrencyFly")
		if flyRE and flyRE:IsA("RemoteEvent") then
			-- A small fixed count: plot claims happen constantly while walking the plot, so the
			-- default 7-11 icon celebration is too loud a beat for them.
			flyRE:FireClient(player, "Cash", 3)
		end
	end

	claimRE.OnServerEvent:Connect(onClaim)
	Players.PlayerRemoving:Connect(function(player: Player)
		claimable[player] = nil
	end)
	ScoreHandler.BallBanked:Connect(onBallBanked)
end

--------------------------------------------------------------------------------
-- Client
--------------------------------------------------------------------------------
function BallPlotService.InitClient()
	local TweenService = game:GetService("TweenService")

	local spawnRE = RS.Remote:WaitForChild("SpawnPlotBall") :: RemoteEvent
	local claimRE = RS.Remote:WaitForChild("ClaimPlotBall") :: RemoteEvent

	-- Every id (its own spawn id, or any id later merged into it) that a given physical ball
	-- currently represents — claiming that ball claims all of them in one remote call.
	local ballIds: { [BasePart]: { number } } = {}
	local ballValue: { [BasePart]: number } = {}
	local ballSkin: { [BasePart]: string } = {}
	-- Live plot balls per skin, for both the MaxPerSkin check and picking a random merge target.
	local ballsBySkin: { [string]: { BasePart } } = {}
	-- Every id -> the ball currently representing it (own or merged-into), so a stray touch/
	-- claim path could look a ball up by id if ever needed.
	local plotBalls: { [number]: BasePart } = {}

	local function resolvePlotPart(): BasePart?
		for _, inst in CollectionService:GetTagged(Config.Tags.TestPlotSpawn) do
			if inst:IsA("BasePart") then
				return inst
			end
		end
		return nil
	end

	local function getSkinList(skinId: string): { BasePart }
		local list = ballsBySkin[skinId]
		if not list then
			list = {}
			ballsBySkin[skinId] = list
		end
		return list
	end

	local function removeFromSkinList(ball: BasePart, skinId: string)
		local list = ballsBySkin[skinId]
		if not list then
			return
		end
		for i, b in list do
			if b == ball then
				table.remove(list, i)
				break
			end
		end
	end

	-- Brief scale-up-then-settle pulse: reads as "this one just got added to". Debounced per
	-- ball — a second merge landing on the same ball mid-tween just skips the pulse instead of
	-- restarting/stacking it (that stacking was producing a visible glitch: the tween fighting
	-- itself over the ball's Size).
	local MERGE_POP_SCALE = 1.15
	local MERGE_POP_TIME = 0.08
	local pulsing: { [BasePart]: boolean } = {}
	local function playMergePulse(ball: BasePart)
		if pulsing[ball] then
			return
		end
		pulsing[ball] = true
		local baseSize = ball.Size
		local up = TweenService:Create(
			ball,
			TweenInfo.new(MERGE_POP_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = baseSize * MERGE_POP_SCALE }
		)
		up.Completed:Once(function()
			local down = TweenService:Create(
				ball,
				TweenInfo.new(MERGE_POP_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Size = baseSize }
			)
			down.Completed:Once(function()
				pulsing[ball] = nil
			end)
			down:Play()
		end)
		up:Play()
	end

	-- A quick particle burst where the claimed ball was, then it's gone — same beat as a skin's
	-- bounce burst (BallEffects.EmitBounce), just not tied to any one skin.
	local function playClaimBurst(position: Vector3, color: Color3)
		local anchor = Instance.new("Part")
		anchor.Name = "PlotClaimBurst"
		anchor.Size = Vector3.new(0.2, 0.2, 0.2)
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.Transparency = 1
		anchor.Position = position
		anchor.Parent = workspace

		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		emitter.Color = ColorSequence.new(color)
		emitter.Lifetime = NumberRange.new(0.35, 0.7)
		emitter.Speed = NumberRange.new(14, 24)
		emitter.Size = NumberSequence.new(0.5, 0)
		emitter.Transparency = NumberSequence.new(0, 1)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Rate = 0
		emitter.LightEmission = 1
		emitter.Parent = anchor

		emitter:Emit(18)
		task.delay(1, function()
			anchor:Destroy()
		end)
	end

	-- Claims EVERY id this ball currently represents (its own + anything merged into it) in one
	-- remote call, rather than one FireServer per merged ball.
	local function claim(ball: BasePart)
		local ids = ballIds[ball]
		if not ids then
			return
		end
		ballIds[ball] = nil
		ballValue[ball] = nil
		pulsing[ball] = nil
		for _, id in ids do
			plotBalls[id] = nil
		end
		local skinId = ballSkin[ball]
		if skinId then
			removeFromSkinList(ball, skinId)
			ballSkin[ball] = nil
		end

		playClaimBurst(ball.Position, ball.Color)
		-- Collect SFX on the touch itself (same sound coin pickups use), not on the server's
		-- credit round trip — the feedback has to land the instant the marble disappears.
		SoundService.Play({ soundId = Config.Sounds.Collect3 })
		ball:Destroy() -- optimistic: gone locally the instant it's touched
		claimRE:FireServer(ids)
	end

	local function onSpawn(id: unknown, skinIdRaw: unknown, value: unknown)
		if type(id) ~= "number" or type(value) ~= "number" then
			return
		end
		local skinId = if type(skinIdRaw) == "string" then skinIdRaw else BallSkins.GetDefaultId()

		-- Already at the cap for this skin: merge into a random existing ball of it instead of
		-- spawning a new physical ball.
		local list = getSkinList(skinId)
		if #list >= Config.BallPlot.MaxPerSkin then
			local target = list[math.random(#list)]
			table.insert(ballIds[target], id)
			ballValue[target] += value
			plotBalls[id] = target
			BallEffects.SetValueUI(target, ballValue[target])
			playMergePulse(target)
			return
		end

		local plotPart = resolvePlotPart()
		if not plotPart then
			return
		end

		local ball = (Config.Templates.Ball :: BasePart):Clone()
		ball.Name = "PlotBall"
		ball.Anchored = false
		ball.CanCollide = true
		ball.CanQuery = true
		ball.CanTouch = true
		ball.CollisionGroup = PLOT_BALL_GROUP
		ball:RemoveTag(Config.Tags.Ball) -- never scored/hidden as a real live ball
		-- Stamped like real board balls get at spawn (CosmeticService.onBallSpawn), so anything
		-- reading a ball's cosmetic identity generically — e.g. AttachValueUI's rarity-tinted
		-- value text — works on plot balls too.
		ball:SetAttribute(Config.Attributes.SkinId, skinId)
		ball.CFrame = CFrame.new(plotPart.Position + Vector3.new(0, plotPart.Size.Y / 2 + ball.Size.Y, 0))
        ball.AssemblyLinearVelocity = Vector3.new(math.random(-SPAWN_VEL_RANGE, SPAWN_VEL_RANGE), 0, math.random(-SPAWN_VEL_RANGE, SPAWN_VEL_RANGE))
		ball.Parent = workspace

		BallEffects.ApplyAppearance(ball, {
			skinId = skinId,
			heat = 0,
		})
		-- Plot balls shed the "Ball" tag (above), so BallEffects' per-frame shape/orbit
		-- positioner never picks them up on its own — without this opt-in, a shape-built
		-- skin (crowns/wings/rings) shows only its base colour + highlight.
		BallEffects.TrackOrbits(ball)
		-- Same value display dropped balls use (BallEffects.AttachValueUI/SetValueUI): a
		-- smooth-follow billboard, independent of this ball's own physics jitter — just
		-- sitting lower and white-stroked so a plot full of them reads differently from
		-- live board balls.
		BallEffects.AttachValueUI(ball, {
			studsOffset = Vector3.new(0, 2, 0),
			extentsOffset = Vector3.new(0, 2, 0),
			strokeColor = Color3.new(1, 1, 1),
		})
		BallEffects.SetValueUI(ball, value)

		ballIds[ball] = { id }
		ballValue[ball] = value
		ballSkin[ball] = skinId
		plotBalls[id] = ball
		table.insert(list, ball)

		local touchedConn: RBXScriptConnection
		touchedConn = ball.Touched:Connect(function(obj: BasePart)
			local char = Players.LocalPlayer.Character
			if char and obj:IsDescendantOf(char) then
				touchedConn:Disconnect()
				claim(ball)
			end
		end)
	end

	spawnRE.OnClientEvent:Connect(onSpawn)
end

return BallPlotService
