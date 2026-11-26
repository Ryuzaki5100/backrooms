--!strict

local H = require("../harness")
local World = require("../../src/shared/procgen/World")
local OpenAdditive = require("../../src/shared/procgen/strategies/OpenAdditive")
local WalkGraph = require("../../src/shared/procgen/grid/WalkGraph")
local Terrain = require("../../src/shared/procgen/features/Terrain")
local Level0 = require("../../src/config/levels/Level_0")

local function level(world: any): any
	return {
		id = "test",
		strategy = { name = "open_additive", params = { cell = 16, chunkCells = 18 } },
		world = world,
	}
end

H.test("size tiers derive a finite world from a lap time", function()
	local tiny = World.resolve(level({ sizeTier = "tiny" }))
	H.eq(tiny.chunkSize, 288, "16 x 18")
	H.eq(tiny.chunks, 4, "60 s at 16 studs/s = 960 studs = 4 chunks")

	local vast = World.resolve(level({ sizeTier = "vast" }))
	H.eq(vast.chunks, 400, "2 h at 16 studs/s = 115200 studs = 400 chunks")
	H.eq(vast.studs, 115200)
end)

H.test("worldSizeChunks overrides the tier", function()
	local resolved = World.resolve(level({ sizeTier = "vast", worldSizeChunks = 3 }))
	H.eq(resolved.chunks, 3)
	H.eq(resolved.studs, 864)
end)

H.test("endless needs an explicit size or infinite boundary", function()
	H.ok(not pcall(World.resolve, level({ sizeTier = "endless" })), "must refuse")
end)

H.test("wrap is positive for negative coordinates", function()
	H.eq(World.wrap(-1, 10), 9)
	H.eq(World.wrap(-10, 10), 0)
	H.eq(World.wrap(12, 10), 2)
end)

H.test("distance is toroidal, not subtraction", function()
	-- 0 and 863 are neighbours on an 864-stud world.
	H.eq(World.distance(0, 0, 863, 0, 864), 1)
	H.eq(World.distance(10, 10, 20, 10, 864), 10)
	-- Half a world away is the maximum.
	H.eq(World.distance(0, 0, 432, 0, 864), 432)
end)

H.test("crossing time is derived from the resolved world", function()
	local size = World.resolve(level({ sizeTier = "tiny", worldSizeChunks = 3 }))
	local lap, diagonal = World.crossing(size, 16)
	H.eq(lap, 864 / 16)
	H.ok(diagonal > lap, "diagonal is longer")
end)

H.test("required radius covers the visible distance", function()
	H.eq(World.requiredRadius(300, 288), 3)
	H.eq(World.requiredRadius(288, 288), 2)
	H.eq(World.loadedChunks(1), 9)
	H.eq(World.loadedChunks(2), 25)
end)

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

local STEPS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- Terrain regions of a laid-out chunk: non-solid, non-template cells of equal
-- floorY that touch (partition walls do not split a region). Returns the cells of each and a lookup.
local function terrainRegions(layout: any): ({ { number } }, { [number]: number })
	local n = layout.n
	local regionOf: { [number]: number } = {}
	local regions: { { number } } = {}
	for start = 1, n * n do
		if
			regionOf[start] == nil
			and not layout.solid[start]
			and not layout.templateCell[start]
		then
			local cells = { start }
			regionOf[start] = #regions + 1
			local head = 1
			while head <= #cells do
				local current = cells[head]
				head += 1
				local i, j = (current - 1) % n + 1, (current - 1) // n + 1
				for _, step in ipairs(STEPS) do
					local ni, nj = i + step[1], j + step[2]
					if ni >= 1 and nj >= 1 and ni <= n and nj <= n then
						local other = ni + (nj - 1) * n
						if
							regionOf[other] == nil
							and not layout.solid[other]
							and not layout.templateCell[other]
							and layout.floorY[other] == layout.floorY[start]
						then
							regionOf[other] = #regions + 1
							table.insert(cells, other)
						end
					end
				end
			end
			table.insert(regions, cells)
		end
	end
	return regions, regionOf
end

