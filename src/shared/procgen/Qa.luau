--!strict

-- Physical QA for a generated level, computed from the geometry description.
--
-- This exists because three rounds of "build it in Studio and look at it" found
-- three geometric flaws that a test could have found first. The description is
-- the level; if a player cannot cross it here, they cannot cross it in Roblox.
--
-- Checks:
--   * doorway clearance — nothing may occupy an opening volume
--   * opening fit       — a character must pass
--   * sealed rooms      — every node needs at least one doorway
--   * walkability       — rasterise at 1 stud, block cells covered by walls,
--                         flood fill from the spawn, and require every node's
--                         interior to be reachable
--
-- Pure Luau: runs under Lune.

local Geometry = if script ~= nil then require(script.Parent.Geometry) else require("./Geometry")

local Qa = {}

local CHARACTER_WIDTH = 4
local CHARACTER_HEIGHT = 6
local CLEARANCE = 0.5
local CELL = 1

-- Penetration on every axis must exceed the wall thickness to count as blocked.
-- Two walls that meet at a corner share a sliver of volume the size of that
-- thickness; that is a T-junction, not an obstruction, and growth packing
-- produces many of them. A wall across the opening penetrates its full width.
local CORNER_SLOP = 1.5

local function boxesOverlap(a: any, b: any): boolean
	return a.minX + CORNER_SLOP < b.maxX
		and b.minX + CORNER_SLOP < a.maxX
		and a.minY + CORNER_SLOP < b.maxY
		and b.minY + CORNER_SLOP < a.maxY
		and a.minZ + CORNER_SLOP < b.maxZ
		and b.minZ + CORNER_SLOP < a.maxZ
end

local function partBox(part: any): any
	return {
		minX = part.position[1] - part.size[1] / 2,
		maxX = part.position[1] + part.size[1] / 2,
		minY = part.position[2] - part.size[2] / 2,
		maxY = part.position[2] + part.size[2] / 2,
		minZ = part.position[3] - part.size[3] / 2,
		maxZ = part.position[3] + part.size[3] / 2,
	}
end

-- ---------------------------------------------------------------- walkability

local function key(x: number, z: number): string
	return x .. ":" .. z
end

local function rasterise(plan: any, parts: { any }, floorY: number): (any, any)
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	for _, node in ipairs(plan.nodes) do
		minX = math.min(minX, node.x)
		maxX = math.max(maxX, node.x + node.w)
		minZ = math.min(minZ, node.z)
		maxZ = math.max(maxZ, node.z + node.d)
	end

	-- The walkable region is the union of node footprints inflated by a wall, so
	-- the doorway gaps (which sit on the boundary) are included.
	local inside: { [string]: boolean } = {}
	for _, node in ipairs(plan.nodes) do
		for x = math.floor(node.x - 1), math.ceil(node.x + node.w + 1) do
			for z = math.floor(node.z - 1), math.ceil(node.z + node.d + 1) do
				inside[key(x, z)] = true
			end
		end
	end

	local blocked: { [string]: boolean } = {}
	for _, part in ipairs(parts) do
		if part.canCollide ~= false then
			local box = partBox(part)
			local bandLow = floorY + 1
			local bandHigh = floorY + 5
			if box.minY < bandHigh and bandLow < box.maxY then
				for x = math.floor(box.minX - CLEARANCE), math.ceil(box.maxX + CLEARANCE) do
					for z = math.floor(box.minZ - CLEARANCE), math.ceil(box.maxZ + CLEARANCE) do
						local cx, cz = x + 0.5, z + 0.5
						if
							cx >= box.minX - CLEARANCE
							and cx <= box.maxX + CLEARANCE
							and cz >= box.minZ - CLEARANCE
							and cz <= box.maxZ + CLEARANCE
						then
							blocked[key(x, z)] = true
						end
					end
				end
			end
		end
	end

	return inside, blocked, minX, minZ, maxX, maxZ
end

