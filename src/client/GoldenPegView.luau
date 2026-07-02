--!strict
-- Renders the LOCAL player's golden pegs (see GoldenPegService): the set is per-player,
-- so the gold look is applied client-side only — other players see their own sets.
--
-- The server repaints peg colors every minute (PegService hot/cold tweens replicate), so
-- a one-shot local recolor would get stomped. Instead each golden peg gets a local gold
-- color/material override that re-asserts itself whenever a replicated repaint touches
-- the property, plus Sparkles so it reads as special even mid-tween.

local RS = game:GetService("ReplicatedStorage")

local GoldenPegView = {}

local GOLD = Color3.fromRGB(255, 200, 40)

type Applied = {
	connections: { RBXScriptConnection },
	sparkles: Sparkles,
	originalColor: Color3,
	originalMaterial: Enum.Material,
}

local applied: { [BasePart]: Applied } = {}

local function markGolden(peg: BasePart)
	if applied[peg] then
		return
	end
	local entry: Applied = {
		connections = {},
		sparkles = Instance.new("Sparkles"),
		originalColor = peg.Color,
		originalMaterial = peg.Material,
	}

	peg.Color = GOLD
	peg.Material = Enum.Material.Neon
	-- Re-assert the override when a server repaint (or its tween frames) replicates over it.
	table.insert(entry.connections, peg:GetPropertyChangedSignal("Color"):Connect(function()
		if peg.Color ~= GOLD then
			peg.Color = GOLD
		end
	end))
	table.insert(entry.connections, peg:GetPropertyChangedSignal("Material"):Connect(function()
		if peg.Material ~= Enum.Material.Neon then
			peg.Material = Enum.Material.Neon
		end
	end))

	entry.sparkles.SparkleColor = GOLD
	entry.sparkles.Parent = peg

	applied[peg] = entry
end

local function unmark(peg: BasePart)
	local entry = applied[peg]
	if not entry then
		return
	end
	applied[peg] = nil
	for _, conn in entry.connections do
		conn:Disconnect()
	end
	entry.sparkles:Destroy()
	-- Best-effort restore; the next server repaint re-colors it authoritatively anyway.
	peg.Color = entry.originalColor
	peg.Material = entry.originalMaterial
end

-- Replace the rendered set with the server's latest list.
local function apply(pegList: { BasePart })
	local keep: { [BasePart]: true } = {}
	for _, peg in pegList do
		if typeof(peg) == "Instance" and peg:IsA("BasePart") then
			keep[peg] = true
			markGolden(peg)
		end
	end
	for peg in applied do
		if not keep[peg] then
			unmark(peg)
		end
	end
end

function GoldenPegView.Init()
	local changedRE = RS.Remote:WaitForChild("GoldenPegsChanged") :: RemoteEvent
	local getRF = RS.Remote:WaitForChild("GetGoldenPegs") :: RemoteFunction

	changedRE.OnClientEvent:Connect(function(pegList)
		if type(pegList) == "table" then
			apply(pegList)
		end
	end)

	-- Snapshot in case the set was pushed before this module bound (join-time race).
	task.spawn(function()
		local ok, pegList = pcall(function()
			return getRF:InvokeServer()
		end)
		if ok and type(pegList) == "table" then
			apply(pegList)
		end
	end)
end

return GoldenPegView
