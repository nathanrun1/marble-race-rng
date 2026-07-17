--!strict
-- Skin loadout panel (crate progression): a centered ScreenGui panel in the ShopGui style
-- (white rounded box, magenta stroke) showing
--   - the APPEARANCE square: which owned skin the marbles wear (visual only — any owned
--     skin, independent of the bonus slots),
--   - one slot button per slot the player has UNLOCKED (the NumSlots track is the
--     authority on slot count), cloned from the invisible authored prefab at
--     Panel.SlotsRow.Frame.Slot: every slotted skin contributes its rarity×star money
--     bonus (CosmeticBonus), applied server-side at banking,
--   - the owned-skin grid below (skins already in the loadout are hidden from it),
--   - an EQUIP BEST button (server fills the slots with the highest-bonus skins).
--
-- Interaction: click a slot (or the appearance square) to arm it — it highlights — then
-- click a skin below to put it there. Clicking a skin with nothing armed fills the first
-- empty slot. While the appearance square is armed, clicking a slotted skin also works.
--
-- The panel itself is Studio-authored (StarterGui.LoadoutGui: Panel > VisualButton /
-- BonusLabel / EquipBestHost / SlotsRow.Frame.Slot (invisible prefab, cloned per unlocked
-- slot) / HintLabel / Grid / CloseButton); this module only resolves + binds it and
-- renders the dynamic bits (slot cloning/painting, the owned-skin grid tiles, selection
-- highlights). Opened from the authored LOADOUT trigger on MainGui.LeftBar.TriggerQuad.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local SoundsConfig = require(RS.Shared.Config.Sounds)
local ProfileStats = require(RS.Shared.ProfileStats)
local BallSkins = require(RS.Shared.BallSkins)
local CosmeticBonus = require(RS.Shared.CosmeticBonus)
local StringUtils = require(RS.Shared.Utility.StringUtils)
local UIButton = require(RS.Shared.Utility.UIButton)
local SoundService = require(RS.Shared.SoundService)
local Signal = require(RS.Shared.Utility.Signal)
local CosmeticsNet = require(RS.Shared.Remote.CosmeticsNet)
local LoadoutNet = require(RS.Shared.Remote.LoadoutNet)
local ProfileNet = require(RS.Shared.Remote.ProfileNet)

local LoadoutUI = {}

