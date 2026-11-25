--!strict

local H = require("../harness")
local Embedding = require("../../src/shared/procgen/Embedding")
local Geometry = require("../../src/shared/procgen/Geometry")
local Macro = require("../../src/shared/procgen/Macro")
local Level0 = require("../../src/config/levels/Level_0")

local OPTIONS = {
	loops = Level0.generate.loops,
	loopPreference = Level0.generate.loopPreference,
	connectivity = Level0.generate.connectivity,
}

local function build(seed: number, styleOptions: any?): ({ any }, any)
	local plan = Embedding.embed(Macro.build(Level0, seed), OPTIONS)
	return Geometry.describe(plan, styleOptions), plan
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

local SIDES = { "N", "E", "S", "W" }

local function span(node: any, side: string): number
	return if side == "N" or side == "S" then node.w else node.d
end

local function origin(node: any, side: string): number
	return if side == "N" or side == "S" then node.x else node.z
end

local function onFace(part: any, node: any, side: string): boolean
	if side == "N" then
		return math.abs(part.position[3] - node.z) < 0.6
	elseif side == "S" then
		return math.abs(part.position[3] - (node.z + node.d)) < 0.6
	elseif side == "W" then
		return math.abs(part.position[1] - node.x) < 0.6
	end
	return math.abs(part.position[1] - (node.x + node.w)) < 0.6
end

local function interval(part: any, node: any, side: string): (number, number)
	local base = origin(node, side)
	if side == "N" or side == "S" then
		return part.position[1] - part.size[1] / 2 - base,
			part.position[1] + part.size[1] / 2 - base
	end
	return part.position[3] - part.size[3] / 2 - base, part.position[3] + part.size[3] / 2 - base
end

-- Union length of a set of intervals.
local function unionLength(intervals: { { number } }): number
	table.sort(intervals, function(a, b)
		return a[1] < b[1]
	end)
	local total = 0
	local cursor = -math.huge
	for _, item in ipairs(intervals) do
		local start = math.max(item[1], cursor)
		if item[2] > start then
			total += item[2] - start
			cursor = item[2]
		end
	end
	return total
end

H.test("describes a plan within budget and without ramps", function()
	local parts = build(42)
	H.ok(#parts > 0, "has parts")
	H.ok(#parts <= 1200, "within budget")
	H.eq(
		count(parts, function(p)
			return p.kind == "ramp"
		end),
		0,
		"no placeholder ramps"
	)
end)

H.test("description is deterministic", function()
	local a, plan = build(42)
	local b = Geometry.describe(plan, nil)
	H.eq(Geometry.fingerprint(a), Geometry.fingerprint(b))
	H.neq(Geometry.fingerprint(a), Geometry.fingerprint((build(43))), "different seed differs")
end)

H.test("every node gets a floor and a ceiling", function()
	local parts, plan = build(42)
	for _, node in ipairs(plan.nodes) do
		local owner = "node:" .. tostring(node.id)
		H.ok(count(parts, function(p)
			return p.owner == owner and p.kind == "floor"
		end) >= 1, "floor " .. tostring(node.id))
		H.ok(count(parts, function(p)
			return p.owner == owner and p.kind == "ceiling"
		end) >= 1, "ceiling " .. tostring(node.id))
	end
end)

-- The leak test: walls plus doorways must cover every face completely.
H.test("every face is covered by walls plus doorways", function()
	local parts, plan = build(42)
	local nodesById: { [number]: any } = {}
	for _, node in ipairs(plan.nodes) do
		nodesById[node.id] = node
	end

	for _, node in ipairs(plan.nodes) do
		for _, side in ipairs(SIDES) do
			local width = span(node, side)
			local intervals = {}
			local doorWidth = 0

			for _, part in ipairs(parts) do
				if part.kind == "wall" and onFace(part, node, side) then
					local isNodeWall = part.owner == "node:" .. tostring(node.id)
					local edgeId = nil
					if string.sub(part.owner, 1, 5) == "edge:" then
						edgeId = tonumber(string.sub(part.owner, 6))
					end
					local belongsToEdge = false
					if edgeId ~= nil then
						for _, edge in ipairs(plan.edges) do
							if edge.id == edgeId and (edge.a == node.id or edge.b == node.id) then
								belongsToEdge = true
								break
							end
						end
					end
					if isNodeWall or belongsToEdge then
						local start, finish = interval(part, node, side)
						-- Door headers sit above the door; they still cover the face.
						table.insert(intervals, { start, finish })
					end
				end
			end

			-- Count doorway gaps implied by edges on this side.
			for _, edge in ipairs(plan.edges) do
				if edge.a == node.id or edge.b == node.id then
					local portId = if edge.a == node.id then edge.aPort else edge.bPort
					local port = node.ports[portId]
					if port ~= nil and port.side == side then
						doorWidth += port.width
					end
				end
			end

			-- A doorway has a header, so the wall projection must cover the whole
			-- face. Anything less is a hole to the outside.
			local covered = unionLength(intervals)
			H.ok(
				math.abs(covered - width) < 1.0,
				string.format(
					"node %d side %s: covered %.1f of span %.1f (doors %.1f)",
					node.id,
					side,
					covered,
					width,
					doorWidth
				)
			)
		end
	end
end)

H.test("QA markers exist only when debug is on", function()
	local production = build(42)
	H.eq(
		count(production, function(p)
			return p.tag == "qa"
		end),
		0,
		"production has none"
	)
	local debug = build(42, { debug = true })
	H.ok(count(debug, function(p)
		return p.tag == "qa"
	end) > 0, "debug has some")
end)

H.test("debug markers tell real anchors from decoys", function()
	-- The whole point of the debug view is being able to see which exit-shaped
	-- feature is bound and which is a lie, so they must differ in name and colour.
	local plan = require("../../src/shared/procgen/Macro").build(Level0, 42)
	local debug = Geometry.describe(plan, { style = Level0.style, debug = true })
	local realColour, decoyColour = nil, nil
	local realMarkers, decoyMarkers = 0, 0
	for _, part in ipairs(debug) do
		if part.tag == "qa" and part.owner ~= "spawn" then
			if string.sub(part.owner, 1, 6) == "decoy:" then
				decoyMarkers += 1
				decoyColour = part.color
			else
				realMarkers += 1
				realColour = part.color
			end
		end
	end
	H.ok(realMarkers > 0, "real anchors have markers")
	H.ok(decoyMarkers > 0, "decoys have markers")
	local function key(colour: any): string
		return table.concat({ tostring(colour[1]), tostring(colour[2]), tostring(colour[3]) }, ",")
	end
	H.neq(key(realColour), key(decoyColour), "the two are distinguishable")
end)
