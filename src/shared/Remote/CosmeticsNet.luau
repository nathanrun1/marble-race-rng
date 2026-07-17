--!strict
-- CosmeticsNet — remotes owned by CosmeticService (Diamonds, skin ownership, crates).
-- The single place these remotes are created (server) and looked up (client).

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
	-- Server -> Client: (info: CosmeticInfo) — full cosmetics snapshot after any change.
	CosmeticChanged = remoteEvent("CosmeticChanged"),
	-- Client -> Server invoke: () -> CosmeticInfo.
	GetCosmeticInfo = remoteFunction("GetCosmeticInfo"),
	-- Client -> Server invoke: (skinId: string) -> PurchaseResult — direct CC purchase.
	PurchaseCosmetic = remoteFunction("PurchaseCosmetic"),
	-- Client -> Server: (skinId: string) — select a skin in the shop (server-side selection state).
	SelectCosmetic = remoteEvent("SelectCosmetic"),
	-- Client -> Server invoke: (boxId: string) -> RollResult — open one held box of this type.
	RollCrate = remoteFunction("RollCrate"),
	-- Client -> Server invoke: () -> RollResult — claim + open the session-timer free box.
	ClaimFreeCrate = remoteFunction("ClaimFreeCrate"),
	-- Client -> Server invoke: (boxId: string) -> PurchaseResult — buy an unopened box with Diamonds.
	BuyCrate = remoteFunction("BuyCrate"),
	-- Client -> Server: (skinId: string) — wear a skin as the visual equip.
	EquipCosmetic = remoteEvent("EquipCosmetic"),
	-- Server -> Client: (result: RollResult) — a crate roll landed (drives the reel reveal for
	-- rolls the server initiated, e.g. Robux crate products).
	CrateRolled = remoteEvent("CrateRolled"),
}