function Qa.reachable(plan: any, parts: { any }): (any, any)
	local floorY = 0
	local spawnNode = nil
	for _, node in ipairs(plan.nodes) do
		if node.id == plan.spawn.nodeId then
			spawnNode = node
			floorY = node.y
		end
	end
	if spawnNode == nil then
		return {}, { "spawn node missing" }
	end

	local inside, blocked = rasterise(plan, parts, floorY)
	local startX = math.floor(spawnNode.x + spawnNode.w / 2)
	local startZ = math.floor(spawnNode.z + spawnNode.d / 2)

	local seen: { [string]: boolean } = {}
	local problems: { string } = {}
	if not inside[key(startX, startZ)] then
		table.insert(problems, "spawn cell is outside the walkable region")
		return seen, problems
	end
	if blocked[key(startX, startZ)] then
		table.insert(problems, "spawn cell is blocked by geometry")
		return seen, problems
	end

	local queue = { { startX, startZ } }
	seen[key(startX, startZ)] = true
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		local neighbours = {
			{ current[1] + CELL, current[2] },
			{ current[1] - CELL, current[2] },
			{ current[1], current[2] + CELL },
			{ current[1], current[2] - CELL },
		}
		for _, next in ipairs(neighbours) do
			local k = key(next[1], next[2])
			if inside[k] and not blocked[k] and not seen[k] then
				seen[k] = true
				table.insert(queue, { next[1], next[2] })
			end
		end
	end

	return seen, problems
end

-- ------------------------------------------------------------ face coverage

-- 2-D coverage: every cell of a face (along × height) must be wall or doorway.
-- The 1-D version passed a 28-stud face with an 18-stud wall, which is exactly
-- the "sky above the short room" bug.
-- Two axes: the face PLANE (constant coordinate) and the ALONG axis (the span).
local function facePlaneValue(node: any, side: string): (string, number)
	if side == "N" then
		return "z", node.z
	elseif side == "S" then
		return "z", node.z + node.d
	elseif side == "W" then
		return "x", node.x
	end
	return "x", node.x + node.w
end

local function alongAxisFor(side: string): string
	return if side == "N" or side == "S" then "x" else "z"
end

local function faceLength(node: any, side: string): number
	return if side == "N" or side == "S" then node.w else node.d
end

local function alongValue(part: any, axis: string): number
	return if axis == "x" then part.position[1] else part.position[3]
end

local function alongSize(part: any, axis: string): number
	return if axis == "x" then part.size[1] else part.size[3]
end

function Qa.coverage(plan: any, parts: { any }, options: any?): { string }
	local problems: { string } = {}
	local openings = Geometry.openings(plan, { style = options and options.style })

	for _, node in ipairs(plan.nodes) do
		for _, side in ipairs({ "N", "E", "S", "W" }) do
			local planeAxis, plane = facePlaneValue(node, side)
			local axis = alongAxisFor(side)
			local length = faceLength(node, side)
			local height = node.h
			local cells: { [string]: boolean } = {}

			local function mark(uStart: number, uLen: number, vStart: number, vLen: number)
				local u0 = math.max(0, math.floor(uStart))
				local u1 = math.min(length, math.ceil(uStart + uLen))
				local v0 = math.max(0, math.floor(vStart))
				local v1 = math.min(height, math.ceil(vStart + vLen))
				for u = u0, u1 - 1 do
					for v = v0, v1 - 1 do
						cells[u .. ":" .. v] = true
					end
				end
			end

			-- Walls lying on this plane.
			for _, part in ipairs(parts) do
				if part.kind == "wall" and part.canCollide ~= false then
					local planeValue = if planeAxis == "x"
						then part.position[1]
						else part.position[3]
					if math.abs(planeValue - plane) < 0.6 then
						local origin = if axis == "x" then node.x else node.z
						local uStart = alongValue(part, axis) - alongSize(part, axis) / 2 - origin
						local vStart = part.position[2] - part.size[2] / 2 - node.y
						mark(uStart, alongSize(part, axis), vStart, part.size[2])
					end
				end
			end

			-- Legal holes: doorways on this plane.
			for _, opening in ipairs(openings) do
				local box = opening.box
				local planeValue = if planeAxis == "x"
					then (box.minX + box.maxX) / 2
					else (box.minZ + box.maxZ) / 2
				if math.abs(planeValue - plane) < 0.6 then
					local origin = if axis == "x" then node.x else node.z
					local uFrom = (if axis == "x" then box.minX else box.minZ) - origin
					local uLen = (if axis == "x" then box.maxX - box.minX else box.maxZ - box.minZ)
					mark(uFrom, uLen, box.minY - node.y, box.maxY - box.minY)
				end
			end

			local missing = 0
			for u = 0, math.ceil(length) - 1 do
				for v = 0, math.ceil(height) - 1 do
					if not cells[u .. ":" .. v] then
						missing += 1
					end
				end
			end
			if missing > 0 then
				table.insert(
					problems,
					string.format(
						"node %d side %s: %d uncovered face cell(s) of %d×%d",
						node.id,
						side,
						missing,
						math.ceil(length),
						math.ceil(height)
					)
				)
			end
		end
	end

	return problems
