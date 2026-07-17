--!strict
-- The Roblox group: membership score boost + the walk-on group reward pad.

local Group = {
	GroupId = 559054633,
	ScoreBoost = 0.10, -- multiplier bonus for group members (0.10 = +10%)

	-- Group reward (a part tagged Tags.GroupReward, walked on to claim). Group
	-- members get Fraction of their current balance, then can't reclaim for Cooldown
	-- seconds. The server owns the cooldown + grant; the client only renders the sign.
	Reward = {
		Fraction = 0.15, -- fraction of current balance granted per claim
		Cooldown = 5 * 60 * 60, -- seconds between claims (5 hours)
		LabelColor = Color3.fromRGB(93, 214, 84), -- "Claim Group Reward" sign colour
		MsgColor = Color3.fromRGB(230, 230, 230),
	},
}

table.freeze(Group)
table.freeze(Group.Reward)

return Group
