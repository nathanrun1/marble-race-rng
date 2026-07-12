--!strict
-- DevNet — remotes owned by DevService (admin/Studio tooling). The single place these
-- remotes are created (server) and looked up (client).

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
	-- Server -> Client: (restricted: boolean?) — mirror a dev PolicyGate override to the
	-- target client (nil clears the override). See PolicyGate.SetOverride.
	DevPolicyOverride = remoteEvent("DevPolicyOverride"),
}
