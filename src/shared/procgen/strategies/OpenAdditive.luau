--!strict

-- open_additive (ADR 0024/0026): start with an open plate, add wall runs and
-- pillars, then remove walls only where a pocket would be unreachable.
--
-- Seam rule: every wall is a pure function of the *shared grid line* and the
-- seed. A block owns the lines east and south of its own cells, so two
-- neighbouring chunks query the same line and get the same answer without
-- reading each other's content. That is what makes generation chunk-order
-- independent and the border invisible.

local Hash = if script ~= nil then require(script.Parent.Parent.Hash) else require("../Hash")
local Rng = if script ~= nil then require(script.Parent.Parent.Rng) else require("../Rng")
local Layout = if script ~= nil
	then require(script.Parent.Parent.grid.ChunkLayout)
	else require("../grid/ChunkLayout")
local World = if script ~= nil then require(script.Parent.Parent.World) else require("../World")

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

-- FNV over a coordinate string has poor avalanche: neighbouring coordinates
-- differ in one byte and land within 0.004 of each other, so zone fields came
-- out banded and some seeds had no terrain at all. A murmur-style finalizer
-- fixes the low-entropy input without a new hash.
local function hash01(seed: number, salt: string, a: number, b: number): number
	local h = Hash.u32(seed .. ":" .. salt .. ":" .. a .. ":" .. b)
	h = Hash.mul32(bit32.bxor(h, bit32.rshift(h, 16)), 2246822507)
	h = Hash.mul32(bit32.bxor(h, bit32.rshift(h, 13)), 3266489909)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h / 4294967296
end

-- A config value is either a number or a {min,max} band. Bands are drawn once
-- per seed, so a level varies within its range but is never fixed nor out of it.
local function bandValue(rng: any, value: any, fallback: number): number
	if type(value) == "number" then
		return value
	end
	if type(value) == "table" and value[1] ~= nil and value[2] ~= nil then
		return value[1] + rng:nextFloat() * (value[2] - value[1])
	end
	return fallback
end

local function drawShares(seed: number, terrain: any): any
	local rng = Rng.new(seed):fork("terrain")
	local t = terrain or {}
	return {
		plateau = bandValue(rng, t.plateauShare, 0.10),
		sunken = bandValue(rng, t.sunkenShare, 0.10),
		rampChance = bandValue(rng, t.rampChance, 0.15),
	}
end

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
	return {
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
		terrainShares = drawShares(seed, params.terrain),
	}
end

