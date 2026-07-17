--!strict
-- Peg "heat sense" visual: hot/cold pegs read as ordinary pegs (the default NormalColor
-- pink) until the LOCAL player invests in the PegHeat ("Heat Sense") upgrade — each tier
-- blends the peg's color
-- further toward its true hot/cold identity and unlocks scaling particle FX (orange sparks
-- on hot, a pale-blue aura on cold), maxing out at PegsConfig.HeatAppearance.MaxTier. Also
-- reveals PegService's hidden "double-hot" promotion (Neon + Fire) once the viewer's tier
-- clears DoubleHotMinTier — otherwise a double-hot peg looks like an ordinary hot one.
-- Normal (neither hot nor cold) pegs ignore the PegHeat tier entirely and stay the flat
-- default purple (NormalColor) — the board/grass carry the bet-tier theme, not the pegs.
--
-- Same "local view of shared state" pattern as GoldenPegView/BoardAppearanceView: the pegs
-- (and their AttributesConfig.PegHeat gameplay value) are server-shared, but the paint job
-- is per-viewer. PegService re-tweens peg Color every ~60s (category re-roll), so the local
-- override re-asserts itself via GetPropertyChangedSignal, same as GoldenPegView.

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local AttributesConfig = require(RS.Shared.Config.Attributes)
local PegsConfig = require(RS.Shared.Config.Pegs)
-- Golden pegs outrank the heat look: both views locally repaint the same pegs and both
-- re-assert Color against server repaints, so exactly ONE of them may own any given peg —
-- two re-assert handlers writing different colors re-trigger each other unboundedly and
-- hard-freeze the client. Heat yields: golden pegs are skipped here (IsGolden) and repainted
-- once they leave the golden set (SetChanged).
local GoldenPegView = require(script.Parent.GoldenPegView)
local ProfileNet = require(RS.Shared.Remote.ProfileNet)

local PegHeatView = {}

local A = PegsConfig.HeatAppearance
local HEAT_ATTR = AttributesConfig.PegHeat
local DOUBLE_HOT_FIRE_NAME = "PegHeatViewDoubleHotFire" -- distinct from any server-side name

type Category = "Hot" | "Cold" | "Normal"

-- Mirrors PegService.CATEGORIES' materials (Hot/Normal = Plastic, Cold = Limestone).
-- Deliberately hardcoded here rather than read back off peg.Material reactively: signal
-- ordering relative to PegService's own SetAttribute-then-Material writes on the SAME event
-- isn't guaranteed (deferred vs. immediate signal behavior), so "restore to whatever
-- Material happened to be when the attribute changed" is fragile — this isn't.
local CATEGORY_MATERIAL: { [Category]: Enum.Material } = {
	Hot = Enum.Material.Plastic,
	Cold = Enum.Material.Limestone,
	Normal = Enum.Material.Plastic,
}

type Entry = {
	colorConn: RBXScriptConnection?,
	attrConn: RBXScriptConnection?,
	category: Category,
	targetColor: Color3?, -- nil only before the first applyEntry (colorFor is never nil once set)
	isDoubleHot: boolean,
	hotSpark: ParticleEmitter?,
	coldAura: ParticleEmitter?,
	doubleFire: ParticleEmitter?,
}

local tier = 0
local entries: { [BasePart]: Entry } = {}

-- Hot/Cold/Normal from the raw heat attribute; also whether a "Hot" peg is actually the
-- hidden double-hot promotion (heat noticeably above the ordinary HotHeat value).
local function readHeat(peg: BasePart): (Category, boolean)
	local h = peg:GetAttribute(HEAT_ATTR)
	if type(h) ~= "number" or h == 0 then
		return "Normal", false
	end
	if h > 0 then
		return "Hot", h > PegsConfig.HotHeat + 1e-6
	end
	return "Cold", false
end

