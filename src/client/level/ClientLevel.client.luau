--!strict

-- Client half of the level runtime (ADR 0033 D78). Stub: it decodes and validates
-- the lighting profile the server publishes and logs one line per change. Zone
-- blending comes in task 0030.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local lighting = require(
	ReplicatedStorage:WaitForChild("Procgen")
		:WaitForChild("level")
		:WaitForChild("systems")
		:WaitForChild("lighting")
) :: any

local ATTRIBUTE: string = lighting.ATTRIBUTE

local function onProfile()
	local raw = workspace:GetAttribute(ATTRIBUTE)
	if type(raw) ~= "string" then
		return
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok or type(decoded) ~= "table" then
		warn("[noclip] lighting profile is not valid JSON")
		return
	end
	local problems: { string } = lighting.validate(decoded)
	if #problems > 0 then
		warn("[noclip] lighting profile rejected: " .. table.concat(problems, "; "))
		return
	end
	local levelId = workspace:GetAttribute("NoclipLevelId")
	print(string.format("[noclip] lighting profile %s", tostring(levelId)))
end

workspace:GetAttributeChangedSignal(ATTRIBUTE):Connect(onProfile)
onProfile()
