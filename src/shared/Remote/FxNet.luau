--!strict
-- FxNet — server-driven client feedback: banner/log messages, SFX, ball VFX, and the
-- currency-fly celebration. Owned by the shared UI/FX modules (ScoreUI, AnnounceUI,
-- WarnUI, SoundService, BallEffects) plus any server granter that wants a currency fly.
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

return {
	-- Server -> Client: (text: string, color: Color3?) — right-side score-log line (ScoreUI).
	ScoreMessage = remoteEvent("ScoreMessage"),
	-- Server -> Client: (text: string, color: Color3?, lifetime: number?) — large centered
	-- banner (AnnounceUI).
	AnnounceMessage = remoteEvent("AnnounceMessage"),
	-- Server -> Client: (text: string, color: Color3?, lifetime: number?) — small lower-screen
	-- warning banner (WarnUI).
	WarnMessage = remoteEvent("WarnMessage"),
	-- Server -> Client: (spec: SoundSpec) — play a pooled SFX on this client (SoundService).
	PlaySound = remoteEvent("PlaySound"),
	-- Server -> Client: (effect: string, ball: BasePart, ...args) — dispatch a BallEffects
	-- visual on this client (SetValueUI, ShowComboPopup, EmitBounce, ...).
	BallEffect = remoteEvent("BallEffect"),
	-- Server -> Client: (kind: "Cash" | "Diamonds" | "Crate", count: number?, amount: number?)
	-- — play the currency-fly celebration into the matching HUD icon (CurrencyFlyUI). With an
	-- amount, the flight drives the balance readout's live sum — granters MUST fire this
	-- BEFORE applying the grant, so the hold seeds from the pre-grant balance.
	PlayCurrencyFly = remoteEvent("PlayCurrencyFly"),
}
