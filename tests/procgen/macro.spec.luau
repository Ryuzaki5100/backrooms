--!strict

local H = require("../harness")
local Macro = require("../../src/shared/procgen/Macro")
local Plan = require("../../src/shared/procgen/Plan")
local Level0 = require("../../src/config/levels/Level_0")

H.test("builds a node inventory", function()
	local plan = Macro.build(Level0, 42)
	H.eq(plan.seed, 42)
	H.ok(#plan.nodes >= Level0.generate.regions[1], "at least the minimum region count")
	H.ok(plan.spawn.nodeId ~= 0, "has spawn")
	H.eq(#plan.edges, 0, "edges are derived by embedding, not authored")
end)

H.test("corridor share stays inside the configured band", function()
	for seed = 1, 50 do
		local plan = Macro.build(Level0, seed)
		local corridors = 0
		for _, node in ipairs(plan.nodes) do
			if node.kind == "corridor" then
				corridors += 1
			end
		end
		local share = corridors / #plan.nodes
		local minShare = Level0.generate.corridors.minShare
		local maxShare = Level0.generate.corridors.maxShare
		H.ok(share >= minShare - 0.001, "seed " .. seed .. " corridor share too low: " .. share)
		H.ok(share <= maxShare + 0.04, "seed " .. seed .. " corridor share too high: " .. share)
	end
end)

H.test("every declared transition gets a host", function()
	local plan = Macro.build(Level0, 42)
	H.eq(#plan.exits, #Level0.transitions, "exit count")
	local seen: { [string]: boolean } = {}
	for _, exit in ipairs(plan.exits) do
		H.ok(not seen[exit.id], "unique exit id")
		seen[exit.id] = true
		H.ok(exit.anchor.hostNode ~= nil, "exit has a host")
	end
end)

H.test("is deterministic", function()
	H.eq(Plan.bytes(Macro.build(Level0, 42)), Plan.bytes(Macro.build(Level0, 42)))
end)

H.test("different seeds produce different inventories", function()
	H.neq(Plan.hash(Macro.build(Level0, 42)), Plan.hash(Macro.build(Level0, 43)))
end)

H.test("dead-end levels are rejected without transitions", function()
	local broken = table.clone(Level0)
	broken.transitions = {}
	local ok = pcall(Macro.build, broken, 42)
	H.ok(not ok, "should refuse a level with no transitions")
end)
