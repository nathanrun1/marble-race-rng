--!strict
-- CoinNet — remotes owned by CoinService (per-player collectible coins). The single
-- place these remotes are created (server) and looked up (client).

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
	-- Server -> Client: (coinId: string, locationName: string, value: number, isBlue: boolean) —
	-- a coin became active for this player at a tagged spawn location.
	CoinActivate = remoteEvent("CoinActivate"),
	-- Server -> Client: (coinId: string) — a coin is no longer active (claimed/expired).
	CoinDeactivate = remoteEvent("CoinDeactivate"),
	-- Client -> Server: (coinId: string) — claim a touched coin (server validates).
	CoinClaim = remoteEvent("CoinClaim"),
	-- Client -> Server: () — the client renderer is ready to receive coin activations.
	CoinReady = remoteEvent("CoinReady"),
	-- Client -> Server: () — force-spawn a coin now (tutorial's NearestCoin arrow).
	ForceSpawnCoin = remoteEvent("ForceSpawnCoin"),
}
