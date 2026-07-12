--!strict
-- Daily quests (QuestService + client QuestUI). Each UTC day every player gets Count quests
-- drawn (distinct) from Templates, with a random target snapped to Target.Step within
-- [Target.Min, Target.Max]. Rewards pay CC (the cosmetics currency, see Config/Cosmetics) —
-- flat amounts, since skin prices don't scale with prestige: reward = lerp(Reward.Min,
-- Reward.Max, t) where t is how far the rolled target sits in its range (bigger ask =
-- bigger payout), locked in at generation. For scale: a full quest day pays ~40–90 CC and
-- the cheapest skin costs 50. Progress persists via DataService and the whole set
-- regenerates at the UTC day rollover.
--   Kind "count" — progress accumulates toward the target (bank N marbles, N jackpots, ...)
--   Kind "best"  — progress is a high-water mark (best combo banked on a single marble)

export type QuestTemplate = {
	Kind: "count" | "best",
	Text: string,
	Icon: string,
	Target: { Min: number, Max: number, Step: number },
	Reward: { Min: number, Max: number },
}

local Quests = {
	Count = 3, -- quests per day
	Templates = {
		BankBalls = { Kind = "count", Text = "Bank %d marbles", Icon = "🏦", Target = { Min = 60, Max = 160, Step = 10 }, Reward = { Min = 10, Max = 25 } },
		HitJackpots = { Kind = "count", Text = "Hit the jackpot %d time(s)", Icon = "💎", Target = { Min = 1, Max = 3, Step = 1 }, Reward = { Min = 15, Max = 40 } },
		BestCombo = { Kind = "best", Text = "Bank a marble with a %d+ combo", Icon = "⚡", Target = { Min = 22, Max = 30, Step = 1 }, Reward = { Min = 12, Max = 28 } },
		HotPegHits = { Kind = "count", Text = "Hit %d hot pegs", Icon = "🔥", Target = { Min = 100, Max = 250, Step = 25 }, Reward = { Min = 10, Max = 25 } },
		CollectCoins = { Kind = "count", Text = "Collect %d coins", Icon = "🪙", Target = { Min = 3, Max = 6, Step = 1 }, Reward = { Min = 8, Max = 18 } },
		BuyUpgrades = { Kind = "count", Text = "Buy %d upgrade tiers", Icon = "🛒", Target = { Min = 3, Max = 8, Step = 1 }, Reward = { Min = 10, Max = 22 } },
		Rebirth = { Kind = "count", Text = "Rebirth %d time(s)", Icon = "🔄", Target = { Min = 1, Max = 2, Step = 1 }, Reward = { Min = 25, Max = 50 } },
	} :: { [string]: QuestTemplate },
}

table.freeze(Quests)
table.freeze(Quests.Templates)

return Quests
