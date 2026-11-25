--!strict

-- Spatial embedding, pack-first (ADR 0015).
--
-- Order is inverted from the old design: instead of authoring a graph and trying
-- to fit it into space, we
--
--   1. pack the spaces into a footprint (shelf packing, no graph constraints),
--   2. derive which spaces actually touch,
--   3. build the door graph from that adjacency (spanning tree + loops),
--   4. stack upper floors above their hosts and link them vertically.
--
-- Contact is therefore true by construction: a door is only ever cut on a shared
-- face. "No overlaps" and "connected" are both properties of the packer, not
-- something repaired afterwards.
--
-- Pure Luau: no Roblox APIs.

local Rng = if script ~= nil then require(script.Parent.Rng) else require("./Rng")

local Embedding = {}

local SLAB = 2
local PLENUM = 4
local MIN_FLOOR = 16
local MAX_FLOOR = 48
local EPSILON = 0.5
local MIN_OPENING = 8
local ASPECT = 1.6

local function round4(value: number): number
	return math.floor((value + 3) / 4) * 4
end

local function clamp(value: number, low: number, high: number): number
	return math.max(low, math.min(high, value))
end

local function overlaps(a: any, b: any): boolean
	local yOverlap = a.y < b.y + b.h and b.y < a.y + a.h
	if not yOverlap then
		return false
	end
	local xOverlap = a.x < b.x + b.w and b.x < a.x + a.w
	local zOverlap = a.z < b.z + b.d and b.z < a.z + a.d
	return xOverlap and zOverlap
end

local function computeFloorHeight(nodes: { any }): number
	local tallest = 0
	for _, node in ipairs(nodes) do
		tallest = math.max(tallest, node.h)
	end
	return clamp(round4(tallest + SLAB + PLENUM), MIN_FLOOR, MAX_FLOOR)
end

-- Do two boxes touch on a vertical face, with enough overlap for a doorway?
local function touch(a: any, b: any): (string?, string?)
	if a.level ~= b.level then
		return nil, nil
	end
	local overlapZ = math.min(a.z + a.d, b.z + b.d) - math.max(a.z, b.z)
	local overlapX = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
	if math.abs(a.x + a.w - b.x) < EPSILON and overlapZ >= MIN_OPENING then
		return "E", "W"
	elseif math.abs(b.x + b.w - a.x) < EPSILON and overlapZ >= MIN_OPENING then
		return "W", "E"
	elseif math.abs(a.z + a.d - b.z) < EPSILON and overlapX >= MIN_OPENING then
		return "S", "N"
	elseif math.abs(b.z + b.d - a.z) < EPSILON and overlapX >= MIN_OPENING then
		return "N", "S"
	end
	return nil, nil
end

-- ------------------------------------------------------------------ packing

local function packLevel(nodes: { any }, factor: number): ()
	local sorted = table.clone(nodes)
	table.sort(sorted, function(a: any, b: any)
		if a.d ~= b.d then
			return a.d > b.d
		end
		return a.id < b.id
	end)

	local area = 0
	for _, node in ipairs(sorted) do
		area += node.w * node.d
	end
	local targetWidth = math.max(40, math.ceil(math.sqrt(area * ASPECT) * factor))

	local x, z, rowDepth = 0, 0, 0
	for _, node in ipairs(sorted) do
		if x > 0 and x + node.w > targetWidth then
			z += rowDepth
			x = 0
			rowDepth = 0
		end
		node.x = x
		node.z = z
		x += node.w
		rowDepth = math.max(rowDepth, node.d)
	end
end

local function deriveAdjacency(nodes: { any }): { any }
	local edges = {}
	for i = 1, #nodes do
		for j = i + 1, #nodes do
			local a = nodes[i]
			local b = nodes[j]
			local sideA, sideB = touch(a, b)
			if sideA ~= nil and sideB ~= nil then
				table.insert(edges, {
					a = a,
					b = b,
					sideA = sideA,
					sideB = sideB,
					key = if a.id < b.id then a.id .. ":" .. b.id else b.id .. ":" .. a.id,
				})
			end
		end
	end
	return edges
end

