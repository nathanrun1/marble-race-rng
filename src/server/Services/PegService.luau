--!strict
-- Owns the peg field. Treats every BasePart under Workspace.Pegs as a peg:
-- tags it ScoreTarget (so ScoringService detects contacts) and, once per minute,
-- paints it hot / cold / normal by its horizontal position in the field.
--
-- Pattern, by distance from the nearest edge: the edges are 50/50 hot/cold, then
-- a hot band, then a cold band, then normal toward the center. Each band is a
-- weighted random pick, so categories mix a little rather than forming clean
-- stripes. The hot/cold heat values live in PegsConfig (cold's malus is meant to
-- run slightly bigger than hot's bonus, so sloppy aim is punished).

local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AttributesConfig = require(RS.Shared.Config.Attributes)
local PegsConfig = require(RS.Shared.Config.Pegs)
local TagsConfig = require(RS.Shared.Config.Tags)
local WeightedRandom = require(RS.Shared.Utility.WeightedRandom)
local PegService = {}

local REASSIGN_INTERVAL = 60 -- seconds between repaints
local COLOR_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Each repaint we promote random hot pegs to "double-hot": same look as an ordinary hot
-- peg by default (SHARED appearance stays identical on purpose — which pegs are promoted
-- is only revealed locally, per-player, to whoever has invested in PegHeat tier 1+; see
-- client PegHeatView, which glows/Fires them for eligible viewers by comparing this heat
-- value against PegsConfig.HotHeat). The only SERVER-side effect is the heat value itself.
--
-- How many we add is a run of coin flips with a halving chance: 50% for the first,
-- 25% for a second, 12.5% for a third, and so on — and the first failure stops the run.
local DOUBLE_HOT_FIRST_CHANCE = 0.5
local DOUBLE_HOT_HEAT = PegsConfig.HotHeat * 3

-- Heat values are fixed per category and live in PegsConfig (we don't vary within
-- hot or cold); color/material remain peg-field presentation owned here.
type Category = { Heat: number, Color: Color3, Material: Enum.Material }
local CATEGORIES: { [string]: Category } = {
	Hot    = { Heat = PegsConfig.HotHeat,     Color = Color3.fromRGB(255,   0, 191), Material = Enum.Material.Plastic },
	Cold   = { Heat = PegsConfig.ColdHeat,    Color = Color3.fromRGB( 98,  37, 209), Material = Enum.Material.Limestone },
	-- Keep in sync with PegsConfig.HeatAppearance.NormalColor (the client override's default pink).
	Normal = { Heat = PegsConfig.NeutralHeat, Color = Color3.fromRGB(240, 140, 220), Material = Enum.Material.Plastic },
}

-- Band thresholds on nd (0 = field edge .. 1 = center) and the category weights
-- per band. Tunable; each band has a dominant category plus spillover for mixing.
local EDGE_BAND, HOT_BAND, COLD_BAND = 0.12, 0.45, 0.80
local HOT_WEIGHTS    = { Hot = 0.80, Cold = 0.1, Normal = 0.1 }
local COLD_WEIGHTS   = { Cold = 0.60, Hot = 0.10, Normal = 0.30 }
local CENTER_WEIGHTS = { Normal = 0.70, Hot = 0.20, Cold = 0.10 }

local pegs: { BasePart } = {}
local minX, maxX = 0, 0

local function weightedPick(weights: { [string]: number }): string
	return WeightedRandom.PickKey(weights) or "Normal"
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
	peg:SetAttribute(AttributesConfig.PegHeat, cat.Heat) -- gameplay: instant
	peg.Material = cat.Material -- Material is an enum; can't tween, set instant
	TweenService:Create(peg, COLOR_TWEEN, { Color = cat.Color }):Play()
end

-- Promote a peg to double-hot: same colour/material as an ordinary hot peg (applyCategory
-- already painted it that way), only the heat attribute changes. No shared Neon/Fire — that
-- reveal is per-player now (client PegHeatView), gated on the viewer's PegHeat tier.
local function promoteDoubleHot(peg: BasePart)
	peg:SetAttribute(AttributesConfig.PegHeat, DOUBLE_HOT_HEAT)
end

-- Repaint every peg from its position. Span is fixed (pegs don't move), so this
-- only re-rolls the categories.
local function assignAll()
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
			inst:AddTag(TagsConfig.ScoreTarget)
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