end

-- -------------------------------------------------------------------- checks

function Qa.check(plan: any, parts: { any }, options: any?): { string }
	local problems: { string } = {}
	local style = options and options.style

	for _, problem in ipairs(Qa.coverage(plan, parts, options)) do
		table.insert(problems, problem)
	end

	if options and options.transitions then
		for _, problem in ipairs(Qa.exits(plan, options.transitions, options)) do
			table.insert(problems, problem)
		end
	end

	-- Doorway clearance and fit.
	local openings = Geometry.openings(plan, { style = style })
	for _, opening in ipairs(openings) do
		if opening.width < CHARACTER_WIDTH then
			table.insert(
				problems,
				string.format(
					"edge %d: doorway %.1f wide (< %d)",
					opening.edgeId,
					opening.width,
					CHARACTER_WIDTH
				)
			)
		end
		if opening.height < CHARACTER_HEIGHT then
			table.insert(
				problems,
				string.format(
					"edge %d: doorway %.1f tall (< %d)",
					opening.edgeId,
					opening.height,
					CHARACTER_HEIGHT
				)
			)
		end
		for _, part in ipairs(parts) do
			if part.kind == "wall" and part.canCollide ~= false then
				if boxesOverlap(partBox(part), opening.box) then
					table.insert(
						problems,
						string.format(
							"edge %d: doorway is blocked by %s",
							opening.edgeId,
							tostring(part.owner)
						)
					)
					break
				end
			end
		end
	end

	-- Every node must be part of at least one doorway.
	local doorCount: { [number]: number } = {}
	for _, edge in ipairs(plan.edges) do
		doorCount[edge.a] = (doorCount[edge.a] or 0) + 1
		doorCount[edge.b] = (doorCount[edge.b] or 0) + 1
	end
	for _, node in ipairs(plan.nodes) do
		if (doorCount[node.id] or 0) == 0 then
			table.insert(problems, "node " .. tostring(node.id) .. " has no doorway")
		end
	end

	-- Walkability: every node's interior must be reachable from the spawn.
	local seen, floodProblems = Qa.reachable(plan, parts)
	for _, problem in ipairs(floodProblems) do
		table.insert(problems, problem)
	end
	for _, node in ipairs(plan.nodes) do
		local reachable = false
		for x = math.floor(node.x + 2), math.ceil(node.x + node.w - 2) do
			for z = math.floor(node.z + 2), math.ceil(node.z + node.d - 2) do
				if seen[key(x, z)] then
					reachable = true
					break
				end
			end
			if reachable then
				break
			end
		end
		if not reachable then
			table.insert(
				problems,
				"node " .. tostring(node.id) .. " is not walkable from the spawn"
			)
		end
	end

	-- Exit hosts must be walkable too (they are nodes, so covered above, but
	-- assert explicitly in case an exit is ever anchored to an edge).
	for _, exit in ipairs(plan.exits or {}) do
		if exit.anchor.hostNode ~= nil and (doorCount[exit.anchor.hostNode] or 0) == 0 then
			table.insert(problems, "exit " .. tostring(exit.id) .. " is anchored to a sealed node")
		end
	end

	return problems
