--!strict
-- StarterQuestNet — remotes owned by StarterQuestService (the one-time Getting Started
-- chain). The single place these remotes are created (server) and looked up (client).

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
	-- Server -> Client: (info: ChainInfo) — the live mission window after any change.
	StarterQuestChanged = remoteEvent("StarterQuestChanged"),
	-- Client -> Server invoke: () -> ChainInfo.
	GetStarterQuestInfo = remoteFunction("GetStarterQuestInfo"),
}
