--!strict

-- Spatial embedding: turn abstract topology into 3D coordinates.
--
-- Pure Luau (Lune-testable). ADR 0012:
--   * port sides are LOCAL; each node gets a yaw (`rotation`) so its port can
--     face the neighbour it connects to;
--   * floors are `level * floorHeight`, with floorHeight derived per plan so a
--     level's ceiling height is part of its identity;
--   * a plenum (ceiling void) is reserved above every node, because Level 0's
--     lore depends on it;
--   * placement is deterministic: same plan in, same coordinates out.

local Embedding = {}

local SLAB = 2
local PLENUM = 4
local MIN_FLOOR = 16
local MAX_FLOOR = 32
local MAX_ATTEMPTS = 8

-- N, E, S, W in clockwise order. U/D are vertical and not part of the cycle.
local SIDES = { "N", "E", "S", "W" }
local INDEX = { N = 1, E = 2, S = 3, W = 4 }
local OPPOSITE = { N = "S", E = "W", S = "N", W = "E" }

local function round4(value: number): number
	return math.floor((value + 3) / 4) * 4
end

local function clamp(value: number, low: number, high: number): number
	return math.max(low, math.min(high, value))
end

-- Effective world side of a local side after a yaw of `rotation` quarter turns.
local function effectiveSide(side: string, rotation: number): string
	local start = INDEX[side]
	if start == nil then
		return side -- vertical: U/D are rotation-invariant
	end
	return SIDES[((start - 1 + rotation) % 4) + 1]
end

-- Yaw needed so that a node's local `side` faces `wanted` in the world.
local function rotationFor(side: string, wanted: string): number
	local localIndex = INDEX[side]
	local wantedIndex = INDEX[wanted]
	if localIndex == nil or wantedIndex == nil then
		return 0
	end
	return (wantedIndex - localIndex + 4) % 4
end

local function worldExtents(node: any): (number, number)
	if node.rotation % 2 == 0 then
		return node.w, node.d
	end
	return node.d, node.w
end

local function overlaps(placed: { any }, candidate: any): boolean
	local cw, cd = worldExtents(candidate)
	local cMinY = candidate.y
	local cMaxY = candidate.y + candidate.h
	for _, other in ipairs(placed) do
		local ow, od = worldExtents(other)
		local yOverlap = cMinY < other.y + other.h and other.y < cMaxY
		if yOverlap then
			local xOverlap = candidate.x < other.x + ow and other.x < candidate.x + cw
			local zOverlap = candidate.z < other.z + od and other.z < candidate.z + cd
			if xOverlap and zOverlap then
				return true
			end
		end
	end
	return false
end

local function computeFloorHeight(nodes: { any }): number
	local tallest = 0
	for _, node in ipairs(nodes) do
		tallest = math.max(tallest, node.h)
	end
	return clamp(round4(tallest + SLAB + PLENUM), MIN_FLOOR, MAX_FLOOR)
end

-- Candidate positions for `node` attached to `parent` across `edge`.
-- Deterministic order: gap first, then perpendicular shifts.
local function candidates(
	parent: any,
	node: any,
	side: string,
	gap: number
): { { x: number, y: number, z: number } }
	local pw, pd = worldExtents(parent)
	local nw, nd = worldExtents(node)
	local list = {}

	local baseX = parent.x + (pw - nw) / 2
	local baseZ = parent.z + (pd - nd) / 2

	if side == "E" then
		baseX = parent.x + pw + gap
	elseif side == "W" then
		baseX = parent.x - nw - gap
	elseif side == "S" then
		baseZ = parent.z + pd + gap
	elseif side == "N" then
		baseZ = parent.z - nd - gap
	end

	-- Perpendicular freedom, stepped by the node's own extent so a shift always
	-- clears the space it was occupying. Fixed order keeps runs reproducible.
	local step = if side == "E" or side == "W" then nd + gap + 4 else nw + gap + 4
	local multipliers = { 0, 1, -1, 2, -2, 3, -3 }
	for _, multiplier in ipairs(multipliers) do
		local shift = multiplier * step
		if side == "E" or side == "W" then
			table.insert(
				list,
				{ x = math.floor(baseX + 0.5), y = parent.y, z = math.floor(baseZ + shift + 0.5) }
			)
		else
			table.insert(
				list,
				{ x = math.floor(baseX + shift + 0.5), y = parent.y, z = math.floor(baseZ + 0.5) }
			)
		end
	end

	return list
end

