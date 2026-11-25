--!strict

local H = require("../harness")
local OpenAdditive = require("../../src/shared/procgen/strategies/OpenAdditive")
local ChunkRenderer = require("../../src/shared/procgen/grid/ChunkRenderer")
local Metrics = require("../../src/shared/procgen/Metrics")
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

H.test("chunk borders agree from both sides", function()
	local make = demo(42)
	local east = OpenAdditive.layout(make, 2, 0)
	local n = make.n
	H.eq(
		select(2, OpenAdditive.cell(make, 0, 5)),
		select(2, OpenAdditive.cell(make, 3 * n, 5)),
		"border cell height is periodic"
	)
	for j = 1, n do
		H.eq(
			OpenAdditive.faceV(make, 0, j - 1),
			east.sealedE[n + (j - 1) * n],
			"west border face equals the east neighbour's face"
		)
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
	H.ok(metrics.sightlineMean > 100, "can see across a hall: " .. metrics.sightlineMean)
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
