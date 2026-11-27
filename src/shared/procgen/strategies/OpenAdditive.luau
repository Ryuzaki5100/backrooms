--!strict

-- open_additive (ADR 0024/0026): start with an open plate, add wall runs and
-- pillars, then remove walls only where a pocket would be unreachable.
--
-- Seam rule: every wall is a pure function of the *shared grid line* and the
-- seed. A block owns the lines east and south of its own cells, so two
-- neighbouring chunks query the same line and get the same answer without
-- reading each other's content. That is what makes generation chunk-order
-- independent and the border invisible.

local Rng = if script ~= nil then require(script.Parent.Parent.Rng) else require("../Rng")
local Layout = if script ~= nil
	then require(script.Parent.Parent.grid.ChunkLayout)
	else require("../grid/ChunkLayout")
local WalkGraph = if script ~= nil
	then require(script.Parent.Parent.grid.WalkGraph)
	else require("../grid/WalkGraph")
local World = if script ~= nil then require(script.Parent.Parent.World) else require("../World")
local Common = if script ~= nil
	then require(script.Parent.Parent.features.Common)
	else require("../features/Common")
local Terrain = if script ~= nil
	then require(script.Parent.Parent.features.Terrain)
	else require("../features/Terrain")
local Level = if script ~= nil
	then require(script.Parent.Parent.level.Level)
	else require("../level/Level")

local OpenAdditive = {}

local DEFAULTS = {
	cell = 16,
	chunkCells = 18,
	block = 6,
	pillarShare = 0.30,
	pillarSize = 2,
	runCount = { 1, 4 },
	runLength = { 2, 6 },
	hallShare = 0.35,
	hallBlocks = 2,
	heights = { 10, 12, 14 },
	detailChance = 0.4,
}

local function param(params: any, key: string, fallback: any): any
	local value = params[key]
	if value == nil then
		return fallback
	end
	return value
end

-- World object -------------------------------------------------------------

function OpenAdditive.world(config: any, seed: number): any
	local params = (config.strategy and config.strategy.params) or {}
	local size = World.resolve(config)
	local n =
		param(params, "chunkCells", config.world and config.world.chunkCells or DEFAULTS.chunkCells)
	local cell = param(params, "cell", DEFAULTS.cell)
	if n % DEFAULTS.block ~= 0 then
		error("OpenAdditive: chunkCells must be a multiple of the block size " .. DEFAULTS.block, 2)
	end
	local boundary = (config.world and config.world.boundaryMode) or "wrap"
	-- Resolved once per world: the generate-phase systems in run order (stage,
	-- then dependencies), hookless descriptors dropped.
	local generators: { any } = {}
	for _, system in ipairs(Level.defaultRegistry():order("generate")) do
		if system.hooks.generate ~= nil then
			table.insert(generators, system)
		end
	end
	return {
		generators = generators,
		seed = seed,
		config = config,
		params = params,
		n = n,
		cell = cell,
		chunks = size.chunks,
		block = DEFAULTS.block,
		period = size.chunks * n,
		boundary = boundary,
		blocks = {},
		ceiling = OpenAdditive.resolveCeiling(params),
		terrainShares = Terrain.drawShares(seed, params.terrain),
	}
end

-- Ceiling bands (ADR 0032 D69). `strategy.params.ceiling = { bands = [{ height,
-- weight }], zoneBlocks }`; without it, `heights` are equal-weight bands.
-- `uniform` keeps the legacy index mapping floor(roll * n) + 1 byte for byte,
-- because a cumulative-weight walk could round differently at a band edge.
export type Ceiling = {
	heights: { number },
	cumulative: { number },
	total: number,
	uniform: boolean,
	zoneBlocks: number,
}

function OpenAdditive.resolveCeiling(params: any): Ceiling
	local ceiling = params.ceiling
	local heights: { number } = {}
	local cumulative: { number } = {}
	local total = 0
	local uniform = true
	local zoneBlocks = 1
	if ceiling ~= nil and ceiling.bands ~= nil then
		local first = nil
		for index, band in ipairs(ceiling.bands) do
			heights[index] = band.height
			total += band.weight
			cumulative[index] = total
			if first == nil then
				first = band.weight
			elseif band.weight ~= first then
				uniform = false
			end
		end
		zoneBlocks = ceiling.zoneBlocks or 1
	else
		heights = params.heights or DEFAULTS.heights
		for index = 1, #heights do
			cumulative[index] = index
		end
		total = #heights
	end
	return {
		heights = heights,
		cumulative = cumulative,
		total = total,
		uniform = uniform,
		zoneBlocks = zoneBlocks,
	}
