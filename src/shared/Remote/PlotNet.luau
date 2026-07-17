--!strict
-- PlotNet — remotes owned by the ball-plot feature (server validates claims, client
-- renders the claimable balls). The single place these remotes are created (server)
-- and looked up (client).

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
	-- Server -> Client: (id: number, skinId: string, value: number, sourceBall: BasePart?) —
	-- a banked marble produced a claimable plot ball for this player. sourceBall is the banked
	-- ball instance itself (still alive during its destroy-delay linger): the client clones it
	-- so every appearance change the drop accumulated (heat paint, size, particles) carries
	-- over; nil/expired falls back to a fresh prefab dressed from skinId.
	SpawnPlotBall = remoteEvent("SpawnPlotBall"),
	-- Client -> Server: (ids: { number }, collectAll: boolean?) — claim the plot balls behind
	-- these ids (server validates + pays). collectAll marks the collect-all pad's batch claim,
	-- which celebrates with a bigger currency fly than a single walked-over ball.
	ClaimPlotBall = remoteEvent("ClaimPlotBall"),
	-- Server -> Client: () — every plot ball is gone (rebirth wiped the claimable set);
	-- destroy all local plot-ball instances and reset the collect pad.
	ClearPlotBalls = remoteEvent("ClearPlotBalls"),
}
