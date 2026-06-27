--!strict
-- Centralized scripted avatar animation. Play an animation on any rig (Model or Humanoid):
--   * by NAME  — a KeyframeSequence under ReplicatedStorage.Assets.Animations. Played WITHOUT
--                uploading by driving the rig's Motor6D joints from the keyframes directly
--                (RegisterKeyframeSequence is Studio/plugin-only, so it can't be used at
--                runtime). No asset, no Animator.
--   * by ASSET — a published "rbxassetid://..." (or bare numeric id), via a normal Animator.
-- Both return a Handle with Stop().
--
-- Replication note: the keyframe player writes Motor6D.Transform, which is solved per-peer, so
-- run NAME playback on each peer that should SEE it (e.g. on every client for a server-built
-- NPC like the podium — the KeyframeSequence lives in ReplicatedStorage, so every client can
-- play it locally). ASSET animations replicate normally via the Animator.

local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local AnimationService = {}

local ANIM_FOLDER = RS:WaitForChild("Assets"):WaitForChild("Animations")

export type PlayOptions = {
	looped: boolean?,
	speed: number?,    -- playback speed (default 1)
	weight: number?,   -- ASSET path only: blend weight (default 1)
	fadeTime: number?, -- ASSET path only: transition-in seconds (default 0)
	priority: Enum.AnimationPriority?, -- ASSET path only
}

-- Stop() halts playback. Track is the AnimationTrack for the ASSET path (nil for NAME).
export type Handle = { Stop: () -> (), Track: AnimationTrack? }

----------------------------------------------------------------------------------
-- KeyframeSequence -> Motor6D player (no upload)
----------------------------------------------------------------------------------

-- Map Pose easing (its own enums) onto TweenService's.
local POSE_STYLE: { [Enum.PoseEasingStyle]: Enum.EasingStyle } = {
	[Enum.PoseEasingStyle.Linear] = Enum.EasingStyle.Linear,
	[Enum.PoseEasingStyle.Cubic] = Enum.EasingStyle.Cubic,
	[Enum.PoseEasingStyle.Bounce] = Enum.EasingStyle.Bounce,
	[Enum.PoseEasingStyle.Elastic] = Enum.EasingStyle.Elastic,
}
local POSE_DIR: { [Enum.PoseEasingDirection]: Enum.EasingDirection } = {
	[Enum.PoseEasingDirection.In] = Enum.EasingDirection.In,
	[Enum.PoseEasingDirection.Out] = Enum.EasingDirection.Out,
	[Enum.PoseEasingDirection.InOut] = Enum.EasingDirection.InOut,
}

local function easedAlpha(alpha: number, style: Enum.PoseEasingStyle, dir: Enum.PoseEasingDirection): number
	if style == Enum.PoseEasingStyle.Constant then
		return if alpha >= 1 then 1 else 0 -- hold previous pose, snap at the end
	end
	return TweenService:GetValue(alpha, POSE_STYLE[style] or Enum.EasingStyle.Linear, POSE_DIR[dir] or Enum.EasingDirection.Out)
end

type Frame = { t: number, cf: CFrame, style: Enum.PoseEasingStyle, dir: Enum.PoseEasingDirection }
type Parsed = { length: number, tracks: { [string]: { Frame } } }

-- Parsed keyframe data is per-KeyframeSequence (independent of the rig), so cache it.
local parsedCache: { [Instance]: Parsed } = {}

local function parse(ks: KeyframeSequence): Parsed
	local cached = parsedCache[ks]
	if cached then
		return cached
	end
	local tracks: { [string]: { Frame } } = {}
	local length = 0
	for _, kf in ks:GetKeyframes() do
		local t = (kf :: Keyframe).Time
		if t > length then
			length = t
		end
		local function walk(pose: Pose)
			local list = tracks[pose.Name]
			if not list then
				list = {}
				tracks[pose.Name] = list
			end
			table.insert(list, { t = t, cf = pose.CFrame, style = pose.EasingStyle, dir = pose.EasingDirection })
			for _, sub in pose:GetSubPoses() do
				walk(sub :: Pose)
			end
		end
		for _, root in (kf :: Keyframe):GetPoses() do
			walk(root :: Pose)
		end
	end
	for _, list in tracks do
		table.sort(list, function(a, b)
			return a.t < b.t
		end)
	end
	local p: Parsed = { length = length, tracks = tracks }
	parsedCache[ks] = p
	return p
end

-- The character Model for a target (Model or Humanoid).
local function modelOf(target: Instance): Model?
	if target:IsA("Model") then
		return target
	elseif target:IsA("Humanoid") and target.Parent and target.Parent:IsA("Model") then
		return target.Parent :: Model
	end
	return nil
end

local function startKeyframePlayer(model: Model, ks: KeyframeSequence, opts: PlayOptions?): Handle
	local parsed = parse(ks)
	-- Joint by the part it drives (Motor6D.Part1.Name = the Pose.Name in the sequence).
	local joints: { [string]: Motor6D } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") and d.Part1 then
			joints[d.Part1.Name] = d
		end
	end

	local function poseAt(t: number)
		for name, list in parsed.tracks do
			local joint = joints[name]
			if joint then
				if #list == 1 or t <= list[1].t then
					joint.Transform = list[1].cf
				elseif t >= list[#list].t then
					joint.Transform = list[#list].cf
				else
					for i = 1, #list - 1 do
						local a, b = list[i], list[i + 1]
						if t >= a.t and t <= b.t then
							local span = b.t - a.t
							local alpha = if span > 0 then (t - a.t) / span else 1
							joint.Transform = a.cf:Lerp(b.cf, easedAlpha(alpha, b.style, b.dir))
							break
						end
					end
				end
			end
		end
	end

	-- Single-frame "pose": just stamp it, nothing to loop.
	if parsed.length <= 0 then
		poseAt(0)
		return { Stop = function() end, Track = nil }
	end

	local speed = (opts and opts.speed) or 1
	local looped = (opts and opts.looped) or false
	local startClock = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.Heartbeat:Connect(function()
		if not model.Parent then
			if conn then conn:Disconnect() end
			return
		end
		local t = (os.clock() - startClock) * speed
		if looped then
			t %= parsed.length
		elseif t >= parsed.length then
			t = parsed.length
		end
		poseAt(t)
		if not looped and t >= parsed.length and conn then
			conn:Disconnect()
		end
	end)

	return {
		Stop = function()
			if conn then
				conn:Disconnect()
				conn = nil
			end
		end,
		Track = nil,
	}
end

----------------------------------------------------------------------------------
-- Asset-id playback (published animation via Animator)
----------------------------------------------------------------------------------

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

----------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------

-- Play a KeyframeSequence from Assets.Animations by name (no upload), driving the rig's joints.
function AnimationService.Play(target: Instance, name: string, opts: PlayOptions?): Handle?
	local model = modelOf(target)
	if not model then
		warn(("AnimationService: %s is not a rig Model/Humanoid"):format(target:GetFullName()))
		return nil
	end
	local ks = ANIM_FOLDER:FindFirstChild(name)
	if not (ks and ks:IsA("KeyframeSequence")) then
		warn(("AnimationService: no KeyframeSequence named '%s' in Assets.Animations"):format(name))
		return nil
	end
	return startKeyframePlayer(model, ks :: KeyframeSequence, opts)
end

-- Play a published animation by asset id ("rbxassetid://..." or a bare numeric id).
function AnimationService.PlayAssetId(target: Instance, assetId: string, opts: PlayOptions?): Handle?
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
