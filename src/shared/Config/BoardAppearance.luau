--!strict
-- Board look scales with the LOCAL player's current bet tier (client BoardAppearanceView) —
-- the board is shared, but each client repaints Tags.Board/BoardFloor/BoardSide parts
-- to reflect its own viewer's bet size, same "local view of shared state" pattern as
-- GoldenPegView/BoardMultiplierView. Boring/plain at tier 0, maximally "leveled up" by
-- MaxTier — tiers beyond MaxTier all render at the MaxTier look (no further escalation).
--
-- Floor/Side are each a list of keyframes (ascending Tier). Between two keyframes, Color
-- lerps linearly by tier; Material has no in-between, so it holds the LOWER keyframe's
-- Material until the tier reaches the next one. A tier past the last keyframe holds that
-- keyframe's Color/Material. Keyframes are deliberately DENSE in the first ~10 tiers (every
-- 2) so the very first few raises already read as a real hue change, not a grayscale
-- flicker — spaced wider after that once the player has more time-per-tier to notice it.

export type Keyframe = {
	Tier: number,
	Color: Color3,
	Material: Enum.Material,
}

-- Grass only ever changes COLOR (material stays whatever was authored) — it's scenery,
-- not the board, so its shifts are deliberately muted: same hue journey as Floor but
-- desaturated and pulled toward green, and neighbouring stages reuse colors where the
-- theme allows. Loud grass would compete with the board for attention.
export type GrassKeyframe = {
	Tier: number,
	Color: Color3,
}

local BoardAppearance = {
	MaxTier = 25,
	Floor = { -- a real color journey, not just darker/lighter: drab -> copper -> steel ->
		-- emerald -> violet -> crimson -> gold -> obsidian
		{ Tier = 0, Color = Color3.fromRGB(58, 58, 62), Material = Enum.Material.Concrete },
		{ Tier = 2, Color = Color3.fromRGB(96, 62, 40), Material = Enum.Material.SmoothPlastic },
		{ Tier = 4, Color = Color3.fromRGB(150, 96, 40), Material = Enum.Material.Metal },
		{ Tier = 6, Color = Color3.fromRGB(40, 92, 150), Material = Enum.Material.Marble },
		{ Tier = 9, Color = Color3.fromRGB(24, 130, 84), Material = Enum.Material.Granite },
		{ Tier = 12, Color = Color3.fromRGB(96, 32, 150), Material = Enum.Material.Marble },
		{ Tier = 16, Color = Color3.fromRGB(150, 20, 44), Material = Enum.Material.Slate },
		{ Tier = 20, Color = Color3.fromRGB(180, 140, 24), Material = Enum.Material.Metal },
		{ Tier = 25, Color = Color3.fromRGB(14, 12, 18), Material = Enum.Material.Neon },
	} :: { Keyframe },
	Side = { -- lighter/brighter counterpart to each Floor stage, same journey
		{ Tier = 0, Color = Color3.fromRGB(235, 235, 235), Material = Enum.Material.SmoothPlastic },
		{ Tier = 2, Color = Color3.fromRGB(235, 195, 150), Material = Enum.Material.Plastic },
		{ Tier = 4, Color = Color3.fromRGB(255, 195, 110), Material = Enum.Material.Foil },
		{ Tier = 6, Color = Color3.fromRGB(140, 195, 245), Material = Enum.Material.Marble },
		{ Tier = 9, Color = Color3.fromRGB(130, 235, 185), Material = Enum.Material.Marble },
		{ Tier = 12, Color = Color3.fromRGB(205, 150, 245), Material = Enum.Material.Marble },
		{ Tier = 16, Color = Color3.fromRGB(255, 140, 165), Material = Enum.Material.Ice },
		{ Tier = 20, Color = Color3.fromRGB(255, 220, 110), Material = Enum.Material.Foil },
		{ Tier = 25, Color = Color3.fromRGB(255, 240, 200), Material = Enum.Material.Neon },
	} :: { Keyframe },
	Grass = { -- muted echo of the Floor journey: green -> warm olive (copper stages share
		-- it) -> cool teal (steel) -> emerald -> dusky violet-green -> wine-tinted ->
		-- golden-dry -> dark moss
		{ Tier = 0, Color = Color3.fromRGB(106, 146, 74) },
		{ Tier = 2, Color = Color3.fromRGB(126, 140, 62) },
		{ Tier = 4, Color = Color3.fromRGB(126, 140, 62) },
		{ Tier = 6, Color = Color3.fromRGB(76, 138, 118) },
		{ Tier = 9, Color = Color3.fromRGB(62, 148, 92) },
		{ Tier = 12, Color = Color3.fromRGB(104, 116, 142) },
		{ Tier = 16, Color = Color3.fromRGB(134, 90, 94) },
		{ Tier = 20, Color = Color3.fromRGB(152, 142, 76) },
		{ Tier = 25, Color = Color3.fromRGB(56, 66, 58) },
	} :: { GrassKeyframe },
}

return BoardAppearance
