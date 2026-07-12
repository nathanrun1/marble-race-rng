--!strict
-- LaunchNet — remotes owned by BallLaunchService. The single place these remotes are
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
	-- Client -> Server: () — request a launch batch of the player's equipped loadout balls
	-- (server owns timing/affordability; silently ignored while a batch window is still open).
	RequestLaunch = remoteEvent("RequestLaunch"),
	-- Client -> Server invoke: () -> number — the server's current launcher swivel phase
	-- (0..1), so the client aim preview stays in sync.
	GetLauncherPhase = remoteFunction("GetLauncherPhase"),
}
