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

H.test("every declared transition gets several anchors", function()
	local plan = Macro.build(Level0, 42)
	local range = Level0.generate.anchors
	for _, transition in ipairs(Level0.transitions) do
		local count = Plan.anchorCount(plan, transition.id)
		H.ok(
			count >= range.min,
			transition.id .. " has " .. count .. " anchors, want >= " .. range.min
		)
		H.ok(
			count <= range.max,
			transition.id .. " has " .. count .. " anchors, want <= " .. range.max
		)
	end
	for _, exit in ipairs(plan.exits) do
		H.ok(exit.anchor.hostNode ~= nil, "exit has a host")
	end
end)

H.test("anchors of one transition are spread as widely as the rooms allow", function()
	-- Finding one exit must not reveal another. On a small level the room pool
	-- runs out, so the invariant is "no repeated host until every room has one".
	local plan = Macro.build(Level0, 42)
	local rooms = 0
	for _, node in ipairs(plan.nodes) do
		if (node.kind == "room" or node.kind == "hall") and node.level == 0 then
			rooms += 1
		end
	end
	for _, transition in ipairs(Level0.transitions) do
		local hosts: { [number]: boolean } = {}
		local count = 0
		for _, exit in ipairs(plan.exits) do
			if exit.id == transition.id and not exit.decoy then
				count += 1
				hosts[exit.anchor.hostNode] = true
			end
		end
		local distinct = 0
		for _ in pairs(hosts) do
			distinct += 1
		end
		H.eq(distinct, math.min(count, rooms), transition.id .. " anchor spread")
	end
end)

H.test("decoys exist, are unbound, and never grant mastery", function()
	local plan = Macro.build(Level0, 42)
	local decoys = 0
	for _, exit in ipairs(plan.exits) do
		if exit.decoy then
			decoys += 1
			H.ok(string.sub(exit.id, 1, 6) == "decoy-", "decoy id is tagged")
			H.eq(exit.resolve, "event", "decoys resolve per use, not per seed")
			local hasNone = false
			for _, outcome in ipairs(exit.outcomes) do
				if outcome.kind == "none" then
					hasNone = true
				end
			end
			H.ok(hasNone, "a decoy can do nothing")
		end
	end
	H.ok(decoys > 0, "seed 42 has decoys when the level configures them")

	local mastery = Plan.masteryIds(plan)
	for _, id in ipairs(mastery) do
		H.ok(string.sub(id, 1, 6) ~= "decoy-", "mastery excludes decoys")
	end
	H.eq(#mastery, #Level0.transitions, "mastery lists every declared transition once")
end)

H.test("decoys are absent when the level asks for none", function()
	local config = table.clone(Level0)
	config.generate = table.clone(Level0.generate)
	config.generate.decoys = { share = 0, trapShare = 0 }
	local plan = Macro.build(config, 42)
	for _, exit in ipairs(plan.exits) do
		H.ok(not exit.decoy, "no decoys at share 0")
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

H.test("configured sizes and heights are respected", function()
	local plan = Macro.build(Level0, 42)
	for _, node in ipairs(plan.nodes) do
		local size = Level0.generate.sizes[node.kind]
		if size ~= nil then
			H.ok(node.w >= size.w[1] - 2 and node.w <= size.w[2] + 2, "width " .. node.kind)
			H.ok(node.d >= size.d[1] - 2 and node.d <= size.d[2] + 2, "depth " .. node.kind)
			H.ok(node.h >= size.h[1] and node.h <= size.h[2], "height " .. node.kind)
		end
	end
end)

H.test("Level 0 has the low ceilings its lore describes", function()
	-- ADR 0013: the canonical photo is a low, wide space. If this drifts back to
	-- office proportions, the level stops being Level 0.
	local plan = Macro.build(Level0, 42)
	for _, node in ipairs(plan.nodes) do
		H.ok(node.h <= 14, node.kind .. " is " .. node.h .. " tall")
	end
	H.ok(plan.floorHeight <= 24, "floor height " .. plan.floorHeight)
end)
