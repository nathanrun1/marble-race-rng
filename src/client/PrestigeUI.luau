--!strict
-- Client controller for the studio-authored PrestigeGui. Pure UI: reads state
-- from PrestigeService over RemoteFunctions and drives the existing widgets
-- (mirrors ShopUI). The layout/styling is built in studio; this only fills in
-- values, runs the FX prototyped by GenUI, and wires the buttons.
--
-- Tree (PlayerGui.PrestigeGui = root):
--   root.Trigger                              -- always-visible badge; opens modal, shows ×mult
--   root.Overlay                              -- backdrop button; click to close
--     .Frame                                  -- panel
--       .UIListIgnore.CloseButton             -- close button
--       .Frame  (TextButton face + base Frame)-- the candy "PRESTIGE" button
--       .HeroGroup.Frame.{Now,Next}           -- ×now → ×next multiplier
--       .Prog.{Pts, Frame.Fill}               -- "$banked / $required" + progress fill (cash, not RP)
--       .Stats.<3 chips>.Val                  -- lifetime / next cost / prestige #

local PrestigeUI = {}

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(RS.Shared.Config)
local GoldenPegSchedule = require(RS.Shared.GoldenPegSchedule)
local StringUtils = require(RS.Shared.StringUtils)
local SoundService = require(RS.Shared.SoundService)
local UIButton = require(RS.Shared.UIButton)
local CurrencyFlyUI = require(script.Parent:WaitForChild("CurrencyFlyUI"))

local player: Player = Players.LocalPlayer :: Player
local PlayerGui: PlayerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local Remote = RS:WaitForChild("Remote")
local GetPrestigeInfoRF: RemoteFunction = Remote:WaitForChild("GetPrestigeInfo") :: RemoteFunction
local PrestigeRF: RemoteFunction = Remote:WaitForChild("Prestige") :: RemoteFunction
local PrestigeChangedRE: RemoteEvent = Remote:WaitForChild("PrestigeChanged") :: RemoteEvent

