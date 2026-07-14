--!strict
-- Ambient "roll preview" sample floating above each part tagged TagsConfig.FreeCratePad (the
-- "MarbleRoll" part in-world; its child "Pad" is the touchable floor part CosmeticsShop wires
-- up to claim). Continuously cycles through random candidate skins (weighted like the real
-- free-crate roll) so the pad reads as "always rolling" now that the free box is claimable so
-- often. Unlike CosmeticBallSample (which shows the player's actual selected skin in full
-- colour), this ball never reveals a real skin's colour/particles — it shows the SHAPE of
-- whatever skin it's cycling through (crowns/wings/etc., same shape attachments BallEffects
-- would apply), rendered as a silhouette, with a Highlight outline in that candidate's rarity
-- colour and a billboard on the pad reading the live "1 in X" odds. Each new candidate pops in
-- (starts small, tweens up to full size) to read as "cycling" rather than a static prop.
--
-- FreeRollBallSample.PlayRoll(result) IS the reveal for an actual claim (see CosmeticsShop's
-- runRoll): it takes over the idle cycle with an accelerating roll — same Bounce tick sound the
-- crate reel uses — that lands on the real rolled skin, in place of a screen-overlay reel.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local RS = game:GetService("ReplicatedStorage")

local BallConfig = require(RS.Shared.Config.Ball)
local CratesConfig = require(RS.Shared.Config.Crates)
local CosmeticBonus = require(RS.Shared.CosmeticBonus)
local WeightedRandom = require(RS.Shared.Utility.WeightedRandom)
local SoundsConfig = require(RS.Shared.Config.Sounds)
local TagsConfig = require(RS.Shared.Config.Tags)
local BallSkins = require(RS.Shared.BallSkins)
local BallEffects = require(RS.Shared.BallEffects)
local SoundService = require(RS.Shared.SoundService)
local StringUtils = require(RS.Shared.Utility.StringUtils)
local ProfileStats = require(RS.Shared.ProfileStats)
local ProfileNet = require(RS.Shared.Remote.ProfileNet)

local FreeRollBallSample = {}

local HEIGHT = 5.5   -- studs the ball floats above the tagged MarbleRoll part
local BOB_AMP = 0.5
local BOB_SPEED = 1.6
local SPIN_SPEED = 1.0
local SCALE = 1.35    -- bigger than a normal/cosmetic sample ball (was 1.8; shrunk to 3/4)
local TICK_INTERVAL = 3.0 -- how often the idle silhouette cycles to a new candidate
local SILHOUETTE_COLOR = Color3.new(0, 0, 0)

-- Same naming BallEffects uses for a skin's fixed shape attachments (crowns/wings/etc.) — matching
-- it lets BallEffects.UpdateOrbits (already exported, called every frame) position/scale these
-- parts for us without duplicating that per-frame math here.
local SHAPE_PART_NAME = "SkinShape"

-- New-candidate "pop": starts small, tweens up to full size — reads as the sample cycling.
local POP_START_FRACTION = 0.35
local POP_TWEEN_TIME = 0.12

-- Roll reveal: ticks fast then eases out, landing on the real result. Mirrors the feel of
-- CrateRollUI's reel (accelerate, then settle) without the screen overlay.
local ROLL_DURATION = 5.0
local ROLL_TICK_START = 0.03
local ROLL_TICK_END = 0.4
-- (No timed linger anymore: the revealed result sits — with its glow FX, idle cycling paused —
-- until the next roll starts and resets it.)
local TICK_VOLUME = 0.5

-- Mid-roll "tease": every TEASE_EVERY_MIN..MAX ticks (uniform), one candidate is picked as if
-- the player's Luck TIER were TEASE_TIERS_MIN..MAX (uniform) tiers higher than it really is —
-- flashing the rarer stuff a few more Luck tiers would surface. Visual flavour only; the roll
-- still lands on the server's real result.
local TEASE_EVERY_MIN, TEASE_EVERY_MAX = 3, 9
local TEASE_TIERS_MIN, TEASE_TIERS_MAX = 3, 10

-- Skins grouped by rarity, weighted-picked the same way CrateRollUI previews crate fillers.
local skinsByRarity: { [number]: { string } } = {}
for id, skin in BallSkins.GetAll() do
	local list = skinsByRarity[skin.rarity]
	if not list then
		list = {}
		skinsByRarity[skin.rarity] = list
	end
	table.insert(list, id)
end

