--!strict
-- Plot balls: when a dropped marble banks at a destroy target, a claimable "ghost" copy of it
-- (same appearance, same final value) spawns at the player's plot for them to walk over and
-- collect. PLACEHOLDER: everyone's plot balls arrive at the single part tagged
-- TagsConfig.PlotSpawn for now (no real per-player plots yet), shot out of the part tagged
-- TagsConfig.PlotShoot along a collision-free curved arc.
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

local AttributesConfig = require(RS.Shared.Config.Attributes)
local BallConfig = require(RS.Shared.Config.Ball)
local BallPlotConfig = require(RS.Shared.Config.BallPlot)
local SoundsConfig = require(RS.Shared.Config.Sounds)
local TagsConfig = require(RS.Shared.Config.Tags)
local CoinsConfig = require(RS.Shared.Config.Coins)
local BallSkins = require(RS.Shared.BallSkins)
local BallEffects = require(RS.Shared.BallEffects)
local SoundService = require(RS.Shared.SoundService)
local StringUtils = require(RS.Shared.Utility.StringUtils)
local WarnUI = require(RS.Shared.WarnUI)
local FxNet = require(RS.Shared.Remote.FxNet)
local PlotNet = require(RS.Shared.Remote.PlotNet)

local BallPlotService = {}

local ID_WRAP = 2 ^ 31
local PLOT_VALUE_FRACTION = 1 / 3 -- a plot ball is only worth a third of what it actually banked

-- Same non-collidable-with-players group shape as CollisionService's "Player" group for real
-- balls; plot balls additionally don't collide with each other.
local PLOT_BALL_GROUP = "PlotBall"
local PLAYER_GROUP = "Player" -- matches CollisionService.luau's PLAYER_GROUP string

--------------------------------------------------------------------------------
-- Server
--------------------------------------------------------------------------------
-- Per-player claimable balls: id -> what it's actually worth/wearing. The server never
-- re-derives this from the client; a claim either matches an entry here or it's ignored.
-- Module-scope (populated/used by InitServer) so InvalidateAll can wipe it.
local claimable: { [Player]: { [number]: { value: number, skinId: string } } } = {}

-- Server-only. Invalidate EVERY claimable plot ball for `player` and tell their client to
-- remove the physical balls. PrestigeService calls this BEFORE the rebirth balance reset —
-- a claim landing between the reset and the wipe would credit pre-rebirth plot money into
-- the fresh balance.
function BallPlotService.InvalidateAll(player: Player)
	claimable[player] = nil
	PlotNet.ClearPlotBalls:FireClient(player)
end

