--!strict
-- DataNet — remotes owned by DataService. The single place these remotes are created
-- (server) and looked up (client).

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
	-- Client -> Server invoke: () -> true — yields until the caller's persisted data has been
	-- applied server-side (join-popup gating, e.g. the daily-reward prompt).
	WaitForDataLoaded = remoteFunction("WaitForDataLoaded"),
}
