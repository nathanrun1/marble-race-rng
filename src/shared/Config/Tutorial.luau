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
--                   { Kind = "LaunchPad" }                         -- the "Interact" launch pad of the
--                                                                     FIRST plot (Slot with SlotNum 1)
--                   { Kind = "SlotAutoSign" }                      -- the "AutoSign" auto-toggle on the
--                                                                     first plot (SlotNum 1)
--                   { Kind = "PlotCollectPad" }                    -- the Collect All pad (PlotCollect tag)
--   complete    : REQUIRED — what finishes the step. Kinds:
--                   { Kind = "LaunchBalls", Count = number } -- N of the player's own marbles launch
--                   { Kind = "BuyUpgrade", Track = string }  -- that track's upgrade tier increases
--                   { Kind = "CollectCoin" }                  -- the player claims any coin
--                   { Kind = "ScoreBalls", Count = number? } -- N of the player's own marbles bank/score (default 1)
--                   { Kind = "BuySkin" }                      -- any skin gets ADDED to the owned set (bought or otherwise earned)
--                   { Kind = "RollCrate" }                    -- any marble box rolls (total copies rise; covers dupes)
--                   { Kind = "OpenLoadout" }                  -- the loadout menu gets opened
--                   { Kind = "EquipLoadoutSlot" }             -- a skin lands in a loadout slot OR Equip Best is pressed
--                   { Kind = "OpenTuningMenu" }               -- the ball-tuning menu gets opened
--                   { Kind = "TouchFreeCratePad" }            -- the player steps on the free-box pad
--                   { Kind = "WatchPlotBank", Count = number? } -- SIDE EFFECT: turns the board-view camera ON on
--                                                                entry, then completes when N of the player's marbles
--                                                                finish falling and bank into the plot (default 1)
--                   { Kind = "DisableBoardView" }             -- SIDE EFFECT: ensures the board-view camera is ON on
--                                                                entry, then completes when the player presses the
--                                                                camera button to turn it back off (teaches the toggle).
--                                                                Pair with highlight.HighlightDim = 1 for no screen dim.
--                   { Kind = "EnableAuto" }                   -- the player enables auto-launch on any plot
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
	-- Reworked for the ball-plot loop (roll -> equip -> plot-launch -> auto -> upgrade). Mostly
	-- SHOW, not tell: each step points a world arrow or highlights the exact control and waits
	-- for the player to do the thing. New players own NO marble (CosmeticService defaults), so
	-- step 1 is rolling their first one at the free-box pad.
	Steps = {
		{
			-- First marble: a fresh player owns nothing, so send them to the free-box pad. The
			-- step completes on the ROLL committing (RollCrate = total copies rising), which
			-- lands AFTER the reveal reel finishes, so step 2 never talks over the spin.
			text = "Welcome! Step on the glowing pad to roll your first marble.",
			arrow = { Kind = "FreeCratePad" },
			complete = { Kind = "RollCrate" },
			boxPosition = UDim2.fromScale(0.5, 0.62),
		},
		{
			text = "Nice marble! Open your LOADOUT to equip it.",
			highlight = { Element = "MainGui.LeftBar.TriggerQuad.LoadoutTriggerHost" },
			complete = { Kind = "OpenLoadout" },
			boxPosition = UDim2.fromScale(0.62, 0.62),
		},
		{
			text = "Tap EQUIP BEST to gear up your best marble.",
			highlight = { Element = "LoadoutGui.Panel.EquipBestHost" },
			complete = { Kind = "EquipLoadoutSlot" },
			boxPosition = UDim2.fromScale(0.5, 0.85),
		},
		{
			text = "Now head to your plot and step on it to launch your marble!",
			arrow = { Kind = "LaunchPad" },
			complete = { Kind = "LaunchBalls", Count = 1 },
			boxPosition = UDim2.fromScale(0.5, 0.62),
		},
		{
			-- WatchPlotBank turns the nicer board view ON, then waits for the marble to finish
			-- falling and bank into the plot (PlotNet.SpawnPlotBall) before advancing.
			text = "Watch your marble drop all the way into your plot!",
			complete = { Kind = "WatchPlotBank", Count = 1 },
			boxPosition = UDim2.fromScale(0.5, 0.82),
		},
		{
			-- Now teach the toggle: highlight the camera button (HighlightDim = 1 so nothing else
			-- darkens — they should still see the board), complete when they press it to turn the
			-- board view back off. The button visual is kept in sync (MiscUI mirrors Toggled), so
			-- one press flips it and completes this step.
			text = "Now tap the camera button to return to your normal view.",
			highlight = { Element = "MainGui.LeftBar.Tools.CamButtonHost", Padding = 6, HighlightDim = 1 },
			complete = { Kind = "DisableBoardView" },
			boxPosition = UDim2.fromScale(0.72, 0.80),
		},
		{
			text = "Step on the COLLECT ALL platform to bank your marble's cash!",
			arrow = { Kind = "PlotCollectPad" },
			complete = { Kind = "ScoreBalls", Count = 1 },
			boxPosition = UDim2.fromScale(0.5, 0.62),
		},
		{
			text = "Turn on AUTO at your plot so it launches for you.",
			arrow = { Kind = "SlotAutoSign" },
			complete = { Kind = "EnableAuto" },
			boxPosition = UDim2.fromScale(0.5, 0.62),
		},
		{
			text = "Last step — upgrade your Mult bonus for bigger payouts!",
			arrow = { Kind = "UpgradeShopTrack", Track = "BaseAdditive" },
			complete = { Kind = "BuyUpgrade", Track = "BaseAdditive" },
			boxPosition = UDim2.fromScale(0.75, 0.80),
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
	-- (The standalone Loadout tutorial was removed — the reworked main Steps above now walk the
	-- player through rolling, opening the loadout, and Equip Best as part of the join flow.)
	-- Tuning tutorial: fires the first time ANY ball-tuning axis (a Config/Upgrades Axes
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
