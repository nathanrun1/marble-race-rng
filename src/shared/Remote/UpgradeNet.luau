--!strict
-- UpgradeNet — remotes owned by UpgradeService (+ UpgradeLockService's lock purchase).
-- The single place these remotes are created (server) and looked up (client).

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
	-- Client -> Server invoke: () -> { [track]: Info } — price/tier/cap info for every track.
	GetUpgradeInfo = remoteFunction("GetUpgradeInfo"),
	-- Client -> Server invoke: (track: string) -> PurchaseResult — buy the next tier.
	PurchaseUpgrade = remoteFunction("PurchaseUpgrade"),
	-- Client -> Server invoke: (track: string) -> boolean — arm the UpgradeBoost (3×) product
	-- prompt for this track (server records the pending track; grant lands via ProcessReceipt).
	RequestUpgradeBoost = remoteFunction("RequestUpgradeBoost"),
	-- Client -> Server invoke: (lockId: string) -> PurchaseResult — buy a world upgrade lock.
	PurchaseUpgradeLock = remoteFunction("PurchaseUpgradeLock"),
}
