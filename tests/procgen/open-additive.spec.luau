--!strict

local H = require("../harness")
local OpenAdditive = require("../../src/shared/procgen/strategies/OpenAdditive")
local ChunkRenderer = require("../../src/shared/procgen/grid/ChunkRenderer")
local Metrics = require("../../src/shared/procgen/Metrics")
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
	H.eq(fp42, "486e871bef980b8d", "seed 42 fingerprint")
	H.eq(count42, 506, "seed 42 part count")

	local fp1337, count1337 = partFingerprint(config, 1337)
	H.eq(fp1337, "0955f018db7b7c1e", "seed 1337 fingerprint")
	H.eq(count1337, 480, "seed 1337 part count")
end)
