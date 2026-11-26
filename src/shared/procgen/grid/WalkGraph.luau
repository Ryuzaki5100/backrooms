--!strict

-- Walk graph (M23a, ADR 0031 D60/D62): height-aware reachability over one
-- chunk. Pure, no Roblox services.
--
-- A `ChunkLayout.Layout` says where walls are and how high each floor sits, but
-- not where a player can actually walk. This module answers that: nodes are
-- cells, edges are traversable faces, and a face only counts when the floor
-- levels on its two sides meet (a step, or a ramp end). Stairs, drops and lifts
-- (D60) are appended later as new `kind`s on `edges`; the graph shape does not
-- change.
--
-- API
--   WalkGraph.build(layout, opts?) -> Graph
--   WalkGraph.components(graph) -> (comps, compId)
--   WalkGraph.reachableFrom(graph, index) -> { [index]: true }
--   WalkGraph.unbridgedRises(layout, opts?) -> { { a, b, axis, rise } }
--   opts.stepMax: largest floor difference walked without a ramp (default 1,
--   the same as features/Terrain.luau DEFAULTS.stepMax).
--
--   Graph = {
--     n, walkable: { boolean },        -- by cell index = i + (j - 1) * n
--     adj: { [index]: { index } },     -- one entry per walkable cell
--     edges: { { a, b, kind } },       -- kind = "face" | "ramp"; a < b
--   }
--
-- Nodes: a cell is walkable iff it is not solid and not a template cell.
-- Template cells are excluded because a template footprint has no declared entry
-- faces yet (known limitation: a chunk with a template can hide the template's
-- interior from reachability, and a template can sit between otherwise joined
-- cells). Columns (a 2-stud post in a 16-stud cell) and hanging walls (a crouch
-- gap) do not block.
--
-- Edges: across interior faces only. The E face of (i, j) joins (i + 1, j); the
-- S face of (i, j) joins (i, j + 1). Border faces are never traversed, exactly
-- like OpenAdditive.components, because a chunk must not decide its border.
--   * the face must not be sealed (sealedE / sealedS of the lower-coordinate
--     cell, the owner);
--   * if neither cell is a ramp: |floorY(a) - floorY(b)| <= stepMax ("face");
--   * ramps: a ramp cell stands on the HIGH side and carries
--     { axis = "x"|"z", dir = 1|-1, lowY, highY }. Verified in
--     Terrain.apply: `dir` points towards the HIGH end, i.e. into the plateau
--     the ramp climbs onto. The ramp's HIGH end faces offset +dir along the
--     axis and meets floor highY, and its LOW end faces offset -dir and meets
--     floor lowY (the lower neighbour). Terrain sets dir = -1 when the ramp sits
--     on the west/north cell with the low cell to its east/south, and dir = +1
--     in the mirrored case. Crossing a ramp end is an edge iff the neighbour's floor
--     (its own end Y when it is also a ramp) is within stepMax of that end Y
--     ("ramp").
--   * the side faces of a ramp (perpendicular axis) join only a neighbour ramp
--     with identical axis, dir, lowY and highY ("ramp"); any other neighbour
--     is a drop from a slope and is not an edge.
--
-- unbridgedRises lists the interior faces between walkable cells that are NOT
-- sealed, rise by more than stepMax, and are not edges: the "open cliffs" the
-- renderer leaves blank (ADR 0031 D61/D62).

local LayoutModule = if script ~= nil
	then require(script.Parent.ChunkLayout)
	else require("./ChunkLayout")

local WalkGraph = {}

export type Edge = { a: number, b: number, kind: string }

export type Graph = {
	n: number,
	walkable: { boolean },
	adj: { [number]: { number } },
	edges: { Edge },
}

export type Component = { cells: { number }, size: number }

export type Rise = { a: number, b: number, axis: string, rise: number }

local DEFAULT_STEP_MAX = 1

local function stepMaxOf(opts: any?): number
	if opts ~= nil and opts.stepMax ~= nil then
		return opts.stepMax
	end
	return DEFAULT_STEP_MAX
end

local function isWalkable(layout: any, index: number): boolean
	return not layout.solid[index] and not layout.templateCell[index]
end

-- Floor Y that `index` presents on a face, looking `side` (+1 towards the
-- higher-coordinate neighbour, -1 towards the lower) along `axis` ("x" | "z").
-- nil for the side face of a ramp.
local function presentedY(layout: any, index: number, axis: string, side: number): number?
	local ramp = layout.ramp[index]
	if ramp == nil then
		return layout.floorY[index]
	end
	if ramp.axis ~= axis then
		return nil
	end
	if side == ramp.dir then
		return ramp.highY
	end
	return ramp.lowY
