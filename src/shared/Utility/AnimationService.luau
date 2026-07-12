--!strict
-- Plays a published animation (by asset id) on any rig (Model or Humanoid) via its Animator,
-- returning a Handle with Stop(). Asset-id animations replicate normally, so this works from
-- the server (for NPCs visible to everyone) or the client.

local AnimationService = {}

export type PlayOptions = {
	looped: boolean?,
	speed: number?,    -- playback speed (default 1)
	weight: number?,   -- blend weight (default 1)
	fadeTime: number?, -- transition-in seconds (default 0)
	priority: Enum.AnimationPriority?,
}

export type Handle = { Stop: () -> (), Track: AnimationTrack? }

-- Resolve a rig (Model or Humanoid) to its Animator, creating one if missing.
local function getAnimator(target: Instance): Animator?
	local humanoid: Humanoid? = nil
	if target:IsA("Humanoid") then
		humanoid = target
	elseif target:IsA("Model") then
		humanoid = target:FindFirstChildOfClass("Humanoid")
	end
	if not humanoid then
		warn(("AnimationService: %s has no Humanoid"):format(target:GetFullName()))
		return nil
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	return animator
end

-- Play a published animation by asset id ("rbxassetid://..." or a bare numeric id).
function AnimationService.Play(target: Instance, assetId: string, opts: PlayOptions?): Handle?
	local animator = getAnimator(target)
	if not animator then
		return nil
	end
	if not assetId:match("://") then
		assetId = "rbxassetid://" .. assetId
	end
	local o = opts or {}
	local anim = Instance.new("Animation")
	anim.AnimationId = assetId
	local ok, track = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if not ok or not track then
		warn(("AnimationService: LoadAnimation failed (%s): %s"):format(assetId, tostring(track)))
		return nil
	end
	if o.looped ~= nil then
		track.Looped = o.looped
	end
	if o.priority then
		track.Priority = o.priority
	end
	track:Play(o.fadeTime or 0, o.weight or 1, o.speed or 1)
	return {
		Stop = function()
			track:Stop()
		end,
		Track = track,
	}
end

return AnimationService
