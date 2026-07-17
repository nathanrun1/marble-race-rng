--!strict
-- ProfileNet — remotes owned by ProfileService (upgrade tiers + loadout). The single place
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
	-- Server -> Client: (profile: Profile) — full profile snapshot after any change.
	ProfileChanged = remoteEvent("ProfileChanged"),
	-- Client -> Server invoke: () -> Profile — the caller's full profile snapshot.
	GetProfile = remoteFunction("GetProfile"),
	-- Client -> Server invoke: (axis: string, value: number) -> Profile? — set a loadout axis
	-- position (server clamps to the tier-unlocked range).
	SetAxis = remoteFunction("SetAxis"),
	-- Client -> Server invoke: (tier: number) -> Profile? — select the active bet tier
	-- (server clamps to owned MaxBet tiers).
	SetBetTier = remoteFunction("SetBetTier"),
}