-- Fired whenever the panel opens (TutorialService's OpenLoadout completion listens).
LoadoutUI.Opened = Signal.new()
-- Fired on every EQUIP BEST press — even one that changes nothing (already-best
-- loadout). TutorialService's EquipLoadoutSlot completion listens, so the tutorial
-- advances on the press itself, not only on a loadout change.
LoadoutUI.EquipBestPressed = Signal.new()

local player = Players.LocalPlayer
local PlayerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local getInfoRF = CosmeticsNet.GetCosmeticInfo :: RemoteFunction
local changedRE = CosmeticsNet.CosmeticChanged :: RemoteEvent
local getLoadoutInfoRF = LoadoutNet.GetLoadoutInfo :: RemoteFunction
local loadoutChangedRE = LoadoutNet.LoadoutChanged :: RemoteEvent
local setSlotRE = LoadoutNet.SetLoadoutSlot :: RemoteEvent
local equipBestRE = LoadoutNet.EquipBestLoadout :: RemoteEvent
local equipRE = CosmeticsNet.EquipCosmetic :: RemoteEvent


-- ShopGui-style palette (white card, magenta border, navy text).
local MAGENTA   = Color3.fromRGB(236, 63, 212)
local CARD_BG   = Color3.fromRGB(255, 253, 255)
local CHIP      = Color3.fromRGB(244, 238, 248)
local CHIP_EDGE = Color3.fromRGB(234, 220, 240)
local NAVY      = Color3.fromRGB(22, 34, 63)
local SUBTLE    = Color3.fromRGB(120, 116, 140)
local GOLD      = Color3.fromRGB(255, 180, 40)
local GREEN     = Color3.fromRGB(96, 200, 110)

type Info = {
	cc: number,
	equipped: string,
	selected: string,
	owned: { [string]: boolean },
	copies: { [string]: number },
	pity: { [string]: number },
	freeCrateIn: number,
}

type LoadoutInfo = {
	loadout: { [string]: string },
	loadoutBonus: number,
}

local info: Info? = nil
local loadoutInfo: LoadoutInfo? = nil

-- What's armed for the next skin click: a slot number, "visual" (appearance square), or nil.
local selection: (number | "visual")? = nil

local screenGui: ScreenGui? = nil
local slotButtons: { TextButton } = {}
local slotStrokes: { UIStroke } = {}
-- The invisible authored slot button (Panel.SlotsRow.Frame.Slot); rebuildSlots clones one
-- visible copy per unlocked slot.
local slotPrefab: TextButton? = nil
local visualButton: TextButton? = nil
local visualStroke: UIStroke? = nil
local bonusLabel: TextLabel? = nil
local hintLabel: TextLabel? = nil
local gridFrame: ScrollingFrame? = nil

local function f(class: string, props: { [string]: any }, parent: Instance?): any
	local o = Instance.new(class)
	for k, v in pairs(props) do
		(o :: any)[k] = v
	end
	if parent then
		o.Parent = parent
	end
	return o
end

local function corner(parent: Instance, r: number)
	f("UICorner", { CornerRadius = UDim.new(0, r) }, parent)
end

local function stroke(parent: Instance, color: Color3, thickness: number): UIStroke
	return f("UIStroke", {
		Color = color,
		Thickness = thickness,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Round,
	}, parent)
end

-- Slot -> skin id array from the pushed keyed table (as many slots as are shown).
local function loadoutArray(): { [number]: string? }
	local arr: { [number]: string? } = {}
	if loadoutInfo then
		for slot = 1, #slotButtons do
			arr[slot] = loadoutInfo.loadout[tostring(slot)]
		end
	end
	return arr
end

local function isInLoadout(id: string): boolean
	if not loadoutInfo then
		return false
	end
	for _, sid in loadoutInfo.loadout do
		if sid == id then
			return true
		end
	end
	return false
end

----------------------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------------------
local function skinBonusText(id: string): string
	local copies = if info then info.copies[id] or 1 else 1
	local bonus = CosmeticBonus.SkinBonus(id, copies)
	return ("+%s%%"):format(StringUtils.FormatShort(bonus * 100))
end

local function paintSwatchButton(btn: TextButton, skinId: string?)
	local swatch = btn:FindFirstChild("Swatch") :: Frame
	local starL = btn:FindFirstChild("Stars") :: TextLabel
	local nameL = btn:FindFirstChild("SkinName") :: TextLabel
	local bonusL = btn:FindFirstChild("Bonus") :: TextLabel
	local skin = if skinId then BallSkins.Get(skinId) else nil
	if skin and skinId then
		swatch.Visible = true
		swatch.BackgroundColor3 = skin.data.color
		local ss = swatch:FindFirstChildOfClass("UIStroke") :: UIStroke
		ss.Color = BallSkins.RarityColor(skin.rarity)
		local copies = if info then info.copies[skinId] or 1 else 1
		starL.Text = string.rep("★", CosmeticBonus.StarOf(copies))
		nameL.Text = skin.name
		bonusL.Text = skinBonusText(skinId)
		btn.Text = ""
	else
		swatch.Visible = false
		starL.Text = ""
		nameL.Text = ""
		bonusL.Text = ""
		btn.Text = "+"
	end
end

local function setHint(text: string)
	if hintLabel then
		hintLabel.Text = text
	end
end

local function renderSelection()
	for i, s in slotStrokes do
		s.Color = if selection == i then GOLD else CHIP_EDGE
		s.Thickness = if selection == i then 3 else 2
	end
	if visualStroke then
		visualStroke.Color = if selection == "visual" then GOLD else MAGENTA
		visualStroke.Thickness = if selection == "visual" then 3 else 2
	end
	if selection == "visual" then
		setHint("Pick any owned marble (slots or grid) to WEAR it")
	elseif type(selection) == "number" then
		setHint("Pick a marble below for slot " .. selection)
	else
		setHint("Click a slot (or the appearance square), then a marble")
	end
end

-- One grid tile per owned skin not already slotted.
local function buildTile(parent: Instance, id: string, order: number)
	local skin = BallSkins.Get(id)
	if not skin then
		return
	end
	local tile = f("TextButton", {
		Name = id,
		Size = UDim2.fromOffset(92, 108),
		BackgroundColor3 = CHIP,
		AutoButtonColor = true,
		Text = "",
		LayoutOrder = order,
	}, parent) :: TextButton
	corner(tile, 10)
	stroke(tile, BallSkins.RarityColor(skin.rarity), 2)

	local swatch = f("Frame", {
		Size = UDim2.fromOffset(46, 46),
		Position = UDim2.new(0.5, 0, 0, 8),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = skin.data.color,
	}, tile)
	f("UICorner", { CornerRadius = UDim.new(0.5, 0) }, swatch)
	stroke(swatch, BallSkins.RarityColor(skin.rarity), 2)

	f("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -6, 0, 16),
		Position = UDim2.new(0, 3, 0, 58),
		Font = Enum.Font.FredokaOne,
		TextSize = 13,
		TextScaled = true,
		TextColor3 = NAVY,
		Text = skin.name,
	}, tile)
	local copies = if info then info.copies[id] or 1 else 1
	f("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 14),
		Position = UDim2.new(0, 0, 0, 76),
		Font = Enum.Font.FredokaOne,
		TextSize = 13,
		TextColor3 = GOLD,
		Text = string.rep("★", CosmeticBonus.StarOf(copies)),
	}, tile)
	f("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 14),
		Position = UDim2.new(0, 0, 0, 91),
		Font = Enum.Font.FredokaOne,
		TextSize = 13,
		TextColor3 = GREEN,
		Text = skinBonusText(id),
	}, tile)

	tile.Activated:Connect(function()
		LoadoutUI.OnSkinClicked(id)
	end)