local function colorFor(category: Category): Color3
	if category == "Normal" then
		-- Neutral pegs carry no heat signal either way, so they don't follow the PegHeat tier
		-- (unlike Hot/Cold below) — they're always the flat default purple; the board/grass
		-- (BoardAppearanceView) carry the bet-tier theme.
		return A.NormalColor
	end
	local trueColor = if category == "Hot" then A.Hot.Color else A.Cold.Color
	local frac = math.clamp(tier / A.MaxTier, 0, 1)
	-- Tier 0 = indistinguishable from a normal peg; each Heat Sense tier blends toward
	-- the true hot/cold identity.
	return A.NormalColor:Lerp(trueColor, frac)
end

local function particleStrength(): number
	if tier < A.Particles.MinTier then
		return 0
	end
	return math.clamp((tier - A.Particles.MinTier) / math.max(1, A.MaxTier - A.Particles.MinTier), 0, 1)
end

local function ensureHotSpark(peg: BasePart): ParticleEmitter
	local existing = peg:FindFirstChild("PegHeatViewSpark")
	if existing and existing:IsA("ParticleEmitter") then
		return existing
	end
	local e = Instance.new("ParticleEmitter")
	e.Name = "PegHeatViewSpark"
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Color = ColorSequence.new(A.Particles.HotSparkColor)
	e.LightEmission = 0.6
	e.LightInfluence = 0
	e.Lifetime = NumberRange.new(0.25, 0.5)
	e.Speed = NumberRange.new(3, 7)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-180, 180)
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Enabled = false
	e.Parent = peg
	return e
end

local function ensureColdAura(peg: BasePart): ParticleEmitter
	local existing = peg:FindFirstChild("PegHeatViewAura")
	if existing and existing:IsA("ParticleEmitter") then
		return existing
	end
	local e = Instance.new("ParticleEmitter")
	e.Name = "PegHeatViewAura"
	e.Texture = "rbxasset://textures/particles/smoke_main.dds"
	e.Color = ColorSequence.new(A.Particles.ColdAuraColor)
	e.LightEmission = 0.15
	e.LightInfluence = 1
	e.Lifetime = NumberRange.new(0.9, 1.5)
	e.Speed = NumberRange.new(0.2, 0.6)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Enabled = false
	e.Parent = peg
	return e
end

local function ensureDoubleFire(peg: BasePart): ParticleEmitter
	local existing = peg:FindFirstChild(DOUBLE_HOT_FIRE_NAME)
	if existing and existing:IsA("ParticleEmitter") then
		return existing
	end
	local e = Instance.new("ParticleEmitter")
	e.Name = DOUBLE_HOT_FIRE_NAME
	e.Texture = "rbxasset://textures/particles/fire_main.dds"
	e.Color = ColorSequence.new(Color3.fromRGB(255, 130, 0), A.Hot.Color)
	e.LightEmission = 1
	e.Lifetime = NumberRange.new(0.4, 0.7)
	e.Rate = 30
	e.Speed = NumberRange.new(2, 4)
	e.SpreadAngle = Vector2.new(20, 20)
	e.Size = NumberSequence.new(peg.Size.Magnitude * 0.5)
	e.Enabled = false
	e.Parent = peg
	return e
end

