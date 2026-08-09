--!strict
-- Tier -> Color3/Material interpolation for Config/BoardAppearance's Floor/Side/Grass
-- keyframe ramps. Pulled out of BoardAppearanceView so any OTHER surface that wants "this
-- zone's board color" (e.g. BallLaunchUI's zone-styled LaunchBtn) reads through the same
-- math instead of re-deriving it and risking drift from what the board itself shows.

local BoardColors = {}

export type Keyframe = { Tier: number, Color: Color3, Material: Enum.Material? }

-- (color, material) for `tier` within a keyframe list (ascending Tier): Color lerps
-- linearly between the two keyframes straddling the tier; Material holds the LOWER
-- keyframe's value until the tier reaches the next one. Clamped to [0, maxTier], so a tier
-- past the last keyframe holds that keyframe's look.
function BoardColors.Lookup(keyframes: { Keyframe }, tier: number, maxTier: number): (Color3, Enum.Material?)
	tier = math.clamp(tier, 0, maxTier)
	local lo = keyframes[1]
	local hi = keyframes[#keyframes]
	for _, kf in keyframes do
		if kf.Tier <= tier and kf.Tier >= lo.Tier then
			lo = kf
		end
	end
	for i = #keyframes, 1, -1 do
		local kf = keyframes[i]
		if kf.Tier >= tier then
			hi = kf
		end
	end
	if lo.Tier == hi.Tier then
		return lo.Color, lo.Material
	end
	local t = (tier - lo.Tier) / (hi.Tier - lo.Tier)
	return lo.Color:Lerp(hi.Color, t), lo.Material
end

return BoardColors
