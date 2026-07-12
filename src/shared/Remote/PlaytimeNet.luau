--!strict
-- PlaytimeNet — remotes owned by PlaytimeBonusService. The single place these remotes
-- are created (server) and looked up (client).

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
	-- Server -> Client: (info: Info) — rung availability/progress after any change.
	PlaytimeChanged = remoteEvent("PlaytimeChanged"),
	-- Client -> Server invoke: () -> Info.
	GetPlaytimeInfo = remoteFunction("GetPlaytimeInfo"),
	-- Client -> Server invoke: () -> (ok: boolean, reward: number?) — claim the next reached rung.
	ClaimPlaytimeBonus = remoteFunction("ClaimPlaytimeBonus"),
}
