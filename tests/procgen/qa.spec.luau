--!strict

local H = require("../harness")
local Embedding = require("../../src/shared/procgen/Embedding")
local Geometry = require("../../src/shared/procgen/Geometry")
local Macro = require("../../src/shared/procgen/Macro")
local Qa = require("../../src/shared/procgen/Qa")
local Level0 = require("../../src/config/levels/Level_0")

local OPTIONS = {
	loops = Level0.generate.loops,
	loopPreference = Level0.generate.loopPreference,
}

local function build(seed: number): (any, { any })
	local plan = Embedding.embed(Macro.build(Level0, seed), OPTIONS)
	return plan, Geometry.describe(plan, { style = Level0.style })
end

H.test("seed 42 passes every physical invariant", function()
	local plan, parts = build(42)
	local problems = Qa.check(plan, parts, { style = Level0.style })
	H.eq(#problems, 0, table.concat(problems, "; "))
end)

H.test("every doorway is actually open", function()
	local plan, parts = build(42)
	local openings = Geometry.openings(plan, { style = Level0.style })
	H.ok(#openings > 0, "has doorways")
	local problems = Qa.check(plan, parts, { style = Level0.style })
	for _, problem in ipairs(problems) do
		H.ok(not string.find(problem, "blocked", 1, true), problem)
	end
end)

H.test("30 seeds are physically valid", function()
	local failures = 0
	local first = nil
	for seed = 1, 30 do
		local ok, plan, parts = pcall(function()
			local p, g = build(seed)
			return p, g
		end)
		if not ok then
			failures += 1
			first = first or ("seed " .. seed .. ": " .. tostring(plan))
		else
			local problems = Qa.check(plan, parts, { style = Level0.style })
			if #problems > 0 then
				failures += 1
				first = first or ("seed " .. seed .. ": " .. problems[1])
			end
		end
	end
	H.eq(failures, 0, "failing seeds (" .. tostring(first) .. ")")
end)

H.test("the harness catches a sealed doorway", function()
	local plan, parts = build(42)
	local openings = Geometry.openings(plan, { style = Level0.style })
	local target = openings[1]
	H.ok(target ~= nil, "has a doorway to sabotage")

	-- Wall the doorway over, exactly the failure mode that shipped.
	table.insert(parts, {
		kind = "wall",
		owner = "sabotage",
		size = { target.box.maxX - target.box.minX, target.box.maxY - target.box.minY, 2 },
		position = {
			(target.box.minX + target.box.maxX) / 2,
			(target.box.minY + target.box.maxY) / 2,
			(target.box.minZ + target.box.maxZ) / 2,
		},
		yaw = 0,
		pitch = 0,
		material = "Concrete",
		color = { 1, 0, 0 },
		canCollide = true,
	})

	local problems = Qa.check(plan, parts, { style = Level0.style })
	local found = false
	for _, problem in ipairs(problems) do
		if string.find(problem, "blocked", 1, true) then
			found = true
		end
	end
	H.ok(found, "the sealed doorway was reported")
end)

H.test("flood fill reaches every node", function()
	local plan, parts = build(42)
	local seen = Qa.reachable(plan, parts)
	local reached = 0
	for _ in pairs(seen) do
		reached += 1
	end
	H.ok(reached > 0, "spawn flood produced cells")
	for _, node in ipairs(plan.nodes) do
		local any = false
		for x = math.floor(node.x + 2), math.ceil(node.x + node.w - 2) do
			for z = math.floor(node.z + 2), math.ceil(node.z + node.d - 2) do
				if seen[x .. ":" .. z] then
					any = true
					break
				end
			end
			if any then
				break
			end
		end
		H.ok(any, "node " .. tostring(node.id) .. " reachable")
	end
end)

H.test("doors are not all centred on their walls", function()
	local plan = build(42)
	local centred, offCentre = 0, 0
	for _, edge in ipairs(plan.edges) do
		local a = nil
		for _, node in ipairs(plan.nodes) do
			if node.id == edge.a then
				a = node
			end
		end
		local port = a and a.ports[edge.aPort]
		if port ~= nil then
			local span = if port.side == "N" or port.side == "S" then a.w else a.d
			local expected = (span - port.width) / 2
			if math.abs(port.offset - expected) < 1 then
				centred += 1
			else
				offCentre += 1
			end
		end
	end
	H.ok(offCentre > 0, "at least some doors are off-centre")
end)
