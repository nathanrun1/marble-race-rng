--!strict
-- Daily login reward: once per UTC day, a centered prompt offers a claim (Streak + Luck
-- Bonus preview); claiming rolls a server-authoritative prize (Config.DailyReward.Pool) and
-- reveals it via a horizontal slot-style reel spin (a strip of decorative filler cells that
-- spins past and decelerates onto the true result). The landed cell sits under the pointer
-- for a beat, then the UI closes itself and fires the currency-fly celebration — no
-- confirm/"NICE!" press. Reward-cell rendering is a small Kind -> renderer registry
-- (CELL_RENDERERS below), mirroring the server's Kind -> roller registry
-- (DailyRewardService) — add a new reward Kind by extending Config.DailyReward.Pool + the
-- registries, nothing else changes.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(RS.Shared.Config)
local StringUtils = require(RS.Shared.StringUtils)
local BallSkins = require(RS.Shared.BallSkins)
local UIButton = require(RS.Shared.UIButton)
local SoundService = require(RS.Shared.SoundService)
local WarnUI = require(RS.Shared.WarnUI)

local DailyRewardUI = {}

local player = Players.LocalPlayer
local TutorialService = require(player:WaitForChild("PlayerScripts"):WaitForChild("TutorialService"))
local CurrencyFlyUI = require(player:WaitForChild("PlayerScripts"):WaitForChild("CurrencyFlyUI"))

export type RewardResult =
	{ Kind: "Diamonds", Amount: number }
	| { Kind: "Cash", Amount: number }
	| { Kind: "Skin", SkinId: string, SkinName: string }

-- Theme: a "prize reveal" moment — darker + gold, distinct from the light quest/playtime panels.
local BG = Color3.fromRGB(22, 18, 30)
local GOLD = Color3.fromRGB(255, 205, 70)
local TEXT_LIGHT = Color3.fromRGB(240, 238, 248)
local LUCK_GREEN = Color3.fromRGB(120, 230, 150)
local CELL_BG = Color3.fromRGB(40, 34, 54)
local CELL_STROKE = Color3.fromRGB(80, 70, 100)

local claimRF: RemoteFunction
local getInfoRF: RemoteFunction

-- UI handles (built in createUI).
local screenGui: ScreenGui
local promptFrame: Frame
local streakLabel: TextLabel
local luckLabel: TextLabel
local claimHandle: UIButton.Handle
local reelViewport: Frame
local reelContent: Frame
local reelViewportWidth = 0

-- Forward-declared: bound to buttons inside createUI, defined for real further down (same
-- forward-decl shape used elsewhere in this codebase — ProfileService.reclampLoadout,
-- QuestUI.openPanel, PlaytimeUI.openPlaytimePanel, TutorialService.advance).
local onClaimClicked: () -> ()

----------------------------------------------------------------
-- Reward cell / result rendering: Kind -> populate a cell or produce (icon, text).
----------------------------------------------------------------

local function setCell(cell: Frame, icon: string, text: string, bg: Color3?)
	local iconLabel = cell:FindFirstChild("Icon") :: TextLabel
	local textLabel = cell:FindFirstChild("Text") :: TextLabel
	iconLabel.Text = icon
	textLabel.Text = text
	if bg then
		cell.BackgroundColor3 = bg
	end
end

