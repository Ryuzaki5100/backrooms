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

-- Growth packing (ADR 0022).
--
-- The old packer sorted spaces by depth and filled rows. That is why a level
-- read as "rooms beside each other": every space was a shelf neighbour of the
-- next in a rectangle. Growth instead places one space at a time, flush against a
-- free face of an already placed space, largest first. Adjacency still comes from
-- real contact; the shape becomes an irregular mass with recesses and wings.
--
-- Corridors are placed before everything else and prefer to attach end-to-end,
-- so circulation is grown as a spine and rooms hang off it rather than touching
-- each other by default.

local function overlapsAny(placed: { any }, node: any): boolean
	for _, other in ipairs(placed) do
		if overlaps(other, node) then
			return true
		end
	end
	return false
end

local function placementOrder(nodes: { any }): { any }
	local corridors, rest = {}, {}
	for _, node in ipairs(nodes) do
		if node.kind == "corridor" then
			table.insert(corridors, node)
		else
			table.insert(rest, node)
		end
	end
	local function byArea(a: any, b: any)
		local areaA, areaB = a.w * a.d, b.w * b.d
		if areaA ~= areaB then
			return areaA > areaB
		end
		return a.id < b.id
	end
	table.sort(corridors, byArea)
	table.sort(rest, byArea)
	local order = {}
	table.move(corridors, 1, #corridors, 1, order)
	table.move(rest, 1, #rest, #corridors + 1, order)
	return order
end

local function hostPool(placed: { any }, kind: string, rng: any): { any }
	local corridors = {}
	for _, node in ipairs(placed) do
		if node.kind == "corridor" then
			table.insert(corridors, node)
		end
	end
	if kind == "corridor" then
		-- Corridors grow the spine from other corridors.
		return if #corridors > 0 then corridors else placed
	end
	-- Rooms hang off circulation most of the time, but not always: a room
	-- reached through another room is part of the warren too.
	if #corridors > 0 and rng:nextBool(0.75) then
		return corridors
	end
	return placed
end

-- Score a placement by how many placed spaces it touches. A pack that only
-- ever attaches one face per space is a tree, and a tree has no loops — which
-- for Level 0 is the defining feature, not a nicety.
local function contactCount(placed: { any }, node: any): number
	local count = 0
	for _, other in ipairs(placed) do
		local sideA, sideB = touch(node, other)
		if sideA ~= nil and sideB ~= nil then
			count += 1
		end
	end
	return count
end

-- `preferred` is the circulation spine; `placed` is everything. Sampling both
-- matters: with only corridors as hosts every room hangs off the comb and no two
-- rooms ever touch, which is exactly the tree we are trying to escape.
local function tryAttach(
	rng: any,
	placed: { any },
	node: any,
	preferred: { any },
	all: { any }
): boolean
	if #all == 0 then
		return false
	end
	local bestContacts = -1
	local best = {}
	for attempt = 1, 24 do
		local pool = if #preferred > 0 and attempt % 2 == 0 then preferred else all
		local host = pool[rng:nextInt(#pool)]
		local side = rng:nextInt(4)
		if node.kind == "corridor" and side > 2 then
			-- extend a corridor run along its long axis
			side = if rng:nextBool(0.5) then 3 else 4
		end
		local x, z
		if side == 1 then
			x, z = host.x + host.w, host.z
		elseif side == 2 then
			x, z = host.x - node.w, host.z
		elseif side == 3 then
			x, z = host.x, host.z + host.d
		else
			x, z = host.x, host.z - node.d
		end
		local shared = if side == 1 or side == 2
			then math.min(host.d, node.d)
			else math.min(host.w, node.w)
		if shared >= MIN_OPENING then
			node.x, node.z = x, z
			if not overlapsAny(placed, node) then
				local contacts = contactCount(placed, node)
				if contacts > bestContacts then
					bestContacts = contacts
					best = { { x, z } }
				elseif contacts == bestContacts then
					table.insert(best, { x, z })
				end
			end
		end
	end
	if #best == 0 then
		return false
	end
	local pick = best[rng:nextInt(#best)]
	node.x, node.z = pick[1], pick[2]
	return true
end

local function packLevel(nodes: { any }, rng: any): boolean
	local placed = {}
	local remaining = placementOrder(nodes)
	local first = table.remove(remaining, 1)
	if first == nil then
		return true
	end
	first.x, first.z = 0, 0
	table.insert(placed, first)

	while #remaining > 0 do
		local progressed = false
		for index = #remaining, 1, -1 do
			local node = remaining[index]
			local preferred = hostPool(placed, node.kind, rng)
			local attached = tryAttach(rng, placed, node, preferred, placed)
			if attached then
				table.insert(placed, node)
				table.remove(remaining, index)
				progressed = true
			end
		end
		if not progressed then
			return false
		end
	end
	return true
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

local function addPort(
	node: any,
	side: string,
	height: number,
	offset: number,
	width: number?
): number
	local id = #node.ports + 1
	table.insert(node.ports, {
		id = id,
		side = side,
		offset = offset,
		width = width or 4,
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
	sideB: string,
	opening: any?
): (number?, number?)
	local startA, lenA = overlapFor(a, sideA, b)
	local startB, lenB = overlapFor(b, sideB, a)
	if startA == nil or startB == nil then
		return nil, nil
	end
	local rng = Rng.new(plan.seed):fork("door:" .. a.id .. ":" .. b.id)
	local t = rng:nextFloat()
	local height = (opening and opening.height) or 8
	local spanA = if sideA == "N" or sideA == "S" then a.w else a.d
	local spanB = if sideB == "N" or sideB == "S" then b.w else b.d
	-- A doorway cannot be wider than the face it is cut into. Without this a
	-- short overlap produced a negative offset, which the codec rejects (u16).
	local width = math.min((opening and opening.width) or 4, spanA, spanB)
	-- Offsets are relative to each node's own face origin, which is what the
	-- geometry layer reads.
	local offsetA = doorOffsetFor(t, startA, lenA, width) - faceOrigin(a, sideA)
	local offsetB = doorOffsetFor(t, startB, lenB, width) - faceOrigin(b, sideB)
	offsetA = clamp(offsetA, 0, math.max(0, spanA - width))
	offsetB = clamp(offsetB, 0, math.max(0, spanB - width))
	return addPort(a, sideA, height, offsetA, width), addPort(b, sideB, height, offsetB, width)
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
	local openings = options.openings

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
		local aPort, bPort = makeDoorPorts(plan, edge.a, edge.sideA, edge.b, edge.sideB, openings)
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

-- ------------------------------------------------------------- exit placement

-- A phenomenon is not an action: a blackout or a phasing wall can happen
-- anywhere, so its anchors are exempt from the separation rule. Everything with
-- an action or trigger gate is a *place*, and two places that hint "this is a
-- way out" must not sit next to each other — the device cannot tell the player
-- which hint is real.
local function isPhenomenon(gate: string): boolean
	return string.sub(tostring(gate), 1, 10) == "phenomenon"
end

local function centre(node: any): (number, number)
	return node.x + node.w / 2, node.z + node.d / 2
end

-- Greedy farthest-point placement: each exit goes to the room whose centre is
-- furthest from everything already placed. Deterministic, no RNG, and it
-- degrades gracefully — on a level that is too small it still spreads as far as
-- the geometry allows, and QA reports the shortfall.
local function placeExits(plan: any, share: number): ()
	if share == nil or share <= 0 then
		return
	end
	local candidates = {}
	for _, node in ipairs(plan.nodes) do
		if (node.kind == "room" or node.kind == "hall") and node.level == 0 then
			table.insert(candidates, node)
		end
	end
	if #candidates == 0 then
		return
	end
	table.sort(candidates, function(a: any, b: any)
		return a.id < b.id
	end)

	-- A stud value cannot be right at every scale: 120 studs is generous on a
	-- 400-stud level and nothing on a 4,000-stud one. The authored value is a
	-- share of the level's smaller extent, so "far apart" grows with the world.
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	for _, node in ipairs(candidates) do
		minX = math.min(minX, node.x)
		minZ = math.min(minZ, node.z)
		maxX = math.max(maxX, node.x + node.w)
		maxZ = math.max(maxZ, node.z + node.d)
	end
	local extent = math.min(maxX - minX, maxZ - minZ)
	local separation = share * extent
	if separation <= 0 then
		return
	end

	-- Deterministic order: real anchors first (by transition, then instance),
	-- decoys last. Decoys then fill the gaps that are left.
	local order = {}
	for index, exit in ipairs(plan.exits or {}) do
		table.insert(order, { exit = exit, index = index })
	end
	table.sort(order, function(a: any, b: any)
		local aDecoy = if a.exit.decoy then 1 else 0
		local bDecoy = if b.exit.decoy then 1 else 0
		if aDecoy ~= bDecoy then
			return aDecoy < bDecoy
		end
		if a.exit.id ~= b.exit.id then
			return a.exit.id < b.exit.id
		end
		return a.index < b.index
	end)

	-- The spawn is the first reference point: exits sit away from where a run
	-- starts, so a run always involves looking for one.
	local spawn: any = nil
	for _, node in ipairs(candidates) do
		if node.id == plan.spawn.nodeId then
			spawn = node
		end
	end
	-- Position of each placed feature, by index into `order`. Phenomena are not
	-- placed (they are exempt), so they have no entry.
	-- `spots` is keyed by order index (holes for exempt phenomena); `placed` is
	-- dense, because ipairs stops at the first hole.
	local spots: { any } = {}
	local placed: { any } = {}
	local used: { [number]: boolean } = {}
	table.sort(candidates, function(a: any, b: any)
		return a.id < b.id
	end)

	local function nearestDistance(x: number, z: number, skip: any?): number
		local nearest = math.huge
		for _, spot in ipairs(placed) do
			if spot ~= skip then
				local dx, dz = x - spot.x, z - spot.z
				nearest = math.min(nearest, math.sqrt(dx * dx + dz * dz))
			end
		end
		return nearest
	end

	-- The spawn is a reference point: exits sit away from where a run starts.
	local spawnX, spawnZ = nil, nil
	for _, node in ipairs(candidates) do
		if node.id == plan.spawn.nodeId then
			spawnX, spawnZ = centre(node)
			used[node.id] = true
		end
	end

	-- Greedy farthest-point: each feature goes to the room furthest from
	-- everything already placed.
	for index, item in ipairs(order) do
		if not isPhenomenon(item.exit.gate) then
			local bestNode, bestKey = nil, -1
			for _, node in ipairs(candidates) do
				if not used[node.id] then
					local x, z = centre(node)
					local key = nearestDistance(x, z)
					if spawnX ~= nil then
						local dx, dz = x - spawnX, z - spawnZ
						key = math.min(key, math.sqrt(dx * dx + dz * dz))
					end
					if key > bestKey then
						bestKey = key
						bestNode = node
					end
				end
			end
			if bestNode ~= nil then
				used[bestNode.id] = true
				local x, z = centre(bestNode)
				local spot = { nodeId = bestNode.id, x = x, z = z }
				spots[index] = spot
				table.insert(placed, spot)
			end
		end
	end

	-- Refinement: greedy insertion can leave one feature in a pocket while the
	-- rest own the open space. Move the worst-off feature to the room that
	-- maximises its own nearest neighbour, and repeat until it stops improving.
	for _ = 1, 8 do
		local improved = false
		for _, spot in ipairs(placed) do
			local before = nearestDistance(spot.x, spot.z, spot)
			local bestNode, bestKey = nil, before
			for _, node in ipairs(candidates) do
				if not used[node.id] then
					local x, z = centre(node)
					local key = nearestDistance(x, z, spot)
					if key > bestKey then
						bestKey = key
						bestNode = node
					end
				end
			end
			if bestNode ~= nil then
				used[spot.nodeId] = nil
				used[bestNode.id] = true
				local x, z = centre(bestNode)
				spot.nodeId = bestNode.id
				spot.x, spot.z = x, z
				improved = true
			end
		end
		if not improved then
			break
		end
	end

	for index, item in ipairs(order) do
		local spot = spots[index]
		if spot ~= nil then
			item.exit.anchor = item.exit.anchor or { kind = "spatial" }
			item.exit.anchor.hostNode = spot.nodeId
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

	-- Loop demand: an absolute count, or a share of the spanning tree. A share is
	-- the honest dial, because "4 loops" means something different on 18 spaces
	-- and on 1,000.
	local wantedLoops = opts.loops or 0
	if (opts.loopShare or 0) > 0 then
		wantedLoops =
			math.max(wantedLoops, math.floor(opts.loopShare * math.max(1, #ground - 1) + 0.5))
	end

	-- Growth packing is randomised, so a layout that cannot reach the loop
	-- target is retried from a different fork. The best successful attempt wins.
	table.sort(ground, function(a: any, b: any)
		return a.id < b.id
	end)
	local best: any = nil
	for attempt = 1, 8 do
		local packed = packLevel(ground, Rng.new(plan.seed):fork("pack:" .. attempt))
		if packed then
			local candidate = deriveAdjacency(ground)
			local snapshot = {}
			for index, node in ipairs(ground) do
				snapshot[index] = { node.x, node.z }
			end
			if best == nil or #candidate > #best.adjacency then
				best = { adjacency = candidate, snapshot = snapshot }
			end
			if #candidate - (#ground - 1) >= wantedLoops then
				break
			end
		end
	end
	if best == nil then
		error("Embedding.embed: could not pack the level in 8 attempts", 2)
	end
	for index, node in ipairs(ground) do
		node.x, node.z = best.snapshot[index][1], best.snapshot[index][2]
	end
	local adjacency = best.adjacency
	repairComponents(ground, adjacency)

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

	buildDoors(out, ground, adjacency, {
		loops = wantedLoops,
		loopPreference = opts.loopPreference,
		connectivity = opts.connectivity,
		openings = opts.openings,
	})

	-- Exit placement needs real coordinates, so it happens after packing (see
	-- placeExits below). Macro's assignment is only the standalone default.
	placeExits(out, opts.exitSeparationShare or 0)

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
