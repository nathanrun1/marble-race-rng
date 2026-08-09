--!strict
-- Client renderer + collector for per-player coins. The server (CoinService) tells this
-- player which TagsConfig.Coin locations are active and what each is worth; we render them
-- as classic collectibles (bob + spin + sparkle, brighter/with a light at higher values),
-- detect the local character touching one, and request a claim. Every visual is a LOCAL
-- write (LocalTransparencyModifier, locally-created emitter/light, client-only PivotTo on
-- the anchored part), so each player sees and collects their own coins independently.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CoinsConfig = require(RS.Shared.Config.Coins)
local TagsConfig = require(RS.Shared.Config.Tags)
local Signal = require(RS.Shared.Utility.Signal)

local CoinPickups = {}

-- Fires () whenever a coin THIS client claimed gets deactivated by the server (i.e. our own
-- claim request resolved, successfully or not — see onTouched's optimistic-hide comment).
-- Orthogonal consumer: e.g. the tutorial's "collect a coin" step just listens for this.
CoinPickups.Claimed = Signal.new()

local player = Players.LocalPlayer
local CurrencyFlyUI = require(script.Parent.CurrencyFlyUI)
local CoinNet = require(RS.Shared.Remote.CoinNet)

local activateRE = CoinNet.CoinActivate :: RemoteEvent
local deactivateRE = CoinNet.CoinDeactivate :: RemoteEvent
local claimRE = CoinNet.CoinClaim :: RemoteEvent
local readyRE = CoinNet.CoinReady :: RemoteEvent
local forceSpawnRE = CoinNet.ForceSpawnCoin :: RemoteEvent

-- Visual tuning (gameplay values — value range, spawn cadence — live in CoinsConfig).
local BOB_HEIGHT = 0.6  -- studs up/down
local BOB_SPEED  = 2.5  -- bob radians/sec
local SPIN_SPEED = 2.0  -- spin radians/sec
local COIN_GOLD  = Color3.fromRGB(255, 205, 55)
local COIN_RED   = Color3.fromRGB(220, 40, 40) -- tint for top-value coins (parts + decals)
local COIN_BLUE  = Color3.fromRGB(60, 140, 255) -- tint for Diamond coins (parts + decals + shine)
local TWO_PI     = math.pi * 2

local SPARKLE_GOLD = ColorSequence.new(Color3.fromRGB(255, 240, 170), Color3.fromRGB(255, 200, 40))
local SPARKLE_BLUE = ColorSequence.new(Color3.fromRGB(190, 225, 255), Color3.fromRGB(60, 140, 255))

type CoinVisual = {
	coin: PVInstance, -- the tagged BasePart/Model (animated via GetPivot/PivotTo)
	base: CFrame,
	parts: { BasePart },
	decals: { Decal }, -- Decals/Textures on the coin (Texture is-a Decal); toggled with the parts
	origColor: { [Instance]: Color3 }, -- authored colour per part/decal, to restore non-red coins
	emitter: ParticleEmitter,
	light: PointLight,
	phase: number,
	active: boolean,
	isBlue: boolean, -- current activation's reward type (Diamonds vs cash)
	value: number?, -- current activation's payout (server-sent), for the fly's live sum
	pending: boolean, -- claim sent, awaiting server deactivate
}

local visuals: { CoinVisual } = {}
local byCoin: { [Instance]: CoinVisual } = {}

-- value -> [0,1] across the configured range (drives particle strength + shine).
local function valueT(value: number): number
	local c = CoinsConfig
	if c.ValueMax <= c.ValueMin then
		return 1
	end
	return math.clamp((value - c.ValueMin) / (c.ValueMax - c.ValueMin), 0, 1)
end

local function renderPart(coin: Instance): BasePart?
	if coin:IsA("BasePart") then
		return coin
	end
	if coin:IsA("Model") then
		return coin.PrimaryPart or coin:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function collectParts(coin: Instance): { BasePart }
	local parts: { BasePart } = {}
	if coin:IsA("BasePart") then
		table.insert(parts, coin)
	end
	for _, d in coin:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	return parts
end

-- All Decals/Textures under the coin (Texture inherits Decal, so IsA("Decal") catches both).
local function collectDecals(coin: Instance): { Decal }
	local decals: { Decal } = {}
	for _, d in coin:GetDescendants() do
		if d:IsA("Decal") then
			table.insert(decals, d)
		end
	end
	return decals
end

-- Scale particle output (and the top-value light) to the coin's worth, then it's ready to
-- show. Blue (Diamond) coins ignore the cash ValueMin/Max range entirely — their reward
-- (1-10 Diamonds) isn't on that scale — and always render at full strength/blue tint.
local function applyStrength(cv: CoinVisual, value: number, isBlue: boolean)
	local t = if isBlue then 1 else valueT(value)
	local e = cv.emitter
	e.Color = if isBlue then SPARKLE_BLUE else SPARKLE_GOLD
	e.Rate = 6 + 26 * t
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2 + 0.55 * t),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Speed = NumberRange.new(1 + 2 * t, 2 + 4 * t)

	-- Only the top fraction of the value range gets an actual light source (blue coins
	-- always get one — they're always "full strength").
	local shine = isBlue or t >= (1 - CoinsConfig.ShineTopFraction)
	cv.light.Enabled = shine
	if shine then
		cv.light.Color = if isBlue then COIN_BLUE else COIN_GOLD
		cv.light.Brightness = 2 + 4 * t
		cv.light.Range = 8 + 8 * t
	end

	-- Blue coins always tint blue; otherwise the top fraction of the value range tints red
	-- (parts + decals); others restore their authored colour (a coin location can be
	-- re-rolled to a different value/type).
	local tint = if isBlue then COIN_BLUE elseif t >= (1 - CoinsConfig.RedTopFraction) then COIN_RED else nil
	for _, p in cv.parts do
		p.Color = tint or cv.origColor[p]
	end
	for _, d in cv.decals do
		d.Color3 = tint or cv.origColor[d]
	end
end

-- Show/hide a coin locally. Coins are authored invisible (Transparency = 1), so showing sets
-- parts AND their decals/textures opaque; hiding sets them back transparent. These are local
-- property writes (never replicated), so each player toggles their own coins. Hidden coins are
-- non-touchable, sparkle-off, and parked at home; the render loop only animates active ones.
local SHOWN_TRANSPARENCY = 0
local HIDDEN_TRANSPARENCY = 1

local function setActive(cv: CoinVisual, active: boolean, value: number?, isBlue: boolean?)
	cv.active = active
	cv.isBlue = isBlue == true
	cv.value = if active then value else nil
	local transparency = if active then SHOWN_TRANSPARENCY else HIDDEN_TRANSPARENCY
	for _, p in cv.parts do
		p.Transparency = transparency
		p.CanTouch = active
	end
	for _, d in cv.decals do
		d.Transparency = transparency
	end
	cv.emitter.Enabled = active
	if active and value then
		applyStrength(cv, value, cv.isBlue)
	else
		cv.light.Enabled = false
		cv.coin:PivotTo(cv.base) -- home pose
	end
end

local function onTouched(cv: CoinVisual, obj: BasePart)
	if not cv.active or cv.pending then
		return
	end
	local char = player.Character
	if not char or not obj:IsDescendantOf(char) then
		return
	end
	cv.pending = true
	-- Same optimism as the hide below: celebrate at touch, before the server confirms (so
	-- the fly's live-sum hold naturally starts pre-grant). Read isBlue/value BEFORE
	-- setActive, which resets them. Smaller burst than the claim-panel flows — coins are
	-- picked up constantly during normal play.
	CurrencyFlyUI.Play(if cv.isBlue then "Diamonds" else "Cash", math.random(4, 6), cv.value)
	setActive(cv, false) -- optimistic hide for snappy feedback
	claimRE:FireServer(cv.coin)
end

local function build(coin: Instance): CoinVisual?
	if byCoin[coin] then
		return byCoin[coin]
	end
	local render = renderPart(coin)
	if not render then
		return nil
	end

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "CoinSparkle"
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 240, 170), Color3.fromRGB(255, 200, 40))
	emitter.LightEmission = 0.7
	emitter.LightInfluence = 0
	emitter.Lifetime = NumberRange.new(0.6, 1.1)
	emitter.Rate = 12
	emitter.Speed = NumberRange.new(1, 3)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, 2, 0)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Enabled = false
	emitter.Parent = render

	local light = Instance.new("PointLight")
	light.Name = "CoinShine"
	light.Color = COIN_GOLD
	light.Enabled = false
	light.Parent = render

	-- renderPart succeeded, so coin is a BasePart/Model (a PVInstance).
	local pv = coin :: PVInstance
	local base = pv:GetPivot()
	local parts = collectParts(coin)
	local decals = collectDecals(coin)
	-- Snapshot authored colours so non-red coins can be restored after a re-roll.
	local origColor: { [Instance]: Color3 } = {}
	for _, p in parts do
		origColor[p] = p.Color
	end
	for _, d in decals do
		origColor[d] = d.Color3
	end
	local cv: CoinVisual = {
		coin = pv,
		base = base,
		parts = parts,
		decals = decals,
		origColor = origColor,
		emitter = emitter,
		light = light,
		-- Desync the bob/spin per coin so a cluster doesn't pulse in unison.
		phase = (base.Position.X + base.Position.Z) % TWO_PI,
		active = false,
		isBlue = false,
		pending = false,
	}
	for _, p in cv.parts do
		p.Touched:Connect(function(obj)
			onTouched(cv, obj)
		end)
	end

	byCoin[coin] = cv
	table.insert(visuals, cv)
	setActive(cv, false) -- start hidden until the server activates it for us
	return cv