end

-- Map a roll in [0,1) to a band height.
function OpenAdditive.pickHeight(ceiling: Ceiling, roll: number): number
	local heights = ceiling.heights
	local count = #heights
	if ceiling.uniform then
		return heights[math.min(count, math.max(1, math.floor(roll * count) + 1))]
	end
	local target = roll * ceiling.total
	for index = 1, count do
		if target < ceiling.cumulative[index] then
			return heights[index]
		end
	end
	return heights[count]
end

local function blockOf(make: any, gx: number, gz: number): any
	local blocksPerAxis = make.period / make.block
	local bx = if make.boundary == "wrap"
		then World.wrap(math.floor(gx / make.block), blocksPerAxis)
		else math.floor(gx / make.block)
	local bz = if make.boundary == "wrap"
		then World.wrap(math.floor(gz / make.block), blocksPerAxis)
		else math.floor(gz / make.block)
	local key = bx .. ":" .. bz
	local cached = make.blocks[key]
	if cached ~= nil then
		return cached
	end

	-- Coarse zone field: some 2-block squares are calm halls with no partitions
	-- at all. This is what turns uniform noise into "large halls with scattered
	-- fragments" (the Three.js project's plateau/zone trick).
	local hallBlocks = param(make.params, "hallBlocks", DEFAULTS.hallBlocks)
	local zoneX = math.floor(bx / hallBlocks)
	local zoneZ = math.floor(bz / hallBlocks)
	local isHall = Common.hash01(make.seed, "zone", zoneX, zoneZ)
		< param(make.params, "hallShare", DEFAULTS.hallShare)

	local rng = Rng.new(make.seed):fork("block:" .. bx .. ":" .. bz)
	local runs = param(make.params, "runCount", DEFAULTS.runCount)
	local lengthRange = param(make.params, "runLength", DEFAULTS.runLength)
	local count = if isHall then 0 else rng:nextInt(runs[2] - runs[1] + 1) + runs[1] - 1
	local E: { [string]: boolean } = {}
	local S: { [string]: boolean } = {}
	for _ = 1, count do
		local horizontal = rng:nextBool(0.5)
		-- A run cannot be longer than the block it lives in.
		local maxLength = math.min(lengthRange[2], make.block)
		local minLength = math.min(lengthRange[1], maxLength)
		local length = rng:nextInt(maxLength - minLength + 1) + minLength - 1
		local maxStart = make.block - length
		local start = rng:nextInt(maxStart + 1) - 1
		local line = rng:nextInt(make.block) - 1
		for step = 0, length - 1 do
			if horizontal then
				S[(start + step) .. ":" .. line] = true
			else
				E[line .. ":" .. (start + step)] = true
			end
		end
	end

	-- Pillar clusters: one 1x1 or 2x2 block of solid mass per chosen block.
	local pillarShare = param(make.params, "pillarShare", DEFAULTS.pillarShare)
	local pillarSize = param(make.params, "pillarSize", DEFAULTS.pillarSize)
	local solid: { [string]: boolean } = {}
	if not isHall and rng:nextFloat() < pillarShare then
		local ox = rng:nextInt(make.block - pillarSize + 1) - 1
		local oz = rng:nextInt(make.block - pillarSize + 1) - 1
		for dz = 0, pillarSize - 1 do
			for dx = 0, pillarSize - 1 do
				solid[(ox + dx) .. ":" .. (oz + dz)] = true
			end
		end
	end

	-- The draw is always consumed so the stream is the same whatever the zone
	-- scale; a zone overrides the roll with a hash of the zone coordinates.
	local ceiling: Ceiling = make.ceiling
	local roll = rng:nextFloat()
	if ceiling.zoneBlocks > 1 then
		roll = Common.hash01(
			make.seed,
			"ceiling",
			math.floor(bx / ceiling.zoneBlocks),
			math.floor(bz / ceiling.zoneBlocks)
		)
	end
	local height = OpenAdditive.pickHeight(ceiling, roll)

	local block = { E = E, S = S, solid = solid, height = height }
	make.blocks[key] = block
	return block
end

-- Cell state ---------------------------------------------------------------

-- Terrain: a coarse zone field, not per-cell noise, so plateaus and sunken
-- areas are large enough to walk on.
function OpenAdditive.cell(make: any, gx: number, gz: number): (boolean, number, number)
	local x = Common.canonical(make, gx)
	local z = Common.canonical(make, gz)
	local bx = math.floor(x / make.block)
	local bz = math.floor(z / make.block)
	local block = blockOf(make, x, z)
	local li = x - bx * make.block
	local lj = z - bz * make.block
	return block.solid[li .. ":" .. lj] == true, block.height, Terrain.terrainAt(make, x, z)
