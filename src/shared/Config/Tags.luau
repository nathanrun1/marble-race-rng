--!strict
-- CollectionService tag names: the registry of every tag scripts find/use/mark
-- instances with. Config on the tagged instances themselves lives in attributes
-- (see Config/Attributes).

local Tags = {
	ScoreTarget = "ScoreTarget", -- Scores on ball collision
	DestroyTarget = "DestroyTarget", -- Destroys ball on collision
	BounceTarget = "BounceTarget", -- Counts towards bounce combo
	JackpotTarget = "JackpotTarget", -- Multiplies the ball's banked value by Scoring.JackpotMultiplier
	Ball = "Ball",
	AutoScale = "AutoScale", -- GuiObject auto-scaled to viewport (see client AutoScale)
	Obstacle = "Obstacle", -- An obstacle that has an active behaviour
	Obby = "Obby", -- An obby model auto-wired by ObbyService (see ObbyZone)
	GroupReward = "GroupReward", -- A floor part that grants the group reward on touch (see GroupRewardService)
	UpgradeShop = "UpgradeShop", -- A part that opens the upgrade shop on touch (Track attribute picks the track; see client UpgradeShop)
	Coin = "Coin", -- A collectible-coin spawn location (per-player; see CoinService server + CoinPickups client)
	CameraZone = "CameraZone", -- A trigger volume: while the local player stands in it, the board camera turns on (client CameraZone)
	CosmeticsGui = "CosmeticsGui", -- A SurfaceGui the cosmetics shop is built into (client CosmeticsShop)
	CosmeticBallSample = "CosmeticBallSample", -- A part; a sample ball of the selected cosmetic floats above it (client CosmeticBallSample)
	Teleport = "Teleport", -- A pad that teleports a touching player to its Teleport attribute (Vector3; see TeleportPads)
	CashBalance = "CashBalance", -- A TextLabel (or a container holding one) kept in sync with the player's Cash balance (client BalanceUI)
	DiamondsBalance = "DiamondsBalance", -- A TextLabel (or a container holding one) kept in sync with the player's Diamonds balance (client BalanceUI)
	Board = "Board", -- Any part of the physical board whose look scales with bet tier (client BoardAppearanceView)
	BoardFloor = "BoardFloor", -- The floor parts marbles roll on (darker default; see Config/BoardAppearance)
	BoardSide = "BoardSide", -- The barrier/side parts (lighter default; see Config/BoardAppearance)
	Grass = "Grass", -- Terrain grass parts; color (only) shifts with bet tier alongside the board (client BoardAppearanceView)
	ZonePreviewGrass = "ZonePreviewGrass", -- Zone-kiosk preview part painted the NEXT zone's Grass color (color only; client BoardAppearanceView)
	ZonePreviewFloor = "ZonePreviewFloor", -- Zone-kiosk preview part painted the NEXT zone's board Floor color+material (client BoardAppearanceView)
	ZonePreviewSide = "ZonePreviewSide", -- Zone-kiosk preview part painted the NEXT zone's board Side color+material (client BoardAppearanceView)
	ZonePreviewBob = "ZonePreviewBob", -- a Model in the Zone kiosk's preview bobbed up/down client-side (client BoardAppearanceView)
	QuestUI = "QuestUI", -- A SurfaceGui the daily-quest panel is also built into (client QuestUI)
	FreeCratePad = "MarbleRoll", -- The free-roll part (e.g. "BallRoll"); child "Pad" claims the free Marble Box on touch (client CosmeticsShop builds its billboard/timer, FreeRollBallSample floats the roll sample above it)
	DailyRewardPad = "DailyReward", -- A pad that claims the daily reward on touch (client DailyRewardUI fills its authored Billboard.BillboardGui Title/Timer)
	UpgradeLock = "UpgradeLock", -- A world lock Model gating upgrade tracks: attribute "UpgradeLock" lists the tracks, "Price" is the cash unlock cost, child "Pad" is the unlock pad (server UpgradeLockService + client UpgradeLocks)
	PlotSpawn = "PlotSpawn", -- the part plot-ball shots land on (client-only, one shared spot for now; see BallPlotService)
	PlotShoot = "PlotShoot", -- the part plot balls are shot out of, arcing to PlotSpawn (client BallPlotService)
	PlotBounds = "PlotBounds", -- CanQuery volume covering the plot; a plot ball not overlapping it after a shot is out of bounds and gets teleported back (client BallPlotService)
	PlotCollect = "PlotCollect", -- pad that claims EVERY plot ball at once on touch; billboards the collectible total (client BallPlotService)
	Slot = "Slot", -- A loadout-slot Model; attribute "SlotNum" is its slot index, child "Platform" is where the equipped marble's sample ball floats (client LoadoutDisplay)
	StarterQuestGui = "StarterQuestGui", -- The Studio-authored Getting Started mission panel ScreenGui (client StarterQuestUI wires and fills it)
}

table.freeze(Tags)

return Tags
