--!strict
-- Tutorial sequences, played by the client TutorialController.
--
-- The join tutorial runs once until every step's objective auto-completes — there is NO
-- Skip/Next button; each step defines its own completion trigger and the client advances
-- the instant it's satisfied. Three concerns are deliberately orthogonal, so any step can
-- mix any combination:
--   presentation (text/boxPosition/highlight/camera) — what's shown, unrelated to...
--   arrow                                            — an optional physical world pointer, and...
--   complete                                         — what finishes the step and advances.
--
--   text        : the message (string).
--   boxPosition : UDim2 centre of the message box (Scale). Defaults to lower-centre.
--   highlight   : optional; present = dim everything except the spot. Two forms:
--                 { Element = "MainGui.LeftBar.TriggerQuad.LoadoutTriggerHost", Padding = px? }
--                   — surround a live GuiObject (dot path under PlayerGui; path segments fall
--                   back to a recursive find, so container frames can be skipped) with Padding
--                   px (default 10) around it. PREFERRED: reads the element's live absolute
--                   rect, so it's immune to resolution / inset differences (Studio vs Player).
--                 { Position = UDim2, Size = UDim2, Anchor = Vector2?, RespectInset = boolean? }
--                   — hand-authored rect. Anchor picks which point of the spot Position refers
--                   to, like GuiObject.AnchorPoint (default centre). RespectInset = true shifts
--                   the spot by the topbar GUI inset for coords copied from an inset-respecting
--                   ScreenGui. The UDim2s resolve like any screen UDim2 (Scale × viewport) but
--                   the Offset is multiplied by the AutoScale factor — author in 1080p offsets.
--   camera      : optional { Position = Vector3, Orientation = Vector3 (deg), FieldOfView = number? }
--                 scripted camera shot for the step (smoothly tweened); absent = default camera.
--   arrow       : optional physical world-arrow target (client WorldArrow), floating near the
--                 player's character and pointing at a live target position. Kinds:
--                   { Kind = "UpgradeShopTrack", Track = string } -- the world kiosk for that
--                                                                     upgrade track (matches the
--                                                                     Track attribute UpgradeShop
--                                                                     kiosks use)
--                   { Kind = "NearestCoin" }                       -- the player's nearest active
--                                                                     coin, force-spawning one if
--                                                                     none are currently active
--                   { Kind = "CosmeticsShop" }                     -- the part carrying the
--                                                                     CosmeticsGui-tagged storefront
--                   { Kind = "FreeCratePad" }                      -- the free-marble-box claim pad
--                                                                     (first FreeCratePad-tagged part)
--   complete    : REQUIRED — what finishes the step. Kinds:
--                   { Kind = "LaunchBalls", Count = number } -- N of the player's own marbles launch
--                   { Kind = "BuyUpgrade", Track = string }  -- that track's upgrade tier increases
--                   { Kind = "CollectCoin" }                  -- the player claims any coin
--                   { Kind = "ScoreBalls", Count = number? } -- N of the player's own marbles bank/score (default 1)
--                   { Kind = "BuySkin" }                      -- any skin gets ADDED to the owned set (bought or otherwise earned)
--                   { Kind = "OpenTuningMenu" }               -- the ball-tuning menu gets opened
--                   { Kind = "TouchFreeCratePad" }            -- the player steps on the free-box pad
-- Adding a new arrow/complete Kind is one handler function + one registry entry in
-- the TutorialController — nothing else in the stepping/rendering logic changes.
--
-- NOTE: the "highlight" rect below for the launch controls is a placeholder (rough
-- bottom-center guess) — the bet UI was reworked to LaunchBtn/RaiseBtn/LowerBtn/AutoBtn
-- since this was last tuned; re-measure their actual Studio-authored Position/Size and
-- update this rect (in 1080p offset pos/size, matching the element's own UDim2) once you can
-- check it visually.

local Upgrades = require(script.Parent.Upgrades)

export type Step = {
	text: string,
	boxPosition: UDim2?,
	highlight: any?, -- { Element, Padding? } or { Position, Size, Anchor?, RespectInset?, HighlightDim? }
	camera: any?, -- { Position, Orientation, FieldOfView? }
	arrow: any?, -- { Kind, ... } (see header)
	complete: any, -- { Kind, ... } (see header)
}

local Tutorial = {
	Steps = {
		{
			text = "Launch a marble for cash!",
			highlight = { Position = UDim2.fromOffset(960, 986), Size = UDim2.fromOffset(528, 183), HighlightDim = 0.9 },
			complete = { Kind = "LaunchBalls", Count = 1 },
			boxPosition = UDim2.fromScale(0.5, 0.62),
		},
		{
			-- Nudges toward the board-camera toggle (MainGui.LeftBar.Tools.CamButtonHost,
			-- CameraController.Toggle) without forcing the view switch ourselves — a soft
			-- highlight so a player who wants to actually see the drop can find the button,
			-- but the step still completes on its own via ScoreBalls either way.
			text = "Watch where the marble drops... (try the camera button!)",
			highlight = { Element = "MainGui.LeftBar.Tools.CamButtonHost", Padding = 6 },
			complete = { Kind = "ScoreBalls", Count = 1 },
			boxPosition = UDim2.fromScale(0.75, 0.80),
		},
		{
			text = "Upgrade Base Bonus to increase multipliers.",
			arrow = { Kind = "UpgradeShopTrack", Track = "BaseAdditive" },
			complete = { Kind = "BuyUpgrade", Track = "BaseAdditive" },
			boxPosition = UDim2.fromScale(0.75, 0.80),
		},
		{
			text = "Upgrade your bet size to make more cash!",
			arrow = { Kind = "UpgradeShopTrack", Track = "MaxBet" },
			complete = { Kind = "BuyUpgrade", Track = "MaxBet" },
			boxPosition = UDim2.fromScale(0.75, 0.80),
		},
		{
			text = "Launch two more marbles.",
			highlight = { Position = UDim2.fromOffset(960, 986), Size = UDim2.fromOffset(528, 183), HighlightDim = 0.9 },
			complete = { Kind = "LaunchBalls", Count = 2 },
			boxPosition = UDim2.fromScale(0.5, 0.62),
		},
		{
			text = "Step on the pad to claim your FREE marble box!",
			arrow = { Kind = "FreeCratePad" },
			complete = { Kind = "TouchFreeCratePad" },
			boxPosition = UDim2.fromScale(0.5, 0.62),
		},
	} :: { Step },
	-- How dark the screen goes around a step's highlighted rect: the BackgroundTransparency of
	-- the four mask panels while a highlight is up (0 = fully black, 1 = no dim at all). A
	-- highlight table can override this per step (highlight.HighlightDim).
	HighlightDim = 0.45,
	-- Second, later tutorial: starts once the player's Diamonds balance reaches
	-- DiamondTrigger (never before the join tutorial is over), pointing them at the
	-- cosmetics shop. Same step shape as Steps above, same Skip button; finishing or
	-- skipping persists separately (Stats.completedCosmeticTutorial) so it runs once ever.
	Cosmetic = {
		-- Trigger: enough Diamonds for the FIRST Luck tier (derived from Config/Upgrades,
		-- so Luck price tuning moves the tutorial with it).
		DiamondTrigger = Upgrades.Tracks.Luck.Cost.Base,
		Steps = {
			{
				text = "You can afford a LUCK upgrade! Boost your roll odds at the marble shop.",
				boxPosition = UDim2.fromScale(0.75, 0.80), -- same lower-right spot as the upgrade steps
				arrow = { Kind = "CosmeticsShop" },
				complete = { Kind = "BuyLuck" }, -- the Luck tier rising (TutorialController)
			},
		},
	},
	-- Third tutorial: fires the first time a skin other than the default Classic is
	-- unlocked — step 1 opens the LOADOUT menu (auto-completes if it's already open),
	-- step 2 waits for a skin to land in a bonus slot. Run-once
	-- (Stats.completedLoadoutTutorial).
	Loadout = {
		Steps = {
			{
				text = "You unlocked a new marble! Open the LOADOUT menu.",
				boxPosition = UDim2.fromScale(0.75, 0.80),
				highlight = { Element = "MainGui.LeftBar.TriggerQuad.LoadoutTriggerHost" },
				complete = { Kind = "OpenLoadout" },
			},
			{
				text = "Equip the best possible loadout for maximum bonus cash.",
				boxPosition = UDim2.fromScale(0.75, 0.80),
				highlight = { Element = "LoadoutGui.Panel.EquipBestHost" },
				complete = { Kind = "EquipLoadoutSlot" },
			},
		},
	},
	-- Fourth tutorial: fires the first time ANY ball-tuning axis (a Config/Upgrades Axes
	-- track: Arc, Angle, Size, Elasticity) gains a tier — highlights the ball-tuning menu
	-- trigger and waits for the player to open it. Run-once (Stats.completedTuningTutorial).
	Tuning = {
		Steps = {
			{
				text = "You've upgraded a tuning axis! Open the ball tuning menu to use it.",
				boxPosition = UDim2.fromScale(0.75, 0.80),
				-- PLACEHOLDER rect (rough guess at the left bar's TuneTriggerHost) — re-measure
				-- its real 1080p-authored position/size and update.
				highlight = { Position = UDim2.fromOffset(285, 870), Size = UDim2.fromOffset(201, 121) },
				complete = { Kind = "OpenTuningMenu" },
			},
		},
	},
	-- Physical world-arrow look/feel (client WorldArrow) — tunable independent of any step. A
	-- chain of BillboardGui chevrons floats between the player and the target, each screen-
	-- rotated to point along the chain and fading from large/NearColor (by the player) to
	-- small/FarColor (by the target) — a directional trail, not a single pointer.
	Arrow = {
		Spacing = 3, -- studs between chevrons; the chain divides the distance evenly, so the count scales with it
		MaxSegments = 65, -- hard cap on chevrons however far the target is (raised with the tighter Spacing so long trails keep their reach)
		NearColor = Color3.fromRGB(255, 40, 90), -- by the player: hot pink/red
		FarColor = Color3.fromRGB(255, 160, 40), -- by the target: orange
		NearSize = 52, -- chevron pixel size by the player
		FarSize = 24, -- chevron pixel size by the target
		TargetHeightOffset = 3, -- studs above the target the chain ends at (it starts at the player's center)
	},
}

table.freeze(Tutorial)

return Tutorial