local function placeOnce(plan: any, floorHeight: number, gap: number): (any?, string?)
	local nodesById: { [number]: any } = {}
	local placed: { any } = {}
	local order: { any } = {}

	for _, node in ipairs(plan.nodes) do
		local copy = table.clone(node)
		copy.rotation = node.rotation or 0
		copy.y = node.level * floorHeight
		nodesById[node.id] = copy
	end

	local spawn = nodesById[plan.spawn.nodeId]
	if spawn == nil then
		return nil, "spawn node missing"
	end
	spawn.x = 0
	spawn.z = 0
	table.insert(placed, spawn)
	table.insert(order, spawn)
	local placedIds: { [number]: boolean } = { [spawn.id] = true }

	-- Adjacency for a deterministic BFS.
	local adjacency: { [number]: { any } } = {}
	for _, node in ipairs(plan.nodes) do
		adjacency[node.id] = {}
	end
	for _, edge in ipairs(plan.edges) do
		if adjacency[edge.a] and adjacency[edge.b] then
			table.insert(
				adjacency[edge.a],
				{ edge = edge, selfPort = edge.aPort, otherPort = edge.bPort }
			)
			table.insert(
				adjacency[edge.b],
				{ edge = edge, selfPort = edge.bPort, otherPort = edge.aPort }
			)
		end
	end

	local head = 1
	while head <= #order do
		local parent = order[head]
		head += 1

		for _, link in ipairs(adjacency[parent.id]) do
			local edge = link.edge
			local otherId = if edge.a == parent.id then edge.b else edge.a
			local child = nodesById[otherId]
			if child ~= nil and not placedIds[child.id] then
				local parentPort = parent.ports[link.selfPort]
				local childPort = child.ports[link.otherPort]
				if parentPort == nil or childPort == nil then
					return nil, "edge " .. tostring(edge.id) .. " references a missing port"
				end

				local parentSide = effectiveSide(parentPort.side, parent.rotation)
				if parentSide == "U" or parentSide == "D" then
					-- Vertical link: prefer the footprint above the parent, but the
					-- upper floor may already be occupied, so search around it.
					local nw, nd = worldExtents(child)
					local pw, pd = worldExtents(parent)
					local baseX = math.floor(parent.x + (pw - nw) / 2 + 0.5)
					local baseZ = math.floor(parent.z + (pd - nd) / 2 + 0.5)
					-- Steps scale with the child's footprint, otherwise a 24-stud room
					-- "shifts by 4" straight back into itself.
					local step = math.max(nw, nd) + 4
					local offsets = { 0, step, -step, 2 * step, -2 * step, 3 * step, -3 * step }
					local chosen = nil
					for _, dx in ipairs(offsets) do
						for _, dz in ipairs(offsets) do
							local trial = table.clone(child)
							trial.x = baseX + dx
							trial.z = baseZ + dz
							trial.y = child.level * floorHeight
							if not overlaps(placed, trial) then
								chosen = trial
								break
							end
						end
						if chosen ~= nil then
							break
						end
					end
					if chosen == nil then
						return nil, "no vertical position for node " .. tostring(child.id)
					end
					child.x = chosen.x
					child.y = chosen.y
					child.z = chosen.z
					table.insert(placed, child)
					table.insert(order, child)
					placedIds[child.id] = true
				else
					child.rotation = rotationFor(childPort.side, OPPOSITE[parentSide])
					local options = candidates(parent, child, parentSide, gap)
					local chosen = nil
					for _, option in ipairs(options) do
						local trial = table.clone(child)
						trial.x = option.x
						trial.z = option.z
						trial.y = child.level * floorHeight
						if not overlaps(placed, trial) then
							chosen = trial
							break
						end
					end
					if chosen == nil then
						return nil, "no free position for node " .. tostring(child.id)
					end
					child.x = chosen.x
					child.y = chosen.y
					child.z = chosen.z
					table.insert(placed, child)
					table.insert(order, child)
					placedIds[child.id] = true
				end
			end
		end
	end

	if #order ~= #plan.nodes then
		return nil, "graph is not connected from spawn"
	end

	-- Preserve the original node order (by id) in the output.
	local outNodes = {}
	for _, node in ipairs(plan.nodes) do
		table.insert(outNodes, nodesById[node.id])
	end

	local out = table.clone(plan)
	out.nodes = outNodes
	out.floorHeight = floorHeight
	out.plenum = PLENUM
	return out
end

function Embedding.embed(plan: any): any
	local floorHeight = computeFloorHeight(plan.nodes)
	local lastError = "unknown"

	for attempt = 0, MAX_ATTEMPTS - 1 do
		local gap = attempt * 2
		local placed, failure = placeOnce(plan, floorHeight, gap)
		if placed ~= nil then
			return placed
		end
		lastError = tostring(failure)
	end

	error("Embedding.embed: no placement after " .. MAX_ATTEMPTS .. " attempts: " .. lastError, 2)
end

-- Structural checks. Overlap and coverage now; port agreement and headroom
-- belong to M10 once fills exist.
function Embedding.validate(plan: any): { string }
	local problems: { string } = {}
	local placed: { any } = {}

	if plan.floorHeight == nil or plan.floorHeight < MIN_FLOOR or plan.floorHeight > MAX_FLOOR then
		table.insert(problems, "floorHeight out of range")
	end

	for _, node in ipairs(plan.nodes) do
		if node.x == nil or node.z == nil then
			table.insert(problems, "node " .. tostring(node.id) .. " is unplaced")
		else
			if node.y ~= node.level * (plan.floorHeight or 0) then
				table.insert(problems, "node " .. tostring(node.id) .. " is off its level")
			end
			if node.rotation ~= nil and (node.rotation < 0 or node.rotation > 3) then
				table.insert(problems, "node " .. tostring(node.id) .. " has an invalid rotation")
			end
			if overlaps(placed, node) then
				table.insert(problems, "node " .. tostring(node.id) .. " overlaps another node")
			end
			table.insert(placed, node)
		end
	end

	return problems
end

return Embedding
