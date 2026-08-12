--!strict
-- WeatherNet — remotes owned by WeatherService. The single place these remotes are created
-- (server) and looked up (client). Atmosphere/Lighting themselves replicate automatically
-- (they're networked instances) — these remotes exist purely so the client knows WHICH
-- preset name is active, to pick the matching falling-particle look (Config/Weather).

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
	-- Server -> Client: (weather: string?) — the active preset name (a Config/Weather.Presets
	-- key), or nil for Clear. Fires on every WeatherService.SetWeather call.
	WeatherChanged = remoteEvent("WeatherChanged"),
	-- Client -> Server invoke: () -> string? — the current weather, for a late join.
	GetWeather = remoteFunction("GetWeather"),
}