-- Mirrors PrestigeService.PrestigeInfo (can't require a server module client-side).
type PrestigeInfo = {
	count: number,
	lifetimeBanked: number,
	prestigePoints: number,
	nextCost: number,
	canPrestige: boolean,
	multiplier: number,
	moneyRequired: number, -- rebirth requirement in cash (see PrestigeService.buildInfo)
	moneyProgress: number, -- how much of moneyRequired is banked so far
}

-- The per-prestige multiplier step; next-mult = current × MULT_PER.
local MULT_PER: number = Config.Prestige.MultPer

-- Palette (from GenUI) for the affordance swap on the button face.
local VIOLET     = Color3.fromRGB(124, 58, 237)
local VIOLET_LT  = Color3.fromRGB(179, 136, 255)
local LOCK_FACE  = Color3.fromRGB(199, 191, 216)
local LOCK_BASE  = Color3.fromRGB(156, 143, 179)

----------------------------------------------------------------
-- widget lookup
----------------------------------------------------------------
local root: any = PlayerGui:WaitForChild("PrestigeGui")
local trigger: any = root.Trigger
local overlay: any = root.Overlay
local panel: any = overlay.Frame

local closeBtn: any = panel.UIListIgnore.CloseButton

-- Candy PRESTIGE button: holder Frame > TextButton (face) + Frame (base).
local goHolder: any = panel.Frame
local goFace: any = goHolder:FindFirstChildOfClass("TextButton")
local goLabel: any = goFace:FindFirstChild("Go") or goFace:FindFirstChildOfClass("TextLabel")

-- Hero multiplier row.
local heroRow: any = panel.HeroGroup:FindFirstChild("Frame")
local heroNow: any = heroRow.Now
local heroNext: any = heroRow.Next

-- Progress bar.
local prog: any = panel.Prog
local ptsVal: any = prog.Pts
local pgFill: any = prog:FindFirstChild("Frame"):FindFirstChild("Fill")

-- Trigger multiplier label (badge meta frame > Mult).
local trigMeta: any = trigger:FindFirstChild("Frame")
local trigMult: any = trigMeta and trigMeta:FindFirstChild("Mult")

-- Studio-authored "💎 +X on Rebirth" line under the stat chips (Diamonds granted on
-- prestige = nextCost × Config.Cosmetics.RebirthCCRatio). FindFirstChild: absent in
-- older saved places, in which case the line just stays blank.
local diamondsGainLabel: any = panel:FindFirstChild("DiamondsGain")

-- Stat chips share the default name "Frame"; resolve them by LayoutOrder. Each
-- chip holds a "Val" label. Order matches GenUI: lifetime, next cost, prestige #.
-- Golden-obstacle footer labels (runtime-built in Init — the panel is Studio-authored, so
-- the row is appended to its UIListLayout and the panel grows to fit). Filled by render.
local GOLD_TEXT = Color3.fromRGB(191, 138, 16)
local pegCountLabel: TextLabel? = nil
local pegNextLabel: TextLabel? = nil

local function resolveStatVals(stats: Instance): (any, any, any)
	local chips = {}
	for _, c in stats:GetChildren() do
		if c:IsA("Frame") and c:FindFirstChild("Val") then
			table.insert(chips, c)
		end
	end
	table.sort(chips, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	return chips[1].Val, chips[2].Val, chips[3].Val
end
local statLife, statCost, statNum = resolveStatVals(panel.Stats)

local function f(class: string, props: { [string]: any }, parent: Instance?): any
	local o = Instance.new(class)
	for k, v in pairs(props) do
		(o :: any)[k] = v
	end
	if parent then o.Parent = parent end
	return o
end

----------------------------------------------------------------
-- FX (preserved from GenUI)
----------------------------------------------------------------

-- Candy press: tween the face/badge down by `drop` on press, back up on release.
local function attachPress(btn: any, drop: number)
	local up = btn.Position
	local down = up + UDim2.fromOffset(0, drop)
	local function toDown() TweenService:Create(btn, TweenInfo.new(0.07), { Position = down }):Play() end
	local function toUp() TweenService:Create(btn, TweenInfo.new(0.07), { Position = up }):Play() end
	btn.MouseButton1Down:Connect(toDown)
	btn.MouseButton1Up:Connect(toUp)
	btn.MouseLeave:Connect(toUp)
end

-- Trigger badge: colour + pulsing glow track prestige availability. The glow is
-- UIButton's pulsing stroke (the trigger is bound via UIButton in Init); `render`
-- drives both through this handle.
local TRIGGER_AVAILABLE = Color3.fromRGB(148, 132, 255)
local TRIGGER_LOCKED = Color3.fromRGB(133, 127, 126)
local triggerButton: UIButton.Handle? = nil

-- Celebratory pop on the panel after a successful prestige. Pops *relative* to the
-- UIScale's resting value (whatever AutoScale set it to) rather than snapping to 1,
-- and rebases only when idle so rapid pops don't drift.
local PUNCH_FACTOR = 1.04
local panelScale: any = panel:FindFirstChildOfClass("UIScale") or f("UIScale", { Scale = 1 }, panel)
local punchRest: number? = nil
local punchTweens: { Tween } = {}
local function punch()
	for _, t in punchTweens do t:Cancel() end
	local base = punchRest or panelScale.Scale
	punchRest = base
	local up = TweenService:Create(panelScale, TweenInfo.new(0.1), { Scale = base * PUNCH_FACTOR })
	local down = TweenService:Create(panelScale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = base })
	punchTweens = { up, down }
	up.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then down:Play() end
	end)
	down.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then punchRest = nil end
	end)
	up:Play()
end

