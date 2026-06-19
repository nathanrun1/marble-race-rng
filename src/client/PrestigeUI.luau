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
--       .Prog.{Pts, Frame.Fill}               -- PP "x / cost" + progress fill
--       .Stats.<3 chips>.Val                  -- lifetime / next cost / prestige #

local PrestigeUI = {}

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(RS.Shared.Config)
local StringUtils = require(RS.Shared.StringUtils)
local SoundService = require(RS.Shared.SoundService)

local player: Player = Players.LocalPlayer :: Player
local PlayerGui: PlayerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local Remote = RS:WaitForChild("Remote")
local GetPrestigeInfoRF: RemoteFunction = Remote:WaitForChild("GetPrestigeInfo") :: RemoteFunction
local PrestigeRF: RemoteFunction = Remote:WaitForChild("Prestige") :: RemoteFunction
local BalanceChangedRE: RemoteEvent = Remote:WaitForChild("BalanceChanged") :: RemoteEvent

-- Mirrors PrestigeService.PrestigeInfo (can't require a server module client-side).
type PrestigeInfo = {
	count: number,
	lifetimeBanked: number,
	prestigePoints: number,
	nextCost: number,
	canPrestige: boolean,
	multiplier: number,
}

-- The per-prestige multiplier step; next-mult = current × MULT_PER.
local MULT_PER: number = Config.Prestige.MultPer

-- Palette (from GenUI) for the affordance swap on the button face.
local VIOLET     = Color3.fromRGB(124, 58, 237)
local VIOLET_LT  = Color3.fromRGB(179, 136, 255)
local LOCK_FACE  = Color3.fromRGB(199, 191, 216)
local LOCK_BASE  = Color3.fromRGB(156, 143, 179)
local GOLD       = Color3.fromRGB(255, 211, 77)

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

-- Stat chips share the default name "Frame"; resolve them by LayoutOrder. Each
-- chip holds a "Val" label. Order matches GenUI: lifetime, next cost, prestige #.
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

-- Gold pulse ring on the trigger badge while a prestige is affordable.
local readyStroke: any = f("UIStroke", {
	Color = GOLD,
	Thickness = 0,
	LineJoinMode = Enum.LineJoinMode.Round,
}, trigger)
local readyTween: Tween? = nil
local function setReady(on: boolean)
	if readyTween then
		readyTween:Cancel()
		readyTween = nil
	end
	if on then
		readyStroke.Thickness = 4
		readyStroke.Transparency = 0
		readyTween = TweenService:Create(
			readyStroke,
			TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Transparency = 1 }
		)
		;(readyTween :: Tween):Play()
	else
		readyStroke.Thickness = 0
	end
end

-- Celebratory pop on the panel after a successful prestige.
local panelScale: any = panel:FindFirstChildOfClass("UIScale") or f("UIScale", { Scale = 1 }, panel)
local function punch()
	panelScale.Scale = 1
	local upT = TweenService:Create(panelScale, TweenInfo.new(0.1), { Scale = 1.04 })
	upT.Completed:Connect(function()
		TweenService:Create(panelScale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end)
	upT:Play()
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
	local pp = info.prestigePoints
	local cost = info.nextCost
	local can = info.canPrestige

	trigMult.Text = ("×%.2f"):format(now)
	heroNow.Text  = ("×%.2f"):format(now)
	heroNext.Text = ("×%.2f"):format(nxt)
	ptsVal.Text   = StringUtils.Commas(pp) .. " / " .. StringUtils.Commas(cost)
	statLife.Text = StringUtils.FormatMoney(info.lifetimeBanked)
	statCost.Text = StringUtils.Commas(cost) .. " PP"
	statNum.Text  = info.count .. " → " .. (info.count + 1)

	local frac = math.clamp(cost > 0 and pp / cost or 0, 0, 1)
	TweenService:Create(pgFill, TweenInfo.new(0.4, Enum.EasingStyle.Quad), { Size = UDim2.new(frac, 0, 1, 0) }):Play()

	-- Only (re)start the pulse when affordability flips, so frequent balance
	-- updates don't restart the animation each tick.
	if can ~= lastCan then
		setReady(can)
		lastCan = can
	end

	-- Button affordance: violet gradient + "PRESTIGE" when ready; greyed + a
	-- "need more PP" prompt when locked.
	for _, g in goFace:GetChildren() do
		if g:IsA("UIGradient") then
			g.Color = if can then ColorSequence.new(VIOLET_LT, VIOLET) else ColorSequence.new(LOCK_FACE, LOCK_BASE)
		end
	end
	goLabel.Text = if can then "PRESTIGE" else ("NEED " .. StringUtils.Commas(cost - pp) .. " MORE PP")
	goLabel.TextSize = if can then 32 else 23
	goFace.Active = can
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
		playFlare("PRESTIGE " .. result.info.count .. "!")
		SoundService.Play({ soundId = Config.Sounds.Prestige })
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

	trigger.Activated:Connect(open)
	overlay.Activated:Connect(close)
	closeBtn.Activated:Connect(close)
	goFace.Activated:Connect(onPrestigePressed)

	attachPress(goFace, 7)
	attachPress(trigger, 7)

	-- Banking grows lifetime-banked (and fires BalanceChanged), so refresh the
	-- badge always and the modal contents while it's open.
	BalanceChangedRE.OnClientEvent:Connect(function()
		refresh()
	end)

	-- Seed the badge multiplier + ready state on load.
	refresh()
end

return PrestigeUI
