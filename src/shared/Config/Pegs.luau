--!strict
-- Peg-field heat values PegService writes to each peg's PegHeat attribute, plus the
-- client-side "heat sense" appearance (PegHeatView). Heat is fixed per category (we
-- don't vary within hot or cold); ScoringService reads the sign of the attribute to
-- classify a hit (>0 hot, <0 cold, 0 neutral).

local Pegs = {
	HotHeat = 1.0,
	ColdHeat = -1.0, -- TEMP: -1.0 for accurate EV testing; gameplay value was -1.1
	NeutralHeat = 0.0,

	-- Peg "heat sense" appearance, driven by the LOCAL player's PegHeat ("Heat Sense") upgrade
	-- tier — client PegHeatView. The shared/server truth (PegService) always paints hot/cold
	-- pegs the same purplish colors for everyone; this is a purely local repaint on top, so a
	-- tier-0 player sees hot, cold, and normal pegs all as the same NormalColor pink (can't
	-- heat-sense yet), and each tier blends hot/cold further toward the "true" hot/cold
	-- color, capped at MaxTier. Hot/Cold true colors lean toward actual red/blue (vs.
	-- PegService's magenta/violet gameplay colors) but deliberately don't go fully pure —
	-- a little of that identity stays.
	HeatAppearance = {
		MaxTier = 15,
		Hot = { Color = Color3.fromRGB(255, 89, 89) }, -- true hot at MaxTier
		Cold = { Color = Color3.fromRGB(98, 37, 209) }, -- true cold at MaxTier
		-- The default peg pink: normal pegs are always this flat color (the board/grass carry
		-- the bet-tier theme now, not the pegs), and it's also the tier-0 starting point
		-- hot/cold pegs blend away from. Mirror any change into PegService's Normal category.
		NormalColor = Color3.fromRGB(240, 140, 220),
		Particles = {
			MinTier = 1, -- no particles at all below this tier (tier 0 is fully plain)
			HotSparkColor = Color3.fromRGB(255, 140, 40), -- orange sparks
			ColdAuraColor = Color3.fromRGB(150, 205, 255), -- pale-blue "cold" puff
		},
		-- PegService silently promotes some hot pegs to a hidden "double-hot" (3x heat, no
		-- shared visual tell — see PegService.promoteDoubleHot). Below this tier a double-hot
		-- peg is indistinguishable from an ordinary hot one; at/above it, PegHeatView reveals
		-- the promotion locally with a Neon glow + Fire (fire is otherwise unused by peg
		-- appearance — reserved for this reveal).
		DoubleHotMinTier = 1,
	},
}

table.freeze(Pegs)

return Pegs
