--!strict

local H = require("../harness")
local Embedding = require("../../src/shared/procgen/Embedding")
local Macro = require("../../src/shared/procgen/Macro")
local Plan = require("../../src/shared/procgen/Plan")
local Level0 = require("../../src/config/levels/Level_0")

H.test("embeds a macro plan with no overlaps", function()
	local plan = Embedding.embed(Macro.build(Level0, 42))
	H.eq(#Embedding.validate(plan), 0, "validators")
	H.ok(plan.floorHeight >= 16 and plan.floorHeight <= 32, "floorHeight in range")
	H.eq(plan.floorHeight % 4, 0, "floorHeight on a 4-stud grid")
	H.ok(plan.plenum > 0, "plenum reserved")
end)

H.test("every node sits on its level", function()
	local plan = Embedding.embed(Macro.build(Level0, 42))
	for _, node in ipairs(plan.nodes) do
		H.eq(node.y, node.level * plan.floorHeight, "node " .. tostring(node.id) .. " elevation")
		H.ok(node.rotation >= 0 and node.rotation <= 3, "rotation in range")
	end
end)

H.test("embedding is deterministic", function()
	local a = Embedding.embed(Macro.build(Level0, 42))
	local b = Embedding.embed(Macro.build(Level0, 43))
	H.neq(Plan.hash(a), Plan.hash(b))
	local c = Embedding.embed(Macro.build(Level0, 42))
	H.eq(Plan.bytes(a), Plan.bytes(c), "same seed, same bytes")
end)

H.test("100 seeds embed without overlap", function()
	local failures = 0
	local firstFailure = nil
	for seed = 1, 100 do
		local ok, plan = pcall(function()
			return Embedding.embed(Macro.build(Level0, seed))
		end)
		if not ok then
			failures += 1
			firstFailure = firstFailure or ("seed " .. seed .. ": " .. tostring(plan))
		else
			local problems = Embedding.validate(plan)
			if #problems > 0 then
				failures += 1
				firstFailure = firstFailure
					or ("seed " .. seed .. ": " .. table.concat(problems, "; "))
			end
		end
	end
	H.eq(failures, 0, "failing seeds (" .. tostring(firstFailure) .. ")")
end)

H.test("floorHeight is derived from the tallest node and clamped", function()
	local small = {
		schemaVersion = 3,
		genVersion = 1,
		macroEpoch = 1,
		seed = 1,
		specId = "test",
		floorHeight = 0,
		plenum = 0,
		nodes = {
			{
				id = 1,
				kind = "room",
				w = 8,
				h = 8,
				d = 8,
				level = 0,
				x = 0,
				y = 0,
				z = 0,
				rotation = 0,
				filler = "wfc",
				params = {},
				ports = {},
				tags = {},
			},
		},
		edges = {},
		connectors = {},
		exits = {},
		spawn = { nodeId = 1, surface = "floor" },
	}
	local embedded = Embedding.embed(small)
	H.eq(embedded.floorHeight, 16, "clamped to the minimum")

	local tall = table.clone(small)
	tall.nodes = { table.clone(small.nodes[1]) }
	tall.nodes[1].h = 40
	local tallEmbedded = Embedding.embed(tall)
	H.eq(tallEmbedded.floorHeight, 32, "clamped to the maximum")
end)