end

local function refresh()
	if not info or not screenGui then
		return
	end
	local arr = loadoutArray()
	for i, btn in slotButtons do
		paintSwatchButton(btn, arr[i])
	end
	if visualButton then
		-- Nothing explicitly worn -> show Classic (what unskinned marbles actually wear)
		-- rather than the "+" empty state.
		local equipped = info.equipped
		paintSwatchButton(visualButton, if equipped ~= nil and equipped ~= "" then equipped else BallSkins.GetDefaultId())
	end
	if bonusLabel then
		-- CORE LOOP REWORK: ball value now comes from rarity, not this loadout %-bonus, so it's
		-- no longer shown as a real quantity to the player (the underlying multiplier still
		-- applies server-side at banking — see LoadoutService.GetMult — just not surfaced here).
		bonusLabel.Text = ""
	end

	-- Rebuild the owned grid (prototype-simple; ~30 tiles max).
	local grid = gridFrame
	if grid then
		for _, c in grid:GetChildren() do
			if c:IsA("TextButton") then
				c:Destroy()
			end
		end
		-- Owned, not slotted, ordered by bonus desc then name — the strongest picks lead.
		local entries: { { id: string, bonus: number } } = {}
		for id in info.owned do
			if not isInLoadout(id) then
				table.insert(entries, { id = id, bonus = CosmeticBonus.SkinBonus(id, info.copies[id] or 1) })
			end
		end
		table.sort(entries, function(a, b)
			if a.bonus ~= b.bonus then
				return a.bonus > b.bonus
			end
			return a.id < b.id
		end)
		for i, e in entries do
			buildTile(grid, e.id, i)
		end
	end
	renderSelection()
end

----------------------------------------------------------------------------------
-- Interaction
----------------------------------------------------------------------------------
function LoadoutUI.OnSkinClicked(id: string)
	if selection == "visual" then
		equipRE:FireServer(id)
		selection = nil
		renderSelection()
		return
	end
	local slot: number? = if type(selection) == "number" then selection :: number else nil
	if not slot then
		-- Nothing armed: fill the first empty slot.
		local arr = loadoutArray()
		for i = 1, #slotButtons do
			if not arr[i] then
				slot = i
				break
			end
		end
	end
	if not slot then
		setHint("Loadout full — click a slot to replace it")
		return
	end
	setSlotRE:FireServer(slot, id)
	selection = nil
	renderSelection()
end

local function onSlotClicked(i: number)
	if selection == "visual" then
		-- Appearance armed: wearing a slotted skin is allowed.
		local id = loadoutArray()[i]
		if id then
			equipRE:FireServer(id)
			selection = nil
			renderSelection()
		end
		return
	end
	selection = if selection == i then nil else i
	renderSelection()
end

local function onVisualClicked()
	selection = if selection == "visual" then nil else "visual"
	renderSelection()
end

-- (Re)build the slot buttons: one visible clone of the authored prefab per unlocked slot.
-- Runs whenever the unlocked count changes (NumSlots purchases push ProfileChanged); the
-- SlotsRow scroll UI handles layout, this only supplies the buttons.
local function rebuildSlots(count: number)
	local prefab = slotPrefab
	if not prefab then
		return
	end
	local container = prefab.Parent :: Instance
	for _, c in container:GetChildren() do
		if c ~= prefab and c.Name:match("^Slot%d+$") then
			c:Destroy()
		end
	end
	table.clear(slotButtons)
	table.clear(slotStrokes)
	if type(selection) == "number" and selection > count then
		selection = nil -- armed slot no longer exists
	end
	for i = 1, count do
		local btn = prefab:Clone()
		btn.Name = "Slot" .. i
		btn.LayoutOrder = i
		btn.Visible = true
		btn.Parent = container
		btn.Activated:Connect(function()
			onSlotClicked(i)
		end)
		slotButtons[i] = btn
		slotStrokes[i] = btn:FindFirstChildOfClass("UIStroke") :: UIStroke
	end
	refresh()
end