local function bbox(nodes: { any }): (number, number, number, number)
	local minX, minZ = math.huge, math.huge
	local maxX, maxZ = -math.huge, -math.huge
	for _, node in ipairs(nodes) do
		minX = math.min(minX, node.x)
		minZ = math.min(minZ, node.z)
		maxX = math.max(maxX, node.x + node.w)
		maxZ = math.max(maxZ, node.z + node.d)
	end
	return minX, minZ, maxX, maxZ
end

-- Translate whole components until the pack is one connected mass. Moving a
-- component preserves its internal adjacency, so this can only add connections.
local function repairComponents(nodes: { any }, edges: { any }): number
	for _ = 1, #nodes do
		local parent: { [number]: number } = {}
		for _, node in ipairs(nodes) do
			parent[node.id] = node.id
		end
		local function find(id: number): number
			while parent[id] ~= id do
				parent[id] = parent[parent[id]]
				id = parent[id]
			end
			return id
		end
		for _, edge in ipairs(edges) do
			local ra, rb = find(edge.a.id), find(edge.b.id)
			if ra ~= rb then
				parent[ra] = rb
			end
		end

		local components: { [number]: { any } } = {}
		for _, node in ipairs(nodes) do
			local root = find(node.id)
			components[root] = components[root] or {}
			table.insert(components[root], node)
		end

		local roots = {}
		for root in pairs(components) do
			table.insert(roots, root)
		end
		if #roots <= 1 then
			return #roots
		end
		table.sort(roots)

		-- Keep the largest component as the anchor, move the rest against it.
		table.sort(roots, function(a, b)
			return #components[a] > #components[b]
		end)
		local anchor = components[roots[1]]
		local anchorMaxX, anchorMinZ = select(3, bbox(anchor)), select(2, bbox(anchor))
		for index = 2, #roots do
			local moving = components[roots[index]]
			local moveMinX, moveMinZ = bbox(moving)
			local dx = anchorMaxX - moveMinX
			local dz = anchorMinZ - moveMinZ
			for _, node in ipairs(moving) do
				node.x += dx
				node.z += dz
			end
			local _, _, newMaxX = bbox(moving)
			anchorMaxX = math.max(anchorMaxX, newMaxX)
		end
		edges = deriveAdjacency(nodes)
	end
	return 999
end

-- --------------------------------------------------------------- door graph

local function loopWeight(a: any, b: any, preference: any): number
	local function pair(x: string, y: string): boolean
		return (a.kind == x and b.kind == y) or (a.kind == y and b.kind == x)
	end
	if pair("corridor", "corridor") then
		return preference.corridor_corridor or 3
	elseif pair("corridor", "hall") then
		return preference.corridor_hall or 2
	elseif pair("room", "room") then
		return preference.room_room or 1
	end
	return 1
end

local function addPort(node: any, side: string, height: number, offset: number): number
	local id = #node.ports + 1
	table.insert(node.ports, {
		id = id,
		side = side,
		offset = offset,
		width = 4,
		height = math.min(height, node.h),
		elevation = 0,
		kind = "door",
		guard = "auto",
	})
	return id
end

local function faceOrigin(node: any, side: string): number
	return if side == "N" or side == "S" then node.x else node.z
end

local function faceSpan(node: any, side: string): number
	return if side == "N" or side == "S" then node.w else node.d
end

-- Where `other` sits on `node`'s face, in absolute face coordinates.
local function overlapFor(node: any, side: string, other: any): (number?, number?)
	local origin = faceOrigin(node, side)
	local finishNode = origin + faceSpan(node, side)
	local otherOrigin = faceOrigin(other, side)
	local finishOther = otherOrigin + faceSpan(other, side)
	local start = math.max(origin, otherOrigin)
	local finish = math.min(finishNode, finishOther)
	if finish - start < MIN_OPENING then
		return nil, nil
	end
	return start, finish - start
end

