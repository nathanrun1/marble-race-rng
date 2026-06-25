--!strict
-- Owns the peg field. Treats every BasePart under Workspace.Pegs as a peg:
-- tags it ScoreTarget (so ScoringService detects contacts) and, once per minute,
-- paints it hot / cold / normal by its horizontal position in the field.
--
-- Pattern, by distance from the nearest edge: the edges are 50/50 hot/cold, then
-- a hot band, then a cold band, then normal toward the center. Each band is a
-- weighted random pick, so categories mix a little rather than forming clean
-- stripes. The hot/cold heat values live in Config.Pegs (cold's malus is meant to
-- run slightly bigger than hot's bonus, so sloppy aim is punished).

local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(RS.Shared.Config)

local PegService = {}

local REASSIGN_INTERVAL = 60 -- seconds between repaints
local COLOR_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Each repaint we promote random hot pegs to "double-hot": they look like a hot peg but
-- glow (Neon) and emit fire, and are worth double the hot heat. Promotions are transient —
-- their fire particles are cleared on the next repaint.
--
-- How many we add is a run of coin flips with a halving chance: 50% for the first,
-- 25% for a second, 12.5% for a third, and so on — and the first failure stops the run.
local DOUBLE_HOT_FIRST_CHANCE = 0.5
local DOUBLE_HOT_HEAT = Config.Pegs.HotHeat * 2
local DOUBLE_HOT_FIRE_NAME = "DoubleHotFire"

-- Heat values are fixed per category and live in Config.Pegs (we don't vary within
-- hot or cold); color/material remain peg-field presentation owned here.
type Category = { Heat: number, Color: Color3, Material: Enum.Material }
local CATEGORIES: { [string]: Category } = {
	Hot    = { Heat = Config.Pegs.HotHeat,     Color = Color3.fromRGB(255,   0, 191), Material = Enum.Material.Plastic },
	Cold   = { Heat = Config.Pegs.ColdHeat,    Color = Color3.fromRGB( 98,  37, 209), Material = Enum.Material.Limestone },
	Normal = { Heat = Config.Pegs.NeutralHeat, Color = Color3.fromRGB(180, 128, 255), Material = Enum.Material.Plastic },
}

-- Band thresholds on nd (0 = field edge .. 1 = center) and the category weights
-- per band. Tunable; each band has a dominant category plus spillover for mixing.
local EDGE_BAND, HOT_BAND, COLD_BAND = 0.12, 0.45, 0.80
local HOT_WEIGHTS    = { Hot = 0.80, Cold = 0.1, Normal = 0.1 }
local COLD_WEIGHTS   = { Cold = 0.60, Hot = 0.10, Normal = 0.30 }
local CENTER_WEIGHTS = { Normal = 0.70, Hot = 0.20, Cold = 0.10 }

local pegs: { BasePart } = {}
local minX, maxX = 0, 0

-- The pegs currently promoted to double-hot, so we can strip their fire on the next
-- repaint regardless of what category they re-roll into.
local doubleHotPegs: { BasePart } = {}

local function weightedPick(weights: { [string]: number }): string
	local total = 0
	for _, w in weights do
		total += w
	end
	local r = math.random() * total
	local acc = 0
	for cat, w in weights do
		acc += w
		if r <= acc then
			return cat
		end
	end
	return "Normal"
end

-- nd: 0 at the field edge, 1 at the center.
local function pickCategory(nd: number): string
	if nd < EDGE_BAND then
		return if math.random() < 0.7 then "Hot" else "Cold"
	elseif nd < HOT_BAND then
		return weightedPick(HOT_WEIGHTS)
	elseif nd < COLD_BAND then
		return weightedPick(COLD_WEIGHTS)
	else
		return weightedPick(CENTER_WEIGHTS)
	end
end

local function applyCategory(peg: BasePart, catName: string)
	local cat = CATEGORIES[catName]
	peg:SetAttribute(Config.Attributes.PegHeat, cat.Heat) -- gameplay: instant
	peg.Material = cat.Material -- Material is an enum; can't tween, set instant
	TweenService:Create(peg, COLOR_TWEEN, { Color = cat.Color }):Play()
end

-- Promote a peg to double-hot: keep the hot color but make it glow, attach fire, and
-- override its heat to double. Appearance aside, the only gameplay change is the heat.
local function promoteDoubleHot(peg: BasePart)
	local hot = CATEGORIES.Hot
	peg:SetAttribute(Config.Attributes.PegHeat, DOUBLE_HOT_HEAT)
	peg.Material = Enum.Material.Neon
	TweenService:Create(peg, COLOR_TWEEN, { Color = hot.Color }):Play()

	local fire = Instance.new("ParticleEmitter")
	fire.Name = DOUBLE_HOT_FIRE_NAME
	fire.Texture = "rbxasset://textures/particles/fire_main.dds"
	fire.Color = ColorSequence.new(Color3.fromRGB(255, 120, 0), Color3.fromRGB(255, 0, 191))
	fire.LightEmission = 1
	fire.Lifetime = NumberRange.new(0.4, 0.7)
	fire.Rate = 30
	fire.Speed = NumberRange.new(2, 4)
	fire.SpreadAngle = Vector2.new(20, 20)
	fire.Size = NumberSequence.new(peg.Size.Magnitude * 0.5)
	fire.Parent = peg
end

-- Strip the fire particles from every previously promoted peg. Their color/material are
-- reset by the normal repaint that follows.
local function clearDoubleHot()
	for _, peg in doubleHotPegs do
		local fire = peg:FindFirstChild(DOUBLE_HOT_FIRE_NAME)
		if fire then
			fire:Destroy()
		end
	end
	table.clear(doubleHotPegs)
end

-- Repaint every peg from its position. Span is fixed (pegs don't move), so this
-- only re-rolls the categories.
local function assignAll()
	clearDoubleHot()

	local span = maxX - minX
	local hotPegs: { BasePart } = {}
	for _, peg in pegs do
		local t: number = if span > 1e-4 then (peg.Position.X - minX) / span else 0.5
		local nd = 2 * math.min(t, 1 - t) -- distance from nearest edge, 0..1
		local cat = pickCategory(nd)
		applyCategory(peg, cat)
		if cat == "Hot" then
			table.insert(hotPegs, peg)
		end
	end

	-- Promote a run of distinct hot pegs to double-hot: 50%, then 25%, then 12.5%, …
	-- Each success halves the next chance; the first failure (or running out of hot
	-- pegs) ends the run.
	local chance = DOUBLE_HOT_FIRST_CHANCE
	while #hotPegs > 0 and math.random() < chance do
		local idx = math.random(#hotPegs)
		local chosen = table.remove(hotPegs, idx) :: BasePart -- distinct each time
		promoteDoubleHot(chosen)
		table.insert(doubleHotPegs, chosen)
		chance /= 2
	end
end

-- Collect pegs once, tag them, and record the field's horizontal span.
local function gatherPegs()
	local folder = workspace:FindFirstChild("Pegs")
	if not folder then
		warn("PegService: no Workspace.Pegs folder; no pegs assigned")
		return
	end
	table.clear(pegs)
	minX, maxX = math.huge, -math.huge
	for _, inst in folder:GetDescendants() do
		if inst:IsA("BasePart") then
			table.insert(pegs, inst)
			inst:AddTag(Config.Tags.ScoreTarget)
			local x = inst.Position.X
			minX = math.min(minX, x)
			maxX = math.max(maxX, x)
		end
	end
	if #pegs == 0 then
		warn("PegService: Workspace.Pegs has no BaseParts")
	end
end

function PegService.Init()
	gatherPegs()
	assignAll()

	task.spawn(function()
		while true do
			task.wait(REASSIGN_INTERVAL)
			assignAll()
		end
	end)
end

return PegService
