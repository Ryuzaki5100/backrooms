--!strict

-- Layout metrics (ADR 0024, verification section).
--
-- These are the numbers that decide whether a cell level looks like the Lobby:
-- how much of the plan is open, how large the open regions are, and how far you
-- can see. They are computed on the layout, not on parts, so they are cheap and
-- independent of the renderer.
--
-- Wrap-aware: a region or a sightline may cross the seam, so every neighbour
-- lookup goes through World.wrap.
--
-- Regions are walk regions (ADR 0031 D60/D61): non-solid cells joined across
-- unsealed faces whose floors meet (a step within stepMax, or a ramp end), the
-- same edge rule as grid/WalkGraph but evaluated across chunk borders. A plateau
-- with no ramp is therefore its own region. Unlike WalkGraph, template cells stay
-- nodes here: a template footprint is open floor and flat worlds keep their
-- existing region numbers.
--
-- reachableShare = cells in the spawn's region / all non-solid cells. The spawn is
-- `options.spawn` ({ cellX, cellZ }, world cell coordinates as returned by the
-- strategy's spawn()); Metrics knows no spawn of its own, so without one the
-- largest region stands in and `reachableOrigin` says "largest". The same share
-- for the largest region is always reported as `largestRegionShare`.

local World = if script ~= nil then require(script.Parent.World) else require("./World")
local Terrain = if script ~= nil
	then require(script.Parent.features.Terrain)
	else require("./features/Terrain")

local Metrics = {}

local function key(cx: number, cz: number): string
	return cx .. ":" .. cz
end

local function cellIndex(layout: any, i: number, j: number): number
	return i + (j - 1) * layout.n
end

-- Accessors over a set of chunks, in canonical (wrapped) cell coordinates.
local function accessors(make: any, layouts: { [string]: any })
	local n = make.n
	local period = make.period
	local stepMax = Terrain.stepMax(make)

	local function chunkOf(value: number): number
		return math.floor(World.wrap(value, period) / n)
	end

	local function localOf(value: number): number
		return math.floor(World.wrap(value, period)) % n + 1
	end

	local function layoutAt(gx: number, gz: number): any
		return layouts[key(chunkOf(gx), chunkOf(gz))]
	end

	local function solidAt(gx: number, gz: number): boolean
		local layout = layoutAt(gx, gz)
		if layout == nil then
			return true
		end
		return layout.solid[cellIndex(layout, localOf(gx), localOf(gz))] == true
	end

	local function heightAt(gx: number, gz: number): number
		local layout = layoutAt(gx, gz)
		if layout == nil then
			return 0
		end
		return layout.height[cellIndex(layout, localOf(gx), localOf(gz))]
	end

	-- Face between (gx,gz) and its neighbour in `axis`. The owner is always the
	-- cell with the lower canonical coordinate, i.e. `gx,gz` for E/S and the
	-- neighbour for W/N.
	local function faceOpen(gx: number, gz: number, axis: string): boolean
		local ownerX, ownerZ, useE = gx, gz, true
		if axis == "W" then
			ownerX, ownerZ = gx - 1, gz
		elseif axis == "N" then
			ownerX, ownerZ, useE = gx, gz - 1, false
		elseif axis == "S" then
			ownerX, ownerZ, useE = gx, gz, false
		end
		local layout = layoutAt(ownerX, ownerZ)
		if layout == nil then
			return false
		end
		local index = cellIndex(layout, localOf(ownerX), localOf(ownerZ))
		if useE then
			return layout.sealedE[index] ~= true
		end
		return layout.sealedS[index] ~= true
	end

	-- Floor Y a cell presents on a face looking `side` (+1 / -1) along `axis`;
	-- nil for the side face of a ramp. Mirrors grid/WalkGraph.
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

	-- Whether the floors on both sides of the face from (gx,gz) by (dx,dz) meet.
	-- Sealing is `faceOpen`'s business.
	local function floorsMeet(gx: number, gz: number, dx: number, dz: number): boolean
		local la, lb = layoutAt(gx, gz), layoutAt(gx + dx, gz + dz)
		if la == nil or lb == nil then
			return false
		end
		local ia = cellIndex(la, localOf(gx), localOf(gz))
		local ib = cellIndex(lb, localOf(gx + dx), localOf(gz + dz))
		local axis = if dx ~= 0 then "x" else "z"
		local side = dx + dz
		local ya = presentedY(la, ia, axis, side)
		local yb = presentedY(lb, ib, axis, -side)
		if ya == nil or yb == nil then
			return sameRamp(la.ramp[ia], lb.ramp[ib])
		end
		return math.abs(ya - yb) <= stepMax
	end

	return {
		solidAt = solidAt,
		heightAt = heightAt,
		faceOpen = faceOpen,
		floorsMeet = floorsMeet,
	}
end

local AXES = {
	{ 1, 0, "E" },
	{ -1, 0, "W" },
	{ 0, 1, "S" },
	{ 0, -1, "N" },
}

function Metrics.compute(make: any, layouts: { [string]: any }, options: any?): any
	local opts = options or {}
	local cell = make.cell
	local period = make.period
	local access = accessors(make, layouts)
	local largeRegionStuds = opts.largeRegionStuds or 4000
	local maxSightlineStuds = opts.maxSightlineStuds or 2000
	local sampleStride = opts.sightlineStride or 1

	local cells, openCells, solidCells = 0, 0, 0
	local wallFaces, wallLength = 0, 0
	for _, layout in pairs(layouts) do
		for index = 1, layout.n * layout.n do
			cells += 1
			if layout.solid[index] then
				solidCells += 1
			else
				openCells += 1
			end
		end
		for i = 1, layout.n do
			for j = 1, layout.n do
				if layout.sealedE[cellIndex(layout, i, j)] then
					wallFaces += 1
					wallLength += cell
				end
				if layout.sealedS[cellIndex(layout, i, j)] then
					wallFaces += 1
					wallLength += cell
				end
			end
		end
	end

	-- Components of open cells, wrap-aware.
	local seen: { [string]: boolean } = {}
	local regions = {}
	local regionOf: { [string]: number } = {}
	local function regionKey(gx: number, gz: number): string
		return World.wrap(gx, period) .. ":" .. World.wrap(gz, period)
	end
	for gx = 0, period - 1 do
		for gz = 0, period - 1 do
			local startKey = regionKey(gx, gz)
			if not seen[startKey] and not access.solidAt(gx, gz) then
				seen[startKey] = true
				local regionId = #regions + 1
				regionOf[startKey] = regionId
				local queue = { { gx, gz } }
				local head = 1
				local size = 0
				while head <= #queue do
					local cellX, cellZ = queue[head][1], queue[head][2]
					head += 1
					size += 1
					for _, axis in ipairs(AXES) do
						local nx = World.wrap(cellX + axis[1], period)
						local nz = World.wrap(cellZ + axis[2], period)
						local nKey = regionKey(nx, nz)
						if
							not seen[nKey]
							and not access.solidAt(nx, nz)
							and access.faceOpen(cellX, cellZ, axis[3])
							and access.floorsMeet(cellX, cellZ, axis[1], axis[2])
						then
							seen[nKey] = true
							regionOf[nKey] = regionId
							table.insert(queue, { nx, nz })
						end
					end
				end
				table.insert(regions, size)
			end
		end
	end

	-- The spawn's region, read before the sort reorders the sizes.
	local spawnRegionSize = nil
	if opts.spawn ~= nil then
		local id = regionOf[regionKey(opts.spawn.cellX, opts.spawn.cellZ)]
		spawnRegionSize = if id ~= nil then regions[id] else nil
	end

	table.sort(regions, function(a, b)
		return a > b
	end)
	local largest = regions[1] or 0
	local totalRegionCells = 0
	local largeCells = 0
	local largeThreshold = largeRegionStuds / (cell * cell)
	for _, size in ipairs(regions) do
		totalRegionCells += size
		if size * cell * cell >= largeRegionStuds then
			largeCells += size
		end
	end
	local enclosedCells = totalRegionCells - largest
	local reachableCells = spawnRegionSize or largest

	-- Sightlines along the axes from a sample of open cells.
	local totalSight, samples, maxSight, countSight = 0, 0, 0, 0
	for gx = 0, period - 1, sampleStride do
		for gz = 0, period - 1, sampleStride do
			if not access.solidAt(gx, gz) then
				samples += 1
				local cellSight = 0
				for _, axis in ipairs(AXES) do
					local steps = 0
					local cx, cz = gx, gz
					while steps * cell < maxSightlineStuds do
						if not access.faceOpen(cx, cz, axis[3]) then
							break
						end
						cx = World.wrap(cx + axis[1], period)
						cz = World.wrap(cz + axis[2], period)
						if access.solidAt(cx, cz) then
							break
						end
						steps += 1
					end
					local length = steps * cell
					totalSight += length
					countSight += 1
					if length > maxSight then
						maxSight = length
					end
					if length > cellSight then
						cellSight = length
					end
				end
			end
		end
	end

	local footprint = cells * cell * cell
	local walkable = openCells * cell * cell - wallLength * (opts.wallThickness or 1)

	return {
		cells = cells,
		openCells = openCells,
		solidCells = solidCells,
		openShare = if cells > 0 then openCells / cells else 0,
		footprint = footprint,
		walkable = math.max(0, walkable),
		walkableShare = if footprint > 0 then math.max(0, walkable) / footprint else 0,
		regions = #regions,
		averageRegion = if #regions > 0 then totalRegionCells / #regions else 0,
		largestRegion = largest,
		largeShare = if totalRegionCells > 0 then largeCells / totalRegionCells else 0,
		largeThresholdCells = largeThreshold,
		enclosedRegions = #regions > 1 and #regions - 1 or 0,
		enclosedShare = if totalRegionCells > 0 then enclosedCells / totalRegionCells else 0,
		reachableShare = if totalRegionCells > 0 then reachableCells / totalRegionCells else 0,
		reachableOrigin = if spawnRegionSize ~= nil then "spawn" else "largest",
		largestRegionShare = if totalRegionCells > 0 then largest / totalRegionCells else 0,
		sightlineMean = if countSight > 0 then totalSight / countSight else 0,
		sightlineMax = maxSight,
		sightSamples = samples,
		wallFaces = wallFaces,
		wallLength = wallLength,
	}
end

return Metrics
