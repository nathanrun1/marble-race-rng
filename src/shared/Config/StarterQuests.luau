--!strict
-- The one-time "Getting Started" mission ladder (StarterQuestService). The first
-- ActiveCount uncompleted steps (in ladder order) are ALL live at once — each tracks its
-- own progress and pays out the moment it completes; later steps enter the window as
-- earlier ones finish. The client panel renders purely from the server's ChainInfo.
--
-- `key` is StarterQuestService's report() vocabulary (which server signal feeds which
-- step); unrelated to QuestService's own daily-quest keys. Keys must be unique.

export type StepDef = {
	key: string,
	target: number,
	reward: number, -- Diamonds, paid via CosmeticService.AddCC the instant the step completes
	text: string, -- string.format pattern taking the target
}

local StarterQuests = {
	-- How many missions are live (and shown) at once: the server progresses exactly this
	-- window, and the client stacks this many cards.
	ActiveCount = 3,
	Steps = {
		{ key = "LaunchBalls", target = 10, reward = 20, text = "Launch %d marbles" },
		{ key = "BuyUpgrades", target = 3, reward = 20, text = "Buy %d upgrades" },
		{ key = "UnlockLock", target = 1, reward = 40, text = "Unlock your first upgrade lock" },
		{ key = "Prestige", target = 1, reward = 100, text = "Prestige for the first time" },
	} :: { StepDef },
}

table.freeze(StarterQuests)

return StarterQuests
