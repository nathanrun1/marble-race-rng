-- Wires one obby zone: end part awards a prize and resets the player to start;
-- death part resets to start. Instanced per obby model passed to .New.
local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Config = require(RS.Shared.Config)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local ScoreUI = require(RS.Shared.ScoreUI)
local StringUtils = require(RS.Shared.StringUtils)

local ObbyZone = {}
ObbyZone.__index = ObbyZone

local COOLDOWN: number = 5

-- Walkspeed while inside the obby area (the Checkpoints.In volume), and the speed to
-- restore on exit.
local OBBY_WALK_SPEED: number = Config.Obby.ObbyWalkSpeed
local DEFAULT_WALK_SPEED: number = Config.Obby.DefaultWalkSpeed

local function getHumanoid(part: BasePart): (Player?, Humanoid?)
	local player: Player? = Players:GetPlayerFromCharacter(part.Parent)
	if not player or not player.Character then
		return nil, nil
	end
	return player, player.Character:FindFirstChildOfClass("Humanoid")
end

local function tpPlayerToPart(player: Player, part: Part)
	local character: Model? = player.Character
	if not character then return end
	local humRoot: Part = character:WaitForChild("HumanoidRootPart") :: Part
	humRoot.CFrame = part.CFrame + Vector3.new(0, 10, 0)
end

function ObbyZone.New(obby: Model)
	local self = setmetatable({}, ObbyZone)

	local checkpoints = obby:FindFirstChild("Checkpoints")
	self.startPart = checkpoints and checkpoints:FindFirstChild("Start") :: BasePart
	self.endPart = checkpoints and checkpoints:FindFirstChild("End") :: BasePart
	self.deathPart = checkpoints and checkpoints:FindFirstChild("Death") :: BasePart
	self.inPart = checkpoints and checkpoints:FindFirstChild("In") :: BasePart?

	assert(self.startPart)
	assert(self.endPart)
	assert(self.deathPart)

	self.prize = (checkpoints:WaitForChild("Settings"):WaitForChild("Prize") :: NumberValue).Value
	self.debounce = {} :: { [number]: true }
	-- Players currently inside the In volume (a part can touch via several limbs, so we
	-- ref-count touches to know when the body has actually fully left).
	self.insideCounts = {} :: { [number]: number }
	self.connections = {} :: { RBXScriptConnection }

	table.insert(self.connections, self.endPart.Touched:Connect(function(part: BasePart)
		local player: Player? = Players:GetPlayerFromCharacter(part.Parent)
		if not player then
			return
		end
		if self.debounce[player.UserId] then
			return
		end
		self.debounce[player.UserId] = true

		CurrencyService.AddPoints(player, self.prize, "Completed Obby, prize: " .. self.prize)
		ScoreUI.PostMessage(player, "Obby Complete! +"..StringUtils.FormatMoney(self.prize))
		tpPlayerToPart(player, self.startPart)

		task.wait(COOLDOWN)
		self.debounce[player.UserId] = nil
	end))

	table.insert(self.connections, self.deathPart.Touched:Connect(function(part: BasePart)
		local player: Player? = Players:GetPlayerFromCharacter(part.Parent)
		if not player then
			return
		end
		tpPlayerToPart(player, self.startPart)
	end))

	if self.inPart then
		table.insert(self.connections, self.inPart.Touched:Connect(function(part: BasePart)
			print("in")
			local player, humanoid = getHumanoid(part)
			if not (player and humanoid) then
				return
			end
			local id = player.UserId
			self.insideCounts[id] = (self.insideCounts[id] or 0) + 1
			humanoid.WalkSpeed = OBBY_WALK_SPEED
		end))

		table.insert(self.connections, self.inPart.TouchEnded:Connect(function(part: BasePart)
			local player, humanoid = getHumanoid(part)
			if not player then
				return
			end
			local id = player.UserId
			local count = (self.insideCounts[id] or 0) - 1
			if count > 0 then
				self.insideCounts[id] = count
				return
			end
			-- Fully left the volume: drop the count and restore the default speed.
			self.insideCounts[id] = nil
			if humanoid then
				humanoid.WalkSpeed = DEFAULT_WALK_SPEED
			end
		end))
	end

	return self
end

function ObbyZone:Destroy()
	for _, conn in self.connections do
		conn:Disconnect()
	end
	table.clear(self.connections)
	table.clear(self.debounce)
	table.clear(self.insideCounts)
end

return ObbyZone