end

local function destroy(coin: Instance)
	local cv = byCoin[coin]
	if not cv then
		return
	end
	cv.emitter:Destroy()
	cv.light:Destroy()
	byCoin[coin] = nil
	for i, v in visuals do
		if v == cv then
			table.remove(visuals, i)
			break
		end
	end
end

local function animate()
	local now = os.clock()
	for _, cv in visuals do
		if cv.active then
			local bob = math.sin(now * BOB_SPEED + cv.phase) * BOB_HEIGHT
			local spin = (now * SPIN_SPEED + cv.phase) % TWO_PI
			cv.coin:PivotTo(cv.base * CFrame.new(0, bob, 0) * CFrame.Angles(0, spin, 0))
		end
	end
end

function CoinPickups.Init()
	for _, coin in CollectionService:GetTagged(TagsConfig.Coin) do
		build(coin)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.Coin):Connect(function(coin)
		build(coin)
	end)
	CollectionService:GetInstanceRemovedSignal(TagsConfig.Coin):Connect(destroy)

	activateRE.OnClientEvent:Connect(function(coin: Instance, value: number, isBlue: boolean?)
		local cv = byCoin[coin] or build(coin)
		if cv then
			cv.pending = false
			setActive(cv, true, value, isBlue == true)
		end
	end)
	deactivateRE.OnClientEvent:Connect(function(coin: Instance)
		local cv = byCoin[coin]
		if cv then
			if cv.pending then
				CoinPickups.Claimed:Fire()
			end
			cv.pending = false
			setActive(cv, false)
		end
	end)

	RunService.RenderStepped:Connect(animate)

	-- Tell the server we're listening; it seeds our initial coins and starts our timer.
	readyRE:FireServer()
end

-- Nearest currently-active coin's world position, or nil if none are active for us right
-- now. Orthogonal helper for anything that wants to point at "the" coin (e.g. WorldArrow).
function CoinPickups.GetNearestActivePosition(fromPos: Vector3): Vector3?
	local best: Vector3? = nil
	local bestDist = math.huge
	for _, cv in visuals do
		if cv.active then
			local pos = cv.coin:GetPivot().Position
			local d = (pos - fromPos).Magnitude
			if d < bestDist then
				bestDist = d
				best = pos
			end
		end
	end
	return best
end

-- Ask the server to force-activate one coin right now (bypassing the spawn timer), for
-- callers that need a guaranteed active coin (the tutorial's "collect a coin" step). No-op
-- server-side if the player's already at MaxActive or there's no free location.
function CoinPickups.RequestForceSpawn()
	forceSpawnRE:FireServer()
end

return CoinPickups
