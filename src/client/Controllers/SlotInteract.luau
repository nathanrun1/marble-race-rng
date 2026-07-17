--!strict
-- SlotInteract: the world launch-slot buttons (PER-SLOT LAUNCH REWORK). Every loadout-slot
-- Model (TagsConfig.Slot, attribute "SlotNum") has a child "Interact" part:
--   * Unlocked slot — Interact is that slot's launch button: green "Launch" billboard,
--     stepping on it fires the slot (LaunchNet.RequestLaunch(slot)); while the slot cools
--     down (the server's SlotLaunched push carries the Frequency-scaled delay) the pad
--     turns red and counts the cooldown down. An unlocked slot with NO ball equipped
--     (LoadoutNet) reads gray "Equip" instead, and stepping on it opens the loadout menu.
--   * The NEXT locked slot — the whole model is hidden EXCEPT its Interact part, which
--     advertises "Unlock - $X" (the NumSlots track's next-tier price, pure UpgradeInfo
--     math) and opens ShopUI's slot-unlock purchase screen on touch.
--   * An unlocked slot's Studio-authored "AutoSign" part (tilted panel behind the pad)
--     advertises the one-time AUTO purchase (Config/SlotAuto price by slot index): this
--     controller fills its SurfaceGui and wires a local ClickDetector + ProximityPrompt,
--     both of which open ShopUI's slot-AUTO purchase screen (ShopUI.OpenSlotAuto) —
--     buying happens there, and the server then auto-fires the slot.
--   * Slots beyond the next — completely hidden, Interact included.
-- Hiding is client-local (LocalTransparencyModifier + local CanCollide) — the slot models
-- are shared world content, and each client sees its own unlock progress on them.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local ProfileStats = require(RS.Shared.ProfileStats)
local UpgradeInfo = require(RS.Shared.UpgradeInfo)
local StringUtils = require(RS.Shared.Utility.StringUtils)
local SlotAutoConfig = require(RS.Shared.Config.SlotAuto)
local SoundsConfig = require(RS.Shared.Config.Sounds)
local SoundService = require(RS.Shared.SoundService)
local TagsConfig = require(RS.Shared.Config.Tags)
local ShopUI = require(script.Parent.ShopUI)
local LoadoutUI = require(script.Parent.LoadoutUI)
local LaunchNet = require(RS.Shared.Remote.LaunchNet)
local LoadoutNet = require(RS.Shared.Remote.LoadoutNet)
local ProfileNet = require(RS.Shared.Remote.ProfileNet)

local player = Players.LocalPlayer

local SlotInteract = {}

local GREEN = Color3.fromRGB(0, 255, 0)
local RED = Color3.fromRGB(255, 0, 0)
local GRAY = Color3.fromRGB(150, 150, 150) -- unlocked but empty: "Equip"
local GOLD = Color3.fromRGB(255, 200, 40)  -- AUTO sign price row
local AUTO_OWNED_GREEN = Color3.fromRGB(107, 223, 101) -- sign body once AUTO is owned (local repaint)
local UNLOCK_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local TOUCH_DEBOUNCE = 0.4 -- seconds; one step-on fires Touched once per limb

type Rig = {
	model: Model,
	slotNum: number,
	interact: BasePart,
	interactColor: Color3, -- authored colour, restored for the "Unlock" state
	label: TextLabel,
	billboard: BillboardGui,
	lastTouch: number,
	cooling: boolean, -- countdown loop renders the label while true
	autoGui: SurfaceGui?,      -- built onto the authored "AutoSign" part, if the model has one
	autoPriceLabel: TextLabel?, -- price row ("$X" / "OWNED ✓")
	autoSign: BasePart?,        -- the sign part itself (recoloured locally when owned)
	autoSignColor: Color3?,     -- its authored colour, restored while not owned
	autoPrompt: ProximityPrompt?, -- "E to buy" on the sign; disabled once owned
}

local rigs: { [number]: Rig } = {}
-- Latest server-pushed upgrade tiers (ProfileChanged); NumSlots/price math renders off this.
local upgrades: { [string]: number } = {}
-- os.clock() timestamp each slot is ready again (from LaunchNet.SlotLaunched).
local readyAt: { [number]: number } = {}
-- Latest server-pushed loadout (LoadoutChanged): stringified slot number -> skinId.
-- An unlocked slot with no entry is EMPTY (renders "Equip"; can't launch).
local loadout: { [string]: string } = {}

local function slotEmpty(slotNum: number): boolean
	return loadout[tostring(slotNum)] == nil
end

-- Latest server-pushed AUTO ownership (ProfileChanged; profile.autoSlots).
local autoSlots: { [string]: boolean } = {}

local function autoOwned(slotNum: number): boolean
	return autoSlots[tostring(slotNum)] == true
end

local function unlockedSlots(): number
	return ProfileStats.GetMaxSlots(upgrades) -- NumSlots is the authority on slot count
end

-- Show/hide a slot model's parts client-locally. `interactToo` hides even the Interact
-- part (slots beyond the next unlock). Originals aren't touched: transparency goes through
-- LocalTransparencyModifier, and CanCollide is restored from attributes-free part state by
-- only ever flipping it while hidden (originals cached on first hide).
local hiddenCollide: { [BasePart]: boolean } = {} -- original CanCollide of parts we hid
local function setPartHidden(part: BasePart, hidden: boolean)
	part.LocalTransparencyModifier = if hidden then 1 else 0
	if hidden then
		if hiddenCollide[part] == nil then
			hiddenCollide[part] = part.CanCollide
		end
		part.CanCollide = false
	elseif hiddenCollide[part] ~= nil then
		part.CanCollide = hiddenCollide[part] :: boolean
		hiddenCollide[part] = nil
	end
end

local function setModelHidden(rig: Rig, hidden: boolean, interactToo: boolean)
	for _, inst in rig.model:GetDescendants() do
		if inst:IsA("BasePart") then
			if inst == rig.interact then
				setPartHidden(inst, hidden and interactToo)
			else
				setPartHidden(inst, hidden)
			end
		elseif inst:IsA("Decal") then
			inst.LocalTransparencyModifier = if hidden then 1 else 0
		end
	end
end

local function render(rig: Rig)
	local unlocked = unlockedSlots()
	local n = rig.slotNum

	-- AUTO sign: only an unlocked slot sells (or shows) it. Enabled here rather than via
	-- part transparency — setModelHidden's LocalTransparencyModifier doesn't hide SurfaceGuis.
	if rig.autoGui then
		rig.autoGui.Enabled = n <= unlocked
		local owned = autoOwned(n)
		local priceL = rig.autoPriceLabel
		if priceL then
			if owned then
				priceL.Text = "OWNED ✓"
				priceL.TextColor3 = GREEN
			else
				priceL.Text = "$" .. StringUtils.FormatShort(SlotAutoConfig.PriceFor(n))
				priceL.TextColor3 = GOLD
			end
		end
		-- Local repaint only (like PegHeatView's peg colours): the sign is shared world
		-- content, but ownership is per-player.
		if rig.autoSign then
			rig.autoSign.Color = if owned then AUTO_OWNED_GREEN else rig.autoSignColor :: Color3
		end
		-- The prompt only offers what's actually buyable: gone once owned or while locked.
		local prompt = rig.autoPrompt
		if prompt then
			prompt.Enabled = n <= unlocked and not owned
			prompt.ActionText = "Buy AUTO — $" .. StringUtils.FormatShort(SlotAutoConfig.PriceFor(n))
		end
	end

	if n <= unlocked then
		setModelHidden(rig, false, false)
		rig.billboard.Enabled = true
		if slotEmpty(n) then
			-- Unlocked but nothing equipped: the pad can't launch, so it sells the fix —
			-- gray "Equip", stepping on it opens the loadout menu (onTouched).
			rig.cooling = false
			rig.label.Text = "Equip"
			rig.label.TextColor3 = UNLOCK_TEXT_COLOR
			rig.interact.Color = GRAY
			return
		end
		-- Launch button: green/ready or red/counting (the countdown loop owns the text
		-- while cooling — see onHeartbeat).
		local remaining = (readyAt[n] or 0) - os.clock()
		rig.cooling = remaining > 0
		if not rig.cooling then
			rig.label.Text = "Launch"
			rig.label.TextColor3 = GREEN
			rig.interact.Color = GREEN
		else
			rig.label.TextColor3 = RED
			rig.interact.Color = RED
		end
	elseif n == unlocked + 1 then
		-- The one slot currently for sale: only its Interact shows, advertising the price.
		setModelHidden(rig, true, false)
		rig.cooling = false
		rig.billboard.Enabled = true
		rig.interact.Color = rig.interactColor
		local price = UpgradeInfo.PriceAt("NumSlots", upgrades.NumSlots or 0)
		rig.label.Text = if price then "Unlock - $" .. StringUtils.FormatShort(price) else "Unlock"
		rig.label.TextColor3 = UNLOCK_TEXT_COLOR
	else
		-- Not purchasable yet: completely invisible, Interact included.
		setModelHidden(rig, true, true)
		rig.cooling = false
		rig.billboard.Enabled = false
		rig.interact.Color = rig.interactColor
	end
end

local function renderAll()
	for _, rig in rigs do
		render(rig)
	end
end

local function onTouched(rig: Rig, obj: BasePart)
	local char = player.Character
	if not (char and obj:IsDescendantOf(char)) then
		return
	end
	local now = os.clock()
	if now - rig.lastTouch < TOUCH_DEBOUNCE then
		return
	end
	rig.lastTouch = now

	local unlocked = unlockedSlots()
	if rig.slotNum <= unlocked then
		if slotEmpty(rig.slotNum) then
			-- Empty slot: nothing to launch — open the loadout menu so they can fill it.
			if not LoadoutUI.IsOpen() then
				LoadoutUI.Open()
			end
			return
		end
		-- Fire-and-forget: the server validates cooldown/equip state and answers with
		-- SlotLaunched, which is what actually starts the pad's countdown.
		LaunchNet.RequestLaunch:FireServer(rig.slotNum)
	elseif rig.slotNum == unlocked + 1 then
		ShopUI.OpenSlotUnlock()
	end
	-- Hidden slots ignore touches (they're invisible, but Touched still fires).
end

local function makeBillboard(interact: BasePart): (BillboardGui, TextLabel)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "SlotInteractBillboard"
	-- Scale units = studs: the label is a fixed WORLD size, shrinking with distance like any
	-- object (a pixel-Offset billboard renders constant screen size, i.e. grows with distance).
	billboard.Size = UDim2.fromScale(7, 1.6)
	-- World-space offset: Interact pads can be authored lying flat/on their side, and the
	-- object-space StudsOffset axes would follow that rotation (see the lock-pad billboards).
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 2, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 120
	billboard.Parent = interact

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = GREEN
	label.Text = ""
	label.Parent = billboard

	local labelStroke = Instance.new("UIStroke")
	labelStroke.Color = Color3.new(0, 0, 0)
	labelStroke.Thickness = 2
	labelStroke.Transparency = 0.2
	labelStroke.Parent = label

	return billboard, label
end

-- The sign is a storefront, not a buy button: clicking it (or its prompt) opens ShopUI's
-- slot-AUTO purchase screen — the actual purchase happens there, server-validated.
local function onAutoClicked(rig: Rig)
	local n = rig.slotNum
	if n > unlockedSlots() or autoOwned(n) then
		return
	end
	ShopUI.OpenSlotAuto(n)
end

-- Fill the authored AutoSign panel: same billboard styling as the pads (FredokaOne,
-- TextScaled, black stroke). Three rows — title / what it does / price. The GUI and the
-- ClickDetector are client-built on the shared part, so each player sees their own
-- price/OWNED state and clicks are handled locally.
local function buildAutoSign(rig: Rig, sign: BasePart)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "AutoSignGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 60
	gui.LightInfluence = 0
	gui.Enabled = false -- render() decides (locked slots hide it)
	gui.Parent = sign

	local function row(yScale: number, heightScale: number, text: string, color: Color3): TextLabel
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Size = UDim2.new(0.94, 0, heightScale, 0)
		l.Position = UDim2.fromScale(0.03, yScale)
		l.Font = Enum.Font.FredokaOne
		l.TextScaled = true
		l.TextColor3 = color
		l.TextStrokeColor3 = Color3.new(0, 0, 0)
		l.TextStrokeTransparency = 0.3
		l.Text = text
		l.Parent = gui
		return l
	end

	row(0.02, 0.40, "⚡ AUTO", GOLD)
	local desc = row(0.44, 0.22, "Launches this slot automatically", Color3.new(1, 1, 1))
	desc.TextTransparency = 0.1
	rig.autoPriceLabel = row(0.70, 0.28, "", GOLD)
	rig.autoGui = gui
	rig.autoSign = sign
	rig.autoSignColor = sign.Color

	local click = Instance.new("ClickDetector")
	click.Name = "AutoSignClick"
	click.MaxActivationDistance = 40
	click.Parent = sign
	click.MouseClick:Connect(function()
		onAutoClicked(rig)
	end)

	-- Same purchase, gamepad/keyboard-friendly: a proximity prompt ("E to interact") on
	-- the sign. Client-built like the ClickDetector, so it's this player's price/state.
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "AutoSignPrompt"
	prompt.ObjectText = "⚡ AUTO"
	prompt.ActionText = "Buy AUTO"
	prompt.HoldDuration = 0 -- just opens the purchase screen; ShopUI's Buy is the commitment
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false -- render() decides (locked/owned hide it)
	prompt.Parent = sign
	prompt.Triggered:Connect(function()
		onAutoClicked(rig)
	end)
	rig.autoPrompt = prompt
end

local function setup(inst: Instance)
	if not inst:IsA("Model") then
		return
	end
	local slotNum = inst:GetAttribute("SlotNum")
	if type(slotNum) ~= "number" then
		return
	end
	local interact = inst:FindFirstChild("Interact")
	if not (interact and interact:IsA("BasePart")) then
		return -- slot model not yet upgraded with an Interact pad; nothing to drive
	end
	local billboard, label = makeBillboard(interact)
	local rig: Rig = {
		model = inst,
		slotNum = slotNum,
		interact = interact,
		interactColor = interact.Color,
		label = label,
		billboard = billboard,
		lastTouch = 0,
		cooling = false,
		autoGui = nil,
		autoPriceLabel = nil,
		autoSign = nil,
		autoSignColor = nil,
		autoPrompt = nil,
	}
	local autoSign = inst:FindFirstChild("AutoSign")
	if autoSign and autoSign:IsA("BasePart") then
		buildAutoSign(rig, autoSign)
	end
	rigs[slotNum] = rig
	interact.Touched:Connect(function(obj: BasePart)
		onTouched(rig, obj)
	end)
	render(rig)
end

-- Countdown painter: while a slot cools, tick its label down; flip back to the green
-- ready state (full render) the frame the cooldown crosses zero.
local function onHeartbeat()
	local now = os.clock()
	for _, rig in rigs do
		if rig.cooling then
			local remaining = (readyAt[rig.slotNum] or 0) - now
			if remaining <= 0 then
				render(rig)
			else
				rig.label.Text = string.format("%.1fs", remaining)
			end
		end
	end
end

function SlotInteract.Init()
	for _, inst in CollectionService:GetTagged(TagsConfig.Slot) do
		setup(inst)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.Slot):Connect(setup)

	;(LaunchNet.SlotLaunched :: RemoteEvent).OnClientEvent:Connect(function(slot: unknown, cooldown: unknown)
		if type(slot) ~= "number" or type(cooldown) ~= "number" then
			return
		end
		readyAt[slot] = os.clock() + cooldown
		local rig = rigs[slot]
		if rig then
			render(rig)
			-- THE launch sound, at the pad that fired, on EVERY launch — pad step, HUD
			-- button, or auto-launch — since the server pushes SlotLaunched for all of
			-- them. Positional so a multi-slot volley reads as separate pads. Sole owner:
			-- nothing else plays SoundsConfig.Launch.
			SoundService.Play({
				soundId = SoundsConfig.Launch,
				volume = 1.0,
				position = rig.interact.Position,
			})
		end
	end)

	local ProfileChangedRE = ProfileNet.ProfileChanged :: RemoteEvent
	ProfileChangedRE.OnClientEvent:Connect(function(profile: any)
		upgrades = (type(profile) == "table" and profile.upgrades) or {}
		if type(profile) == "table" and type(profile.autoSlots) == "table" then
			autoSlots = profile.autoSlots
		end
		renderAll()
	end)

	-- Equipped-per-slot state, for the empty-slot "Equip" pad (same push+seed pattern as
	-- the upgrades cache below).
	local function applyLoadout(info: any)
		if type(info) == "table" and type(info.loadout) == "table" then
			loadout = info.loadout
			renderAll()
		end
	end
	;(LoadoutNet.LoadoutChanged :: RemoteEvent).OnClientEvent:Connect(applyLoadout)
	task.spawn(function()
		local ok, info = pcall(function()
			return (LoadoutNet.GetLoadoutInfo :: RemoteFunction):InvokeServer()
		end)
		if ok and next(loadout) == nil then
			applyLoadout(info)
		end
	end)

	-- Seed once on startup (pushes only arrive on changes). A push that lands first wins:
	-- only adopt the pull if nothing has populated the cache yet.
	task.spawn(function()
		local GetProfileRF = ProfileNet.GetProfile :: RemoteFunction
		local ok, profile = pcall(function()
			return GetProfileRF:InvokeServer()
		end)
		if ok and next(upgrades) == nil and type(profile) == "table" and type(profile.upgrades) == "table" then
			upgrades = profile.upgrades
			if type(profile.autoSlots) == "table" then
				autoSlots = profile.autoSlots
			end
			renderAll()
		end
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return SlotInteract