-- Doors are placed inside their shared interval with a margin, from a per-edge
-- fork, so they are not always centred. Stored in port.offset: the plan owns it.
-- A door must keep clear of both ends of its overlap: the neighbouring room's
-- wall is centred on the boundary and protrudes half a stud each way. If the
-- overlap is too narrow for that, centre the door rather than putting it flush.
local function doorOffsetFor(t: number, start: number, len: number, width: number): number
	local clearance = 2
	local low = start + clearance
	local high = start + len - width - clearance
	if high <= low then
		return math.floor(start + (len - width) / 2 + 0.5)
	end
	return math.floor(low + t * (high - low) + 0.5)
end

-- Create the two ports of a doorway, with matching positions along the wall.
local function makeDoorPorts(
	plan: any,
	a: any,
	sideA: string,
	b: any,
	sideB: string
): (number?, number?)
	local startA, lenA = overlapFor(a, sideA, b)
	local startB, lenB = overlapFor(b, sideB, a)
	if startA == nil or startB == nil then
		return nil, nil
	end
	local rng = Rng.new(plan.seed):fork("door:" .. a.id .. ":" .. b.id)
	local t = rng:nextFloat()
	local width = 4
	-- Offsets are relative to each node's own face origin, which is what the
	-- geometry layer reads.
	local offsetA = doorOffsetFor(t, startA, lenA, width) - faceOrigin(a, sideA)
	local offsetB = doorOffsetFor(t, startB, lenB, width) - faceOrigin(b, sideB)
	return addPort(a, sideA, 8, offsetA), addPort(b, sideB, 8, offsetB)
end

local function buildDoors(plan: any, nodes: { any }, adjacency: { any }, options: any): ()
	local byId: { [number]: any } = {}
	for _, node in ipairs(nodes) do
		byId[node.id] = node
	end

	local connectivity = options.connectivity or {}
	local bias = connectivity.corridorBias or 0.85
	local roomToRoom = connectivity.roomToRoom or 0.15
	local extraChance = connectivity.extraChance or 0

	local doorRng = Rng.new(plan.seed):fork("doors")

	-- How much the tree prefers a door onto this kind of space. A bias of 1
	-- means "corridor whenever possible"; 0 means "plain BFS".
	local function kindScore(kind: string): number
		if kind == "corridor" then
			return 1
		elseif kind == "hall" then
			return 0.7
		end
		return 1 - bias
	end

	local linked: { [number]: { any } } = {}
	for _, node in ipairs(nodes) do
		linked[node.id] = {}
	end
	for _, edge in ipairs(adjacency) do
		table.insert(linked[edge.a.id], edge)
		table.insert(linked[edge.b.id], edge)
	end

	local visited: { [number]: boolean } = { [plan.spawn.nodeId] = true }
	local queue = { plan.spawn.nodeId }
	local expanded: { [number]: boolean } = {}
	local used: { [string]: boolean } = {}
	local edgeId = 0

	local function addDoor(edge: any, kind: string): boolean
		if used[edge.key] then
			return false
		end
		local aPort, bPort = makeDoorPorts(plan, edge.a, edge.sideA, edge.b, edge.sideB)
		if aPort == nil then
			return false
		end
		used[edge.key] = true
		edgeId += 1
		table.insert(plan.edges, {
			id = edgeId,
			a = edge.a.id,
			b = edge.b.id,
			aPort = aPort,
			bPort = bPort,
			kind = kind,
		})
		return true
	end

	-- Best-first expansion: corridors and halls claim their neighbours before
	-- rooms get a chance to open into each other. A plain FIFO BFS makes the
	-- tree shape depend on the pack order, which is why most doors were
	-- room-to-room a moment ago.
	while true do
		local pickIndex, pickScore = nil, -1
		for index = 1, #queue do
			local id = queue[index]
			if not expanded[id] then
				local score = kindScore(byId[id].kind)
				if score > pickScore then
					pickScore = score
					pickIndex = index
				end
			end
		end
		if pickIndex == nil then
			break
		end
		local current = queue[pickIndex]
		expanded[current] = true
		local currentKind = byId[current].kind

		local candidates = {}
		for _, edge in ipairs(linked[current]) do
			if not used[edge.key] then
				local other = if edge.a.id == current then edge.b else edge.a
				if not visited[other.id] then
					table.insert(candidates, {
						edge = edge,
						other = other,
						score = kindScore(other.kind),
						roomRoom = currentKind == "room" and other.kind == "room",
					})
				end
			end
		end
		table.sort(candidates, function(x: any, y: any)
			if x.score ~= y.score then
				return x.score > y.score
			end
			return x.edge.key < y.edge.key
		end)

		local function connectCandidate(candidate: any): boolean
			if addDoor(candidate.edge, "passage") then
				visited[candidate.other.id] = true
				table.insert(queue, candidate.other.id)
				return true
			end
			return false
		end

		-- Every unvisited neighbour gets a door when the policy allows it; a
		-- spanning tree needs all of them, not just the best one.
		for _, candidate in ipairs(candidates) do
			if not candidate.roomRoom or doorRng:nextFloat() <= roomToRoom then
				connectCandidate(candidate)
			end
		end
	end

	-- Forced sweep: anything the policy skipped (a room whose only neighbours
	-- are rooms, a cluster of them) still needs a door, or it is sealed by
	-- accident rather than by design.
	local guard = #nodes * 4
	while guard > 0 do
		guard -= 1
		local progressed = false
		for _, edge in ipairs(adjacency) do
			local aVisited = visited[edge.a.id] == true
			local bVisited = visited[edge.b.id] == true
			if aVisited ~= bVisited and not used[edge.key] then
				if addDoor(edge, "passage") then
					visited[edge.a.id] = true
					visited[edge.b.id] = true
					progressed = true
				end
			end
		end
		if not progressed then
			break
		end
	end

	-- Incidental doors, off by default.
	if extraChance > 0 then
		for _, edge in ipairs(adjacency) do
			if not used[edge.key] and doorRng:nextFloat() <= extraChance then
				addDoor(edge, "passage")
			end
		end
	end

	-- Loops: the deliberate extras, biased by the level's preference table.
	local candidates = table.clone(adjacency)
	table.sort(candidates, function(x: any, y: any)
		local wx = loopWeight(x.a, x.b, options.loopPreference or {})
		local wy = loopWeight(y.a, y.b, options.loopPreference or {})
		if wx ~= wy then
			return wx > wy
		end
		return x.key < y.key
	end)
	local loops = options.loops or 0
	for _, edge in ipairs(candidates) do
		if loops <= 0 then
			break
		end
		if not used[edge.key] then
			if addDoor(edge, "loop") then
				loops -= 1
			end
		end
	end