function BallPlotService.InitServer()
	local SSS = game:GetService("ServerScriptService")
	local ScoreHandler = require(SSS.Scripts.Services.ScoreHandler)
	local CurrencyService = require(SSS.Scripts.Services.CurrencyService)

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

	local spawnRE = PlotNet.SpawnPlotBall
	local claimRE = PlotNet.ClaimPlotBall
	local nextId = 0

	local function onBallBanked(player: Player, ball: BasePart, amount: number)
		if amount <= 0 then
			return
		end
		local rawSkinId = ball:GetAttribute(AttributesConfig.SkinId)
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

		-- The banked ball rides along so the client can clone its exact look (it stays alive
		-- through its destroy-delay linger, which comfortably covers the remote's flight).
		spawnRE:FireClient(player, id, skinId, plotValue, ball)
	end

	-- ids: a list, since a client-combined plot ball claims every id merged into it at once
	-- rather than firing one remote per merged ball. Each id is validated independently —
	-- unknown/already-claimed ids in the batch are silently skipped, not a failure of the batch.
	local function onClaim(player: Player, ids: unknown, collectAll: unknown)
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
		local flyRE = FxNet.PlayCurrencyFly
		if flyRE then
			-- Single walked-over claims fly a small fixed count (they happen constantly while
			-- walking the plot; the full celebration is too loud a beat for them). The
			-- collect-all pad's batch claim IS the big beat: 10 icons.
			flyRE:FireClient(player, "Cash", if collectAll == true then 10 else 3)
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
	local RunService = game:GetService("RunService")

	local spawnRE = PlotNet.SpawnPlotBall
	local claimRE = PlotNet.ClaimPlotBall

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

	local function resolveTaggedPart(tag: string): BasePart?
		for _, inst in CollectionService:GetTagged(tag) do
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

	-- Fires the ball out of the PlotShoot part along a curved (y-arcing) path that lands at
	-- landPos. Animated along a quadratic Bezier (start -> raised midpoint -> landing) rather
	-- than launched as a live projectile: with fixed gravity a real ballistic shot can't have
	-- its flight time AND arc height tuned independently, and both are config knobs
	-- (BallPlotConfig.ShotTime / ShotArcHeight). The ball is fully ghosted (anchored, no
	-- collide/touch/query) for the flight so nothing can deflect it or claim it mid-air; at
	-- touchdown it unanchors with the curve's end velocity so physics take over seamlessly.
	-- After landing, the first moment the ball overlaps the PlotBounds volume its velocity is
	-- damped by BallPlotConfig.BoundsHitSlowFactor so the handoff momentum can't skid it across
	-- (or out of) the plot. Safety net: BallPlotConfig.OutOfBoundsRescueTime after the shot, a
	-- ball that is still not overlapping PlotBounds (a bad arc, a bounce off a fence) teleports
	-- to landPos.

	-- nil if no PlotBounds part is tagged (bounds checks then just no-op).
	local function isInPlotBounds(ball: BasePart): boolean?
		local bounds = resolveTaggedPart(TagsConfig.PlotBounds)
		if not bounds then
			return nil
		end
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { bounds }
		return #workspace:GetPartsInPart(ball, params) > 0
	end

	-- dress: parenting-dependent decoration (appearance/orbits/value UI) — the ball stays OUT
	-- of workspace for the ShotDelay muzzle hold (it must not be visible while the banked ball
	-- is still lingering out its destroy delay), so launchShot parents it when the shot fires
	-- and calls this right after. A ball consumed mid-hold (collect-all) never appears at all.
	-- onBoundsHit: optional override for the first-PlotBounds-overlap moment after landing —
	-- the merge shot deletes its visual ball there instead of damping it. Called exactly once.
	local function launchShot(ball: BasePart, shootPart: BasePart, landPos: Vector3, dress: () -> (), onBoundsHit: (() -> ())?)
		ball.CanCollide = false
		ball.CanTouch = false
		ball.CanQuery = false
		ball.Anchored = true
		local startPos = shootPart.Position
		local midPos = (startPos + landPos) / 2 + Vector3.new(0, BallPlotConfig.ShotArcHeight, 0)
		ball.CFrame = CFrame.new(startPos)

		-- Consumed (Destroyed) while still unparented can't be seen via ball.Parent — track it.
		local destroyed = false
		ball.Destroying:Once(function()
			destroyed = true
		end)

		task.delay(BallPlotConfig.ShotDelay, function()
			if destroyed then
				return -- claimed/consumed during the muzzle hold; it never appears
			end
			ball.Parent = workspace
			dress()

			local flightTime = BallPlotConfig.ShotTime
			local elapsed = 0
			local landed = false
			local conn: RBXScriptConnection
			conn = RunService.Heartbeat:Connect(function(dt: number)
				if not ball.Parent then
					conn:Disconnect() -- claimed/destroyed mid-flight
					return
				end
				if landed then
					-- Post-landing: watch for the first PlotBounds overlap.
					local inBounds = isInPlotBounds(ball)
					if inBounds == nil then
						-- No bounds volume tagged: still fire the callback (a merge must complete
						-- rather than strand its visual ball forever); nothing to damp against.
						conn:Disconnect()
						if onBoundsHit then
							onBoundsHit()
						end
					elseif inBounds then
						conn:Disconnect()
						if onBoundsHit then
							onBoundsHit()
						else
							ball.AssemblyLinearVelocity *= BallPlotConfig.BoundsHitSlowFactor
						end
					end
					return
				end
				elapsed += dt
				local t = math.min(elapsed / flightTime, 1)
				ball.Position = startPos:Lerp(midPos, t):Lerp(midPos:Lerp(landPos, t), t)
				if t >= 1 then
					landed = true
					ball.Anchored = false
					-- Bezier end tangent B'(1) = 2*(landPos - midPos)/T: physics continues the curve
					ball.AssemblyLinearVelocity = (landPos - midPos) * 2 / flightTime
					ball.CanCollide = true
					ball.CanTouch = true
					ball.CanQuery = true
				end
			end)
		end)

		-- Unconditional: fires even if the ball already hit bounds earlier (it may have bounced
		-- back out since). It only teleports, never retires the watcher — a still-pending
		-- onBoundsHit (merge finalize) then triggers off the now-in-bounds ball next frame.
		-- Counted from when the shot actually FIRES, so the muzzle hold doesn't eat into it.
		task.delay(BallPlotConfig.ShotDelay + BallPlotConfig.OutOfBoundsRescueTime, function()
			if not ball.Parent then
				return -- already claimed/consumed
			end
			if isInPlotBounds(ball) == false then
				ball.CFrame = CFrame.new(landPos)
				ball.AssemblyLinearVelocity = Vector3.zero
			end
		end)
	end

	-- Same gold the coin pickups' "+$X" banner uses (CoinService REWARD_COLOR) — a plot
	-- claim is the same "walked over free money" beat.
	local CLAIM_WARN_COLOR = Color3.fromRGB(255, 210, 60)

	----------------------------------------------------------------------------
	-- Collect-all pad (TagsConfig.PlotCollect): billboards the total claimable $
	-- and claims every plot ball at once on touch. Wired at the end of InitClient;
	-- refreshCollect is safe to call before then (it just no-ops).
	----------------------------------------------------------------------------
	local COLLECT_GREEN = Color3.fromRGB(0, 255, 0)
	local COLLECT_GRAY = Color3.fromRGB(128, 128, 128)
	local collectPart: BasePart? = nil
	local collectAmountLabel: TextLabel? = nil

	local function totalCollectible(): number
		local total = 0
		for _, v in ballValue do
			total += v
		end
		return total
	end

	-- Repaint the collect pad + its billboard from the current claimable total. Called on
	-- every event that changes ballValue (spawn, merge, claim, collect-all).
	local function refreshCollect()
		local part = collectPart
		local label = collectAmountLabel
		if not (part and label) then
			return
		end
		local total = totalCollectible()
		local hasMoney = total > 0
		label.Text = "$" .. StringUtils.FormatShort(total)
		label.TextColor3 = if hasMoney then COLLECT_GREEN else COLLECT_GRAY
		part.Color = if hasMoney then COLLECT_GREEN else COLLECT_GRAY
	end

	-- Visually + logically consume one plot ball (bookkeeping, burst, instance) WITHOUT the
	-- claim side effects (sound/banner/remote/refresh) — claim() and collectAll() layer
	-- those, since collect-all batches every ball into ONE remote call and one banner.
	local function consumeBall(ball: BasePart): ({ number }?, number)
		local ids = ballIds[ball]
		if not ids then
			return nil, 0
		end
		local value = ballValue[ball] or 0
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
		ball:Destroy() -- optimistic: gone locally the instant it's consumed
		return ids, value
	end

	local function claim(ball: BasePart)
		local ids, value = consumeBall(ball)
		if not ids then
			return
		end
		-- Collect SFX + "+$X" banner on the touch itself (same sound/colour/lifetime the coin
		-- pickups use), not on the server's credit round trip — the feedback has to land the
		-- instant the marble disappears. Optimistic like the rest of the claim.
		SoundService.Play({ soundId = SoundsConfig.Collect3 })
		if value > 0 then
			WarnUI.WarnLocal("+$" .. StringUtils.FormatShort(value), CLAIM_WARN_COLOR, CoinsConfig.RewardWarnLifetime)
		end
		claimRE:FireServer(ids)
		refreshCollect()
	end

	-- Claim EVERY plot ball (in-flight real shots included — the server already holds their
	-- ids as claimable) in one remote call, one sound, one summed banner.
	local function collectAll()
		local balls = {}
		for ball in ballIds do
			table.insert(balls, ball)
		end
		local allIds: { number } = {}
		local total = 0
		for _, ball in balls do
			local ids, value = consumeBall(ball)
			if ids then
				table.move(ids, 1, #ids, #allIds + 1, allIds)
				total += value
			end
		end
		if #allIds == 0 then
			return
		end
		SoundService.Play({ soundId = SoundsConfig.Collect3 })
		WarnUI.WarnLocal("+$" .. StringUtils.FormatShort(total), CLAIM_WARN_COLOR, CoinsConfig.RewardWarnLifetime)
		claimRE:FireServer(allIds, true) -- collect-all: server flies the big 10-icon celebration
		refreshCollect()
	end

	-- Rebirth wiped the claimable set server-side: remove every physical plot ball (and any
	-- still holding at the muzzle / mid-shot — Destroy retires their flight watchers) with no
	-- claim/burst/banner, and reset the collect pad.
	local function onClearAll()
		for ball in ballIds do
			ball:Destroy()
		end
		table.clear(ballIds)
		table.clear(ballValue)
		table.clear(ballSkin)
		table.clear(ballsBySkin)
		table.clear(plotBalls)
		table.clear(pulsing)
		refreshCollect()
	end

	-- Two stacked rows over the pad, WORLD-space offset (camera-space offsets lean/bend as
	-- the camera orbits; object-space ones follow the pad's authored rotation).
	local function setupCollectPad(part: BasePart)
		if collectPart then
			return -- one pad; ignore extras
		end
		collectPart = part

		local billboard = Instance.new("BillboardGui")
		billboard.Name = "PlotCollectBillboard"
		-- Scale units = studs: fixed WORLD size, shrinks with distance (pixel-Offset billboards
		-- render constant screen size, i.e. grow with distance).
		billboard.Size = UDim2.fromScale(7, 2.6)
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0)
		billboard.AlwaysOnTop = true
		billboard.MaxDistance = 120
		billboard.Parent = part

		local function makeRow(name: string, yScale: number, heightScale: number): TextLabel
			local row = Instance.new("TextLabel")
			row.Name = name
			row.Size = UDim2.new(1, 0, heightScale, 0)
			row.Position = UDim2.fromScale(0, yScale)
			row.BackgroundTransparency = 1
			row.Font = Enum.Font.FredokaOne
			row.TextScaled = true
			row.TextColor3 = Color3.new(1, 1, 1)
			row.Parent = billboard
			local rowStroke = Instance.new("UIStroke")
			rowStroke.Color = Color3.new(0, 0, 0)
			rowStroke.Thickness = 2
			rowStroke.Transparency = 0.2
			rowStroke.Parent = row
			return row
		end
		local title = makeRow("Title", 0, 0.5)
		title.Text = "Collect All"
		collectAmountLabel = makeRow("Amount", 0.5, 0.5)

		local TOUCH_DEBOUNCE = 0.4
		local lastTouch = 0
		part.Touched:Connect(function(obj: BasePart)
			local char = Players.LocalPlayer.Character
			if not (char and obj:IsDescendantOf(char)) then
				return
			end
			local now = os.clock()
			if now - lastTouch < TOUCH_DEBOUNCE then
				return
			end
			lastTouch = now
			collectAll()
		end)

		refreshCollect()
	end

	-- The visible half of a merge: bump the target's displayed value and pulse it. Split from
	-- the id bookkeeping because the merge shot defers this until its ball reaches the plot.
	local function showMerge(target: BasePart, value: number)
		ballValue[target] += value
		BallEffects.SetValueUI(target, ballValue[target])
		playMergePulse(target)
		refreshCollect()
	end

	local function onSpawn(id: unknown, skinIdRaw: unknown, value: unknown, sourceBall: unknown)
		if type(id) ~= "number" or type(value) ~= "number" then
			return
		end
		local skinId = if type(skinIdRaw) == "string" then skinIdRaw else BallSkins.GetDefaultId()
		-- The banked ball itself, if it's still lingering out its destroy delay on this
		-- client — cloning it carries EVERY appearance change the drop accumulated (heat
		-- paint/particles, size, material), not just the skin.
		local source: BasePart? = if typeof(sourceBall) == "Instance"
				and sourceBall:IsA("BasePart")
				and sourceBall.Parent
			then sourceBall
			else nil

		-- Already at the cap for this skin: merge into a random existing ball of it instead of
		-- adding a new live one. The id/claim bookkeeping happens NOW — a claim on the target
		-- mid-shot must still collect this value — but the visible merge waits for the shot.
		local list = getSkinList(skinId)
		local mergeTarget: BasePart? = nil
		if #list >= BallPlotConfig.MaxPerSkin then
			mergeTarget = list[math.random(#list)]
			table.insert(ballIds[mergeTarget], id)
			plotBalls[id] = mergeTarget
		end

		local plotPart = resolveTaggedPart(TagsConfig.PlotSpawn)
		local shootPart = resolveTaggedPart(TagsConfig.PlotShoot)
		if mergeTarget and not (plotPart and shootPart) then
			-- No way to play the shot: apply the merge instantly (pre-shot behavior).
			showMerge(mergeTarget, value)
			return
		end
		if not plotPart then
			return
		end

		local ball = (if source then source:Clone() else (BallConfig.Prefab :: BasePart):Clone())
		ball.Name = "PlotBall"
		ball.Anchored = false
		ball.CanCollide = true
		ball.CanQuery = true
		ball.CanTouch = true
		ball.CollisionGroup = PLOT_BALL_GROUP
		ball:RemoveTag(TagsConfig.Ball) -- never scored/hidden as a real live ball
		ball:SetAttribute(AttributesConfig.OwnerUserId, nil) -- a clone of a live ball isn't one
		-- Stamped like real board balls get at spawn (CosmeticService.onBallSpawn), so anything
		-- reading a ball's cosmetic identity generically — e.g. AttachValueUI's rarity-tinted
		-- value text — works on plot balls too.
		ball:SetAttribute(AttributesConfig.SkinId, skinId)
		local spread = BallPlotConfig.ShotSpread
		local landPos = plotPart.Position
			+ Vector3.new(
				(math.random() - 0.5) * 2 * spread,
				plotPart.Size.Y / 2 + ball.Size.Y,
				(math.random() - 0.5) * 2 * spread
			)
		-- Parenting-dependent decoration; the shot paths run it via launchShot when the ball
		-- actually enters workspace (after the ShotDelay muzzle hold), the no-shot fallback
		-- runs it right here.
		local function dress()
			if not source then
				-- Prefab fallback only: a source clone already wears the drop's full look, and
				-- re-applying would repaint it back to neutral (heat 0, default size/material).
				BallEffects.ApplyAppearance(ball, {
					skinId = skinId,
					heat = 0,
				})
			end
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
				worldSized = true, -- plot balls linger; their readout must shrink with distance
			})
			BallEffects.SetValueUI(ball, value)
		end

		if mergeTarget and shootPart then
			-- Visual-only merge shot: the ball flies in, vanishes on its first PlotBounds
			-- overlap, and only THEN does the target visibly absorb it (value bump + pulse).
			local target = mergeTarget
			launchShot(ball, shootPart, landPos, dress, function()
				ball:Destroy()
				if ballIds[target] then -- target may have been claimed mid-shot (this id went with it)
					showMerge(target, value)
				end
			end)
		elseif shootPart then
			launchShot(ball, shootPart, landPos, dress)
		else
			ball.CFrame = CFrame.new(landPos)
			ball.AssemblyLinearVelocity = Vector3.zero -- a source clone copies the drop's velocity
			ball.Parent = workspace
			dress()
		end

		if mergeTarget then
			return -- visual-only shot: its id already belongs to the merge target, and it is
			-- never claimable/tracked itself — launchShot's bounds hit consumes it
		end

		ballIds[ball] = { id }
		ballValue[ball] = value
		ballSkin[ball] = skinId
		plotBalls[id] = ball
		table.insert(list, ball)
		refreshCollect()

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
	;(PlotNet.ClearPlotBalls :: RemoteEvent).OnClientEvent:Connect(onClearAll)

	local collectPad = resolveTaggedPart(TagsConfig.PlotCollect)
	if collectPad then
		setupCollectPad(collectPad)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.PlotCollect):Connect(function(inst: Instance)
		if inst:IsA("BasePart") then
			setupCollectPad(inst)
		end
	end)
end

return BallPlotService