----------------------------------------------------------------------------------
-- Resolve (the LoadoutGui panel is Studio-authored in StarterGui — see the swatch
-- button structure paintSwatchButton expects: Swatch/SkinName/Stars/Bonus children)
----------------------------------------------------------------------------------
local function resolveUI()
	local gui = PlayerGui:WaitForChild("LoadoutGui") :: ScreenGui
	gui.Enabled = false -- clean closed state regardless of how it was saved
	screenGui = gui
	local panel = gui:WaitForChild("Panel")

	local closeBtn = panel:WaitForChild("CloseButton") :: GuiButton
	closeBtn.Activated:Connect(function()
		SoundService.PlayClick()
		LoadoutUI.Close()
	end)

	local vBtn = panel:WaitForChild("VisualButton") :: TextButton
	visualButton = vBtn
	visualStroke = vBtn:FindFirstChildOfClass("UIStroke")
	vBtn.Activated:Connect(onVisualClicked)

	-- The live amount lives in a child of the authored BonusLabel (which keeps its own
	-- static "Loadout Bonus" text).
	bonusLabel = (panel:WaitForChild("BonusLabel") :: Instance):WaitForChild("BonusAmount") :: TextLabel
	hintLabel = panel:WaitForChild("HintLabel") :: TextLabel
	gridFrame = panel:WaitForChild("Grid") :: ScrollingFrame

	UIButton.bind(panel:WaitForChild("EquipBestHost"), {
		onClick = function()
			equipBestRE:FireServer()
			selection = nil
			LoadoutUI.EquipBestPressed:Fire()
		end,
		pressOffset = 3,
		clickSound = SoundsConfig.Toggle2,
	})

	-- The invisible authored slot prefab; rebuildSlots clones it per unlocked slot.
	local slotsRow = panel:WaitForChild("SlotsRow")
	slotPrefab = slotsRow:WaitForChild("Slot") :: TextButton
end

----------------------------------------------------------------------------------
-- Open/close + trigger button
----------------------------------------------------------------------------------
function LoadoutUI.IsOpen(): boolean
	return screenGui ~= nil and (screenGui :: ScreenGui).Enabled
end

function LoadoutUI.Open()
	if screenGui then
		selection = nil
		refresh()
		screenGui.Enabled = true
		LoadoutUI.Opened:Fire()
	end
end

function LoadoutUI.Close()
	if screenGui then
		screenGui.Enabled = false
	end
end

-- LOADOUT trigger: Studio-authored on MainGui.LeftBar (LoadoutTriggerHost, same UIButton
-- contract as QuestTriggerHost/PlaytimeTriggerHost) — this just binds the toggle.
local function makeTrigger()
	task.spawn(function()
		local mainGui = PlayerGui:WaitForChild("MainGui")
		local leftBar = mainGui:WaitForChild("LeftBar")
		local quad = leftBar:WaitForChild("TriggerQuad", 10)
		local host = quad and quad:FindFirstChild("LoadoutTriggerHost", true)
		if not (host and host:IsA("GuiObject")) then
			warn("LoadoutUI: LoadoutTriggerHost not found on LeftBar — no loadout trigger button")
			return
		end
		UIButton.bind(host, {
			onClick = function()
				if LoadoutUI.IsOpen() then
					LoadoutUI.Close()
				else
					LoadoutUI.Open()
				end
			end,
			pressOffset = 3,
			hoverScale = 1.08,
		})
	end)
end

function LoadoutUI.Init()
	resolveUI()
	makeTrigger()

	-- Slot count follows the NumSlots upgrade — THE authority on slot count (same
	-- derivation as the world pads / LoadoutService) — rebuilt only when it changes.
	local function applyUpgrades(upgrades: any)
		local count = ProfileStats.GetMaxSlots(if type(upgrades) == "table" then upgrades else {})
		if count ~= #slotButtons then
			rebuildSlots(count)
		end
	end
	;(ProfileNet.ProfileChanged :: RemoteEvent).OnClientEvent:Connect(function(profile: any)
		applyUpgrades(type(profile) == "table" and profile.upgrades)
	end)
	task.spawn(function()
		local ok, profile = pcall(function()
			return (ProfileNet.GetProfile :: RemoteFunction):InvokeServer()
		end)
		if ok and #slotButtons == 0 and type(profile) == "table" then
			applyUpgrades(profile.upgrades)
		end
	end)

	changedRE.OnClientEvent:Connect(function(newInfo: Info)
		if newInfo then
			info = newInfo
			refresh()
		end
	end)
	loadoutChangedRE.OnClientEvent:Connect(function(newLoadoutInfo: LoadoutInfo)
		if newLoadoutInfo then
			loadoutInfo = newLoadoutInfo
			refresh()
		end
	end)

	task.spawn(function()
		local got = getInfoRF:InvokeServer()
		if got and not info then
			info = got
			refresh()
		end
	end)
	task.spawn(function()
		local got = getLoadoutInfoRF:InvokeServer()
		if got and not loadoutInfo then
			loadoutInfo = got
			refresh()
		end
	end)
end

return LoadoutUI
