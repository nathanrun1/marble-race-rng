--!strict
-- Generic currency-balance HUD binder. Any UI object tagged TagsConfig.CashBalance or
-- TagsConfig.DiamondsBalance is kept in sync with the player's Cash / Diamonds (the CC
-- cosmetics currency) balance — the tag can sit directly on a TextLabel, or on a container
-- whose first descendant TextLabel is used. This lets Studio-authored HUD pieces (icon +
-- number, anywhere on screen) just get tagged rather than needing bespoke wiring per screen.

local CollectionService = game:GetService("CollectionService")
local RS = game:GetService("ReplicatedStorage")

local TagsConfig = require(RS.Shared.Config.Tags)
local StringUtils = require(RS.Shared.Utility.StringUtils)
local CosmeticsNet = require(RS.Shared.Remote.CosmeticsNet)
local CurrencyNet = require(RS.Shared.Remote.CurrencyNet)

local BalanceUIController = {}

local cashLabels: { [Instance]: TextLabel } = {}
local diamondsLabels: { [Instance]: TextLabel } = {}

local cash = 0
local diamonds = 0

-- Live-sum override (driven by CurrencyFlyUI): while at least one currency fly "holds" a
-- currency, its labels show a COSMETIC live sum instead of the real balance. The sum is
-- seeded from whatever was displayed when the first hold began and bumped only by
-- AddFlyAmount (one bump per landing fly icon) — it deliberately does NOT track the real
-- balance, which keeps updating underneath and snaps back into view when the last hold
-- releases.
export type FlyKind = "Cash" | "Diamonds"
local flyHolds: { [string]: number } = { Cash = 0, Diamonds = 0 }
local liveSum: { [string]: number } = { Cash = 0, Diamonds = 0 }

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
	label.Text = StringUtils.FormatMoney(if flyHolds.Cash > 0 then liveSum.Cash else cash)
end

local function renderDiamonds(label: TextLabel)
	label.Text = StringUtils.FormatShort(if flyHolds.Diamonds > 0 then liveSum.Diamonds else diamonds, true, 2)
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

local function renderAllFor(kind: FlyKind)
	if kind == "Cash" then
		renderAllCash()
	else
		renderAllDiamonds()
	end
end

-- Take a live-sum hold. The FIRST hold seeds the sum from the currently-displayed value
-- (call BEFORE the grant's BalanceChanged can land, or the sum seeds post-grant and the
-- arriving fly icons double-count).
function BalanceUIController.BeginFlyHold(kind: FlyKind)
	flyHolds[kind] += 1
	if flyHolds[kind] == 1 then
		liveSum[kind] = if kind == "Cash" then cash else diamonds
		renderAllFor(kind)
	end
end

-- One fly icon landed: bump the live sum (no-op unless something holds the currency).
function BalanceUIController.AddFlyAmount(kind: FlyKind, amount: number)
	if flyHolds[kind] <= 0 or amount == 0 then
		return
	end
	liveSum[kind] += amount
	renderAllFor(kind)
end

-- Drop one hold; the LAST release snaps the labels back to the authentic balance.
function BalanceUIController.ReleaseFlyHold(kind: FlyKind)
	flyHolds[kind] = math.max(flyHolds[kind] - 1, 0)
	if flyHolds[kind] == 0 then
		renderAllFor(kind)
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
	local getBalanceRF = CurrencyNet.GetBalance :: RemoteFunction
	local balanceChangedRE = CurrencyNet.BalanceChanged :: RemoteEvent
	local getCosmeticInfoRF = CosmeticsNet.GetCosmeticInfo :: RemoteFunction
	local cosmeticChangedRE = CosmeticsNet.CosmeticChanged :: RemoteEvent

	for _, inst in CollectionService:GetTagged(TagsConfig.CashBalance) do
		addCash(inst)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.CashBalance):Connect(addCash)
	CollectionService:GetInstanceRemovedSignal(TagsConfig.CashBalance):Connect(removeCash)

	for _, inst in CollectionService:GetTagged(TagsConfig.DiamondsBalance) do
		addDiamonds(inst)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.DiamondsBalance):Connect(addDiamonds)
	CollectionService:GetInstanceRemovedSignal(TagsConfig.DiamondsBalance):Connect(removeDiamonds)

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