-- Rising fade-out flare. The authored label is kept hidden as a template; each
-- call clones it so spammed prestiges animate independently (no shared tween to
-- interrupt). The clone drifts up while fading text (+ outline) out, then dies.
-- Style is left as authored; only anim + text here.
local flareTemplate: any = root:FindFirstChild("UpgradeFlare")
local flareBasePos: UDim2 = flareTemplate and flareTemplate.Position
local FLARE_RISE = UDim2.fromOffset(0, -60)
local FLARE_INFO = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
if flareTemplate then flareTemplate.Visible = false end
local function playFlare(text: string)
	if not flareTemplate then return end

	local flare = flareTemplate:Clone()
	flare.Text = text
	flare.Position = flareBasePos
	flare.TextTransparency = 0
	flare.Visible = true
	local flareStroke = flare:FindFirstChildOfClass("UIStroke")
	if flareStroke then flareStroke.Transparency = 0 end
	flare.Parent = flareTemplate.Parent

	local move = TweenService:Create(flare, FLARE_INFO, { Position = flareBasePos + FLARE_RISE, TextTransparency = 1 })
	move.Completed:Once(function()
		flare:Destroy()
	end)
	move:Play()
	if flareStroke then
		TweenService:Create(flareStroke, FLARE_INFO, { Transparency = 1 }):Play()
	end
end

----------------------------------------------------------------
-- render
----------------------------------------------------------------
local lastInfo: PrestigeInfo? = nil
local lastCan: boolean? = nil

local function render(info: PrestigeInfo)
	local now = info.multiplier
	local nxt = info.multiplier * MULT_PER
	local can = info.canPrestige

	-- Multipliers keep decimals (×1.25) but abbreviate once large (×1.2K). The requirement
	-- rows show CASH (what the player actually banks), not the underlying RP numbers —
	-- server-inverted from the PP curve (info.moneyRequired/moneyProgress), so "how do I
	-- rebirth" reads as a money target instead of an abstract currency.
	local moneyRequired = info.moneyRequired or 0
	local moneyProgress = info.moneyProgress or 0
	trigMult.Text = "×" .. StringUtils.FormatShort(now)
	heroNow.Text  = "×" .. StringUtils.FormatShort(now)
	heroNext.Text = "×" .. StringUtils.FormatShort(nxt)
	ptsVal.Text   = StringUtils.FormatMoney(moneyProgress) .. " / " .. StringUtils.FormatMoney(moneyRequired)
	statLife.Text = StringUtils.FormatMoney(info.lifetimeBanked)
	statCost.Text = StringUtils.FormatMoney(moneyRequired)
	if diamondsGainLabel then
		-- Mirrors the server grant: PrestigeService pays floor(nextCost × RebirthCCRatio).
		local ccGained = math.floor(info.nextCost * Config.Cosmetics.RebirthCCRatio)
		diamondsGainLabel.Text = "💎 +" .. StringUtils.FormatShort(ccGained) .. " on Rebirth"
	end
	statNum.Text  = info.count .. " → " .. (info.count + 1)

	local frac = math.clamp(moneyRequired > 0 and moneyProgress / moneyRequired or 0, 0, 1)
	TweenService:Create(pgFill, TweenInfo.new(0.4, Enum.EasingStyle.Quad), { Size = UDim2.new(frac, 0, 1, 0) }):Play()

	-- Only (re)start the glow / recolour when affordability flips, so frequent balance
	-- updates don't restart the pulse each tick.
	if can ~= lastCan then
		trigger.BackgroundColor3 = if can then TRIGGER_AVAILABLE else TRIGGER_LOCKED
		if triggerButton then
			triggerButton.SetGlowing(can)
		end
		lastCan = can
	end

	-- Button affordance: violet gradient + "PRESTIGE" when ready; greyed + a
	-- "need more PP" prompt when locked.
	for _, g in goFace:GetChildren() do
		if g:IsA("UIGradient") then
			g.Color = if can then ColorSequence.new(VIOLET_LT, VIOLET) else ColorSequence.new(LOCK_FACE, LOCK_BASE)
		end
	end
	goLabel.Text = if can then "REBIRTH" else ("BANK " .. StringUtils.FormatMoney(moneyRequired - moneyProgress) .. " MORE")
	goLabel.TextSize = if can then 32 else 23
	goFace.Active = can

	-- Golden obstacle progress — same schedule the server sizes the set with
	-- (shared GoldenPegSchedule: peg k at prestige k(k+1)/2, capped at MaxPegs).
	if pegCountLabel and pegNextLabel then
		local have = GoldenPegSchedule.PegsEarned(info.count)
		pegCountLabel.Text = have .. " Golden Obstacle" .. (if have == 1 then "" else "s")
		local nextAt = GoldenPegSchedule.NextPegAt(info.count)
		if nextAt then
			local remaining = nextAt - info.count
			pegNextLabel.Text = remaining .. " Rebirth" .. (if remaining == 1 then "" else "s") .. " until next Golden Obstacle"
		else
			pegNextLabel.Text = "Golden Obstacles maxed!"
		end
	end
