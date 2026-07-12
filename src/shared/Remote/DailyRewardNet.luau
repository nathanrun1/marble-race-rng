--!strict
-- DailyRewardNet — remotes owned by DailyRewardService. The single place these remotes
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
	-- Server -> Client: (info: Info) — claimability/streak snapshot after any change.
	DailyRewardChanged = remoteEvent("DailyRewardChanged"),
	-- Client -> Server invoke: () -> Info.
	GetDailyRewardInfo = remoteFunction("GetDailyRewardInfo"),
	-- Client -> Server invoke: () -> ClaimResult — claim today's reward (server rolls the pool).
	ClaimDailyReward = remoteFunction("ClaimDailyReward"),
}
