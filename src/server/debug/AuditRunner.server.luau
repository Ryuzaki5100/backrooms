--!strict

-- Studio-only trigger for the geometry audit (task 0032). Set the Workspace
-- attribute `NoclipAudit` to true (Play server) and this audits the chunks
-- around each player, prints the report, stores a one-line summary in
-- `NoclipAuditResult` and resets the flag. A live server never runs it.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

if RunService:IsStudio() then
	local GeometryAudit = require(script.Parent:WaitForChild("GeometryAudit"))
	local RADIUS_CHUNKS = 2 -- Level 0 generationRadius
	local running = false

	local function auditAll()
		local world = workspace:WaitForChild("NoclipWorld", 30)
		if world == nil then
			warn("[audit] NoclipWorld never appeared")
			workspace:SetAttribute("NoclipAuditResult", "no world")
			return
		end
		local summary: { string } = {}
		local specs: { { name: string, around: Vector3? } } = {}
		for _, player in ipairs(Players:GetPlayers()) do
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if root ~= nil and root:IsA("BasePart") then
				table.insert(specs, { name = player.Name, around = root.Position })
			end
		end
		if #specs == 0 then
			table.insert(specs, { name = "world", around = nil })
		end
		for _, spec in ipairs(specs) do
			local report = GeometryAudit.run({
				folder = world,
				around = spec.around,
				radiusChunks = RADIUS_CHUNKS,
				markers = workspace:GetAttribute("NoclipAuditMarkers") == true,
			})
			print(string.format("[audit] around %s", spec.name))
			print(GeometryAudit.format(report))
			table.insert(summary, GeometryAudit.summary(report))
		end
		workspace:SetAttribute("NoclipAuditResult", table.concat(summary, " | "))
	end

	workspace:GetAttributeChangedSignal("NoclipAudit"):Connect(function()
		if workspace:GetAttribute("NoclipAudit") ~= true or running then
			return
		end
		running = true
		task.spawn(function()
			local ok, err = pcall(auditAll)
			if not ok then
				warn("[audit] failed: " .. tostring(err))
				workspace:SetAttribute("NoclipAuditResult", "error: " .. tostring(err))
			end
			running = false
			workspace:SetAttribute("NoclipAudit", false)
		end)
	end)
end
