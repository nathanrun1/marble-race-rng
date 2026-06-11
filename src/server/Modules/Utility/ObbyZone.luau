-- Wires one obby zone: end part awards a prize and resets the player to start;
-- death part resets to start. Instanced per obby model passed to .New.
local SSS = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)

local ObbyZone = {}
ObbyZone.__index = ObbyZone

local COOLDOWN: number = 5

local function tpPlayerToPart(player: Player, part: Part)
	local character: Model? = player.Character
	if not character then return end
	local humRoot: Part = character:WaitForChild("HumanoidRootPart") :: Part
	humRoot.CFrame = part.CFrame + Vector3.new(0, 10, 0)
end

function ObbyZone.New(obby: Model)
	local self = setmetatable({}, ObbyZone)

	self.startPart = obby.Start :: Part
	assert(self.startPart)
	self.endPart = obby.End :: Part
	assert(self.endPart)
	self.deathPart = obby.Death :: Part
	assert(self.deathPart)
	self.prize = (obby.Settings.Prize :: NumberValue).Value
	assert(self.prize)
	self.debounce = {} :: { [number]: true }
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
		tpPlayerToPart(player, self.startPart)

		task.wait(COOLDOWN)
		self.debounce[player.UserId] = nil
	end))

	table.insert(self.connections, self.deathPart.Touched:Connect(function(part: BasePart)
		local player: Player? = Players:GetPlayerFromCharacter(part.Parent)
		if not player then
			return
		end
		print("dead")
		tpPlayerToPart(player, self.startPart)
	end))

	return self
end

function ObbyZone:Destroy()
	for _, conn in self.connections do
		conn:Disconnect()
	end
	table.clear(self.connections)
	table.clear(self.debounce)
end

return ObbyZone