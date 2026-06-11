-- BallEffects (one ModuleScript in SSS or RS.Shared; stateless, operates ON a ball)
--!strict
local BallEffects = {}

function BallEffects.SetValueUI(ball: BasePart, value: number): ()
	if not ball then
		return
	end
	
	local textLabel: TextLabel = (ball:FindFirstChild("ValueUI") :: Instance):FindFirstChild("TextLabel") :: TextLabel
	textLabel.Text = tostring(value)
end

return BallEffects