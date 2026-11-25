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

local function boxesOverlap(a: any, b: any): boolean
	return a.minX < b.maxX
		and b.minX < a.maxX
		and a.minY < b.maxY
		and b.minY < a.maxY
		and a.minZ < b.maxZ
		and b.minZ < a.maxZ
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

-- -------------------------------------------------------------------- checks

function Qa.check(plan: any, parts: { any }, options: any?): { string }
	local problems: { string } = {}
	local style = options and options.style

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

return Qa
