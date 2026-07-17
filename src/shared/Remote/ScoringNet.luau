--!strict
-- ScoringNet — remotes owned by ScoringService. The single place these remotes are
-- created (server) and looked up (client).

local RunService = game:GetService("RunService")

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
	-- Client -> Server invoke: (ball: BasePart) -> number — the ball's current effective
	-- (live-multiplied) value, for the overhead value UI.
	GetEffectiveBallValue = remoteFunction("GetEffectiveBallValue"),
}