H.test("ramps are sparse: per region boundary, spaced, still connected", function()
	local totalRamps = 0
	for seed = 1, 10 do
		local config = clone(Level0)
		config.world.worldSizeChunks = 3
		config.world.boundaryMode = "wrap"
		config.strategy.params.terrain = {
			rise = 4,
			plateauShare = 0.15,
			sunkenShare = 0.15,
			rampChance = 0.30,
			minHeadroom = 9,
		}
		local make = OpenAdditive.world(config, seed)
		local stepMax = Terrain.stepMax(make)
		local spacing = Terrain.rampSpacing(make)
		local extraCells = Terrain.extraRampCells(make)
		local seedRamps, maxPerBoundary, maxPerRegion = 0, 0, 0
		for cz = 0, 2 do
			for cx = 0, 2 do
				local layout = OpenAdditive.layout(make, cx, cz)
				local n = layout.n
				local where = "seed " .. seed .. " chunk " .. cx .. "," .. cz
				local regions, regionOf = terrainRegions(layout)
				-- Ramps grouped by the region boundary they cross: the region they
				-- climb onto and the region (or outside floor) they descend to.
				local boundaries: { [string]: { cells: { { number } }, cap: number } } = {}
				local byRegion: { [number]: { { number } } } = {}
				for index, ramp in pairs(layout.ramp) do
					seedRamps += 1
					local i, j = (index - 1) % n + 1, (index - 1) // n + 1
					local high = regionOf[index]
					H.ok(high ~= nil, where .. ": a ramp stands on open ground")
					if high ~= nil then
						local li = if ramp.axis == "x" then i - ramp.dir else i
						local lj = if ramp.axis == "z" then j - ramp.dir else j
						local lowSize = 0
						local lowKey = "out" .. ramp.lowY
						if li >= 1 and lj >= 1 and li <= n and lj <= n then
							local low = regionOf[li + (lj - 1) * n]
							lowKey = "r" .. tostring(low)
							lowSize = if low ~= nil then #regions[low] else 0
						end
						local key = high .. ">" .. lowKey
						local size = math.max(#regions[high], lowSize)
						local entry = boundaries[key]
						if entry == nil then
							local cap = 2
							if size > extraCells then
								cap = math.floor(size / extraCells + 0.5) + 1
							end
							entry = { cells = {}, cap = cap }
							boundaries[key] = entry
						end
						table.insert(entry.cells, { i, j })
						byRegion[high] = byRegion[high] or {}
						table.insert(byRegion[high], { i, j })
					end
				end
				for key, entry in pairs(boundaries) do
					maxPerBoundary = math.max(maxPerBoundary, #entry.cells)
					H.ok(
						#entry.cells <= entry.cap,
						where .. ": boundary " .. key .. " has " .. #entry.cells .. " ramps"
					)
				end
				for region, list in pairs(byRegion) do
					maxPerRegion = math.max(maxPerRegion, #list)
					for a = 1, #list do
						for b = a + 1, #list do
							local apart = math.abs(list[a][1] - list[b][1])
								+ math.abs(list[a][2] - list[b][2])
							H.ok(
								apart >= spacing,
								where
									.. ": two ramps "
									.. apart
									.. " cells apart in one region of "
									.. #regions[region]
							)
						end
					end
				end

				H.eq(
					#WalkGraph.unbridgedRises(layout, { stepMax = stepMax }),
					0,
					where .. ": no open cliffs"
				)
				local graph = WalkGraph.build(layout, { stepMax = stepMax })
				local comps = WalkGraph.components(graph)
				if #comps > 0 then
					local main = 1
					for index = 2, #comps do
						if comps[index].size > comps[main].size then
							main = index
						end
					end
					for index, comp in ipairs(comps) do
						if index ~= main then
							local outward = false
							for _, cell in ipairs(comp.cells) do
								local i, j = (cell - 1) % n + 1, (cell - 1) // n + 1
								local gx, gz = cx * n + i - 1, cz * n + j - 1
								local floor = layout.floorY[cell]
								outward = outward
									or (i == n and not layout.sealedE[cell])
									or (j == n and not layout.sealedS[cell])
									or (i == 1 and not OpenAdditive.faceV(make, gx, gz) and math.abs(
										Terrain.terrainAt(make, gx - 1, gz) - floor
									) <= stepMax)
									or (
										j == 1
										and not OpenAdditive.faceH(make, gx, gz)
										and math.abs(
												Terrain.terrainAt(make, gx, gz - 1) - floor
											)
											<= stepMax
									)
							end
							H.ok(outward, where .. ": unreachable component of " .. comp.size)
						end
					end
				end
			end
		end
		totalRamps += seedRamps
		print(
			string.format(
				"  [ramps] seed %d: %d ramps over 9 chunks, at most %d per boundary, %d per region",
				seed,
				seedRamps,
				maxPerBoundary,
				maxPerRegion
			)
		)
	end
	print(string.format("  [ramps] total: %d ramps (was 733 with per-face rolls)", totalRamps))
	H.ok(totalRamps < 733 / 2, "ramps are well below the per-face baseline")
end)
