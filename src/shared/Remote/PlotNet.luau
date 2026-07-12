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
	-- Server -> Client: (plotId: string, skinId: string, value: number) — a banked marble
	-- produced a claimable plot ball for this player.
	SpawnPlotBall = remoteEvent("SpawnPlotBall"),
	-- Client -> Server: (plotId: string) — claim a touched plot ball (server validates + pays).
	ClaimPlotBall = remoteEvent("ClaimPlotBall"),
}