end

-- Vertical wall on the grid line `lineX`, at row `cellZ`.
function OpenAdditive.faceV(make: any, lineX: number, cellZ: number): boolean
	local line = Common.canonical(make, lineX)
	local z = Common.canonical(make, cellZ)
	local west = Common.canonical(make, line - 1)
	local westSolid = OpenAdditive.cell(make, west, z)
	local eastSolid = OpenAdditive.cell(make, line, z)
	if westSolid or eastSolid then
		return false
	end
	local bx = math.floor(west / make.block)
	local bz = math.floor(z / make.block)
	local block = blockOf(make, west, z)
	local li = west - bx * make.block
	local lj = z - bz * make.block
	return block.E[li .. ":" .. lj] == true
end

-- Horizontal wall on the grid line `lineZ`, at column `cellX`.
function OpenAdditive.faceH(make: any, cellX: number, lineZ: number): boolean
	local x = Common.canonical(make, cellX)
	local line = Common.canonical(make, lineZ)
	local north = Common.canonical(make, line - 1)
	local northSolid = OpenAdditive.cell(make, x, north)
	local southSolid = OpenAdditive.cell(make, x, line)
	if northSolid or southSolid then
		return false
	end
	local bx = math.floor(x / make.block)
	local bz = math.floor(north / make.block)
	local block = blockOf(make, x, north)
	local li = x - bx * make.block
	local lj = north - bz * make.block
	return block.S[li .. ":" .. lj] == true
end

-- Layout -------------------------------------------------------------------

local STEPS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function cellOf(n: number, index: number): (number, number)
	return (index - 1) % n + 1, (index - 1) // n + 1
end

-- Components of walkable floor (ADR 0031 D60): non-solid, non-template cells
-- joined across interior unsealed faces whose floors meet (a step within
-- `stepMax`, or a ramp end). Border faces are never traversed, because the chunk
-- is not allowed to decide them. Cells are cell indices, not (i, j) pairs.
local function components(layout: any, stepMax: number): ({ any }, { [number]: number }, any)
	local graph = WalkGraph.build(layout, { stepMax = stepMax })
	local list, compId = WalkGraph.components(graph)
	return list, compId, graph
end

local function largestComponent(comps: { any }): number
	local main = 1
	for index = 2, #comps do
		if comps[index].size > comps[main].size then
			main = index
		end
	end
	return main
end

local function setSealed(
	layout: any,
	i: number,
	j: number,
	di: number,
	dj: number,
	value: boolean
): ()
	local index = Layout.index(layout.n, i, j)
	if di == 1 then
		layout.sealedE[index] = value
	elseif dj == 1 then
		layout.sealedS[index] = value
	elseif di == -1 then
		layout.sealedE[Layout.index(layout.n, i - 1, j)] = value
	else
		layout.sealedS[Layout.index(layout.n, i, j - 1)] = value
	end
end

-- Terrain can leave a face open that no foot can cross: its ramp's low end lands
-- on the side of another ramp (a slope is not a floor to step down onto). That
-- is an open cliff (ADR 0031 D62). Seal it, and drop a ramp whose low end was
-- that face, since it would now end at a wall. Returns the faces sealed.
local function sealOpenCliffs(layout: any, stepMax: number): number
	local sealed = 0
	for _, rise in ipairs(WalkGraph.unbridgedRises(layout, { stepMax = stepMax })) do
		local a, b = rise.a, rise.b
		local axis = if rise.axis == "E" then "x" else "z"
		if rise.axis == "E" then
			layout.sealedE[a] = true
		else
			layout.sealedS[a] = true
		end
		-- b is the higher-coordinate cell: its low end faces a when dir == 1.
		local rampB, rampA = layout.ramp[b], layout.ramp[a]
		if rampB ~= nil and rampB.axis == axis and rampB.dir == 1 then
			layout.ramp[b] = nil
		end
		if rampA ~= nil and rampA.axis == axis and rampA.dir == -1 then
			layout.ramp[a] = nil
		end
		sealed += 1
	end
	return sealed
end

-- The walk graph the layout would have with every interior face open: its edges
-- are exactly the faces that are legal to open (same level, a step within
-- stepMax, or a ramp end).
local function openableGraph(layout: any, stepMax: number): any
	local shadow = {
		n = layout.n,
		solid = layout.solid,
		templateCell = layout.templateCell,
		floorY = layout.floorY,
		ramp = layout.ramp,
		sealedE = {},
		sealedS = {},
	}
	return WalkGraph.build(shadow, { stepMax = stepMax })
