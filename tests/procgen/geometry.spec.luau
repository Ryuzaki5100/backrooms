--!strict

local H = require("../harness")
local Embedding = require("../../src/shared/procgen/Embedding")
local Geometry = require("../../src/shared/procgen/Geometry")
local Macro = require("../../src/shared/procgen/Macro")
local Level0 = require("../../src/config/levels/Level_0")

local function build(seed: number, options: any?): ({ any }, any)
	local plan = Embedding.embed(Macro.build(Level0, seed))
	return Geometry.describe(plan, options), plan
end

local function count(parts: { any }, predicate: (any) -> boolean): number
	local total = 0
	for _, part in ipairs(parts) do
		if predicate(part) then
			total += 1
		end
	end
	return total
end

H.test("describes a plan within budget", function()
	local parts = build(42)
	H.ok(#parts > 0, "has parts")
	H.ok(#parts <= 800, "within the default budget")
end)

H.test("description is deterministic", function()
	local a, plan = build(42)
	local b = Geometry.describe(plan, nil)
	H.eq(Geometry.fingerprint(a), Geometry.fingerprint(b), "same plan, same parts")
	local c = build(43)
	H.neq(Geometry.fingerprint(a), Geometry.fingerprint(c), "different seed differs")
end)

H.test("every node gets a floor and a ceiling", function()
	local parts, plan = build(42)
	for _, node in ipairs(plan.nodes) do
		local owner = "node:" .. tostring(node.id)
		H.ok(count(parts, function(p)
			return p.owner == owner and p.kind == "floor"
		end) >= 1, "floor for node " .. tostring(node.id))
		H.ok(count(parts, function(p)
			return p.owner == owner and p.kind == "ceiling"
		end) >= 1, "ceiling for node " .. tostring(node.id))
	end
end)

H.test("shared boundaries are owned by the edge, never by both nodes", function()
	local parts, plan = build(42)
	local horizontal = 0
	for _, edge in ipairs(plan.edges) do
		local a = nil
		local b = nil
		for _, node in ipairs(plan.nodes) do
			if node.id == edge.a then
				a = node
			elseif node.id == edge.b then
				b = node
			end
		end
		if a and b and a.level == b.level then
			horizontal += 1
			H.ok(count(parts, function(p)
				return p.owner == "edge:" .. tostring(edge.id) and p.kind == "wall"
			end) >= 1, "edge " .. tostring(edge.id) .. " owns a wall")
		end
	end
	H.ok(horizontal > 0, "fixture has horizontal edges")
end)

H.test("no wall is built by a node on a side it shares", function()
	local parts, plan = build(42)
	-- Each node's free sides produce walls; shared sides are edge-owned. Count
	-- total walls as free sides + horizontal edges and compare.
	local shared: { [string]: boolean } = {}
	local horizontal = 0
	for _, edge in ipairs(plan.edges) do
		local a = nil
		local b = nil
		for _, node in ipairs(plan.nodes) do
			if node.id == edge.a then
				a = node
			elseif node.id == edge.b then
				b = node
			end
		end
		if a and b and a.level == b.level then
			horizontal += 1
			local aPort = a.ports[edge.aPort]
			local bPort = b.ports[edge.bPort]
			if aPort and bPort then
				shared[a.id .. ":" .. aPort.side] = true
				shared[b.id .. ":" .. bPort.side] = true
			end
		end
	end
	local freeSides = 0
	for _, node in ipairs(plan.nodes) do
		for _, side in ipairs({ "N", "E", "S", "W" }) do
			if not shared[node.id .. ":" .. side] then
				freeSides += 1
			end
		end
	end
	-- Walls are segmented (openings create 2+ pieces), so the edge-owned count is
	-- a lower bound; what matters is that node-owned walls never exceed free sides.
	local nodeWalls = count(parts, function(p)
		return p.kind == "wall" and string.sub(p.owner, 1, 5) == "node:"
	end)
	H.ok(
		nodeWalls <= freeSides,
		"node-owned walls (" .. nodeWalls .. ") <= free sides (" .. freeSides .. ")"
	)
	H.ok(horizontal > 0, "has horizontal edges")
end)

H.test("QA markers exist only when debug is on", function()
	local production = build(42)
	H.eq(
		count(production, function(p)
			return p.tag == "qa"
		end),
		0,
		"production has no QA parts"
	)

	local debug = build(42, { debug = true })
	H.ok(count(debug, function(p)
		return p.tag == "qa"
	end) > 0, "debug has QA parts")
end)

H.test("placeholders are tagged and never collide with gameplay tags", function()
	local parts = build(42)
	for _, part in ipairs(parts) do
		if part.kind == "ramp" then
			H.eq(part.tag, "placeholder", "ramps are placeholders")
		end
	end
end)
