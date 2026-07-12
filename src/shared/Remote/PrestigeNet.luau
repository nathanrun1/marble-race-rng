--!strict
-- PrestigeNet — remotes owned by PrestigeService. The single place these remotes are
-- created (server) and looked up (client).

local RunService = game:GetService("RunService")

local function remoteEvent(name: string): RemoteEvent
	if RunService:IsServer() then
		local re = Instance.new("RemoteEvent")
		re.Name = name
		re.Parent = script
		return re
	end
	return script:WaitForChild(name) :: RemoteEvent
end

local function remoteFunction(name: string): RemoteFunction
	if RunService:IsServer() then
		local rf = Instance.new("RemoteFunction")
		rf.Name = name
		rf.Parent = script
		return rf
	end
	return script:WaitForChild(name) :: RemoteFunction
end

return {
	-- Server -> Client: (info: PrestigeInfo) — after any prestige-state change.
	PrestigeChanged = remoteEvent("PrestigeChanged"),
	-- Client -> Server invoke: () -> PrestigeInfo.
	GetPrestigeInfo = remoteFunction("GetPrestigeInfo"),
	-- Client -> Server invoke: () -> (ok: boolean, info: PrestigeInfo?) — perform a rebirth.
	Prestige = remoteFunction("Prestige"),
}