end

-- Exit-shape invariants. These are plan-level (no geometry needed), but they
-- belong with the physical checks because both are "the level is playable"
-- claims. `transitions` is the level's declared list; without it we can only
-- check internal consistency.
function Qa.exits(plan: any, transitions: { any }?, options: any?): { string }
	local problems: { string } = {}
	local declared: { [string]: boolean } = {}
	for _, transition in ipairs(transitions or {}) do
		declared[transition.id] = true
	end

	local anchors: { [string]: number } = {}
	for _, exit in ipairs(plan.exits or {}) do
		if exit.decoy then
			-- A decoy is unbound: it must not carry a real transition id, and it
			-- must be able to resolve to nothing.
			if declared[exit.id] then
				table.insert(
					problems,
					"decoy " .. tostring(exit.id) .. " reuses a declared transition id"
				)
			end
			local hasNone = false
			for _, outcome in ipairs(exit.outcomes or {}) do
				if outcome.kind == "none" then
					hasNone = true
				end
			end
			if not hasNone then
				table.insert(
					problems,
					"decoy " .. tostring(exit.id) .. " has no 'none' outcome, so it is not a decoy"
				)
			end
		else
			if not declared[exit.id] then
				table.insert(
					problems,
					"exit " .. tostring(exit.id) .. " is not a declared transition"
				)
			end
			anchors[exit.id] = (anchors[exit.id] or 0) + 1
		end
	end

	-- Mastery is only honest if every declared transition is actually reachable
	-- in every seed (ADR 0006): at least one guaranteed, non-decoy anchor.
	for _, transition in ipairs(transitions or {}) do
		if (anchors[transition.id] or 0) < 1 then
			table.insert(
				problems,
				"transition " .. tostring(transition.id) .. " has no real anchor"
			)
		end
	end

	-- Separation: the device cannot say which hint is true, so two exit-like
	-- features must not both be reachable from the same place. Phenomena are
	-- exempt — they are not places (ADR 0023).
	local share = options and options.separationShare
	if share ~= nil and share > 0 then
		local nodesById: { [number]: any } = {}
		local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
		for _, node in ipairs(plan.nodes or {}) do
			nodesById[node.id] = node
			if node.level == 0 then
				minX = math.min(minX, node.x)
				minZ = math.min(minZ, node.z)
				maxX = math.max(maxX, node.x + node.w)
				maxZ = math.max(maxZ, node.z + node.d)
			end
		end
		local separation = share * math.min(maxX - minX, maxZ - minZ)
		local live = {}
		for _, exit in ipairs(plan.exits or {}) do
			if string.sub(tostring(exit.gate), 1, 10) ~= "phenomenon" then
				local host = nodesById[exit.anchor.hostNode or 0]
				if host ~= nil then
					table.insert(live, {
						name = (if exit.decoy then "decoy " else "exit ") .. tostring(exit.id),
						x = host.x + host.w / 2,
						z = host.z + host.d / 2,
					})
				end
			end
		end
		for i = 1, #live do
			for j = i + 1, #live do
				local dx = live[i].x - live[j].x
				local dz = live[i].z - live[j].z
				local distance = math.sqrt(dx * dx + dz * dz)
				if distance < separation then
					table.insert(
						problems,
						string.format(
							"%s and %s are %.0f studs apart (< %.0f)",
							live[i].name,
							live[j].name,
							distance,
							separation
						)
					)
				end
			end
		end
	end

	return problems
end

return Qa
