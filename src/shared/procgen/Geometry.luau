--!strict

-- Geometry description: turn an embedded plan into a list of boxes.
--
-- Pure — no Roblox APIs — so it runs under Lune and is hashable. `Build.luau`
-- only applies these boxes (ADR 0011).
--
-- Wall rule (the leak fix): every face is covered by intervals.
--
--   * a face's span is split into the parts shared with neighbours and the rest;
--   * the node builds walls over "the rest";
--   * each edge builds a wall over exactly its shared interval, with the door
--     opening in it.
--
-- That way a boundary is built once, no part of any face is left open, and two
-- differently sized rooms touching along one wall cannot leave a gap. It also
-- removes the old "a side is shared, so skip it" assumption, which leaked
-- whenever the neighbour was narrower.
--
-- No vertical placeholder geometry: v1 content is single-floor (ADR 0016), and
-- real connectors are M08b.

local Hash = if script ~= nil then require(script.Parent.Hash) else require("./Hash")

local Geometry = {}

local MIN_OPENING = 2

local SIDES = { "N", "E", "S", "W" }

local DEFAULT_STYLE = {
	wallThickness = 1,
	budget = { parts = 1200 },
	materials = {
		wall = { material = "Concrete", color = { 0.52, 0.5, 0.44 } },
		floor = { material = "Fabric", color = { 0.33, 0.3, 0.24 } },
		ceiling = { material = "SmoothPlastic", color = { 0.78, 0.77, 0.7 } },
		trim = { material = "Wood", color = { 0.28, 0.23, 0.18 } },
	},
}

local function pick(value: any, fallback: any): any
	return if value == nil then fallback else value
end

local function styleOf(options: any): any
	local s = (options and options.style) or {}
	local materials = s.materials or {}
	local defaults = DEFAULT_STYLE.materials
	return {
		wallThickness = pick(s.wallThickness, DEFAULT_STYLE.wallThickness),
		budget = pick(s.budget and s.budget.parts, DEFAULT_STYLE.budget.parts),
		materials = {
			wall = materials.wall or defaults.wall,
			floor = materials.floor or defaults.floor,
			ceiling = materials.ceiling or defaults.ceiling,
			trim = materials.trim or defaults.trim,
		},
	}
end

local function box(
	parts: { any },
	kind: string,
	owner: string,
	size: { number },
	position: { number },
	material: any,
	extra: any?
): ()
	local part = {
		kind = kind,
		owner = owner,
		size = size,
		position = position,
		yaw = 0,
		pitch = 0,
		material = material.material,
		color = material.color,
		canCollide = true,
	}
	if extra ~= nil then
		for key, value in pairs(extra) do
			part[key] = value
		end
	end
	table.insert(parts, part)
end

-- Interval helpers -----------------------------------------------------------

local function complement(
	span: number,
	intervals: { { start: number, len: number } }
): { { start: number, len: number } }
	table.sort(intervals, function(a, b)
		return a.start < b.start
	end)
	local gaps = {}
	local cursor = 0
	for _, interval in ipairs(intervals) do
		local start = math.max(cursor, interval.start)
		if start > cursor then
			table.insert(gaps, { start = cursor, len = start - cursor })
		end
		cursor = math.max(cursor, interval.start + interval.len)
	end
	if cursor < span then
		table.insert(gaps, { start = cursor, len = span - cursor })
	end
	return gaps
end

local function faceSpan(node: any, side: string): number
	if side == "N" or side == "S" then
		return node.w
	end
	return node.d
end

local function faceOrigin(node: any, side: string): number
	if side == "N" or side == "S" then
		return node.x
	end
	return node.z
end

-- Where a neighbour sits on this node's face, relative to the face origin.
local function overlapOn(node: any, side: string, other: any): (number?, number?)
	local origin = faceOrigin(node, side)
	local span = faceSpan(node, side)
	local otherOrigin = faceOrigin(other, side)
	local otherSpan = faceSpan(other, side)
	local start = math.max(origin, otherOrigin)
	local finish = math.min(origin + span, otherOrigin + otherSpan)
	local len = finish - start
	if len < MIN_OPENING then
		return nil, nil
	end
	return start - origin, len
end

-- Wall boxes -----------------------------------------------------------------

-- One wall slice on `side`, spanning [start, start+len] of the face and
-- [bottom, top] vertically.
local function wallSlice(
	parts: { any },
	owner: string,
	node: any,
	side: string,
	start: number,
	len: number,
	bottom: number,
	top: number,
	thickness: number,
	material: any
): ()
	if len <= 0 or top <= bottom then
		return
	end
	local centre = start + len / 2
	local y = node.y + (bottom + top) / 2
	local sizeX = if side == "N" or side == "S" then len else thickness
	local sizeZ = if side == "N" or side == "S" then thickness else len
	local x = if side == "N" or side == "S" then node.x + centre else node.x
	local z = if side == "N" or side == "S" then node.z else node.z + centre
	if side == "N" then
		z = node.z
	elseif side == "S" then
		z = node.z + node.d
	elseif side == "W" then
		x = node.x
	elseif side == "E" then
		x = node.x + node.w
	end
	box(parts, "wall", owner, { sizeX, top - bottom, sizeZ }, { x, y, z }, material)