end

local function sameRamp(a: any, b: any): boolean
	return a ~= nil
		and b ~= nil
		and a.axis == b.axis
		and a.dir == b.dir
		and a.lowY == b.lowY
		and a.highY == b.highY
end

-- Whether the face between `a` (lower coordinate) and `b` can be walked, and as
-- what. `axis` is the face axis in layout terms: "E" or "S". Sealing and
-- walkability are the caller's business.
local function crossing(layout: any, a: number, b: number, axis: string, stepMax: number): string?
	local rampA, rampB = layout.ramp[a], layout.ramp[b]
	local faceAxis = if axis == "E" then "x" else "z"
	local ya = presentedY(layout, a, faceAxis, 1)
	local yb = presentedY(layout, b, faceAxis, -1)
	if ya == nil or yb == nil then
		-- A side face of a ramp.
		if sameRamp(rampA, rampB) then
			return "ramp"
		end
		return nil
	end
	if math.abs(ya - yb) > stepMax then
		return nil
	end
	if rampA ~= nil or rampB ~= nil then
		return "ramp"
	end
	return "face"
end

-- Calls fn(a, b, axis) for every interior face, E then S per cell, row-major.
local function eachFace(layout: any, fn: (number, number, string) -> ()): ()
	local n = layout.n
	for j = 1, n do
		for i = 1, n do
			local index = LayoutModule.index(n, i, j)
			if i < n then
				fn(index, index + 1, "E")
			end
			if j < n then
				fn(index, index + n, "S")
			end
		end
	end
end

local function isSealed(layout: any, a: number, axis: string): boolean
	if axis == "E" then
		return layout.sealedE[a] == true
	end
	return layout.sealedS[a] == true
end

function WalkGraph.build(layout: any, opts: any?): Graph
	local stepMax = stepMaxOf(opts)
	local n = layout.n
	local graph: Graph = { n = n, walkable = {}, adj = {}, edges = {} }
	for index = 1, n * n do
		local walkable = isWalkable(layout, index)
		graph.walkable[index] = walkable
		if walkable then
			graph.adj[index] = {}
		end
	end
	eachFace(layout, function(a: number, b: number, axis: string)
		if not graph.walkable[a] or not graph.walkable[b] or isSealed(layout, a, axis) then
			return
		end
		local kind = crossing(layout, a, b, axis, stepMax)
		if kind ~= nil then
			table.insert(graph.edges, { a = a, b = b, kind = kind })
			table.insert(graph.adj[a], b)
			table.insert(graph.adj[b], a)
		end
	end)
	return graph
end

function WalkGraph.components(graph: Graph): ({ Component }, { [number]: number })
	local compId: { [number]: number } = {}
	local list: { Component } = {}
	for start = 1, graph.n * graph.n do
		if graph.walkable[start] and compId[start] == nil then
			local id = #list + 1
			local cells = { start }
			compId[start] = id
			local head = 1
			while head <= #cells do
				local current = cells[head]
				head += 1
				for _, neighbour in ipairs(graph.adj[current]) do
					if compId[neighbour] == nil then
						compId[neighbour] = id
						table.insert(cells, neighbour)
					end
				end
			end
			table.insert(list, { cells = cells, size = #cells })
		end
	end
	return list, compId
end

function WalkGraph.reachableFrom(graph: Graph, index: number): { [number]: boolean }
	local seen: { [number]: boolean } = {}
	if not graph.walkable[index] then
		return seen
	end
	seen[index] = true
	local queue = { index }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, neighbour in ipairs(graph.adj[current]) do
			if not seen[neighbour] then
				seen[neighbour] = true
				table.insert(queue, neighbour)
			end
		end
	end
	return seen
end

function WalkGraph.unbridgedRises(layout: any, opts: any?): { Rise }
	local stepMax = stepMaxOf(opts)
	local result: { Rise } = {}
	eachFace(layout, function(a: number, b: number, axis: string)
		if not isWalkable(layout, a) or not isWalkable(layout, b) or isSealed(layout, a, axis) then
			return
		end
		local rise = math.abs(layout.floorY[a] - layout.floorY[b])
		if rise > stepMax and crossing(layout, a, b, axis, stepMax) == nil then
			table.insert(result, { a = a, b = b, axis = axis, rise = rise })
		end
	end)
	return result
end

return WalkGraph