end

function Embedding.embed(plan: any, options: any?): any
	local opts = options or {}
	local floorHeight = computeFloorHeight(plan.nodes)

	local nodesById: { [number]: any } = {}
	for _, node in ipairs(plan.nodes) do
		local copy = table.clone(node)
		copy.rotation = 0
		copy.ports = {}
		copy.y = copy.level * floorHeight
		nodesById[copy.id] = copy
	end

	local ground: { any } = {}
	local upper: { any } = {}
	for _, node in ipairs(plan.nodes) do
		local copy = nodesById[node.id]
		if copy.level == 0 then
			table.insert(ground, copy)
		else
			table.insert(upper, copy)
		end
	end

	if #ground == 0 then
		error("Embedding.embed: no ground-level nodes", 2)
	end

	-- Packing density is a knob: tighter packs create more shared walls, which
	-- is where loops come from. Try progressively denser layouts until there are
	-- enough spare adjacency pairs for the requested loops.
	local wantedLoops = opts.loops or 0
	local adjacency = {}
	local factors = { 1.0, 0.85, 0.7, 0.55 }
	for _, factor in ipairs(factors) do
		packLevel(ground, factor)
		repairComponents(ground, adjacency)
		adjacency = deriveAdjacency(ground)
		if #adjacency - (#ground - 1) >= wantedLoops or factor == factors[#factors] then
			break
		end
	end

	-- Upper floors stack above distinct ground nodes with the same footprint, so
	-- they cannot overlap each other and their shaft is exactly vertical.
	local hosts = table.clone(ground)
	table.sort(hosts, function(a: any, b: any)
		return a.id < b.id
	end)
	table.sort(upper, function(a: any, b: any)
		return a.id < b.id
	end)
	for index, node in ipairs(upper) do
		local host = hosts[((index - 1) % #hosts) + 1]
		node.w = host.w
		node.d = host.d
		node.x = host.x
		node.z = host.z
		node.y = node.level * floorHeight
		node.tags = node.tags or {}
		table.insert(node.tags, "stacked:" .. tostring(host.id))
	end

	local out = table.clone(plan)
	out.nodes = {}
	for _, node in ipairs(plan.nodes) do
		table.insert(out.nodes, nodesById[node.id])
	end
	out.edges = {}
	out.floorHeight = floorHeight
	out.plenum = PLENUM

	buildDoors(out, ground, adjacency, opts)

	-- Vertical links: one per upper node, with U on the host and D on the upper.
	local edgeId = #out.edges
	for index, node in ipairs(upper) do
		local host = hosts[((index - 1) % #hosts) + 1]
		local hostNode = nodesById[host.id]
		local upPort = addPort(hostNode, "U", 8)
		local downPort = addPort(node, "D", 8)
		edgeId += 1
		table.insert(out.edges, {
			id = edgeId,
			a = hostNode.id,
			b = node.id,
			aPort = upPort,
			bPort = downPort,
			kind = "shaft",
		})
	end

	local problems = Embedding.validate(out)
	if #problems > 0 then
		error("Embedding.embed: " .. table.concat(problems, "; "), 2)
	end
	return out
end

-- -------------------------------------------------------------- validation

function Embedding.validate(plan: any): { string }
	local problems: { string } = {}
	local nodesById: { [number]: any } = {}
	local placed: { any } = {}

	for _, node in ipairs(plan.nodes) do
		nodesById[node.id] = node
		if node.y ~= node.level * (plan.floorHeight or 0) then
			table.insert(problems, "node " .. tostring(node.id) .. " is off its level")
		end
		for _, other in ipairs(placed) do
			if overlaps(node, other) then
				table.insert(
					problems,
					"node " .. tostring(node.id) .. " overlaps node " .. tostring(other.id)
				)
				break
			end
		end
		table.insert(placed, node)
	end

	local adjacency: { [number]: { number } } = {}
	for _, node in ipairs(plan.nodes) do
		adjacency[node.id] = {}
	end

	for _, edge in ipairs(plan.edges) do
		local a = nodesById[edge.a]
		local b = nodesById[edge.b]
		if a == nil or b == nil then
			table.insert(problems, "edge " .. tostring(edge.id) .. " references a missing node")
		else
			table.insert(adjacency[a.id], b.id)
			table.insert(adjacency[b.id], a.id)
			if a.level == b.level then
				local sideA = touch(a, b)
				if sideA == nil then
					table.insert(
						problems,
						"edge "
							.. tostring(edge.id)
							.. " does not touch ("
							.. tostring(a.id)
							.. "-"
							.. tostring(b.id)
							.. ")"
					)
				end
			else
				local overlapX = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
				local overlapZ = math.min(a.z + a.d, b.z + b.d) - math.max(a.z, b.z)
				if
					math.abs(a.level - b.level) ~= 1
					or overlapX < MIN_OPENING
					or overlapZ < MIN_OPENING
				then
					table.insert(
						problems,
						"edge " .. tostring(edge.id) .. " has no usable vertical overlap"
					)
				end
			end
		end
	end

	local spawn = plan.spawn.nodeId
	local seen: { [number]: boolean } = { [spawn] = true }
	local queue = { spawn }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, neighbour in ipairs(adjacency[current] or {}) do
			if not seen[neighbour] then
				seen[neighbour] = true
				table.insert(queue, neighbour)
			end
		end
	end
	for _, node in ipairs(plan.nodes) do
		if not seen[node.id] then
			table.insert(problems, "node " .. tostring(node.id) .. " is unreachable")
		end
	end

	for _, exit in ipairs(plan.exits or {}) do
		if exit.anchor.hostNode ~= nil and not seen[exit.anchor.hostNode] then
			table.insert(
				problems,
				"exit " .. tostring(exit.id) .. " is anchored to an unreachable node"
			)
		end
	end

	return problems
end

return Embedding