end

local function refresh()
	local info: PrestigeInfo = GetPrestigeInfoRF:InvokeServer()
	lastInfo = info
	render(info)
end

----------------------------------------------------------------
-- open / close / submit
----------------------------------------------------------------
local function open()
	refresh()
	overlay.Visible = true
end

local function close()
	overlay.Visible = false
end

local function onPrestigePressed()
	if not lastInfo or not lastInfo.canPrestige then
		return
	end
	local result: { ok: boolean, reason: string?, info: PrestigeInfo } = PrestigeRF:InvokeServer()
	if result and result.ok then
		lastInfo = result.info
		render(result.info)
		punch()
		playFlare("REBIRTH Lv " .. result.info.count .. "!")
		SoundService.Play({ soundId = Config.Sounds.Prestige })
		-- Rebirth's currency payout is Diamonds (PrestigeService's RebirthCCRatio cut) —
		-- cash just resets, so that's the balance worth celebrating.
		CurrencyFlyUI.Play("Diamonds")
	end
end

----------------------------------------------------------------
-- public
----------------------------------------------------------------
function PrestigeUI.IsOpen(): boolean
	return overlay.Visible
end

function PrestigeUI.Open()
	open()
end

function PrestigeUI.Close()
	close()
end

function PrestigeUI.Init()
	overlay.Visible = false

	-- Golden-obstacle footer: one slim row appended below the PRESTIGE button (the
	-- panel's UIListLayout runs on LayoutOrder; the button row is order 10, after the
	-- authored DiamondsGain line took 8). The panel has a fixed authored height, so
	-- grow it by the row's height + list padding.
	local ROW_HEIGHT = 44
	local row = f("Frame", {
		Name = "GoldenPegs",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		LayoutOrder = 11,
	}, panel)
	f("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 2),
	}, row)
	pegCountLabel = f("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 22),
		Font = Enum.Font.FredokaOne,
		TextSize = 19,
		TextColor3 = GOLD_TEXT,
		Text = "",
		LayoutOrder = 1,
	}, row)
	pegNextLabel = f("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 18),
		Font = Enum.Font.FredokaOne,
		TextSize = 15,
		TextColor3 = GOLD_TEXT,
		TextTransparency = 0.25,
		Text = "",
		LayoutOrder = 2,
	}, row)
	panel.Size += UDim2.fromOffset(0, ROW_HEIGHT + 5)

	-- Trigger uses UIButton (press feel + the availability glow); the rest keep their
	-- bespoke FX.
	triggerButton = UIButton.bind(trigger, { onClick = open, pressOffset = 7, glowColor = Color3.fromRGB(237, 206, 135) })
	overlay.Activated:Connect(close)
	closeBtn.Activated:Connect(close)
	goFace.Activated:Connect(onPrestigePressed)

	attachPress(goFace, 7)

	-- Server pushes prestige info on every change (load, banking, prestige), so the
	-- badge (multiplier, progress, availability colour + glow) updates live whether or
	-- not the modal is open.
	PrestigeChangedRE.OnClientEvent:Connect(function(info: PrestigeInfo)
		lastInfo = info
		render(info)
	end)

	-- Seed the badge multiplier + ready state on load.
	refresh()
end

return PrestigeUI
