--!strict
-- StatsNet — remotes owned by StatsService (persisted meta-stats: cash multiplier/boost,
-- upgrades purchased, tutorial flags, $/marble average). The single place these remotes
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
	-- Server -> Client: (stats: Stats) — full stats snapshot after any change.
	StatsChanged = remoteEvent("StatsChanged"),
	-- Client -> Server invoke: () -> Stats.
	GetStats = remoteFunction("GetStats"),
	-- Client -> Server: (which: string?) — mark a tutorial completed ("join" default,
	-- "cosmetic", "loadout", "tuning").
	CompleteTutorial = remoteEvent("CompleteTutorial"),
}
