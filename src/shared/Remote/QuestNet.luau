--!strict
-- QuestNet — remotes owned by QuestService (daily quests). The single place these
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
	-- Server -> Client: (info: Info) — quest set/progress snapshot (throttled push). A
	-- completed quest's reward is already paid by the time this arrives (QuestService pays
	-- out the instant progress hits target) — there is no separate claim remote.
	QuestsChanged = remoteEvent("QuestsChanged"),
	-- Client -> Server invoke: () -> Info.
	GetQuestInfo = remoteFunction("GetQuestInfo"),
}
