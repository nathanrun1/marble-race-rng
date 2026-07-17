--!strict
-- LeaderboardNet — remotes owned by the physical-leaderboards service. The single place
-- these remotes are created (server) and looked up (client).

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

return {
	-- Server -> Client: (rank: number?) — this player's global Avg $/Marble rank (nil = unranked).
	MoneyPerBallRank = remoteEvent("MoneyPerBallRank"),
}