local function randomSkinNameAndId(): (string, string)
	local ids: { string } = {}
	for id in BallSkins.GetAll() do
		table.insert(ids, id)
	end
	local id = ids[math.random(#ids)]
	local skin = BallSkins.Get(id)
	return id, if skin then skin.name else id
end

-- Real-result cell content, keyed by RewardResult.Kind.
local CELL_RENDERERS: { [string]: (Frame, any) -> () } = {
	Diamonds = function(cell, result)
		setCell(cell, "💎", StringUtils.FormatShort(result.Amount))
	end,
	Cash = function(cell, result)
		setCell(cell, "💰", StringUtils.FormatMoney(result.Amount))
	end,
	Skin = function(cell, result)
		local skin = BallSkins.Get(result.SkinId)
		setCell(cell, "🎨", result.SkinName, if skin then skin.data.color:Lerp(CELL_BG, 0.5) else nil)
	end,
}

-- Decorative filler content — never granted, just visual spin noise drawn from the same pool
-- shape (a plausible-looking but not-actually-rolled value/skin).
local FILLER_RENDERERS: { [string]: (Frame, any) -> () } = {
	Diamonds = function(cell, entry)
		setCell(cell, "💎", StringUtils.FormatShort(math.random(entry.Min, entry.Max)))
	end,
	Cash = function(cell, entry)
		setCell(cell, "💰", "$" .. StringUtils.FormatShort(entry.Multiplier * 1000))
	end,
	Skin = function(cell, _entry)
		local id, name = randomSkinNameAndId()
		local skin = BallSkins.Get(id)
		setCell(cell, "🎨", name, if skin then skin.data.color:Lerp(CELL_BG, 0.5) else nil)
	end,
}

----------------------------------------------------------------
-- UI construction
----------------------------------------------------------------

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function makeCell(parent: Instance, layoutOrder: number): Frame
	local R = Config.DailyReward.Reel
	local cell = Instance.new("Frame")
	cell.Name = "Cell"
	cell.Size = UDim2.fromOffset(R.CellSize.X, R.CellSize.Y)
	cell.BackgroundColor3 = CELL_BG
	cell.BorderSizePixel = 0
	cell.LayoutOrder = layoutOrder
	cell.Parent = parent
	corner(cell, 12)
	local stroke = Instance.new("UIStroke")
	stroke.Color = CELL_STROKE
	stroke.Thickness = 2
	stroke.Parent = cell

	local icon = Instance.new("TextLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.new(1, 0, 0.55, 0)
	icon.Position = UDim2.fromScale(0, 0.06)
	icon.Font = Enum.Font.FredokaOne
	icon.TextScaled = true
	icon.Text = ""
	icon.Parent = cell

	local text = Instance.new("TextLabel")
	text.Name = "Text"
	text.BackgroundTransparency = 1
	text.Size = UDim2.new(1, -10, 0.3, 0)
	text.Position = UDim2.fromScale(0, 0.65)
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextColor3 = TEXT_LIGHT
	text.TextWrapped = true
	text.Text = ""
	text.Parent = cell

	return cell
end

-- A UIButton-contract button (Host > { Shadow, Button > Hover }).
local function makeButton(parent: Instance, position: UDim2, size: UDim2, text: string, onClick: () -> ()): UIButton.Handle
	local host = Instance.new("Frame")
	host.Name = "ButtonHost"
	host.AnchorPoint = Vector2.new(0.5, 1)
	host.Position = position
	host.Size = size
	host.BackgroundTransparency = 1
	host.Parent = parent

	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.Size = UDim2.fromScale(1, 1)
	shadow.Position = UDim2.fromOffset(0, 4)
	shadow.BackgroundColor3 = Color3.fromRGB(20, 16, 10)
	shadow.BorderSizePixel = 0
	shadow.Parent = host
	corner(shadow, 12)

	local button = Instance.new("TextButton")
	button.Name = "Button"
	button.Size = UDim2.fromScale(1, 1)
	button.BackgroundColor3 = GOLD
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Font = Enum.Font.FredokaOne
	button.TextScaled = true
	button.Text = text
	button.TextColor3 = Color3.fromRGB(40, 30, 10)
	button.Parent = host
	corner(button, 12)

	local hover = Instance.new("Frame")
	hover.Name = "Hover"
	hover.Size = UDim2.fromScale(1, 1)
	hover.BackgroundColor3 = Color3.new(1, 1, 1)
	hover.BackgroundTransparency = 1
	hover.BorderSizePixel = 0
	hover.Parent = button
	corner(hover, 12)

	return UIButton.bind(host, { onClick = onClick, clickSound = Config.Sounds.Upgrade })
end

local function createUI(playerGui: PlayerGui)
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "DailyRewardUI"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	-- Instance.new ScreenGuis default to the legacy Global ZIndexBehavior, where this frame's
	-- own children (ZIndex 1) render BEHIND it (ZIndex 2) — i.e. an empty-looking box. Sibling
	-- (the Studio default) always draws children above their parent.
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 45
	screenGui.Enabled = false
	screenGui.Parent = playerGui

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.45
	dim.BorderSizePixel = 0
	dim.ZIndex = 1
	dim.Parent = screenGui

	----- Prompt (Claim) -----
	promptFrame = Instance.new("Frame")
	promptFrame.Name = "Prompt"
	promptFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	promptFrame.Position = UDim2.fromScale(0.5, 0.5)
	promptFrame.Size = UDim2.fromOffset(520, 320)
	promptFrame.BackgroundColor3 = BG
	promptFrame.BorderSizePixel = 0
	promptFrame.ZIndex = 2
	promptFrame.Parent = screenGui
	corner(promptFrame, 18)
	local ps = Instance.new("UIStroke")
	ps.Color = GOLD
	ps.Thickness = 2
	ps.Parent = promptFrame

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromScale(0, 0.06)
	title.Size = UDim2.new(1, 0, 0, 44)
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = GOLD
	title.Text = "🎁 Daily Reward!"
	title.Parent = promptFrame

	streakLabel = Instance.new("TextLabel")
	streakLabel.BackgroundTransparency = 1
	streakLabel.Position = UDim2.fromScale(0, 0.34)
	streakLabel.Size = UDim2.new(1, 0, 0, 32)
	streakLabel.Font = Enum.Font.FredokaOne
	streakLabel.TextScaled = true
	streakLabel.TextColor3 = TEXT_LIGHT
	streakLabel.Text = ""
	streakLabel.Parent = promptFrame

	luckLabel = Instance.new("TextLabel")
	luckLabel.BackgroundTransparency = 1
	luckLabel.Position = UDim2.fromScale(0, 0.46)
	luckLabel.Size = UDim2.new(1, 0, 0, 28)
	luckLabel.Font = Enum.Font.FredokaOne
	luckLabel.TextScaled = true
	luckLabel.TextColor3 = LUCK_GREEN
	luckLabel.Text = ""
	luckLabel.Parent = promptFrame

	claimHandle = makeButton(promptFrame, UDim2.new(0.5, 0, 1, -28), UDim2.fromOffset(220, 56), "CLAIM", function()
		onClaimClicked()
	end)

	----- Reel (slot spin), hidden until claim -----
	local R = Config.DailyReward.Reel
	reelViewportWidth = R.CellSize.X * 3 + R.CellPadding * 2

	reelViewport = Instance.new("Frame")
	reelViewport.Name = "ReelViewport"
	reelViewport.AnchorPoint = Vector2.new(0.5, 0.5)
	reelViewport.Position = UDim2.fromScale(0.5, 0.5)
	reelViewport.Size = UDim2.fromOffset(reelViewportWidth, R.CellSize.Y + 24)
	reelViewport.BackgroundColor3 = BG
	reelViewport.BorderSizePixel = 0
	reelViewport.ClipsDescendants = true
	reelViewport.Visible = false
	reelViewport.ZIndex = 2
	reelViewport.Parent = screenGui
	corner(reelViewport, 18)
	local rvs = Instance.new("UIStroke")
	rvs.Color = GOLD
	rvs.Thickness = 3
	rvs.Parent = reelViewport

	-- Pointer marking the "winning" center position.
	local pointer = Instance.new("Frame")
	pointer.Name = "Pointer"
	pointer.AnchorPoint = Vector2.new(0.5, 0)
	pointer.Position = UDim2.fromScale(0.5, 0)
	pointer.Size = UDim2.new(0, 4, 1, 0)
	pointer.BackgroundColor3 = GOLD
	pointer.BorderSizePixel = 0
	pointer.ZIndex = 3
	pointer.Parent = reelViewport

	reelContent = Instance.new("Frame")
	reelContent.Name = "ReelContent"
	reelContent.AnchorPoint = Vector2.new(0, 0.5)
	reelContent.Position = UDim2.new(0, 0, 0.5, 0)
	reelContent.AutomaticSize = Enum.AutomaticSize.X
	reelContent.Size = UDim2.fromOffset(0, R.CellSize.Y)
	reelContent.BackgroundTransparency = 1
	reelContent.ZIndex = 2
	reelContent.Parent = reelViewport
	local reelLayout = Instance.new("UIListLayout")
	reelLayout.FillDirection = Enum.FillDirection.Horizontal
	reelLayout.SortOrder = Enum.SortOrder.LayoutOrder
	reelLayout.Padding = UDim.new(0, R.CellPadding)
	reelLayout.Parent = reelContent

end

----------------------------------------------------------------
-- Spin + reveal
----------------------------------------------------------------

local function clearReel()
	for _, c in reelContent:GetChildren() do
		if c.Name == "Cell" then
			c:Destroy()
		end
	end
end

-- The X offset (in the reel's local space) that centers the land-index cell under the
-- viewport's pointer.
local function spinTargetX(): number
	local R = Config.DailyReward.Reel
	local landIndex = R.FillerCells - R.CellsAfterResult + 1
	local cellStride = R.CellSize.X + R.CellPadding
	local cellCenterX = (landIndex - 1) * cellStride + R.CellSize.X / 2
	return -(cellCenterX - reelViewportWidth / 2)
end

local RESULT_LINGER = 1.0 -- seconds the landed cell sits under the pointer before the UI closes
local WARN_LIFETIME = 3   -- seconds the post-spin reward banner stays up

-- Post-spin banner text (WarnUI), keyed by RewardResult.Kind — the lasting record of what
-- was won now that there's no confirm screen to read at leisure.
local WARN_TEXT: { [string]: (any) -> string } = {
	Diamonds = function(r)
		return "+" .. StringUtils.FormatShort(r.Amount) .. " Diamonds!"
	end,
	Cash = function(r)
		return "+" .. StringUtils.FormatMoney(r.Amount) .. "!"
	end,
	Skin = function(r)
		return "New Skin: " .. r.SkinName .. "!"
	end,
}

-- The spin has landed: ding, let the winning cell sit visibly for a beat, then close the
-- whole UI, banner the reward, and fire the currency-fly celebration (the grant itself
-- already happened server-side at claim time). No confirm press. Yields; runs on the
-- tween's Completed thread.
local function finishSpin(result: RewardResult)
	-- Muted for now (no daily-reward SFX at spin start or land) — restore if it earns a sound.
	-- SoundService.Play({ soundId = Config.Sounds.Jackpot })
	task.wait(RESULT_LINGER)
	reelViewport.Visible = false
	screenGui.Enabled = false
	local textFn = WARN_TEXT[result.Kind]
	if textFn then
		WarnUI.WarnLocal(textFn(result), GOLD, WARN_LIFETIME)
	end
	-- Skins have no balance icon to fly into; only the two currencies celebrate this way.
	if result.Kind == "Cash" or result.Kind == "Diamonds" then
		CurrencyFlyUI.Play(result.Kind)
	end
end

local function startSpin(result: RewardResult)
	local R = Config.DailyReward.Reel
	clearReel()

	local total = R.FillerCells + 1
	local landIndex = R.FillerCells - R.CellsAfterResult + 1
	for i = 1, total do
		local cell = makeCell(reelContent, i)
		if i == landIndex then
			local renderer = CELL_RENDERERS[result.Kind]
			if renderer then
				renderer(cell, result)
			end
		else
			local entry = Config.DailyReward.Pool[math.random(#Config.DailyReward.Pool)]
			local filler = FILLER_RENDERERS[entry.Kind]
			if filler then
				filler(cell, entry)
			end
		end
	end

	reelContent.Position = UDim2.new(0, 0, 0.5, 0)
	promptFrame.Visible = false
	reelViewport.Visible = true

	local tween = TweenService:Create(
		reelContent,
		TweenInfo.new(R.SpinTime, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0, spinTargetX(), 0.5, 0) }
	)
	tween.Completed:Connect(function(state: Enum.PlaybackState)
		if state == Enum.PlaybackState.Completed then
			finishSpin(result)
		end
	end)
	tween:Play()
end

function onClaimClicked()
	claimHandle.SetDisabled(true)
	local ok, res = pcall(function()
		return claimRF:InvokeServer()
	end)
	claimHandle.SetDisabled(false)
	if not ok or type(res) ~= "table" or not res.ok or not res.reward then
		return
	end
	startSpin(res.reward :: RewardResult)
end

----------------------------------------------------------------
-- Init
----------------------------------------------------------------

function DailyRewardUI.Init()
	getInfoRF = RS.Remote:WaitForChild("GetDailyRewardInfo") :: RemoteFunction
	claimRF = RS.Remote:WaitForChild("ClaimDailyReward") :: RemoteFunction

	task.spawn(function()
		-- Wait for saved data to load first, so a returning player reads their real streak
		-- (not a pre-load default), same gate the join tutorial uses.
		local remote = RS:WaitForChild("Remote")
		local waitLoaded = remote:WaitForChild("WaitForDataLoaded") :: RemoteFunction
		waitLoaded:InvokeServer()

		-- A brand-new player gets the tutorial on this same join; don't stack a second
		-- centered modal on top of it — the reward prompt waits its turn.
		TutorialService.WaitUntilOver()

		local ok, info = pcall(function()
			return getInfoRF:InvokeServer()
		end)
		if not ok or type(info) ~= "table" or not info.claimableToday then
			return
		end

		local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
		createUI(playerGui)
		streakLabel.Text = "Streak: " .. tostring(info.streak)
		luckLabel.Text = if info.luckBonus > 0
			then string.format("🍀 Luck Bonus: +%d%%", math.floor(info.luckBonus * 100 + 0.5))
			else "🍀 Luck Bonus: —"
		screenGui.Enabled = true
	end)
end

return DailyRewardUI
