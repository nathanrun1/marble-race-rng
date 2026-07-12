--!strict
-- Configures every DestroyTarget-tagged slot on load from ScoringConfig.DestroyTargets.Multipliers,
-- keyed by the part's DestroyTargetID attribute:
--   * a numeric multiplier -> set the PointMul attribute.
--   * the Jackpot sentinel  -> add the JackpotTarget tag (the slot then pays via
--                              Scoring.JackpotMultiplier), and clear any PointMul.
-- It also writes the multiplier onto the slot's Parent.Display.SurfaceGui.TextLabel as
-- "x[MULT]" — for a jackpot slot that's its effective multiplier, 1 + Scoring.JackpotMultiplier.

local CollectionService = game:GetService("CollectionService")
local RS = game:GetService("ReplicatedStorage")

local AttributesConfig = require(RS.Shared.Config.Attributes)
local ScoringConfig = require(RS.Shared.Config.Scoring)
local TagsConfig = require(RS.Shared.Config.Tags)
local StringUtils = require(RS.Shared.Utility.StringUtils)

local DestroyTargetService = {}

local MULTS = ScoringConfig.DestroyTargets.Multipliers :: { [number]: any }
local JACKPOT = ScoringConfig.DestroyTargets.Jackpot

-- Base (tier-0) display. Each client then overwrites the labels locally with its own
-- Base-Bonus-boosted values (BoardMultiplierView); same "x" + FormatShort format.
local function displayText(mult: any): string
	-- Jackpot slots pay base × (1 + JackpotMultiplier); show that effective multiplier.
	local n = if mult == JACKPOT then (1 + ScoringConfig.JackpotMultiplier) else mult
	return "x" .. StringUtils.FormatShort(n)
end

local function setLabel(part: Instance, text: string)
	local parent = part.Parent
	local display = parent and parent:FindFirstChild("Display")
	local gui = display and display:FindFirstChild("SurfaceGui")
	local label = gui and gui:FindFirstChild("TextLabel")
	if label and label:IsA("TextLabel") then
		label.Text = text
	else
		warn(("DestroyTargetService: no Display.SurfaceGui.TextLabel under %s"):format(part:GetFullName()))
	end
end

local function configure(part: Instance)
	if not part:IsA("BasePart") then
		return
	end
	local id = tonumber(part:GetAttribute(AttributesConfig.DestroyTargetID))
	if not id or type(id) ~= "number" then
		warn(("DestroyTargetService: %s has no numeric DestroyTargetID"):format(part:GetFullName()))
		return
	end
	local mult = MULTS[id]
	if mult == nil then
		warn(("DestroyTargetService: no multiplier configured for DestroyTargetID %d (%s)"):format(id, part:GetFullName()))
		return
	end

	if mult == JACKPOT then
		-- Pays through the jackpot mechanic, not a PointMul; clear any stale PointMul.
		part:SetAttribute(AttributesConfig.PointMul, nil)
		CollectionService:AddTag(part, TagsConfig.JackpotTarget)
	else
		part:SetAttribute(AttributesConfig.PointMul, mult)
	end
	setLabel(part, displayText(mult))
end

function DestroyTargetService.Init()
	for _, part in CollectionService:GetTagged(TagsConfig.DestroyTarget) do
		configure(part)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.DestroyTarget):Connect(configure)
end

return DestroyTargetService
