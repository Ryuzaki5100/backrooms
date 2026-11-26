--!strict

local H = require("../harness")
local ChunkLayout = require("../../src/shared/procgen/grid/ChunkLayout")
local WalkGraph = require("../../src/shared/procgen/grid/WalkGraph")
local OpenAdditive = require("../../src/shared/procgen/strategies/OpenAdditive")
local Level0 = require("../../src/config/levels/Level_0")

local function clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value) do
		copy[k] = clone(v)
	end
	return copy
end

local function demo(seed: number, terrain: any?): any
	local config = clone(Level0)
	config.world = clone(Level0.world)
	config.world.worldSizeChunks = 3
	config.world.boundaryMode = "wrap"
	if terrain ~= nil then
		config.strategy = clone(Level0.strategy)
		config.strategy.params = clone(Level0.strategy.params)
		config.strategy.params.terrain = terrain
	end
	return OpenAdditive.world(config, seed)
end

local function flat(n: number): any
	local layout = ChunkLayout.new(0, 0, n, 16)
	for index = 1, n * n do
		layout.height[index] = 12
	end
	return layout
end

local function at(layout: any, i: number, j: number): number
	return ChunkLayout.index(layout.n, i, j)
end

local function hasEdge(graph: any, a: number, b: number): boolean
	return table.find(graph.adj[a] or {}, b) ~= nil and table.find(graph.adj[b] or {}, a) ~= nil
end

-- Reference: flood fill over sealed faces on non-solid, non-template cells.
local function referenceSizes(layout: any): { number }
	local n = layout.n
	local seen: { [number]: boolean } = {}
	local sizes = {}
	local function usable(index: number): boolean
		return not layout.solid[index] and not layout.templateCell[index]
	end
	for start = 1, n * n do
		if usable(start) and not seen[start] then
			local count = 0
			local stack = { start }
			seen[start] = true
			while #stack > 0 do
				local current = table.remove(stack) :: number
				count += 1
				local i = (current - 1) % n + 1
				local j = (current - 1) // n + 1
				local candidates = {}
				if i < n and not layout.sealedE[current] then
					table.insert(candidates, current + 1)
				end
				if j < n and not layout.sealedS[current] then
					table.insert(candidates, current + n)
				end
				if i > 1 and not layout.sealedE[current - 1] then
					table.insert(candidates, current - 1)
				end
				if j > 1 and not layout.sealedS[current - n] then
					table.insert(candidates, current - n)
				end
				for _, candidate in ipairs(candidates) do
					if usable(candidate) and not seen[candidate] then
						seen[candidate] = true
						table.insert(stack, candidate)
					end
				end
			end
			table.insert(sizes, count)
		end
	end
	table.sort(sizes)
	return sizes
end

local function graphSizes(graph: any): { number }
	local comps = WalkGraph.components(graph)
	local sizes = {}
	for _, comp in ipairs(comps) do
		table.insert(sizes, comp.size)
	end
	table.sort(sizes)
	return sizes
end

