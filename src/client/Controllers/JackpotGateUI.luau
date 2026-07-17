--!strict
-- Client: keeps the jackpot-gate billboards in sync with the local player's gate price.
--
-- The two gate signs live at workspace["Slanted Board"].JackpotWall.{LeftGate,RightGate}.
-- GatePrice.BillboardGui.TextLabel. The price a ball must carry to clear the gate is
-- V_JACK, which is a constant fraction of the player's max bet — so it only ever changes
-- when the MaxBet upgrade does. We refresh both labels once at start and on every profile
-- change (cheap; recomputing the text is trivial).

local RS = game:GetService("ReplicatedStorage")

local ProfileStats = require(RS.Shared.ProfileStats)
local StringUtils = require(RS.Shared.Utility.StringUtils)
local ProfileNet = require(RS.Shared.Remote.ProfileNet)

local JackpotGateUI = {}

local GetProfileRF = ProfileNet.GetProfile :: RemoteFunction
local ProfileChangedRE = ProfileNet.ProfileChanged :: RemoteEvent

-- Resolved once; the gate parts are static board geometry.
local leftLabel: TextLabel? = nil
local rightLabel: TextLabel? = nil

local function resolveLabel(gateName: string): TextLabel?
	local board = workspace:FindFirstChild("Slanted Board")
	local wall = board and board:FindFirstChild("JackpotWall")
	local gate = wall and wall:FindFirstChild(gateName)
	local price = gate and gate:FindFirstChild("GatePrice")
	local billboard = price and price:FindFirstChild("BillboardGui")
	local label = billboard and billboard:FindFirstChild("TextLabel")
	return label :: TextLabel?
end

local function setLabels(vjack: number)
	local text = "Min " .. StringUtils.FormatMoney(vjack)
	if leftLabel then
		leftLabel.Text = text
	end
	if rightLabel then
		rightLabel.Text = text
	end
end

local function applyProfile(profile: any)
	if not (profile and profile.upgrades) then
		return
	end
	setLabels(ProfileStats.GetVJack(profile.upgrades))
end

function JackpotGateUI.Init()
	leftLabel = resolveLabel("LeftGate")
	rightLabel = resolveLabel("RightGate")
	if not (leftLabel and rightLabel) then
		warn("JackpotGateUI: gate price label(s) not found under workspace['Slanted Board'].JackpotWall")
	end

	applyProfile(GetProfileRF:InvokeServer())
	ProfileChangedRE.OnClientEvent:Connect(applyProfile)
end

return JackpotGateUI