local function canonical(make: any, value: number): number
	if make.boundary == "wrap" then
		return World.wrap(value, make.period)
	end
	return value
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
	local isHall = hash01(make.seed, "zone", zoneX, zoneZ)
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

	local heights = param(make.params, "heights", DEFAULTS.heights)
	local roll = rng:nextFloat()
	local height = heights[math.min(#heights, math.max(1, math.floor(roll * #heights) + 1))]

	local block = { E = E, S = S, solid = solid, height = height }
	make.blocks[key] = block
	return block
end

-- Cell state ---------------------------------------------------------------

-- Terrain: a coarse zone field, not per-cell noise, so plateaus and sunken
-- areas are large enough to walk on.
local function terrainAt(make: any, gx: number, gz: number): number
	local terrain = make.params.terrain
	if terrain == nil then
		return 0
	end
	local blocks = terrain.blocksPerZone or 2
	local span = make.block * blocks
	local bx = math.floor(canonical(make, gx) / span)
	local bz = math.floor(canonical(make, gz) / span)
	local roll = hash01(make.seed, "terrain", bx, bz)
	local shares = make.terrainShares or { plateau = 0, sunken = 0 }
	local level = terrain.level or 4
	if roll < shares.sunken then
		return -level
	elseif roll < shares.sunken + shares.plateau then
		return level
	end
	return 0
end

function OpenAdditive.cell(make: any, gx: number, gz: number): (boolean, number, number)
	local x = canonical(make, gx)
	local z = canonical(make, gz)
	local bx = math.floor(x / make.block)
	local bz = math.floor(z / make.block)
	local block = blockOf(make, x, z)
	local li = x - bx * make.block
	local lj = z - bz * make.block
	return block.solid[li .. ":" .. lj] == true, block.height, terrainAt(make, x, z)
end

-- Vertical wall on the grid line `lineX`, at row `cellZ`.
function OpenAdditive.faceV(make: any, lineX: number, cellZ: number): boolean
	local line = canonical(make, lineX)
	local z = canonical(make, cellZ)
	local west = canonical(make, line - 1)
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
	local x = canonical(make, cellX)
	local line = canonical(make, lineZ)
	local north = canonical(make, line - 1)
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

local function openNeighbour(layout: any, i: number, j: number, di: number, dj: number): boolean
	if di == 1 then
		return not layout.sealedE[Layout.index(layout.n, i, j)]
	elseif di == -1 then
		return i > 1 and not layout.sealedE[Layout.index(layout.n, i - 1, j)]
	elseif dj == 1 then
		return not layout.sealedS[Layout.index(layout.n, i, j)]
	end
	return j > 1 and not layout.sealedS[Layout.index(layout.n, i, j - 1)]
end

-- Components of open floor, traversing only faces inside the chunk. Border
-- faces are never traversed, because the chunk is not allowed to decide them.
local function components(layout: any): ({ any }, { [number]: number })
	local n = layout.n
	local compId: { [number]: number } = {}
	local list = {}
	for j = 1, n do
		for i = 1, n do
			local index = Layout.index(n, i, j)
			if not layout.solid[index] and compId[index] == nil then
				local id = #list + 1
				local cells = {}
				local queue = { { i, j } }
				compId[index] = id
				local head = 1
				while head <= #queue do
					local cell = queue[head]
					head += 1
					table.insert(cells, cell)
					for _, step in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
						local ni, nj = cell[1] + step[1], cell[2] + step[2]
						if ni >= 1 and nj >= 1 and ni <= n and nj <= n then
							local nIndex = Layout.index(n, ni, nj)
							if
								not layout.solid[nIndex]
								and compId[nIndex] == nil
								and openNeighbour(layout, cell[1], cell[2], step[1], step[2])
							then
								compId[nIndex] = id
								table.insert(queue, { ni, nj })
							end
						end
					end
				end
				table.insert(list, { cells = cells, size = #cells })
			end
		end
	end
	return list, compId
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

-- Remove walls only: for every component that is not the main one, BFS inside
-- the chunk to the main component and open the faces along the path.
local function connect(layout: any): ()
	local n = layout.n
	for _ = 1, n * n do
		local comps = components(layout)
		if #comps <= 1 then
			return
		end
		local main = 1
		for index = 2, #comps do
			if comps[index].size > comps[main].size then
				main = index
			end
		end

		local connected = false
		for index, comp in ipairs(comps) do
			if index ~= main then
				-- BFS from this component to any main cell, inside the chunk.
				local start = comp.cells[1]
				local parent: { [number]: number } = {}
				local seen: { [number]: boolean } = {}
				local queue = { start }
				local startIndex = Layout.index(n, start[1], start[2])
				seen[startIndex] = true
				local head = 1
				local targetIndex = nil
				while head <= #queue and targetIndex == nil do
					local cell = queue[head]
					head += 1
					for _, step in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
						local ni, nj = cell[1] + step[1], cell[2] + step[2]
						if ni >= 1 and nj >= 1 and ni <= n and nj <= n then
							local nIndex = Layout.index(n, ni, nj)
							if not layout.solid[nIndex] and not seen[nIndex] then
								seen[nIndex] = true
								parent[nIndex] = Layout.index(n, cell[1], cell[2])
								table.insert(queue, { ni, nj })
								if targetIndex == nil then
									-- is this cell in the main component?
									local isMain = false
									for _, mainCell in ipairs(comps[main].cells) do
										if mainCell[1] == ni and mainCell[2] == nj then
											isMain = true
											break
										end
									end
									if isMain then
										targetIndex = nIndex
									end
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
						local ci = (cursor - 1) % n + 1
						local cj = math.floor((cursor - 1) / n) + 1
						local pi = (previous - 1) % n + 1
						local pj = math.floor((previous - 1) / n) + 1
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

-- A pocket is a component that is not the main one and has no open face to the
-- outside. With `solidify` it becomes mass, which is honest: an invisible room
-- is wasted volume, and windows (M13) are what would make it visible.
local function settlePockets(make: any, layout: any, policy: string): number
	local comps = components(layout)
	if #comps <= 1 then
		return 0
	end
	local main = 1
	for index = 2, #comps do
		if comps[index].size > comps[main].size then
			main = index
		end
	end
	local n = layout.n
	local solidified = 0
	for index, comp in ipairs(comps) do
		if index ~= main then
			local function touchesOutside(): boolean
				for _, cell in ipairs(comp.cells) do
					local i, j = cell[1], cell[2]
					local idx = Layout.index(n, i, j)
					local gx = layout.cx * n + i - 1
					local gz = layout.cz * n + j - 1
					if
						(i == 1 and not OpenAdditive.faceV(make, gx, gz))
						or (i == n and not layout.sealedE[idx])
						or (j == 1 and not OpenAdditive.faceH(make, gx, gz))
						or (j == n and not layout.sealedS[idx])
					then
						return true
					end
				end
				return false
			end
			local open = touchesOutside()
			if not open and policy == "solidify" then
				for _, cell in ipairs(comp.cells) do
					Layout.set(layout, cell[1], cell[2], true)
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
	local comps, compId = components(layout)
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
				if not layout.solid[index] then
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

function OpenAdditive.layout(make: any, cx: number, cz: number, options: any?): any
	local opts = options or {}
	local n, cell = make.n, make.cell
	local layout = Layout.new(cx, cz, n, cell)
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

	-- Terrain pass (ADR 0029): a rise above one stud is a retaining edge unless
	-- a ramp can stand on the higher side and continue into the plateau. A ramp
	-- replaces that cell's floor; the boundary stays open.
	local terrain = make.params.terrain or {}
	local stepMax = terrain.stepMax or 1
	local minHeadroom = terrain.minHeadroom or 9

	local function floorOf(i: number, j: number): number
		if i < 1 or j < 1 or i > n or j > n then
			local gx = originX + i - 1
			local gz = originZ + j - 1
			return select(3, OpenAdditive.cell(make, gx, gz))
		end
		return layout.floorY[Layout.index(n, i, j)]
	end

	local function placeRamp(
		i: number,
		j: number,
		axis: string,
		dir: number,
		lowY: number,
		highY: number
	)
		if i < 1 or j < 1 or i > n or j > n then
			return false
		end
		local index = Layout.index(n, i, j)
		if layout.ramp[index] ~= nil then
			return false
		end
		layout.ramp[index] = { axis = axis, dir = dir, lowY = lowY, highY = highY }
		return true
	end

	for j = 1, n do
		for i = 1, n do
			local index = Layout.index(n, i, j)
			local here = layout.floorY[index]

			-- east boundary
			local east = floorOf(i + 1, j)
			local diff = east - here
			if diff ~= 0 then
				if math.abs(diff) <= stepMax then
					layout.sealedE[index] = false
				else
					local highIsHere = diff < 0
					local rampI = if highIsHere then i else i + 1
					local inward = if highIsHere then i - 1 else i + 2
					local chosen = hash01(
						make.seed,
						"ramp:x",
						canonical(make, originX + i - 1),
						canonical(make, originZ + j - 1)
					) < ((make.terrainShares and make.terrainShares.rampChance) or 0.15)
					local placed = chosen
						and placeRamp(
							rampI,
							j,
							"x",
							if highIsHere then -1 else 1,
							math.min(here, east),
							math.max(here, east)
						)
					if placed then
						local inwardFloor = floorOf(inward, j)
						if inwardFloor ~= layout.floorY[Layout.index(n, rampI, j)] then
							-- The plateau does not continue: a ramp would end in mid-air.
							layout.ramp[Layout.index(n, rampI, j)] = nil
							placed = false
						end
					end
					layout.sealedE[index] = not placed
				end
			end

			-- south boundary
			local south = floorOf(i, j + 1)
			local diffS = south - here
			if diffS ~= 0 then
				if math.abs(diffS) <= stepMax then
					layout.sealedS[index] = false
				else
					local highIsHere = diffS < 0
					local rampJ = if highIsHere then j else j + 1
					local inward = if highIsHere then j - 1 else j + 2
					local chosen = hash01(
						make.seed,
						"ramp:z",
						canonical(make, originX + i - 1),
						canonical(make, originZ + j - 1)
					) < ((make.terrainShares and make.terrainShares.rampChance) or 0.15)
					local placed = chosen
						and placeRamp(
							i,
							rampJ,
							"z",
							if highIsHere then -1 else 1,
							math.min(here, south),
							math.max(here, south)
						)
					if placed then
						local inwardFloor = floorOf(i, inward)
						if inwardFloor ~= layout.floorY[Layout.index(n, i, rampJ)] then
							layout.ramp[Layout.index(n, i, rampJ)] = nil
							placed = false
						end
					end
					layout.sealedS[index] = not placed
				end
			end
		end
	end

	for index = 1, n * n do
		layout.height[index] = math.max(layout.height[index], minHeadroom)
	end

	-- Feature zones (pillar grids and hanging walls): a flat zone with a
	-- structure standing on it, not another height.
	local features = make.params.features or {}
	if features.pillarGrid ~= nil or features.hangingWall ~= nil then
		local pillar = features.pillarGrid or {}
		local hang = features.hangingWall or {}
		local pillarShare = pillar.share or 0
		local hangShare = hang.share or 0
		for j = 1, n do
			for i = 1, n do
				local index = Layout.index(n, i, j)
				local gx = originX + i - 1
				local gz = originZ + j - 1
				local bx = math.floor(canonical(make, gx) / make.block)
				local bz = math.floor(canonical(make, gz) / make.block)
				local roll = hash01(make.seed, "feature", bx, bz)
				if roll < pillarShare and not layout.solid[index] then
					local spacing = pillar.spacing or 2
					if (i - 1) % spacing == 0 and (j - 1) % spacing == 0 then
						layout.column[index] = true
					end
					if layout.columnStuds == nil then
						layout.columnStuds = pillar.columnStuds or 2
					end
				elseif roll < pillarShare + hangShare and not layout.solid[index] then
					if layout.hangClearance == nil then
						layout.hangClearance = hang.clearance or 3
					end
					local density = hang.density or 0.5
					if
						not layout.sealedE[index]
						and hash01(
								make.seed,
								"hang:x",
								canonical(make, gx),
								canonical(make, gz)
							)
							< density
					then
						layout.hangE[index] = true
					end
					if
						not layout.sealedS[index]
						and hash01(
								make.seed,
								"hang:z",
								canonical(make, gx),
								canonical(make, gz)
							)
							< density
					then
						layout.hangS[index] = true
					end
				end
			end
		end
	end

	connect(layout)
	local policy = opts.enclosedPolicy or DEFAULTS.enclosedPolicy or "solidify"
	layout.solidified = settlePockets(make, layout, policy)
	placeDetails(make, layout)
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
	local comps, compId = components(layout)
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