end

local function solidWall(
	parts: { any },
	owner: string,
	node: any,
	side: string,
	start: number,
	len: number,
	thickness: number,
	material: any
): ()
	wallSlice(parts, owner, node, side, start, len, 0, node.h, thickness, material)
end

-- A shared wall over one overlap interval, with the doorway cut in the middle.
local function doorway(
	parts: { any },
	owner: string,
	node: any,
	side: string,
	start: number,
	len: number,
	thickness: number,
	material: any,
	opening: any
): ()
	local width = math.min(opening.width, len - 2 * MIN_OPENING)
	if width < MIN_OPENING then
		-- Too narrow for a door: build a solid wall rather than leak.
		solidWall(parts, owner, node, side, start, len, thickness, material)
		return
	end
	local height = math.min(opening.height, node.h)
	local sill = math.max(0, math.min(opening.elevation or 0, node.h - height))
	local doorStart = start + (len - width) / 2

	wallSlice(parts, owner, node, side, start, doorStart - start, 0, node.h, thickness, material)
	wallSlice(
		parts,
		owner,
		node,
		side,
		doorStart + width,
		start + len - (doorStart + width),
		0,
		node.h,
		thickness,
		material
	)
	wallSlice(
		parts,
		owner,
		node,
		side,
		doorStart,
		width,
		sill + height,
		node.h,
		thickness,
		material
	)
	if sill > 0 then
		wallSlice(parts, owner, node, side, doorStart, width, 0, sill, thickness, material)
	end
end

-- Slabs ----------------------------------------------------------------------

local function emitSlab(
	parts: { any },
	owner: string,
	kind: string,
	node: any,
	thickness: number,
	material: any
): ()
	local y = if kind == "floor" then node.y + thickness / 2 else node.y + node.h - thickness / 2
	box(
		parts,
		kind,
		owner,
		{ node.w, thickness, node.d },
		{ node.x + node.w / 2, y, node.z + node.d / 2 },
		material
	)
end

-- Description ----------------------------------------------------------------

function Geometry.describe(plan: any, options: any?): { any }
	local style = styleOf(options)
	local debug = options ~= nil and options.debug == true
	local parts: { any } = {}
	local nodesById: { [number]: any } = {}

	for _, node in ipairs(plan.nodes) do
		nodesById[node.id] = node
	end

	-- Gather shared intervals per node and side.
	local shared: { [string]: { any } } = {}
	for _, edge in ipairs(plan.edges) do
		local a = nodesById[edge.a]
		local b = nodesById[edge.b]
		if a ~= nil and b ~= nil and a.level == b.level then
			local aPort = a.ports[edge.aPort]
			local bPort = b.ports[edge.bPort]
			if aPort ~= nil and bPort ~= nil then
				-- BOTH endpoints must know the face is shared. Registering only `a`
				-- let `b` build a solid wall across its own face, sealing every
				-- doorway from the far side.
				local pairsToRegister = {
					{ node = a, side = aPort.side, other = b, port = aPort, otherPort = bPort },
					{ node = b, side = bPort.side, other = a, port = bPort, otherPort = aPort },
				}
				for _, pair in ipairs(pairsToRegister) do
					local key = pair.node.id .. ":" .. pair.side
					shared[key] = shared[key] or {}
					local start, len = overlapOn(pair.node, pair.side, pair.other)
					if start ~= nil and len ~= nil then
						table.insert(shared[key], {
							start = start,
							len = len,
							edge = edge,
							port = pair.port,
							otherPort = pair.otherPort,
						})
					end
				end
			end
		end
	end

	-- Node walls: the complement of its shared intervals on each side.
	for _, node in ipairs(plan.nodes) do
		local owner = "node:" .. tostring(node.id)
		emitSlab(parts, owner, "floor", node, style.wallThickness, style.materials.floor)
		emitSlab(parts, owner, "ceiling", node, style.wallThickness, style.materials.ceiling)

		for _, side in ipairs(SIDES) do
			local span = faceSpan(node, side)
			local intervals = shared[node.id .. ":" .. side] or {}
			local occupied = {}
			for _, interval in ipairs(intervals) do
				table.insert(occupied, { start = interval.start, len = interval.len })
			end
			for _, gap in ipairs(complement(span, occupied)) do
				solidWall(
					parts,
					owner,
					node,
					side,
					gap.start,
					gap.len,
					style.wallThickness,
					style.materials.wall
				)
			end
		end
	end

	-- Edge walls: exactly the shared interval, with the doorway in it.
	for _, edge in ipairs(plan.edges) do
		local a = nodesById[edge.a]
		local b = nodesById[edge.b]
		if a ~= nil and b ~= nil and a.level == b.level then
			local aPort = a.ports[edge.aPort]
			local bPort = b.ports[edge.bPort]
			if aPort ~= nil and bPort ~= nil then
				local start, len = overlapOn(a, aPort.side, b)
				if start ~= nil and len ~= nil then
					doorway(
						parts,
						"edge:" .. tostring(edge.id),
						a,
						aPort.side,
						start,
						len,
						style.wallThickness,
						style.materials.wall,
						{
							width = math.min(aPort.width, bPort.width),
							height = math.min(aPort.height, bPort.height),
							elevation = math.min(aPort.elevation, bPort.elevation),
						}
					)
				end
			end
		end
	end

	-- QA-only markers (ADR 0011). Never part of a production description.
	if debug then
		local spawn = nodesById[plan.spawn.nodeId]
		if spawn ~= nil then
			box(
				parts,
				"marker",
				"spawn",
				{ 2, 2, 2 },
				{ spawn.x + spawn.w / 2, spawn.y + 3, spawn.z + spawn.d / 2 },
				{ material = "Neon", color = { 0.2, 1, 0.4 } },
				{ canCollide = false, tag = "qa" }
			)
		end
		for _, exit in ipairs(plan.exits) do
			local host = exit.anchor.hostNode and nodesById[exit.anchor.hostNode]
			if host ~= nil then
				box(
					parts,
					"marker",
					"exit:" .. tostring(exit.id),
					{ 1.5, 1.5, 1.5 },
					{ host.x + host.w / 2, host.y + host.h - 2, host.z + host.d / 2 },
					{ material = "Neon", color = { 1, 0.4, 0.2 } },
					{ canCollide = false, tag = "qa" }
				)
			end
		end
	end

	if #parts > style.budget then
		error(
			string.format(
				"Geometry.describe: %d parts exceeds the budget of %d",
				#parts,
				style.budget
			),
			2
		)
	end

	return parts