end

-- Remove walls only: for every component that is not the main one, BFS inside
-- the chunk to the main component and open the faces along the path. A step is
-- only taken across a face that would be walkable once opened: opening a face
-- between floors that differ by more than stepMax would make a cliff (ADR 0031
-- D61). Regions that only a ramp can join are left to `repairRamps`.
local function connect(layout: any, stepMax: number): ()
	local n = layout.n
	for _ = 1, n * n do
		local comps = components(layout, stepMax)
		if #comps <= 1 then
			return
		end
		local main = largestComponent(comps)
		local inMain: { [number]: boolean } = {}
		for _, cellIndex in ipairs(comps[main].cells) do
			inMain[cellIndex] = true
		end
		local openable = openableGraph(layout, stepMax)

		local connected = false
		for index, comp in ipairs(comps) do
			if index ~= main then
				-- BFS from this component to any main cell, inside the chunk.
				local startIndex = comp.cells[1]
				local parent: { [number]: number } = {}
				local seen: { [number]: boolean } = { [startIndex] = true }
				local queue = { startIndex }
				local head = 1
				local targetIndex = nil
				while head <= #queue and targetIndex == nil do
					local current = queue[head]
					head += 1
					local ci, cj = cellOf(n, current)
					for _, step in ipairs(STEPS) do
						local ni, nj = ci + step[1], cj + step[2]
						if ni >= 1 and nj >= 1 and ni <= n and nj <= n then
							local nIndex = Layout.index(n, ni, nj)
							if
								not seen[nIndex]
								and openable.walkable[nIndex]
								and table.find(openable.adj[current], nIndex) ~= nil
							then
								seen[nIndex] = true
								parent[nIndex] = current
								table.insert(queue, nIndex)
								if inMain[nIndex] then
									targetIndex = nIndex
									break
								end
							end
						end
					end
				end

				if targetIndex ~= nil then
					-- Walk back to the start, opening every face crossed.
					local cursor = targetIndex
					while cursor ~= startIndex do
						local previous = parent[cursor]
						if previous == nil then
							break
						end
						local ci, cj = cellOf(n, cursor)
						local pi, pj = cellOf(n, previous)
						setSealed(layout, pi, pj, ci - pi, cj - pj, false)
						cursor = previous
					end
					connected = true
				end
				if connected then
					break
				end
			end
		end

		if not connected then
			return
		end
	end
end

-- Repair for height-separated regions (ADR 0031 D61, D68). A walkable component
-- that `connect` could not join is separated from the main one by a rise above
-- stepMax; the only legal bridge is a ramp. For each such component, candidate
-- boundary faces (between it and a cell reachable from main, sealed, rising by
-- more than stepMax) are sorted by a canonical hash and the first that fits the
-- Terrain ramp rule AND actually joins the component is taken: one ramp per
-- unjoined component is guaranteed. Only a component larger than
-- `terrain.extraRampCells` (default 48) gets more, round(size / extraRampCells)
-- in total, each at least `terrain.rampSpacing` (default 4) cells from the
-- other ramps of the chunk. Joins one component per call and returns the number
-- of ramps added.

