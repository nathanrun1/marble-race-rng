--!strict
-- Luck ranks: named tiers for a player's lifetime average $/marble (the same server-
-- authoritative figure StatsService.GetAvgMoneyPerBall / the $/marble leaderboard use).
-- Thresholds run on a roughly logarithmic scale ending at $1B/marble, which only very
-- late prestiges ever approach — the top ranks are long-tail chase goals.
--
-- Shared: the client HUD (MoneyPerBallUI) shows the local player's rank live, and the
-- server (LeaderboardService) mirrors it into a leaderstats column so everyone's rank
-- is visible in the player list.

local LuckRanks = {}

export type Rank = {
	Threshold: number, -- avg $/marble at which this rank starts
	Name: string,
	Color: Color3,             -- flat text color (also the fallback where a gradient can't render)
	Gradient: ColorSequence?,  -- top ranks: a UIGradient over the text (see ApplyToLabel)
}

-- Ascending by Threshold; RankFor walks it back-to-front. The first entry is the floor
-- (everyone qualifies), so RankFor never returns nil. The last four ranks carry a text
-- gradient; Godly is a full rainbow.
LuckRanks.Ranks = {
	{ Threshold = 0,     Name = "Noob",        Color = Color3.fromRGB(150, 150, 150) },
	{ Threshold = 25,    Name = "Rookie",      Color = Color3.fromRGB(200, 200, 200) },
	{ Threshold = 100,   Name = "Amateur",     Color = Color3.fromRGB(130, 210, 130) },
	{ Threshold = 500,   Name = "Skilled",     Color = Color3.fromRGB(80, 220, 120) },
	{ Threshold = 2.5e3, Name = "Talented",    Color = Color3.fromRGB(80, 200, 255) },
	{ Threshold = 10e3,  Name = "Pro",         Color = Color3.fromRGB(70, 140, 255) },
	{ Threshold = 50e3,  Name = "Expert",      Color = Color3.fromRGB(170, 110, 255) },
	{ Threshold = 250e3, Name = "Master",      Color = Color3.fromRGB(255, 140, 60) },
	{
		Threshold = 1e6,
		Name = "Grandmaster",
		Color = Color3.fromRGB(255, 90, 90),
		Gradient = ColorSequence.new(Color3.fromRGB(255, 130, 130), Color3.fromRGB(200, 30, 30)),
	},
	{
		Threshold = 10e6,
		Name = "Legend",
		Color = Color3.fromRGB(255, 210, 60),
		Gradient = ColorSequence.new(Color3.fromRGB(255, 240, 160), Color3.fromRGB(255, 165, 25)),
	},
	{
		Threshold = 100e6,
		Name = "Hacker",
		Color = Color3.fromRGB(80, 255, 160),
		Gradient = ColorSequence.new(Color3.fromRGB(170, 255, 210), Color3.fromRGB(20, 215, 110)),
	},
	{
		Threshold = 1e9,
		Name = "Godly",
		Color = Color3.fromRGB(255, 110, 240),
		Gradient = ColorSequence.new({
			ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 80, 80)),
			ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 205, 60)),
			ColorSequenceKeypoint.new(0.50, Color3.fromRGB(90, 255, 130)),
			ColorSequenceKeypoint.new(0.75, Color3.fromRGB(80, 180, 255)),
			ColorSequenceKeypoint.new(1.00, Color3.fromRGB(215, 110, 255)),
		}),
	},
} :: { Rank }

table.freeze(LuckRanks.Ranks)

local GRADIENT_NAME = "LuckGradient"

-- Style a TextLabel for a rank: flat ranks get a plain TextColor3; gradient ranks get a
-- horizontal UIGradient over white text (the gradient multiplies the text color, so white
-- shows it pure). Idempotent per rank — safe to call from periodic refresh loops without
-- churning instances or replicating no-op writes.
function LuckRanks.ApplyToLabel(label: TextLabel, rank: Rank)
	if label:GetAttribute("LuckRankName") == rank.Name then
		return
	end
	label:SetAttribute("LuckRankName", rank.Name)
	local gradient = label:FindFirstChild(GRADIENT_NAME)
	if rank.Gradient then
		label.TextColor3 = Color3.new(1, 1, 1)
		if not (gradient and gradient:IsA("UIGradient")) then
			gradient = Instance.new("UIGradient")
			gradient.Name = GRADIENT_NAME
			gradient.Parent = label
		end
		(gradient :: UIGradient).Color = rank.Gradient :: ColorSequence
	else
		label.TextColor3 = rank.Color
		if gradient then
			gradient:Destroy()
		end
	end
end

-- The rank for an average $/marble, plus the next rank up (nil at the top). avg <= 0
-- (no balls banked yet) lands on the floor rank.
function LuckRanks.RankFor(avg: number): (Rank, Rank?)
	local ranks = LuckRanks.Ranks
	for i = #ranks, 1, -1 do
		if avg >= ranks[i].Threshold then
			return ranks[i], ranks[i + 1]
		end
	end
	return ranks[1], ranks[2]
end

return LuckRanks
