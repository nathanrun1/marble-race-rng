--!strict
-- GroupRewardNet — remotes owned by GroupRewardService. The single place these remotes
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

return {
	-- Server -> Client: () — the player touched the pad while not in the group; the client
	-- opens the group join prompt.
	PromptGroupJoin = remoteEvent("PromptGroupJoin"),
	-- Server -> Client: (reward: number) — a claim succeeded (drives the celebration).
	GroupRewardClaimed = remoteEvent("GroupRewardClaimed"),
}