local function applyEntry(peg: BasePart, entry: Entry)
	local category, isDoubleHot = readHeat(peg)
	entry.category = category
	entry.isDoubleHot = isDoubleHot

	-- Hands off golden pegs entirely (color, material, particles): GoldenPegView owns their
	-- look while they're golden. targetColor stays nil so our Color re-assert stands down too.
	if GoldenPegView.IsGolden(peg) then
		entry.targetColor = nil
		if entry.hotSpark then
			entry.hotSpark.Enabled = false
		end
		if entry.coldAura then
			entry.coldAura.Enabled = false
		end
		if entry.doubleFire then
			entry.doubleFire.Enabled = false
		end
		return
	end

	entry.targetColor = colorFor(category)
	if entry.targetColor then
		peg.Color = entry.targetColor
	end

	local strength = particleStrength()
	if category == "Hot" and strength > 0 then
		local spark = entry.hotSpark or ensureHotSpark(peg)
		entry.hotSpark = spark
		spark.Rate = 4 + 20 * strength
		spark.Enabled = true
	elseif entry.hotSpark then
		entry.hotSpark.Enabled = false
	end

	if category == "Cold" and strength > 0 then
		local aura = entry.coldAura or ensureColdAura(peg)
		entry.coldAura = aura
		aura.Rate = 2 + 8 * strength
		aura.Enabled = true
	elseif entry.coldAura then
		entry.coldAura.Enabled = false
	end

	-- Reveal the hidden double-hot promotion only once heat sense clears its own,
	-- separately-gated threshold — a Neon glow + Fire, matching PegService's original
	-- (now server-removed) shared look.
	local revealDouble = isDoubleHot and tier >= A.DoubleHotMinTier
	if revealDouble then
		peg.Material = Enum.Material.Neon
		local fire = entry.doubleFire or ensureDoubleFire(peg)
		entry.doubleFire = fire
		fire.Enabled = true
	else
		peg.Material = CATEGORY_MATERIAL[category]
		if entry.doubleFire then
			entry.doubleFire.Enabled = false
		end
	end
end

local function trackPeg(peg: BasePart)
	if entries[peg] then
		return
	end
	local entry: Entry = {
		colorConn = nil,
		attrConn = nil,
		category = "Normal",
		targetColor = nil,
		isDoubleHot = false,
		hotSpark = nil,
		coldAura = nil,
		doubleFire = nil,
	}
	entries[peg] = entry
	-- PegService's repaint tween replicates a Color write every frame it steps; re-assert
	-- our override the same way GoldenPegView does so it wins the tug-of-war. NEVER against
	-- a golden peg though (checked live, not just via targetColor: the peg may turn golden
	-- before our next applyEntry) — see the GoldenPegView require above.
	entry.colorConn = peg:GetPropertyChangedSignal("Color"):Connect(function()
		if entry.targetColor and peg.Color ~= entry.targetColor and not GoldenPegView.IsGolden(peg) then
			peg.Color = entry.targetColor
		end
	end)
	-- The category (and double-hot promotion) can change on every ~60s repaint.
	entry.attrConn = peg:GetAttributeChangedSignal(HEAT_ATTR):Connect(function()
		applyEntry(peg, entry)
	end)
	applyEntry(peg, entry)
end

local function repaintAll()
	for peg, entry in entries do
		applyEntry(peg, entry)
	end
end

local function gatherPegs(): { BasePart }
	local out: { BasePart } = {}
	local folder = workspace:FindFirstChild("Pegs")
	if not folder then
		return out
	end
	for _, inst in folder:GetDescendants() do
		if inst:IsA("BasePart") then
			table.insert(out, inst)
		end
	end
	return out
end

local function setTierFromProfile(profile: any)
	local t = if type(profile) == "table" and type(profile.upgrades) == "table" then profile.upgrades.PegHeat else nil
	if type(t) == "number" and t ~= tier then
		tier = t
		repaintAll()
	end
end

function PegHeatView.Init()
	for _, peg in gatherPegs() do
		trackPeg(peg)
	end

	local getProfileRF = ProfileNet.GetProfile :: RemoteFunction
	local profileChangedRE = ProfileNet.ProfileChanged :: RemoteEvent

	profileChangedRE.OnClientEvent:Connect(setTierFromProfile)
	-- A peg entering the golden set gets skipped above; one leaving it needs its heat look
	-- put back — repaint on every set change (rare: join load, prestige).
	GoldenPegView.SetChanged:Connect(repaintAll)

	local ok, profile = pcall(function()
		return getProfileRF:InvokeServer()
	end)
	if ok then
		setTierFromProfile(profile)
	end
end

return PegHeatView
