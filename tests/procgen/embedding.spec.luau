--!strict

local H = require("../harness")
local Embedding = require("../../src/shared/procgen/Embedding")
local Macro = require("../../src/shared/procgen/Macro")
local Plan = require("../../src/shared/procgen/Plan")
local Level0 = require("../../src/config/levels/Level_0")

local Level = require("../support/level")
local OPTIONS = Level.embedOptions()

local function embed(seed: number): any
	return Embedding.embed(Macro.build(Level0, seed), OPTIONS)
end

H.test("packs a level with every edge touching", function()
	local plan = embed(42)
	H.eq(#Embedding.validate(plan), 0, "validators")
	H.ok(#plan.edges > 0, "has doors")
	H.ok(plan.floorHeight >= 16 and plan.floorHeight <= 48, "floorHeight in range")
end)

H.test("the door graph connects every node", function()
	local plan = embed(42)
	local adjacency: { [number]: { number } } = {}
	for _, node in ipairs(plan.nodes) do
		adjacency[node.id] = {}
	end
	for _, edge in ipairs(plan.edges) do
		table.insert(adjacency[edge.a], edge.b)
		table.insert(adjacency[edge.b], edge.a)
	end
	local seen: { [number]: boolean } = { [plan.spawn.nodeId] = true }
	local queue = { plan.spawn.nodeId }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, next in ipairs(adjacency[current] or {}) do
			if not seen[next] then
				seen[next] = true
				table.insert(queue, next)
			end
		end
	end
	local reached = 0
	for _ in pairs(seen) do
		reached += 1
	end
	H.eq(reached, #plan.nodes, "all nodes reachable")
end)

H.test("loops are realised from spare shared walls", function()
	-- A loop is a second door on a wall that already touches. How many exist is a
	-- property of the pack, so the target is a ceiling, not a guarantee.
	local plan = embed(42)
	local loops = 0
	for _, edge in ipairs(plan.edges) do
		if edge.kind == "loop" then
			loops += 1
		end
	end
	H.ok(loops >= 1, "at least one loop")
	local target =
		math.max(Level0.generate.loops, math.floor(Level0.generate.loopShare * (#plan.nodes - 1)))
	H.ok(loops <= target, "no more than the target")
end)

H.test("no two nodes overlap", function()
	local plan = embed(42)
	for i = 1, #plan.nodes do
		for j = i + 1, #plan.nodes do
			local a = plan.nodes[i]
			local b = plan.nodes[j]
			local yOverlap = a.y < b.y + b.h and b.y < a.y + a.h
			local xOverlap = a.x < b.x + b.w and b.x < a.x + a.w
			local zOverlap = a.z < b.z + b.d and b.z < a.z + a.d
			H.ok(not (yOverlap and xOverlap and zOverlap), "nodes " .. a.id .. "/" .. b.id)
		end
	end
end)

H.test("embedding is deterministic", function()
	local a = embed(42)
	local b = embed(42)
	H.eq(Plan.bytes(a), Plan.bytes(b))
	H.neq(Plan.hash(a), Plan.hash(embed(43)), "different seed differs")
end)

H.test("100 seeds embed, connect and validate", function()
	local failures = 0
	local first = nil
	for seed = 1, 100 do
		local ok, plan = pcall(embed, seed)
		if not ok then
			failures += 1
			first = first or ("seed " .. seed .. ": " .. tostring(plan))
		else
			local problems = Embedding.validate(plan)
			if #problems > 0 then
				failures += 1
				first = first or ("seed " .. seed .. ": " .. table.concat(problems, "; "))
			end
		end
	end
	H.eq(failures, 0, "failing seeds (" .. tostring(first) .. ")")
end)

H.test("loopShare yields a cyclic level, not a tree", function()
	-- With no loops configured the packer may still find contacts, but the share
	-- is the authored promise: a Level 0 that is a tree is not Level 0.
	local loops = Embedding.embed(Macro.build(Level0, 42), {
		loops = 0,
		loopShare = Level0.generate.loopShare,
		loopPreference = Level0.generate.loopPreference,
		connectivity = Level0.generate.connectivity,
	})
	local spaces = #loops.nodes
	local extra = #loops.edges - (spaces - 1)
	local target = math.floor(Level0.generate.loopShare * (spaces - 1))
	H.ok(extra > target * 0.8, "loops " .. extra .. " of target " .. target)
	H.ok(extra > 20, "a 393-space level has real cycle density")
end)
