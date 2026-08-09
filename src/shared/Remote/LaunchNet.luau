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
	-- Client -> Server: (slot: number?) — request a launch. With a slot number, launches just
	-- that slot's equipped ball (silently ignored while the slot is cooling down / empty /
	-- not yet unlocked); with no slot, launches every ready slot (the HUD LAUNCH button).
	RequestLaunch = remoteEvent("RequestLaunch"),
	-- Server -> Client: (slot: number, cooldown: number, stake: number) — this slot just
	-- fired; it is on cooldown for `cooldown` seconds (client SlotInteract renders the
	-- countdown from this) and `stake` was just deducted for the ball's value (SlotInteract
	-- pops a red "-$X" over the pad).
	SlotLaunched = remoteEvent("SlotLaunched"),
	-- Client -> Server invoke: () -> number — the server's current launcher swivel phase
	-- (0..1), so the client aim preview stays in sync.
	GetLauncherPhase = remoteFunction("GetLauncherPhase"),
	-- Client -> Server invoke: (slot: number) -> { ok: boolean, enabled: boolean?, reason:
	-- string? } — flip a slot's free built-in AUTO on/off (the AutoSign's click; reasons:
	-- "invalid_slot" | "locked"). The new state lands in the autoSlots value and
	-- replicates via ProfileChanged.
	ToggleSlotAuto = remoteFunction("ToggleSlotAuto"),
}
