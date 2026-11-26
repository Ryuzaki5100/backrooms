--!strict

local H = require("../harness")
local OpenAdditive = require("../../src/shared/procgen/strategies/OpenAdditive")
local ChunkRenderer = require("../../src/shared/procgen/grid/ChunkRenderer")
local Metrics = require("../../src/shared/procgen/Metrics")
local ChunkLayout = require("../../src/shared/procgen/grid/ChunkLayout")
local WalkGraph = require("../../src/shared/procgen/grid/WalkGraph")
local Terrain = require("../../src/shared/procgen/features/Terrain")
local Hash = require("../../src/shared/procgen/Hash")
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

local function demo(seed: number): any
	local config = clone(Level0)
	config.world = clone(Level0.world)
	config.world.worldSizeChunks = 3
	config.world.boundaryMode = "wrap"
	return OpenAdditive.world(config, seed)
end

local function signature(layout: any): string
	local parts = {}
	for i = 1, layout.n * layout.n do
		parts[#parts + 1] = (if layout.solid[i] then "1" else "0")
			.. (if layout.sealedE[i] then "1" else "0")
			.. (if layout.sealedS[i] then "1" else "0")
			.. layout.height[i]
	end
	return table.concat(parts, ",")
end

H.test("the same seed produces the same chunk", function()
	local a = OpenAdditive.layout(demo(42), 1, 1)
	local b = OpenAdditive.layout(demo(42), 1, 1)
	H.eq(signature(a), signature(b))
end)

H.test("a chunk does not depend on what was generated before it", function()
	local alone = OpenAdditive.layout(demo(42), 2, 1)
	local make = demo(42)
	OpenAdditive.layout(make, 0, 0)
	OpenAdditive.layout(make, 1, 0)
	OpenAdditive.layout(make, 0, 1)
	local after = OpenAdditive.layout(make, 2, 1)
	H.eq(signature(alone), signature(after), "chunk order independence")
end)

H.test("wrapped chunk coordinates generate the identical chunk", function()
	local make = demo(42)
	local zero = OpenAdditive.layout(make, 0, 0)
	local wrapped = OpenAdditive.layout(make, 3, 0)
	H.eq(signature(zero), signature(wrapped), "chunk 3 is chunk 0")
end)

H.test("chunk borders agree on terrain, not just walls", function()
	-- The east owner decides a border face. Terrain overrides wall runs there, so
	-- the invariant is: a rise above one stud is sealed unless a ramp was placed,
	-- and a one-stud rise is open. Cell heights stay periodic.
	local make = demo(42)
	local east = OpenAdditive.layout(make, 2, 0)
	local n = make.n
	H.eq(
		select(2, OpenAdditive.cell(make, 0, 5)),
		select(2, OpenAdditive.cell(make, 3 * n, 5)),
		"border cell height is periodic"
	)
	for j = 1, n do
		local _, _, westFloor = OpenAdditive.cell(make, 3 * n - 1, j - 1)
		local _, _, eastFloor = OpenAdditive.cell(make, 3 * n, j - 1)
		local sealed = east.sealedE[n + (j - 1) * n]
		local rise = math.abs(eastFloor - westFloor)
		if rise > 1 then
			local ramp = east.ramp[n + (j - 1) * n]
			if ramp ~= nil then
				H.eq(sealed, false, "a ramp keeps the border open")
			else
				H.eq(sealed, true, "a rise above a step is a retaining edge")
			end
		elseif rise == 1 then
			H.eq(sealed, false, "a one-stud rise is a step")
		end
	end
end)

H.test("a chunk is a handful of parts, not hundreds", function()
	local layout = OpenAdditive.layout(demo(42), 1, 1)
	local parts = ChunkRenderer.describe(layout, { style = { budget = 400, wallThickness = 1 } })
	H.ok(#parts <= 120, "parts per chunk: " .. #parts)
end)

H.test("the world is one open region, not a grid of sealed rooms", function()
	local make = demo(42)
	local layouts = {}
	for cz = 0, 2 do
		for cx = 0, 2 do
			layouts[cx .. ":" .. cz] = OpenAdditive.layout(make, cx, cz)
		end
	end
	local metrics =
		Metrics.compute(make, layouts, { largeRegionStuds = 4000, maxSightlineStuds = 2000 })
	H.ok(metrics.openShare > 0.85, "open share " .. metrics.openShare)
	H.ok(metrics.enclosedShare < 0.10, "enclosed share " .. metrics.enclosedShare)
	H.ok(metrics.wallFaces > 100, "has partitions")
	H.ok(metrics.sightlineMean > 80, "can see across a hall: " .. metrics.sightlineMean)
end)

H.test("details are capped and deterministic", function()
	local a = OpenAdditive.layout(demo(42), 1, 1)
	local b = OpenAdditive.layout(demo(42), 1, 1)
	H.eq(#a.details, #b.details, "same detail count")
	local cap = 18
	local counts: { [string]: number } = {}
	for _, detail in ipairs(a.details) do
		counts[detail.id] = (counts[detail.id] or 0) + 1
	end
	for id, count in pairs(counts) do
		H.ok(count <= cap, id .. " exceeds cap: " .. count)
	end
end)

H.test("metrics are wrap-aware: 0 and the last cell are neighbours", function()
	local make = demo(42)
	local layouts = {}
	for cz = 0, 2 do
		for cx = 0, 2 do
			layouts[cx .. ":" .. cz] = OpenAdditive.layout(make, cx, cz)
		end
	end
	local metrics = Metrics.compute(make, layouts)
	H.ok(metrics.regions >= 1)
	H.eq(metrics.enclosedRegions, metrics.regions - 1, "enclosed = all but the main region")
end)

H.test("spawn prefers open ground over a spot beside a long wall", function()
	local make = demo(42)
	local layout = OpenAdditive.layout(make, 1, 1)
	local spawn = OpenAdditive.spawn(make, layout)
	H.ok(spawn ~= nil, "has a spawn")
	H.ok(spawn.openFaces >= 3, "at least three ways out: " .. spawn.openFaces)
	H.ok((spawn.openness or 0) >= 60, "open neighbourhood: " .. tostring(spawn.openness))
end)

H.test("terrain generates plateaus and sound ramps when enabled", function()
	-- Level 0 ships flat; the ramp machinery is exercised by enabling terrain on
	-- a clone, so a broken ramp is still caught without shipping one.
	local config = clone(Level0)
	config.world = clone(Level0.world)
	config.world.worldSizeChunks = 3
	config.world.boundaryMode = "wrap"
	config.strategy = clone(Level0.strategy)
	config.strategy.params = clone(Level0.strategy.params)
	config.strategy.params.terrain = {
		rise = 4,
		plateauShare = 0.15,
		sunkenShare = 0.15,
		rampChance = 0.30,
		minHeadroom = 9,
	}
	local make = OpenAdditive.world(config, 42)
	local ramps = 0
	for cz = 0, 2 do
		for cx = 0, 2 do
			local layout = OpenAdditive.layout(make, cx, cz)
			for j = 1, layout.n do
				for i = 1, layout.n do
					local index = i + (j - 1) * layout.n
					local ramp = layout.ramp[index]
					if ramp ~= nil then
						ramps += 1
						local gx = cx * layout.n + i - 1
						local gz = cz * layout.n + j - 1
						local _, _, floor = OpenAdditive.cell(make, gx, gz)
						H.eq(floor, ramp.highY, "ramp sits on the high side")
						local lowNeighbour = false
						for _, step in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
							local _, _, other = OpenAdditive.cell(make, gx + step[1], gz + step[2])
							if other == ramp.lowY then
								lowNeighbour = true
							end
						end
						H.ok(lowNeighbour, "the low edge meets a lower floor")
					end
					H.ok(layout.height[index] >= 9, "headroom")
				end
			end
		end
	end
	H.ok(ramps > 0, "has ramps")
end)

local function terrainWorld(seed: number): any
	local config = clone(Level0)
	config.world = clone(Level0.world)
	config.world.worldSizeChunks = 3
	config.world.boundaryMode = "wrap"
	config.strategy = clone(Level0.strategy)
	config.strategy.params = clone(Level0.strategy.params)
	config.strategy.params.terrain = {
		rise = 4,
		plateauShare = 0.15,
		sunkenShare = 0.15,
		rampChance = 0.30,
		minHeadroom = 9,
	}
	return OpenAdditive.world(config, seed)
end

local STEPS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- Cells with floorY ~= 0 flooded by equal floor level (walls ignored): each
-- result is one plateau / sunken region.
local function levelRegions(layout: any): { { number } }
	local n = layout.n
	local seen: { [number]: boolean } = {}
	local regions = {}
	for start = 1, n * n do
		if not seen[start] and not layout.solid[start] and layout.floorY[start] ~= 0 then
			local level = layout.floorY[start]
			local cells = { start }
			seen[start] = true
			local head = 1
			while head <= #cells do
				local current = cells[head]
				head += 1
				local i, j = (current - 1) % n + 1, (current - 1) // n + 1
				for _, step in ipairs(STEPS) do
					local ni, nj = i + step[1], j + step[2]
					if ni >= 1 and nj >= 1 and ni <= n and nj <= n then
						local other = ChunkLayout.index(n, ni, nj)
						if
							not seen[other]
							and not layout.solid[other]
							and layout.floorY[other] == level
						then
							seen[other] = true
							table.insert(cells, other)
						end
					end
				end
			end
			table.insert(regions, cells)
		end
	end
	return regions
end

-- Whether the cell at `index` can walk out of the chunk through a border face.
-- East and south faces are this chunk's; west and north are the neighbour's, so
-- they count when the seam leaves them open and the floors meet within stepMax.
local function opensOutward(make: any, layout: any, index: number, stepMax: number): boolean
	local n = layout.n
	local i, j = (index - 1) % n + 1, (index - 1) // n + 1
	local gx, gz = layout.cx * n + i - 1, layout.cz * n + j - 1
	local floor = layout.floorY[index]
	return (i == n and not layout.sealedE[index])
		or (j == n and not layout.sealedS[index])
		or (i == 1 and not OpenAdditive.faceV(make, gx, gz) and math.abs(
			Terrain.terrainAt(make, gx - 1, gz) - floor
		) <= stepMax)
		or (
			j == 1
			and not OpenAdditive.faceH(make, gx, gz)
			and math.abs(Terrain.terrainAt(make, gx, gz - 1) - floor) <= stepMax
		)
end

H.test("terrain sweep: no open cliffs, every region reachable", function()
	local totalRamps, totalSolidified = 0, 0
	for seed = 1, 10 do
		local make = terrainWorld(seed)
		local stepMax = Terrain.stepMax(make)
		local repaired, solidified, regionCount, tails = 0, 0, 0, 0
		local layouts = {}
		for cz = 0, 2 do
			for cx = 0, 2 do
				local layout = OpenAdditive.layout(make, cx, cz)
				layouts[cx .. ":" .. cz] = layout
				local where = "seed " .. seed .. " chunk " .. cx .. "," .. cz
				repaired += layout.rampsRepaired
				solidified += layout.solidified
				local n = layout.n

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
					local reach = WalkGraph.reachableFrom(graph, comps[main].cells[1])
					-- A walkable cell outside main's component is only allowed when the
					-- component continues into the neighbouring chunk, which this chunk
					-- may not decide (a border tail); anything else would be a pocket.
					for _, comp in ipairs(comps) do
						if not reach[comp.cells[1]] then
							local outward = false
							for _, index in ipairs(comp.cells) do
								outward = outward or opensOutward(make, layout, index, stepMax)
							end
							tails += comp.size
							H.ok(
								outward,
								where .. ": unreachable component of " .. comp.size .. " cells"
							)
						end
					end
				end

				-- A plateau or sunken region needs a ramp in it or beside it, unless it
				-- runs off the chunk (its way up may be in the neighbour).
				for _, cells in ipairs(levelRegions(layout)) do
					regionCount += 1
					local bridged, offChunk = false, false
					for _, index in ipairs(cells) do
						local i, j = (index - 1) % n + 1, (index - 1) // n + 1
						if i == 1 or j == 1 or i == n or j == n then
							offChunk = true
						end
						if layout.ramp[index] ~= nil then
							bridged = true
						end
						for _, step in ipairs(STEPS) do
							local ni, nj = i + step[1], j + step[2]
							if ni >= 1 and nj >= 1 and ni <= n and nj <= n then
								if layout.ramp[ChunkLayout.index(n, ni, nj)] ~= nil then
									bridged = true
								end
							end
						end
					end
					H.ok(
						bridged or offChunk,
						where .. ": region of " .. #cells .. " cells has no ramp"
					)
				end
			end
		end
		-- Across chunk borders the border tails join their neighbours: the whole
		-- wrap world is one walk region.
		local metrics = Metrics.compute(make, layouts, { sightlineStride = 6 })
		H.eq(metrics.regions, 1, "seed " .. seed .. ": one walk region across the world")
		H.eq(metrics.reachableShare, 1, "seed " .. seed .. ": reachableShare")
		totalRamps += repaired
		totalSolidified += solidified
		print(
			string.format(
				"  [sweep] seed %d: %d ramps added by repair, %d cells solidified, %d border-tail cells, %d level regions",
				seed,
				repaired,
				solidified,
				tails,
				regionCount
			)
		)
	end
	print(
		string.format(
			"  [sweep] total: %d repair ramps, %d solidified cells",
			totalRamps,
			totalSolidified
		)
	)
end)

H.test("metrics: a plateau without a ramp is not in the reachable region", function()
	local n = 6
	local make = { n = n, cell = 16, period = n, seed = 1, params = {} }
	local function at(i: number, j: number): number
		return ChunkLayout.index(n, i, j)
	end
	local function near(a: number, b: number): boolean
		return math.abs(a - b) < 1e-9
	end
	-- A 2x2 plateau at (3..4, 3..4), rise 4, walled on all four sides.
	local function plateau(withRamp: boolean): any
		local layout = ChunkLayout.new(0, 0, n, 16)
		for j = 3, 4 do
			for i = 3, 4 do
				layout.floorY[at(i, j)] = 4
			end
		end
		for k = 3, 4 do
			layout.sealedE[at(2, k)] = true
			layout.sealedE[at(4, k)] = true
			layout.sealedS[at(k, 2)] = true
			layout.sealedS[at(k, 4)] = true
		end
		if withRamp then
			-- (3,3) climbs eastwards onto the plateau from (2,3).
			layout.ramp[at(3, 3)] = { axis = "x", dir = 1, lowY = 0, highY = 4 }
			layout.sealedE[at(2, 3)] = false
		end
		return layout
	end

	local walled = Metrics.compute(make, { ["0:0"] = plateau(false) })
	H.eq(walled.regions, 2, "the walled plateau is its own region")
	H.eq(walled.largestRegion, 32, "main region")
	H.ok(near(walled.reachableShare, 32 / 36), "plateau is not reachable")
	H.eq(walled.reachableOrigin, "largest", "no spawn given")

	local ramped = Metrics.compute(make, { ["0:0"] = plateau(true) })
	H.eq(ramped.regions, 1, "the ramp joins the plateau")
	H.ok(near(ramped.reachableShare, 1), "plateau is reachable")

	-- The spawn picks the region: standing on the plateau, only it is reachable.
	local fromPlateau = Metrics.compute(
		make,
		{ ["0:0"] = plateau(false) },
		{ spawn = { cellX = 2, cellZ = 2 } }
	)
	H.eq(fromPlateau.reachableOrigin, "spawn", "spawn given")
	H.ok(near(fromPlateau.reachableShare, 4 / 36), "the spawn's own region")

	-- Unsealed but 4 studs up with no ramp: an open cliff is not a way in.
	local cliff = plateau(false)
	cliff.sealedE[at(2, 3)] = false
	H.eq(Metrics.compute(make, { ["0:0"] = cliff }).regions, 2, "an open cliff is not walkable")

	-- A 1-stud step needs no ramp.
	local stepped = plateau(false)
	for j = 3, 4 do
		for i = 3, 4 do
			stepped.floorY[at(i, j)] = 1
		end
	end
	stepped.sealedE[at(2, 3)] = false
	H.eq(Metrics.compute(make, { ["0:0"] = stepped }).regions, 1, "a 1-stud step is walkable")
end)

local function partFingerprint(config: any, seed: number): (string, number)
	local make = OpenAdditive.world(config, seed)
	local lines = {}
	for cz = 0, 2 do
		for cx = 0, 2 do
			local layout = OpenAdditive.layout(make, cx, cz)
			for _, part in ipairs(ChunkRenderer.describe(layout, { style = { budget = 9000 } })) do
				lines[#lines + 1] = table.concat({
					part.kind,
					part.owner,
					tostring(part.size[1]),
					tostring(part.size[2]),
					tostring(part.size[3]),
					tostring(part.position[1]),
					tostring(part.position[2]),
					tostring(part.position[3]),
					tostring(part.yaw),
					tostring(part.wedge or false),
				}, "|")
			end
		end
	end
	table.sort(lines)
	return Hash.of(table.concat(lines, "\n")), #lines
end

H.test("pinned Level 0 fingerprint (templates clear their footprint)", function()
	-- The shipped config fingerprints to these values. Re-baseline deliberately
	-- whenever a feature changes geometry on purpose.
	local config = clone(Level0)
	config.world = clone(Level0.world)
	config.world.worldSizeChunks = 3

	local fp42, count42 = partFingerprint(config, 42)
	H.eq(fp42, "2a1d1eac7fbc544a", "seed 42 fingerprint")
	H.eq(count42, 524, "seed 42 part count (506 + a cap and a base per template)")

	local fp1337, count1337 = partFingerprint(config, 1337)
	H.eq(fp1337, "91dd197390bbc4e5", "seed 1337 fingerprint")
	H.eq(count1337, 500, "seed 1337 part count")
end)
