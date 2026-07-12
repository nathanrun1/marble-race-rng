--!strict
-- LoadoutNet — remotes owned by LoadoutService (the bonus-slot skin loadout).
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
	-- Server -> Client: (info: LoadoutInfo) — after any loadout change.
	LoadoutChanged = remoteEvent("LoadoutChanged"),
	-- Client -> Server invoke: () -> LoadoutInfo.
	GetLoadoutInfo = remoteFunction("GetLoadoutInfo"),
	-- Client -> Server: (slot: number, skinId: string?) — equip a skin into a slot (nil clears).
	SetLoadoutSlot = remoteEvent("SetLoadoutSlot"),
	-- Client -> Server: () — fill every slot with the best-bonus owned skins.
	EquipBestLoadout = remoteEvent("EquipBestLoadout"),
}
