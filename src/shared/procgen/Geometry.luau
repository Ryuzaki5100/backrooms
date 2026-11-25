--!strict

-- Geometry description: turn an embedded plan into a list of boxes.
--
-- Deliberately pure — no Roblox APIs — so it runs under Lune, is hashable, and
-- can be asserted on without a DataModel. `Build.luau` is the thin layer that
-- turns these boxes into Parts (ADR 0011).
--
-- Ownership rule (the double-wall fix): a boundary shared by two nodes is owned
-- by the EDGE and built once. A node only builds walls on sides it does not
-- share. Result: exactly one wall per boundary, one opening, no tunnel.
--
-- Variables that belong to a level's art (materials, wall thickness, opening
-- sizes, budget) come from `config.style`; M17 replaces the provisional defaults
-- below with the authored schema. The field names are the contract.

local Hash = if script ~= nil then require(script.Parent.Hash) else require("./Hash")

local Geometry = {}

local SIDES = { "N", "E", "S", "W" }
local INDEX = { N = 1, E = 2, S = 3, W = 4 }

-- Provisional style defaults. Field names are the contract (M17 fills them).
local DEFAULT_STYLE = {
	wallThickness = 1,
	budget = { parts = 800 },
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

local function effectiveSide(side: string, rotation: number): string
	local start = INDEX[side]
	if start == nil then
		return side
	end
	return SIDES[((start - 1 + rotation) % 4) + 1]
end

local function worldExtents(node: any): (number, number)
	if (node.rotation or 0) % 2 == 0 then
		return node.w, node.d
	end
	return node.d, node.w
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

-- A wall on one face of a node, cut around a centred opening.
local function emitWall(
	parts: { any },
	owner: string,
	worldSide: string,
	node: any,
	thickness: number,
	material: any,
	opening: any? -- { width, height, elevation }
): ()
	local W, D = worldExtents(node)
	local width = if worldSide == "N" or worldSide == "S" then W else D
	local height = node.h
	local minX, minZ = node.x, node.z

	local function segment(start: number, length: number, bottom: number, top: number)
		if length <= 0 or top <= bottom then
			return
		end
		local center = start + length / 2
		local y = node.y + (bottom + top) / 2
		local sizeX = if worldSide == "N" or worldSide == "S" then length else thickness
		local sizeZ = if worldSide == "N" or worldSide == "S" then thickness else length
		local x = if worldSide == "N" or worldSide == "S" then minX + center else minX
		local z = if worldSide == "N" or worldSide == "S" then minZ else minZ + center
		if worldSide == "N" then
			z = minZ
		elseif worldSide == "S" then
			z = minZ + D
		elseif worldSide == "W" then
			x = minX
		elseif worldSide == "E" then
			x = minX + W
		end
		box(parts, "wall", owner, { sizeX, top - bottom, sizeZ }, { x, y, z }, material)
	end

	if opening == nil then
		-- Whole wall, thickness centred on the face plane.
		segment(0, width, 0, height)
		return
	end

	local w = math.min(opening.width, width)
	local h = math.min(opening.height, height)
	local sill = math.max(0, math.min(opening.elevation or 0, height - h))
	local start = (width - w) / 2

	segment(0, start, 0, height)
	segment(start + w, width - (start + w), 0, height)
	segment(start, w, sill + h, height) -- header
	if sill > 0 then
		segment(start, w, 0, sill) -- sill / parapet
	end
end

-- A floor or ceiling slab, optionally with one centred hole.
local function emitSlab(
	parts: { any },
	owner: string,
	kind: string,
	node: any,
	thickness: number,
	material: any,
	hole: any? -- { width }
): ()
	local W, D = worldExtents(node)
	local y = if kind == "floor" then node.y + thickness / 2 else node.y + node.h - thickness / 2
	local minX, minZ = node.x, node.z

	if hole == nil then
		box(parts, kind, owner, { W, thickness, D }, { minX + W / 2, y, minZ + D / 2 }, material)
		return
	end

	local hw = math.min(hole.width, W)
	local hd = math.min(hole.width, D)
	local westEdge = (W - hw) / 2
	local eastEdge = (W + hw) / 2
	local northEdge = (D - hd) / 2
	local southEdge = (D + hd) / 2

	-- North and south strips span the full width.
	box(
		parts,
		kind,
		owner,
		{ W, thickness, northEdge },
		{ minX + W / 2, y, minZ + northEdge / 2 },
		material
	)
	box(
		parts,
		kind,
		owner,
		{ W, thickness, D - southEdge },
		{ minX + W / 2, y, minZ + (D + southEdge) / 2 },
		material
	)
	-- East and west strips fill the hole's depth only.
	box(
		parts,
		kind,
		owner,
		{ westEdge, thickness, hd },
		{ minX + westEdge / 2, y, minZ + D / 2 },
		material
	)
	box(
		parts,
		kind,
		owner,
		{ W - eastEdge, thickness, hd },
		{ minX + (W + eastEdge) / 2, y, minZ + D / 2 },
		material
	)
end

local function partCount(parts: { any }): number
	return #parts
end

function Geometry.describe(plan: any, options: any?): { any }
	local style = styleOf(options)
	local debug = options ~= nil and options.debug == true
	local parts: { any } = {}
	local nodesById: { [number]: any } = {}
	local sharedSides: { [string]: boolean } = {}

	for _, node in ipairs(plan.nodes) do
		nodesById[node.id] = node
	end

	-- Which local sides are shared (owned by an edge)?
	local verticalPorts: { [number]: any } = {}
	for _, edge in ipairs(plan.edges) do
		local a = nodesById[edge.a]
		local b = nodesById[edge.b]
		if a ~= nil and b ~= nil then
			local aPort = a.ports[edge.aPort]
			local bPort = b.ports[edge.bPort]
			if aPort ~= nil and bPort ~= nil then
				if a.level == b.level then
					sharedSides[a.id .. ":" .. aPort.side] = true
					sharedSides[b.id .. ":" .. bPort.side] = true
				else
					local lower = if a.level < b.level then a else b
					local lowerPort = if lower == a then aPort else bPort
					verticalPorts[lower.id] = lowerPort
				end
			end
		end
	end

	-- Shells: floor, ceiling, and the walls this node owns.
	for _, node in ipairs(plan.nodes) do
		local owner = "node:" .. tostring(node.id)
		local hole = verticalPorts[node.id]
		emitSlab(parts, owner, "floor", node, style.wallThickness, style.materials.floor, hole)
		emitSlab(parts, owner, "ceiling", node, style.wallThickness, style.materials.ceiling, hole)
		for _, side in ipairs(SIDES) do
			if not sharedSides[node.id .. ":" .. side] then
				emitWall(
					parts,
					owner,
					effectiveSide(side, node.rotation or 0),
					node,
					style.wallThickness,
					style.materials.wall,
					nil
				)
			end
		end
	end

	-- Edges own their shared walls: exactly one per boundary.
	for _, edge in ipairs(plan.edges) do
		local a = nodesById[edge.a]
		local b = nodesById[edge.b]
		if a ~= nil and b ~= nil and a.level == b.level then
			local aPort = a.ports[edge.aPort]
			local bPort = b.ports[edge.bPort]
			if aPort ~= nil and bPort ~= nil then
				local side = effectiveSide(aPort.side, a.rotation or 0)
				local opening = {
					width = math.min(aPort.width, bPort.width),
					height = math.min(aPort.height, bPort.height),
					elevation = math.min(aPort.elevation, bPort.elevation),
				}
				emitWall(
					parts,
					"edge:" .. tostring(edge.id),
					side,
					a,
					style.wallThickness,
					style.materials.wall,
					opening
				)
			end
		end
	end

	-- Vertical links: a placeholder ramp, explicitly temporary (M08b replaces).
	for _, edge in ipairs(plan.edges) do
		local a = nodesById[edge.a]
		local b = nodesById[edge.b]
		if a ~= nil and b ~= nil and a.level ~= b.level then
			local lower = if a.level < b.level then a else b
			local upper = if lower == a then b else a
			local rise = upper.y - lower.y
			if rise > 0 then
				local run = math.max(8, rise * 1.4)
				local thick = 1
				local centerX = lower.x + select(1, worldExtents(lower)) / 2 + run / 2
				local centerZ = lower.z + select(2, worldExtents(lower)) / 2
				local pitch = -math.deg(math.atan2(rise, run))
				box(
					parts,
					"ramp",
					"edge:" .. tostring(edge.id),
					{ math.sqrt(run * run + rise * rise), thick, 6 },
					{ centerX, lower.y + rise / 2, centerZ },
					style.materials.trim,
					{ pitch = pitch, tag = "placeholder" }
				)
			end
		end
	end

	-- QA-only markers. Never part of a production description (ADR 0011).
	if debug then
		local spawn = nodesById[plan.spawn.nodeId]
		if spawn ~= nil then
			local W, D = worldExtents(spawn)
			box(
				parts,
				"marker",
				"spawn",
				{ 2, 2, 2 },
				{ spawn.x + W / 2, spawn.y + 3, spawn.z + D / 2 },
				{ material = "Neon", color = { 0.2, 1, 0.4 } },
				{ canCollide = false, tag = "qa" }
			)
		end
		for _, exit in ipairs(plan.exits) do
			local host = exit.anchor.hostNode and nodesById[exit.anchor.hostNode]
			if host ~= nil then
				local W, D = worldExtents(host)
				box(
					parts,
					"marker",
					"exit:" .. tostring(exit.id),
					{ 1.5, 1.5, 1.5 },
					{ host.x + W / 2, host.y + host.h - 2, host.z + D / 2 },
					{ material = "Neon", color = { 1, 0.4, 0.2 } },
					{ canCollide = false, tag = "qa" }
				)
			end
		end
	end

	if partCount(parts) > style.budget then
		error(
			string.format(
				"Geometry.describe: %d parts exceeds the budget of %d",
				partCount(parts),
				style.budget
			),
			2
		)
	end

	return parts
end

-- Deterministic fingerprint of a description, so Lune and Studio can be compared.
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
