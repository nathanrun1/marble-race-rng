--!strict
-- Generic currency-balance HUD binder. Any UI object tagged Config.Tags.CashBalance or
-- Config.Tags.DiamondsBalance is kept in sync with the player's Cash / Diamonds (the CC
-- cosmetics currency) balance — the tag can sit directly on a TextLabel, or on a container
-- whose first descendant TextLabel is used. This lets Studio-authored HUD pieces (icon +
-- number, anywhere on screen) just get tagged rather than needing bespoke wiring per screen.

local CollectionService = game:GetService("CollectionService")
local RS = game:GetService("ReplicatedStorage")

local Config = require(RS.Shared.Config)
local StringUtils = require(RS.Shared.StringUtils)

local BalanceUIController = {}

local cashLabels: { [Instance]: TextLabel } = {}
local diamondsLabels: { [Instance]: TextLabel } = {}

local cash = 0
local diamonds = 0

-- Direct children only (not a recursive descendant search) — a deep search risks
-- grabbing an unrelated nested label if the tagged container happens to hold more than
-- one TextLabel anywhere inside it (e.g. a shared currency-row prefab with both a Cash
-- and a Diamonds label under one frame). Tag the label itself, or its immediate parent.
local function resolveLabel(inst: Instance): TextLabel?
	if inst:IsA("TextLabel") then
		return inst
	end
	return inst:FindFirstChildWhichIsA("TextLabel")
end

local function renderCash(label: TextLabel)
	label.Text = StringUtils.FormatMoney(cash)
end

local function renderDiamonds(label: TextLabel)
	label.Text = StringUtils.FormatShort(diamonds, false, 0)
end

local function renderAllCash()
	for _, label in cashLabels do
		renderCash(label)
	end
end

local function renderAllDiamonds()
	for _, label in diamondsLabels do
		renderDiamonds(label)
	end
end

local function addCash(inst: Instance)
	if cashLabels[inst] then
		return
	end
	local label = resolveLabel(inst)
	if not label then
		warn(("BalanceUIController: no TextLabel found on/under %s (CashBalance)"):format(inst:GetFullName()))
		return
	end
	cashLabels[inst] = label
	renderCash(label)
end

local function addDiamonds(inst: Instance)
	if diamondsLabels[inst] then
		return
	end
	local label = resolveLabel(inst)
	if not label then
		warn(("BalanceUIController: no TextLabel found on/under %s (DiamondsBalance)"):format(inst:GetFullName()))
		return
	end
	-- If the SAME label instance is also tracked as a CashBalance, both currencies fight
	-- over its .Text (whichever fires last wins — usually Cash, since it updates on every
	-- ball banked) — almost always a double-tag mistake in Studio (one object tagged both
	-- CashBalance and DiamondsBalance, or two containers that share a nested label), not
	-- two independent UI elements.
	for _, cashLabel in cashLabels do
		if cashLabel == label then
			warn(("BalanceUIController: %s resolves to the same TextLabel as a CashBalance-tagged object — give DiamondsBalance its own label"):format(inst:GetFullName()))
			break
		end
	end
	diamondsLabels[inst] = label
	renderDiamonds(label)
end

local function removeCash(inst: Instance)
	cashLabels[inst] = nil
end

local function removeDiamonds(inst: Instance)
	diamondsLabels[inst] = nil
end

function BalanceUIController.Init()
	local Remote = RS:WaitForChild("Remote")
	local getBalanceRF = Remote:WaitForChild("GetBalance") :: RemoteFunction
	local balanceChangedRE = Remote:WaitForChild("BalanceChanged") :: RemoteEvent
	local getCosmeticInfoRF = Remote:WaitForChild("GetCosmeticInfo") :: RemoteFunction
	local cosmeticChangedRE = Remote:WaitForChild("CosmeticChanged") :: RemoteEvent

	for _, inst in CollectionService:GetTagged(Config.Tags.CashBalance) do
		addCash(inst)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.CashBalance):Connect(addCash)
	CollectionService:GetInstanceRemovedSignal(Config.Tags.CashBalance):Connect(removeCash)

	for _, inst in CollectionService:GetTagged(Config.Tags.DiamondsBalance) do
		addDiamonds(inst)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.DiamondsBalance):Connect(addDiamonds)
	CollectionService:GetInstanceRemovedSignal(Config.Tags.DiamondsBalance):Connect(removeDiamonds)

	balanceChangedRE.OnClientEvent:Connect(function(new: number)
		if type(new) == "number" then
			cash = new
			renderAllCash()
		end
	end)
	cosmeticChangedRE.OnClientEvent:Connect(function(info: any)
		if type(info) == "table" and type(info.cc) == "number" then
			diamonds = info.cc
			renderAllDiamonds()
		end
	end)

	local okCash, initCash = pcall(function()
		return getBalanceRF:InvokeServer()
	end)
	if okCash and type(initCash) == "number" then
		cash = initCash
		renderAllCash()
	end

	local okDiamonds, initInfo = pcall(function()
		return getCosmeticInfoRF:InvokeServer()
	end)
	if okDiamonds and type(initInfo) == "table" and type(initInfo.cc) == "number" then
		diamonds = initInfo.cc
		renderAllDiamonds()
	end
end

return BalanceUIController