local function repairRamps(make: any, layout: any, stepMax: number): number
	local n = layout.n
	local originX, originZ = layout.cx * n, layout.cz * n
	local added = 0

	-- Sealed boundary faces from `cells` to cells in `target` across a rise
	-- above stepMax, sorted by the canonical hash (ties: E before S, then cell).
	local function candidates(cells: { number }, target: { [number]: boolean }): { any }
		local result = {}
		for _, a in ipairs(cells) do
			local ai, aj = cellOf(n, a)
			for _, step in ipairs(STEPS) do
				local bi, bj = ai + step[1], aj + step[2]
				if bi >= 1 and bj >= 1 and bi <= n and bj <= n then
					local b = Layout.index(n, bi, bj)
					if
						target[b]
						and layout.ramp[a] == nil
						and layout.ramp[b] == nil
						and math.abs(layout.floorY[a] - layout.floorY[b]) > stepMax
					then
						-- The owner of a face is its lower-coordinate cell.
						local ownerI, ownerJ = math.min(ai, bi), math.min(aj, bj)
						local axis = if step[1] ~= 0 then "E" else "S"
						local ownerIndex = Layout.index(n, ownerI, ownerJ)
						local sealed = if axis == "E"
							then layout.sealedE[ownerIndex]
							else layout.sealedS[ownerIndex]
						if sealed then
							table.insert(result, {
								a = a,
								b = b,
								ownerI = ownerI,
								ownerJ = ownerJ,
								axis = axis,
								order = if axis == "E" then 0 else 1,
								key = Common.hash01(
									make.seed,
									"ramp:repair",
									Common.canonical(make, originX + ownerI - 1),
									Common.canonical(make, originZ + ownerJ - 1)
								),
							})
						end
					end
				end
			end
		end
		table.sort(result, function(x, y)
			if x.key ~= y.key then
				return x.key < y.key
			end
			if x.order ~= y.order then
				return x.order < y.order
			end
			return x.a < y.a
		end)
		return result
	end

	-- Bridge candidate `c` with a ramp on its high side (the Terrain rule) and
	-- unseal the face. `accept` judges the rebuilt graph; a rejected bridge is
	-- rolled back exactly.
	local function tryCandidate(c: any, accept: (any) -> boolean): boolean
		local aHigh = layout.floorY[c.a] > layout.floorY[c.b]
		local high = if aHigh then c.a else c.b
		local low = if aHigh then c.b else c.a
		local hi, hj = cellOf(n, high)
		local li, lj = cellOf(n, low)
		local axis = if c.axis == "E" then "x" else "z"
		local dir = if axis == "x" then hi - li else hj - lj
		if
			not Terrain.tryRamp(
				make,
				layout,
				hi,
				hj,
				axis,
				dir,
				layout.floorY[low],
				layout.floorY[high]
			)
		then
			return false
		end
		local ownerIndex = Layout.index(n, c.ownerI, c.ownerJ)
		local sealedMap = if c.axis == "E" then layout.sealedE else layout.sealedS
		sealedMap[ownerIndex] = false
		if accept(WalkGraph.build(layout, { stepMax = stepMax })) then
			return true
		end
		sealedMap[ownerIndex] = true
		layout.ramp[high] = nil
		return false
	end

	-- The cell that carries the ramp for candidate `c` (the high side).
	local function highOf(c: any): number
		return if layout.floorY[c.a] > layout.floorY[c.b] then c.a else c.b
	end

	-- Whether a ramp on candidate `c` would keep `terrain.rampSpacing` cells
	-- (Manhattan) from every ramp already standing on the same high floor (the
	-- chunk's ramps of the same level are a superset of the same high region's,
	-- so a clear spot is clear of that region's ramps too; Terrain.farFrom is the
	-- one distance rule).
	local function clearOfRamps(c: any): boolean
		local high = highOf(c)
		local hi, hj = cellOf(n, high)
		local others: { { number } } = {}
		for other in pairs(layout.ramp) do
			if layout.floorY[other] == layout.floorY[high] then
				local oi, oj = cellOf(n, other)
				table.insert(others, { oi, oj })
			end
		end
		return Terrain.farFrom(others, hi, hj, Terrain.rampSpacing(make))
	end

	local function allReached(seen: { [number]: boolean }, cells: { [number]: boolean }): boolean
		for cellIndex in pairs(cells) do
			if not seen[cellIndex] then
				return false
			end
		end
		return true
	end

	local graph = WalkGraph.build(layout, { stepMax = stepMax })
	local comps = WalkGraph.components(graph)
	if #comps <= 1 then
		return added
	end
	local main = largestComponent(comps)
	local reach: { [number]: boolean } = {}
	for _, cellIndex in ipairs(comps[main].cells) do
		reach[cellIndex] = true
	end
	local mainRep = comps[main].cells[1]

	for index, comp in ipairs(comps) do
		if index ~= main then
			local first = comp.cells[1]
			local joined = false
			local joinedHigh: number? = nil
			-- The bridge must put this component in main's and strand nothing
			-- main already reached.
			-- Prefer a spot clear of every other ramp; settle for any when the
			-- guarantee demands it. A scrap too small to be worth a ramp beside
			-- another is left to `settlePockets`.
			local list = candidates(comp.cells, reach)
			local scrap = comp.size < Terrain.rampSpacing(make) ^ 2
			for pass = 1, if scrap then 1 else 2 do
				for _, c in ipairs(list) do
					local spaced = clearOfRamps(c)
					if pass == 2 or spaced then
						if
							tryCandidate(c, function(g: any): boolean
								local seen = WalkGraph.reachableFrom(g, mainRep)
								return seen[first] == true and allReached(seen, reach)
							end)
						then
							joined = true
							joinedHigh = highOf(c)
							added += 1
							if not spaced then
								-- No spaced face could join this component: the guaranteed
								-- ramp stands closer than rampSpacing and is counted.
								layout.rampsUnspaced += 1
								layout.unspacedRamps[highOf(c)] = true
							end
							break
						end
					end
				end
				if joined then
					break
				end
			end
			if joined then
				-- Only a big region earns more than one way in.
				local extraCells = Terrain.extraRampCells(make)
				local want = math.floor(comp.size / extraCells + 0.5)
				if comp.size > extraCells and want > 1 then
					local together: { [number]: boolean } = {}
					for cellIndex in pairs(reach) do
						together[cellIndex] = true
					end
					for _, cellIndex in ipairs(comp.cells) do
						together[cellIndex] = true
					end
					-- Ramps already standing in or on this component count towards its
					-- total.
					local near: { { number } } = {}
					local counted: { [number]: boolean } = {}
					local function note(cellIndex: number): ()
						if not counted[cellIndex] then
							counted[cellIndex] = true
							local ri, rj = cellOf(n, cellIndex)
							table.insert(near, { ri, rj })
						end
					end
					for _, cellIndex in ipairs(comp.cells) do
						if layout.ramp[cellIndex] ~= nil then
							note(cellIndex)
						end
					end
					if joinedHigh ~= nil then
						note(joinedHigh)
					end
					local extra = math.max(1, #near)
					for _, c in ipairs(candidates(comp.cells, reach)) do
						if extra >= want then
							break
						end
						local hi, hj = cellOf(n, highOf(c))
						if
							clearOfRamps(c)
							and tryCandidate(c, function(g: any): boolean
								return allReached(WalkGraph.reachableFrom(g, mainRep), together)
							end)
						then
							table.insert(near, { hi, hj })
							extra += 1
							added += 1
						end
					end
				end
				-- One component per call: the caller opens walls again before the
				-- next, because a ramp can make a neighbouring piece reachable by
				-- walls alone.
				return added
			end
		end
	end
	return added
end

-- A pocket is a component that is not the main one and has no open face to the
-- outside. With `solidify` it becomes mass, which is honest: an invisible room
-- is wasted volume, and windows (M13) are what would make it visible. A region
-- the repair could not bridge (a plateau with nowhere to put a ramp) is a
-- pocket too: it is not reachable, so it is not floor (ADR 0031 D61).
local function settlePockets(make: any, layout: any, policy: string, stepMax: number): number
	local comps = components(layout, stepMax)
	if #comps <= 1 then
		return 0
	end
	local main = largestComponent(comps)
	local n = layout.n
	local solidified = 0
	for index, comp in ipairs(comps) do
		if index ~= main then
			-- Whether the component can continue into the neighbouring chunk. The
			-- west and north faces belong to the neighbour, so they are judged by
			-- the seam function plus the floors on both sides: a rise above
			-- stepMax is a wall unless the neighbour happens to ramp it, which
			-- this chunk cannot know and must not assume.
			local function touchesOutside(): boolean
				for _, cellIndex in ipairs(comp.cells) do
					local i, j = cellOf(n, cellIndex)
					local gx = layout.cx * n + i - 1
					local gz = layout.cz * n + j - 1
					local floor = layout.floorY[cellIndex]
					if
						(
							i == 1
							and not OpenAdditive.faceV(make, gx, gz)
							and math.abs(Terrain.terrainAt(make, gx - 1, gz) - floor) <= stepMax
						)
						or (i == n and not layout.sealedE[cellIndex])
						or (j == 1 and not OpenAdditive.faceH(make, gx, gz) and math.abs(
							Terrain.terrainAt(make, gx, gz - 1) - floor
						) <= stepMax)
						or (j == n and not layout.sealedS[cellIndex])
					then
						return true
					end
				end
				return false
			end
			local open = touchesOutside()
			if not open and policy == "solidify" then
				for _, cellIndex in ipairs(comp.cells) do
					local i, j = cellOf(n, cellIndex)
					Layout.set(layout, i, j, true)
					solidified += 1
				end
			end
		end
	end
	if solidified > 0 then
		for j = 1, n do
			for i = 1, n do
				local idx = Layout.index(n, i, j)
				if layout.solid[idx] then
					layout.sealedE[idx] = false
					layout.sealedS[idx] = false
				else
					-- A wall against mass is the mass itself.
					if i < n and layout.solid[Layout.index(n, i + 1, j)] then
						layout.sealedE[idx] = false
					end
					if j < n and layout.solid[Layout.index(n, i, j + 1)] then
						layout.sealedS[idx] = false
					end
				end
			end
		end
	end
	return solidified
end

-- Details (ADR 0025): deterministic per cell id + coordinates, never per
-- player. Placement is scored on the layout (open hall / near wall / dead end),
-- then min spacing and a per-chunk cap are applied in a fixed order.
local function placeDetails(make: any, layout: any): ()
	local n, cell = layout.n, layout.cell
	local details = make.config.details or {}
	if #details == 0 then
		return
	end
	local comps, compId = components(layout, Terrain.stepMax(make))
	local sizes = {}
	for index, comp in ipairs(comps) do
		sizes[index] = comp.size
	end

	local function componentSize(i: number, j: number): number
		return sizes[compId[Layout.index(n, i, j)] or 0] or 0
	end

	local function nearWall(i: number, j: number): boolean
		local index = Layout.index(n, i, j)
		if layout.solid[index] then
			return false
		end
		if layout.sealedE[index] or layout.sealedS[index] then
			return true
		end
		if i > 1 and layout.sealedE[Layout.index(n, i - 1, j)] then
			return true
		end
		if j > 1 and layout.sealedS[Layout.index(n, i, j - 1)] then
			return true
		end
		for _, step in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
			local ni, nj = i + step[1], j + step[2]
			if ni >= 1 and nj >= 1 and ni <= n and nj <= n then
				if layout.solid[Layout.index(n, ni, nj)] then
					return true
				end
			end
		end
		return false
	end

	local function openFaces(i: number, j: number): number
		local index = Layout.index(n, i, j)
		local count = 0
		if i > 1 and not layout.sealedE[Layout.index(n, i - 1, j)] then
			count += 1
		end
		if i < n and not layout.sealedE[index] then
			count += 1
		end
		if j > 1 and not layout.sealedS[Layout.index(n, i, j - 1)] then
			count += 1
		end
		if j < n and not layout.sealedS[index] then
			count += 1
		end
		return count
	end

	for _, detail in ipairs(details) do
		local chance = detail.chance or 0.05
		local minSpacing = detail.minSpacing or 0
		local cap = (detail.densityCap and detail.densityCap.perChunk) or math.huge
		local hallMin = detail.hallMinCells or 30
		local where = detail.where or { "any_open" }
		local allowed: { [string]: boolean } = {}
		for _, rule in ipairs(where) do
			allowed[rule] = true
		end
		local rng = Rng.new(make.seed)
			:fork("detail:" .. detail.id .. ":" .. layout.cx .. ":" .. layout.cz)
		local placed = {}
		local count = 0
		for j = 1, n do
			for i = 1, n do
				if count >= cap then
					break
				end
				local index = Layout.index(n, i, j)
				-- A template owns its interior: procedural decor stays out (0038).
				if not layout.solid[index] and not layout.templateCell[index] then
					local ok = false
					if allowed["any_open"] then
						ok = true
					end
					if allowed["open_hall"] and componentSize(i, j) >= hallMin then
						ok = true
					end
					if allowed["near_wall"] and nearWall(i, j) then
						ok = true
					end
					if allowed["dead_end"] and openFaces(i, j) <= 1 then
						ok = true
					end
					if ok and rng:nextFloat() < chance then
						local x = (i - 0.5) * cell
						local z = (j - 0.5) * cell
						local spaced = true
						for _, other in ipairs(placed) do
							local dx, dz = x - other.x, z - other.z
							if math.sqrt(dx * dx + dz * dz) < minSpacing then
								spaced = false
								break
							end
						end
						if spaced then
							table.insert(placed, { x = x, z = z })
							table.insert(layout.details, {
								id = detail.id,
								cellX = i,
								cellZ = j,
								x = x,
								z = z,
								y = if detail.id == "wall_stain"
									then 3
									else (layout.height[index] - 0.3),
							})
							count += 1
						end
					end
				end
			end
		end
	end
end

-- The repair and decorate passes, handed to the connectivity and details systems
-- through the hook context (they share this module's grid helpers).
local PASSES = {
	sealOpenCliffs = sealOpenCliffs,
	connect = connect,
	repairRamps = repairRamps,
	settlePockets = settlePockets,
	placeDetails = placeDetails,
}

function OpenAdditive.layout(make: any, cx: number, cz: number, options: any?): any
	local opts = options or {}
	local n, cell = make.n, make.cell
	local layout = Layout.new(cx, cz, n, cell)
	-- Repair ramps placed closer than `terrain.rampSpacing` to another ramp of
	-- their level because no spaced face could join the component (count, and the
	-- set of their cells keyed by cell index).
	layout.rampsUnspaced = 0
	layout.unspacedRamps = {}
	local originX = cx * n
	local originZ = cz * n

	for j = 1, n do
		for i = 1, n do
			local gx, gz = originX + i - 1, originZ + j - 1
			local solid, height, floorY = OpenAdditive.cell(make, gx, gz)
			local index = Layout.index(n, i, j)
			layout.solid[index] = solid
			layout.height[index] = height
			layout.floorY[index] = floorY
			layout.sealedE[index] = OpenAdditive.faceV(make, gx + 1, gz)
			layout.sealedS[index] = OpenAdditive.faceH(make, gx, gz + 1)
		end
		local outE = { OpenAdditive.cell(make, originX + n, originZ + j - 1) }
		local outS = { OpenAdditive.cell(make, originX + j - 1, originZ + n) }
		layout.outHeightE[j] = outE[2]
		layout.outFloorE[j] = outE[3]
		layout.outHeightS[j] = outS[2]
		layout.outFloorS[j] = outS[3]
	end

	-- Every generate-phase system in registry order: terrain, structures,
	-- templates, connectivity, details for Level 0 (ADR 0033 D75).
	local ctx = {
		options = opts,
		enclosedPolicy = opts.enclosedPolicy or DEFAULTS.enclosedPolicy or "solidify",
		passes = PASSES,
	}
	for _, system in ipairs(make.generators) do
		(system.hooks.generate :: any)(make, layout, ctx)
	end
	return layout
end

-- World-level entry point. A grid strategy cannot return one plan for a vast
-- level, so `build` returns the world object and chunks are produced on demand.
function OpenAdditive.build(config: any, seed: number, options: any?): any
	local make = OpenAdditive.world(config, seed)
	make.options = options or {}
	return make
end

-- Spawn (ADR 0026): chosen from the layout, not from a coordinate. It must be
-- open, in the main region, and have at least two open sides so the player can
-- walk out of it. Nearest to the chunk centre, deterministic tie-break.
function OpenAdditive.spawn(make: any, layout: any): any
	local n = layout.n
	local comps, compId = components(layout, Terrain.stepMax(make))
	local main, size = 0, 0
	for index, comp in ipairs(comps) do
		if comp.size > size then
			main, size = index, comp.size
		end
	end
	local function openFaces(i: number, j: number): number
		local index = Layout.index(n, i, j)
		local count = 0
		if i > 1 and not layout.sealedE[Layout.index(n, i - 1, j)] then
			count += 1
		end
		if i < n and not layout.sealedE[index] then
			count += 1
		end
		if j > 1 and not layout.sealedS[Layout.index(n, i, j - 1)] then
			count += 1
		end
		if j < n and not layout.sealedS[index] then
			count += 1
		end
		return count
	end

	local spawnParams = make.params.spawn or {}
	local minFaces = spawnParams.minOpenFaces or 3
	local radius = spawnParams.openRadiusCells or 4

	-- Local openness: how much floor is around the cell. A spawn next to a long
	-- partition can look like it splits the level in two, so prefer open ground.
	local function openness(i: number, j: number): number
		local count = 0
		for dz = -radius, radius do
			for dx = -radius, radius do
				local ni, nj = i + dx, j + dz
				if ni >= 1 and nj >= 1 and ni <= n and nj <= n then
					if not layout.solid[Layout.index(n, ni, nj)] then
						count += 1
					end
				end
			end
		end
		return count
	end

	local centre = (n + 1) / 2
	local best = nil
	for attempt = 1, 2 do
		local need = if attempt == 1 then minFaces else 1
		local bestScore = -math.huge
		for j = 1, n do
			for i = 1, n do
				local index = Layout.index(n, i, j)
				if not layout.solid[index] and compId[index] == main then
					local faces = openFaces(i, j)
					if faces >= need then
						local score = openness(i, j) * 10
							+ faces * 5
							- math.abs(i - centre)
							- math.abs(j - centre)
						if score > bestScore then
							bestScore = score
							best = { i = i, j = j, faces = faces }
						end
					end
				end
			end
		end
		if best ~= nil then
			break
		end
	end
	if best == nil then
		return nil
	end
	local gx = layout.cx * n + best.i - 1
	local gz = layout.cz * n + best.j - 1
	return {
		cellX = gx,
		cellZ = gz,
		x = (gx + 0.5) * make.cell,
		z = (gz + 0.5) * make.cell,
		openFaces = best.faces,
		openness = openness(best.i, best.j),
	}
end

function OpenAdditive.defaults(): any
	return DEFAULTS
end

return OpenAdditive