H.test("flat Level 0 chunks match a plain flood fill over sealed faces", function()
	for _, seed in ipairs({ 42, 1337 }) do
		local make = demo(seed)
		for cz = 0, 2 do
			for cx = 0, 2 do
				local layout = OpenAdditive.layout(make, cx, cz)
				local expected = referenceSizes(layout)
				local actual = graphSizes(WalkGraph.build(layout))
				H.eq(
					table.concat(actual, ","),
					table.concat(expected, ","),
					string.format("seed %d chunk %d,%d component sizes", seed, cx, cz)
				)
				H.eq(#WalkGraph.unbridgedRises(layout), 0, "flat world has no cliffs")
			end
		end
	end
end)

H.test("a 1-stud step is an edge, a 4-stud rise is not and is reported", function()
	local layout = flat(4)
	layout.floorY[at(layout, 2, 1)] = 1
	layout.floorY[at(layout, 3, 1)] = 5
	local graph = WalkGraph.build(layout)
	H.ok(hasEdge(graph, at(layout, 1, 1), at(layout, 2, 1)), "1-stud step walks")
	H.ok(not hasEdge(graph, at(layout, 2, 1), at(layout, 3, 1)), "4-stud rise does not")
	local found = false
	for _, rise in ipairs(WalkGraph.unbridgedRises(layout)) do
		if rise.a == at(layout, 2, 1) and rise.b == at(layout, 3, 1) then
			found = true
			H.eq(rise.axis, "E")
			H.eq(rise.rise, 4)
		end
	end
	H.ok(found, "the open 4-stud face is reported")
	local relaxed = WalkGraph.build(layout, { stepMax = 4 })
	H.ok(hasEdge(relaxed, at(layout, 2, 1), at(layout, 3, 1)), "stepMax 4 walks it")
	for _, rise in ipairs(WalkGraph.unbridgedRises(layout, { stepMax = 4 })) do
		H.ok(rise.rise > 4, "a larger stepMax relaxes the report")
	end
end)

H.test("a sealed rise is a wall, not a cliff", function()
	local layout = flat(4)
	layout.floorY[at(layout, 2, 1)] = 4
	ChunkLayout.seal(layout, "E", 1, 1, true)
	ChunkLayout.seal(layout, "E", 2, 1, true)
	ChunkLayout.seal(layout, "S", 2, 1, true)
	H.eq(#WalkGraph.unbridgedRises(layout), 0)
end)

local AXES = {
	{ axis = "x", dir = 1 },
	{ axis = "x", dir = -1 },
	{ axis = "z", dir = 1 },
	{ axis = "z", dir = -1 },
}

-- A ramp at the centre of a 5x5 chunk. Returns the layout and the indices of
-- the ramp, its high-end neighbour, its low-end neighbour and its two sides.
local function rampLayout(axis: string, dir: number): (any, number, number, number, number, number)
	local layout = flat(5)
	local ci, cj = 3, 3
	local function offset(along: number, across: number): number
		if axis == "x" then
			return at(layout, ci + along, cj + across)
		end
		return at(layout, ci + across, cj + along)
	end
	-- The ramp stands on the high side: its own floor is highY, as is the cell
	-- at its high end. The cell at its low end is on the lower floor.
	for index = 1, 25 do
		layout.floorY[index] = 4
	end
	layout.floorY[offset(-dir, 0)] = 0
	layout.ramp[at(layout, ci, cj)] = { axis = axis, dir = dir, lowY = 0, highY = 4 }
	return layout, at(layout, ci, cj), offset(dir, 0), offset(-dir, 0), offset(0, -1), offset(0, 1)
end

H.test("a ramp joins its high and low neighbours in both directions", function()
	for _, spec in ipairs(AXES) do
		local layout, ramp, high, low = rampLayout(spec.axis, spec.dir)
		local label = spec.axis .. spec.dir
		local graph = WalkGraph.build(layout)
		H.ok(hasEdge(graph, ramp, high), label .. " high end")
		H.ok(hasEdge(graph, ramp, low), label .. " low end")
		H.ok(WalkGraph.reachableFrom(graph, high)[low] == true, label .. " high reaches low")
		H.ok(WalkGraph.reachableFrom(graph, low)[high] == true, label .. " low reaches high")
		local tagged = false
		for _, edge in ipairs(graph.edges) do
			if (edge.a == ramp or edge.b == ramp) and edge.kind == "ramp" then
				tagged = true
			end
		end
		H.ok(tagged, label .. " ramp edges are tagged")
		-- The low cell is a one-cell pit, so its three other faces are cliffs; the
		-- ramp's own face must not be one of them.
		local rises = WalkGraph.unbridgedRises(layout)
		H.eq(#rises, 3, label .. " only the pit's other faces")
		for _, rise in ipairs(rises) do
			H.ok(rise.a ~= ramp and rise.b ~= ramp, label .. " the ramp bridges the drop")
		end
	end
end)

H.test("a ramp end only meets a floor at the matching height", function()
	for _, spec in ipairs(AXES) do
		local layout, ramp, high, low = rampLayout(spec.axis, spec.dir)
		-- Swap the neighbours' heights: now neither end meets its floor.
		layout.floorY[high] = 0
		layout.floorY[low] = 4
		local graph = WalkGraph.build(layout)
		H.ok(not hasEdge(graph, ramp, high), spec.axis .. spec.dir .. " high end at wrong Y")
		H.ok(not hasEdge(graph, ramp, low), spec.axis .. spec.dir .. " low end at wrong Y")
	end
end)

H.test("a ramp's side faces do not connect to a flat neighbour", function()
	for _, spec in ipairs(AXES) do
		local layout, ramp, _, _, sideA, sideB = rampLayout(spec.axis, spec.dir)
		local label = spec.axis .. spec.dir
		local graph = WalkGraph.build(layout)
		H.ok(not hasEdge(graph, ramp, sideA), label .. " side A")
		H.ok(not hasEdge(graph, ramp, sideB), label .. " side B")
		-- A neighbouring ramp with identical geometry does connect sideways.
		layout.ramp[sideA] = clone(layout.ramp[ramp])
		local twin = WalkGraph.build(layout)
		H.ok(hasEdge(twin, ramp, sideA), label .. " twin ramp")
		H.ok(not hasEdge(twin, ramp, sideB), label .. " still blocked on B")
	end
end)

H.test("two ramps meeting at the same height connect end to end", function()
	local layout = flat(5)
	for index = 1, 25 do
		layout.floorY[index] = 4
	end
	-- A valley: both ramps stand on high ground, their low ends touch the middle.
	local left, middle, right = at(layout, 2, 3), at(layout, 3, 3), at(layout, 4, 3)
	layout.floorY[middle] = 0
	layout.ramp[left] = { axis = "x", dir = -1, lowY = 0, highY = 4 }
	layout.ramp[right] = { axis = "x", dir = 1, lowY = 0, highY = 4 }
	local graph = WalkGraph.build(layout)
	H.ok(hasEdge(graph, left, middle), "left ramp low end meets the valley")
	H.ok(hasEdge(graph, right, middle), "right ramp low end meets the valley")
	-- The valley floor is still a cliff to the cells above and below it.
	H.eq(#WalkGraph.unbridgedRises(layout), 2, "only the valley's north and south faces")
end)

H.test("sealed faces are never edges, template cells are not nodes", function()
	local layout = flat(4)
	ChunkLayout.seal(layout, "E", 1, 1, true)
	ChunkLayout.seal(layout, "S", 2, 2, true)
	layout.templateCell[at(layout, 4, 4)] = true
	layout.solid[at(layout, 3, 3)] = true
	local graph = WalkGraph.build(layout)
	H.ok(not hasEdge(graph, at(layout, 1, 1), at(layout, 2, 1)), "sealed E")
	H.ok(not hasEdge(graph, at(layout, 2, 2), at(layout, 2, 3)), "sealed S")
	H.ok(hasEdge(graph, at(layout, 1, 1), at(layout, 1, 2)), "unsealed S")
	H.eq(graph.walkable[at(layout, 4, 4)], false, "template cell is not walkable")
	H.eq(graph.adj[at(layout, 4, 4)], nil, "template cell has no adjacency")
	H.eq(graph.walkable[at(layout, 3, 3)], false, "solid cell is not walkable")
	for _, edge in ipairs(graph.edges) do
		H.ok(edge.a ~= at(layout, 4, 4) and edge.b ~= at(layout, 4, 4), "no edge into a template")
		H.ok(edge.a ~= at(layout, 3, 3) and edge.b ~= at(layout, 3, 3), "no edge into solid")
	end
	local total = 0
	for _, size in ipairs(graphSizes(graph)) do
		total += size
	end
	H.eq(total, 14, "16 cells less one solid and one template")
end)

H.test("border faces are not traversed", function()
	local layout = flat(3)
	-- Border-owned faces stay unsealed: a chunk must not decide them.
	local graph = WalkGraph.build(layout)
	H.eq(#graph.edges, 12, "a 3x3 grid has 12 interior faces")
	H.eq(#graph.adj[at(layout, 1, 1)], 2, "a corner has two neighbours")
	H.eq(#graph.adj[at(layout, 2, 1)], 3, "an edge cell has three neighbours")
	H.eq(#graph.adj[at(layout, 2, 2)], 4, "the centre has four")
	-- A rise across the border is invisible to the chunk.
	layout.outFloorE[2] = 40
	layout.outFloorS[2] = 40
	H.eq(#WalkGraph.unbridgedRises(layout), 0, "border rises are not reported")
end)

H.test("real Terrain ramps are traversable both ways", function()
	local terrain = {
		rise = 4,
		plateauShare = 0.15,
		sunkenShare = 0.15,
		rampChance = 0.30,
		minHeadroom = 9,
	}
	local checked, totalRamps = 0, 0
	for _, seed in ipairs({ 42, 1337 }) do
		local make = demo(seed, terrain)
		local seedCliffs, seedRamps = 0, 0
		for cz = 0, 2 do
			for cx = 0, 2 do
				local layout = OpenAdditive.layout(make, cx, cz)
				local n = layout.n
				local graph = WalkGraph.build(layout)
				for index = 1, n * n do
					local ramp = layout.ramp[index]
					if ramp ~= nil then
						seedRamps += 1
						local i = (index - 1) % n + 1
						local j = (index - 1) // n + 1
						local di = if ramp.axis == "x" then ramp.dir else 0
						local dj = if ramp.axis == "z" then ramp.dir else 0
						-- The low end is at -dir. Skip it when it leaves the chunk.
						local li, lj = i - di, j - dj
						if li >= 1 and lj >= 1 and li <= n and lj <= n then
							local low = at(layout, li, lj)
							if graph.walkable[low] and graph.walkable[index] then
								local owner = math.min(index, low)
								local sealed = if ramp.axis == "x"
									then layout.sealedE[owner]
									else layout.sealedS[owner]
								H.ok(not sealed, "Terrain opened the ramp's low face")
								H.eq(
									layout.floorY[low],
									ramp.lowY,
									"low neighbour is on the low floor"
								)
								H.ok(hasEdge(graph, index, low), "ramp low end is an edge")
								H.ok(
									WalkGraph.reachableFrom(graph, index)[low] == true
										and WalkGraph.reachableFrom(graph, low)[index] == true,
									"ramp is reachable both ways"
								)
								checked += 1
							end
						end
					end
				end
				for _, edge in ipairs(graph.edges) do
					if edge.kind == "face" then
						H.ok(
							math.abs(layout.floorY[edge.a] - layout.floorY[edge.b]) <= 1,
							"a plain face edge is at most one step"
						)
					end
				end
				seedCliffs += #WalkGraph.unbridgedRises(layout)
			end
		end
		print(
			string.format(
				"  [walkgraph] seed %d, terrain bands on: %d ramps, %d unbridged rises over 9 chunks",
				seed,
				seedRamps,
				seedCliffs
			)
		)
		totalRamps += seedRamps
	end
	H.ok(totalRamps > 0, "terrain produced ramps")
	H.ok(checked > 0, "at least one ramp was checked end to end")
end)
