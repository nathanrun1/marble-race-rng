--!strict
-- Auto-wires an ObbyZone for every workspace instance tagged TagsConfig.Obby, and
-- tears it down if the model is untagged/removed. Tag a new obby model and it just
-- works — no per-obby code.

local CollectionService = game:GetService("CollectionService")
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

local TagsConfig = require(RS.Shared.Config.Tags)
local ObbyZone = require(SSS.Scripts.Utility.ObbyZone)

local ObbyService = {}

-- Live zones keyed by their model, so we can Destroy the right one on removal.
local zones: { [Instance]: any } = {}

local function addObby(inst: Instance)
	if zones[inst] then
		return
	end
	if not inst:IsA("Model") then
		warn(("ObbyService: tagged instance %s is not a Model; skipping"):format(inst:GetFullName()))
		return
	end
	-- ObbyZone.New asserts its required parts exist; don't let one malformed obby take
	-- down the wiring of the others.
	local ok, zoneOrErr = pcall(ObbyZone.New, inst)
	if not ok then
		warn(("ObbyService: failed to wire obby %s: %s"):format(inst:GetFullName(), tostring(zoneOrErr)))
		return
	end
	zones[inst] = zoneOrErr
end

local function removeObby(inst: Instance)
	local zone = zones[inst]
	if zone then
		zone:Destroy()
		zones[inst] = nil
	end
end

function ObbyService.Init()
	for _, inst in CollectionService:GetTagged(TagsConfig.Obby) do
		addObby(inst)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.Obby):Connect(addObby)
	CollectionService:GetInstanceRemovedSignal(TagsConfig.Obby):Connect(removeObby)
end

return ObbyService