end

-- Doorway volumes, in world coordinates. Used by QA to assert that an opening
-- is actually open (nothing walls it over) and that it fits a character.
function Geometry.openings(plan: any, options: any?): { any }
	local style = styleOf(options)
	local openings = {}
	local nodesById: { [number]: any } = {}
	for _, node in ipairs(plan.nodes) do
		nodesById[node.id] = node
	end

	for _, edge in ipairs(plan.edges) do
		local a = nodesById[edge.a]
		local b = nodesById[edge.b]
		if a ~= nil and b ~= nil and a.level == b.level then
			local aPort = a.ports[edge.aPort]
			local bPort = b.ports[edge.bPort]
			if aPort ~= nil and bPort ~= nil then
				local start, len = overlapOn(a, aPort.side, b)
				if start ~= nil and len ~= nil then
					-- Same clamp the wall cutter applies, or the QA box and the
					-- real hole disagree.
					local width = math.min(aPort.width, len - 2 * MIN_OPENING)
					local height = math.min(aPort.height, a.h)
					local sill = math.max(0, math.min(aPort.elevation or 0, a.h - height))
					local doorStart = start + (len - width) / 2
					local side = aPort.side
					local t = style.wallThickness
					local rect = nil
					if side == "N" or side == "S" then
						local z = if side == "N" then a.z else a.z + a.d
						rect = {
							minX = a.x + doorStart,
							maxX = a.x + doorStart + width,
							minZ = z - t / 2,
							maxZ = z + t / 2,
							minY = a.y + sill,
							maxY = a.y + sill + height,
						}
					else
						local x = if side == "W" then a.x else a.x + a.w
						rect = {
							minX = x - t / 2,
							maxX = x + t / 2,
							minZ = a.z + doorStart,
							maxZ = a.z + doorStart + width,
							minY = a.y + sill,
							maxY = a.y + sill + height,
						}
					end
					if width >= MIN_OPENING then
						table.insert(openings, {
							edgeId = edge.id,
							nodeId = a.id,
							side = side,
							width = width,
							height = height,
							box = rect,
						})
					end
				end
			end
		end
	end
	return openings
end

function Geometry.fingerprint(parts: { any }): string
	local lines = {}
	for _, part in ipairs(parts) do
		table.insert(
			lines,
			table.concat({
				part.kind,
				part.owner,
				tostring(part.size[1]),
				tostring(part.size[2]),
				tostring(part.size[3]),
				tostring(part.position[1]),
				tostring(part.position[2]),
				tostring(part.position[3]),
				tostring(part.yaw),
				tostring(part.pitch),
				part.material,
				tostring(part.tag or ""),
			}, "|")
		)
	end
	return Hash.of(table.concat(lines, "\n"))
end

return Geometry
