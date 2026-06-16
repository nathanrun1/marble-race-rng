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

-- Heat values are fixed per category and live in Config.Pegs (we don't vary within
-- hot or cold); color/material remain peg-field presentation owned here.
type Category = { Heat: number, Color: Color3, Material: Enum.Material }
local CATEGORIES: { [string]: Category } = {
	Hot    = { Heat = Config.Pegs.HotHeat,     Color = Color3.fromRGB(255,   0, 191), Material = Enum.Material.Neon },
	Cold   = { Heat = Config.Pegs.ColdHeat,    Color = Color3.fromRGB( 98,  37, 209), Material = Enum.Material.Limestone },
	Normal = { Heat = Config.Pegs.NeutralHeat, Color = Color3.fromRGB(180, 128, 255), Material = Enum.Material.Plastic },
}

-- Band thresholds on nd (0 = field edge .. 1 = center) and the category weights
-- per band. Tunable; each band has a dominant category plus spillover for mixing.
local EDGE_BAND, HOT_BAND, COLD_BAND = 0.12, 0.60, 0.90
local HOT_WEIGHTS    = { Hot = 0.80, Cold = 0.1, Normal = 0.1 }
local COLD_WEIGHTS   = { Cold = 0.60, Hot = 0.10, Normal = 0.30 }
local CENTER_WEIGHTS = { Normal = 0.70, Hot = 0.20, Cold = 0.10 }

local pegs: { BasePart } = {}
local minX, maxX = 0, 0

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

-- Repaint every peg from its position. Span is fixed (pegs don't move), so this
-- only re-rolls the categories.
local function assignAll()
	local span = maxX - minX
	for _, peg in pegs do
		local t: number = if span > 1e-4 then (peg.Position.X - minX) / span else 0.5
		local nd = 2 * math.min(t, 1 - t) -- distance from nearest edge, 0..1
		applyCategory(peg, pickCategory(nd))
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
