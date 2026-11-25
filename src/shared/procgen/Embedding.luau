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

local function addPort(node: any, side: string, height: number): number
	local id = #node.ports + 1
	table.insert(node.ports, {
		id = id,
		side = side,
		offset = 0,
		width = 4,
		height = math.min(height, node.h),
		elevation = 0,
		kind = "door",
		guard = "auto",
	})
	return id
end

local function buildDoors(plan: any, nodes: { any }, adjacency: { any }, options: any): ()
	local byId: { [number]: any } = {}
	for _, node in ipairs(nodes) do
		byId[node.id] = node
	end

	-- BFS over the adjacency graph from the spawn.
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
	local head = 1
	local used: { [string]: boolean } = {}
	local edgeId = 0

	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, edge in ipairs(linked[current]) do
			if not used[edge.key] then
				local other = if edge.a.id == current then edge.b else edge.a
				if not visited[other.id] then
					visited[other.id] = true
					table.insert(queue, other.id)
					used[edge.key] = true
					edgeId += 1
					local aPort = addPort(edge.a, edge.sideA, 8)
					local bPort = addPort(edge.b, edge.sideB, 8)
					table.insert(plan.edges, {
						id = edgeId,
						a = edge.a.id,
						b = edge.b.id,
						aPort = aPort,
						bPort = bPort,
						kind = "passage",
					})
				end
			end
		end
	end

	-- Loops: adjacent pairs that are not already doorways.
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
			used[edge.key] = true
			loops -= 1
			edgeId += 1
			local aPort = addPort(edge.a, edge.sideA, 8)
			local bPort = addPort(edge.b, edge.sideB, 8)
			table.insert(plan.edges, {
				id = edgeId,
				a = edge.a.id,
				b = edge.b.id,
				aPort = aPort,
				bPort = bPort,
				kind = "loop",
			})
		end
	end
end

-- -------------------------------------------------------------------- entry

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