-- The player's live Luck stat (and its raw tier, for the tease boost above), kept fresh from
-- ProfileChanged (see Init). The fake candidates the sample cycles through are skewed by it
-- exactly like the server's real roll (CosmeticService rollRarity's inverse-CDF sampling), so
-- what ticks past honestly previews the player's OWN odds — not the base odds a luckless
-- player would see.
local luck = 0
local luckTier = 0

local function rollSkin(weights: { number }, luckOverride: number?): (string, number)
	-- The same sampler the server's real roll uses (WeightedRandom, luck-biased), so what
	-- ticks past honestly previews the player's own odds.
	local rarity = WeightedRandom.PickIndexLuckBiased(weights, luckOverride or luck, nil, function(r)
		return skinsByRarity[r] ~= nil
	end) or 1
	local pool = skinsByRarity[rarity] or (skinsByRarity :: any)[next(skinsByRarity)]
	return pool[math.random(#pool)], rarity
end

local function oddsText(weights: { number }, rarity: number): string
	local total = 0
	for _, w in weights do
		total += w
	end
	local w = weights[rarity] or 0
	if w <= 0 then
		return "1 in ???"
	end
	return "1 in " .. StringUtils.FormatCompact(math.floor(total / w + 0.5))
end

-- The ball's bet multiplier (PER-SLOT LAUNCH REWORK: rarity multiplies your bet size —
-- CosmeticBonus.RarityBetMult — so the roll readout shows the N× you'd be launching at).
local function valueText(rarity: number): string
	return StringUtils.FormatShort(CosmeticBonus.RarityBetMult(rarity)) .. "×"
end

local function clearShapes(ball: BasePart)
	for _, child in ball:GetChildren() do
		if child:IsA("BasePart") and child.Name:sub(1, #SHAPE_PART_NAME) == SHAPE_PART_NAME then
			child:Destroy()
		end
	end
end

-- Rebuilds the ball's shape attachments from a skin's ShapeData, but in the silhouette colour
-- instead of the skin's real colours — same attributes BallEffects sets, so UpdateOrbits (called
-- every frame in onStep below) positions/scales them exactly like it would for a real skin.
local function applySilhouetteShapes(ball: BasePart, shapes: { BallSkins.ShapeData }?)
	clearShapes(ball)
	if not shapes then
		return
	end
	for i, s in shapes do
		local p = Instance.new("Part")
		p.Name = SHAPE_PART_NAME .. tostring(i)
		p.Shape = s.shape or Enum.PartType.Block
		p.Size = s.size or Vector3.new(0.8, 0.8, 0.8)
		p.Color = SILHOUETTE_COLOR
		p.Material = Enum.Material.Neon -- flat/unlit: no specular highlight on the silhouette
		p.Transparency = s.transparency or 0
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Massless = true
		p:SetAttribute("ShapeOffset", s.offset or Vector3.new(0, 1.2, 0))
		p:SetAttribute("ShapeOrient", s.orientation or Vector3.zero)
		p:SetAttribute("ShapeFollow", s.followRotation == true)
		p:SetAttribute("ShapeSize", p.Size)
		p.Parent = ball
	end
end

type Rig = {
	origin: Vector3,
	ball: BasePart,
	baseSize: Vector3,
	highlight: Highlight,
	nameLabel: TextLabel,   -- top row: skin name (white)
	rarityLabel: TextLabel, -- tall middle row: "1 in X", rarity-coloured
	valueLabel: TextLabel,  -- bottom row: bet multiplier "N×" (rarity-coloured)
	nextTick: number,
	rolling: boolean,
}

local rigs: { Rig } = {}
local clock = 0

-- The tagged instance is the "MarbleRoll" part; the ball floats above ITS position (not the
-- pad's), and the touch/billboard target is its child "Pad". A bare tagged part with no "Pad"
-- child falls back to itself (legacy shape).
local function resolvePad(inst: Instance): BasePart?
	local child = inst:FindFirstChild("Pad")
	if child and child:IsA("BasePart") then
		return child
	end
	if inst:IsA("BasePart") then
		return inst
	end
	return nil
end

local function resolveOrigin(inst: Instance, pad: BasePart): Vector3
	if inst:IsA("BasePart") then
		return inst.Position
	elseif inst:IsA("Model") then
		return inst:GetPivot().Position
	end
	return pad.Position
end

local function buildRig(origin: Vector3, pad: BasePart): Rig
	local ball = (BallConfig.Prefab :: BasePart):Clone()
	ball.Name = "FreeRollSampleBall"
	local baseSize = ball.Size * SCALE
	ball.Size = baseSize
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.Material = Enum.Material.Neon -- flat/unlit: no specular highlight on the silhouette
	ball.Color = SILHOUETTE_COLOR
	ball:RemoveTag(TagsConfig.Ball) -- appearance only; never a real (scored/hideable) ball

	-- Wrapped in a Model so the Highlight (adorned to the model, not the bare ball part) outlines
	-- every shape attachment (crowns/wings/etc, parented under the ball) too, not just the ball's
	-- own sphere — a Highlight adorned directly to a BasePart ignores its descendants.
	local model = Instance.new("Model")
	model.Name = "FreeRollSample"
	ball.Parent = model
	model.Parent = workspace

	local highlight = Instance.new("Highlight")
	highlight.Name = "RollHighlight"
	highlight.Adornee = model
	highlight.FillColor = SILHOUETTE_COLOR
	highlight.FillTransparency = 0.5
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = ball

	-- Three stacked rows: skin name (white) / rarity + odds (rarity colour, EMPHASIZED — the
	-- rarity is the hook, so its row is the tall one) / ball value (green). Adorned to the
	-- sample BALL, not the pad, riding just above it via ExtentsOffsetWorldSpace — WORLD-space
	-- (the plain ExtentsOffset is camera-space, which made the readout lean/bend over the ball
	-- as the camera orbited), still in units of the adornee's extents so the per-tick pop tween
	-- (ball shrinks then springs back) makes the billboard's height dip and rise with it.
	--
	-- STUD-sized (Scale) billboard + TextScaled rows: a fixed WORLD size that shrinks with
	-- camera distance like any object (a pixel-Offset billboard renders constant screen size,
	-- i.e. grows relative to the world as you back away). Wide enough that the longest odds
	-- row ("1 in 500.5K") fits with margin.
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "RollOddsBillboard"
	billboard.Adornee = ball
	billboard.Size = UDim2.fromScale(10, 3.1)
	billboard.ExtentsOffsetWorldSpace = Vector3.new(0, 2.1, 0) -- above the ball; tracks its tweened size
	billboard.MaxDistance = 120
	billboard.AlwaysOnTop = true
	billboard.Parent = ball

	-- Row text scales to its row height (the stud-sized billboard means rows have a fixed
	-- world height), so the height split IS the text-size hierarchy: rarity row tallest.
	local function makeRow(name: string, yScale: number, heightScale: number): TextLabel
		local row = Instance.new("TextLabel")
		row.Name = name
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, heightScale, 0)
		row.Position = UDim2.fromScale(0, yScale)
		row.Font = Enum.Font.FredokaOne
		row.TextScaled = true
		row.TextColor3 = Color3.new(1, 1, 1)
		row.TextStrokeColor3 = Color3.new(0, 0, 0)
		row.TextStrokeTransparency = 0.3
		row.Text = ""
		row.Parent = billboard
		-- Vertical shading: bright at the top, dimmer at the bottom. Multiplies the row's
		-- TextColor3, so each row keeps its own hue (white name, rarity-coloured rarity/value).
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = 90
		gradient.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(150, 150, 150))
		gradient.Parent = row
		return row
	end
	local nameLabel = makeRow("Name", 0, 0.26)
	local rarityLabel = makeRow("Rarity", 0.26, 0.48) -- the tall middle row
	-- Value row: rarity-coloured per tick/reveal (presentCandidate/presentReveal), like the rarity row.
	local valueLabel = makeRow("Value", 0.74, 0.26)

	return {
		origin = origin,
		ball = ball,
		baseSize = baseSize,
		highlight = highlight,
		nameLabel = nameLabel,
		rarityLabel = rarityLabel,
		valueLabel = valueLabel,
		nextTick = 0,
		rolling = false,
	}
end

-- Pops the ball back to full size from small — plays on every new candidate to read as cycling.
local function popBall(rig: Rig)
	rig.ball.Size = rig.baseSize * POP_START_FRACTION
	local tween = TweenService:Create(
		rig.ball,
		TweenInfo.new(POP_TWEEN_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = rig.baseSize }
	)
	tween:Play()
end

-- Cycling (idle ticks + mid-roll ticks): silhouette shape (fixed black fill, rarity-coloured
-- outline) + the three billboard rows. Never reveals the real skin's colour/particles, but
-- the name is fair game while idling. Mid-roll ticks pass masked=true: name and value read
-- "???" so only the rarity row carries information until the reveal lands.
local function presentCandidate(rig: Rig, skinId: string, rarity: number, masked: boolean?)
	local skin = BallSkins.Get(skinId)
	applySilhouetteShapes(rig.ball, skin and skin.data.shapes)
	local color = BallSkins.RarityColor(rarity)
	rig.highlight.OutlineColor = color
	-- The rarity and value rows wear the rarity colour; only the name stays white.
	rig.nameLabel.Text = if masked then "???" else (if skin then skin.name else skinId)
	rig.rarityLabel.TextColor3 = color
	rig.rarityLabel.Text = oddsText(CratesConfig.Free.Weights, rarity)
	rig.valueLabel.TextColor3 = color
	rig.valueLabel.Text = if masked then "???" else valueText(rarity)
	popBall(rig)
end

-- Reveal celebration: a big one-shot rarity-coloured burst plus an ambient glow emitter that
-- keeps sparkling for as long as the revealed ball lingers (cleaned up by resetToSilhouette
-- when the next roll starts).
local REVEAL_BURST_NAME = "RevealBurst"
local REVEAL_GLOW_NAME = "RevealGlow"
local REVEAL_BURST_COUNT = 50
local function clearRevealFX(ball: BasePart)
	for _, name in { REVEAL_BURST_NAME, REVEAL_GLOW_NAME } do
		local existing = ball:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
	end
end
local function playRevealFX(ball: BasePart, color: Color3)
	clearRevealFX(ball)

	local burst = Instance.new("ParticleEmitter")
	burst.Name = REVEAL_BURST_NAME
	burst.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	burst.Color = ColorSequence.new(color)
	burst.Lifetime = NumberRange.new(0.6, 1.2)
	burst.Speed = NumberRange.new(22, 38)
	burst.Size = NumberSequence.new(1.2, 0)
	burst.Transparency = NumberSequence.new(0, 1)
	burst.SpreadAngle = Vector2.new(180, 180)
	burst.Rate = 0
	burst.Drag = 4
	burst.RotSpeed = NumberRange.new(-360, 360)
	burst.LightEmission = 1
	burst.Brightness = 8
	burst.Parent = ball
	burst:Emit(REVEAL_BURST_COUNT)

	local glow = Instance.new("ParticleEmitter")
	glow.Name = REVEAL_GLOW_NAME
	glow.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	glow.Color = ColorSequence.new(color)
	glow.Lifetime = NumberRange.new(0.8, 1.6)
	glow.Speed = NumberRange.new(1, 3)
	glow.Size = NumberSequence.new(0.5, 0)
	glow.Transparency = NumberSequence.new(0.1, 1)
	glow.SpreadAngle = Vector2.new(180, 180)
	glow.Rate = 24
	glow.LightEmission = 1
	glow.Brightness = 4
	glow.Parent = ball
end

-- The final landing of an actual roll: shows the REAL skin (full colour/particles/shapes via
-- BallEffects, same path the shop sample uses), not a silhouette, plus the reveal burst/glow.
-- Our own outline is disabled while BallEffects' own skin highlight (if any) takes over; the
-- billboard rows read the same as during idle cycling (name / rarity + odds / value).
local function presentReveal(rig: Rig, skinId: string, rarity: number)
	local skin = BallSkins.Get(skinId)
	BallEffects.ApplyAppearance(rig.ball, { skinId = skinId, heat = 0 })
	rig.highlight.Enabled = false
	rig.nameLabel.Text = if skin then skin.name else skinId
	local color = BallSkins.RarityColor(rarity)
	rig.rarityLabel.TextColor3 = color
	rig.rarityLabel.Text = oddsText(CratesConfig.Free.Weights, rarity)
	rig.valueLabel.TextColor3 = color
	rig.valueLabel.Text = valueText(rarity)
	playRevealFX(rig.ball, color)
	popBall(rig)
end

-- Clears whatever a reveal left behind (real particles/orbits/highlight via ApplyAppearance,
-- plus our burst/glow emitters) and puts the ball back into its silhouette base state.
local function resetToSilhouette(rig: Rig)
	BallEffects.ApplyAppearance(rig.ball, { skinId = BallSkins.GetDefaultId(), heat = 0 })
	clearRevealFX(rig.ball)
	local skinHighlight = rig.ball:FindFirstChild("SkinHighlight")
	if skinHighlight then
		skinHighlight:Destroy()
	end
	rig.ball.Color = SILHOUETTE_COLOR
	rig.ball.Material = Enum.Material.Neon -- flat/unlit: no specular highlight on the silhouette
	rig.highlight.Enabled = true
end

local function onStep(dt: number)
	clock += dt
	for _, rig in rigs do
		local bob = math.sin(clock * BOB_SPEED * math.pi * 2) * BOB_AMP
		local pos = rig.origin + Vector3.new(0, HEIGHT + bob, 0)
		rig.ball.CFrame = CFrame.new(pos) * CFrame.Angles(0, clock * SPIN_SPEED, 0)
		BallEffects.UpdateOrbits(rig.ball) -- positions/scales the shape attachments each frame
		if not rig.rolling and clock >= rig.nextTick then
			rig.nextTick = clock + TICK_INTERVAL
			local skinId, rarity = rollSkin(CratesConfig.Free.Weights)
			presentCandidate(rig, skinId, rarity)
		end
	end
end

-- The reveal for an actual free-crate claim (passed as CosmeticsShop.runRoll's `reveal`):
-- takes over the idle cycle with an accelerating roll that lands on the ACTUAL rolled skin.
-- Yields only through the roll+reveal (same contract as CrateRollUI.Play — runRoll banners the
-- result right after this returns). The revealed ball then LINGERS — full skin, burst/glow FX
-- — until the NEXT roll starts (no timed reset back to idle cycling; the next PlayRoll's
-- resetToSilhouette below is what clears it).
function FreeRollBallSample.PlayRoll(result: any)
	if #rigs == 0 or type(result) ~= "table" or not result.ok or type(result.rarity) ~= "number" then
		return
	end
	for _, rig in rigs do
		-- Clear whatever the still-lingering previous reveal left on the ball (real
		-- particles/orbits/colour, reveal FX) — a new roll always starts from a clean
		-- silhouette.
		resetToSilhouette(rig)
		rig.rolling = true
	end

	local elapsed = 0
	local ticksUntilTease = math.random(TEASE_EVERY_MIN, TEASE_EVERY_MAX)
	while elapsed < ROLL_DURATION do
		local t = elapsed / ROLL_DURATION
		local waitTime = ROLL_TICK_START + (ROLL_TICK_END - ROLL_TICK_START) * t
		local skinId, rarity
		ticksUntilTease -= 1
		if ticksUntilTease <= 0 then
			-- Tease tick: pick as if Luck were a few tiers higher than it really is.
			ticksUntilTease = math.random(TEASE_EVERY_MIN, TEASE_EVERY_MAX)
			local boostedLuck = ProfileStats.GetLuck({ Luck = luckTier + math.random(TEASE_TIERS_MIN, TEASE_TIERS_MAX) })
			skinId, rarity = rollSkin(CratesConfig.Free.Weights, boostedLuck)
		else
			skinId, rarity = rollSkin(CratesConfig.Free.Weights)
		end
		for _, rig in rigs do
			presentCandidate(rig, skinId, rarity, true) -- masked: name/value read "???" mid-roll
		end
		SoundService.Play({ soundId = SoundsConfig.Bounce, volume = TICK_VOLUME, jitter = 0.04 })
		task.wait(waitTime)
		elapsed += waitTime
	end

	for _, rig in rigs do
		presentReveal(rig, result.skinId, result.rarity)
	end
	SoundService.Play({ soundId = SoundsConfig.Bounce, volume = TICK_VOLUME + 0.1 })
	-- rig.rolling stays true on purpose: the revealed ball (and its glow) lingers, with idle
	-- cycling paused, until the next PlayRoll resets everything.
end

function FreeRollBallSample.Init()
	local function setup(inst: Instance)
		local pad = resolvePad(inst)
		if pad then
			local origin = resolveOrigin(inst, pad)
			local rig = buildRig(origin, pad)
			table.insert(rigs, rig)
			local skinId, rarity = rollSkin(CratesConfig.Free.Weights)
			presentCandidate(rig, skinId, rarity) -- show something immediately
		end
	end
	for _, inst in CollectionService:GetTagged(TagsConfig.FreeCratePad) do
		setup(inst)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.FreeCratePad):Connect(setup)

	-- Keep `luck` fresh so the fake candidates skew like the player's real rolls (same
	-- ProfileChanged + initial-GetProfile pattern BallLaunchUI uses for its cached upgrades).
	local function adoptProfile(profile: any)
		if type(profile) == "table" and type(profile.upgrades) == "table" then
			luck = ProfileStats.GetLuck(profile.upgrades)
			luckTier = if type(profile.upgrades.Luck) == "number" then profile.upgrades.Luck else 0
		end
	end
	;(ProfileNet.ProfileChanged :: RemoteEvent).OnClientEvent:Connect(adoptProfile)
	task.spawn(function()
		local ok, profile = pcall(function()
			return (ProfileNet.GetProfile :: RemoteFunction):InvokeServer()
		end)
		if ok then
			adoptProfile(profile)
		end
	end)

	RunService.RenderStepped:Connect(onStep)
end

return FreeRollBallSample
