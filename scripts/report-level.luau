--!strict

-- Level report: the numbers that decide whether a cell level is the Lobby.
--
--   lune run scripts/report-level.luau [seed] [worldChunks]
--
-- Prints per-chunk size, global layout metrics, crossing time, and a top-down
-- map of the centre chunk with walls drawn.

local process = require("@lune/process")

local OpenAdditive = require("../src/shared/procgen/strategies/OpenAdditive")
local ChunkRenderer = require("../src/shared/procgen/grid/ChunkRenderer")
local Metrics = require("../src/shared/procgen/Metrics")
local World = require("../src/shared/procgen/World")
local Level0 = require("../src/config/levels/Level_0")

local seed = tonumber(process.args[1]) or 42
local worldChunks = tonumber(process.args[2]) or 3

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

local config = clone(Level0)
config.world = clone(Level0.world)
config.world.worldSizeChunks = worldChunks
-- The demo is a closed room: the shipped level wraps, but a 3x3 inspection would
-- otherwise show the stream boundary. Soffits (height steps) apply either way.
config.world.boundaryMode = "wall"
config.render = clone(Level0.render or {})
config.render.enclosure = "perimeter"

local size = World.resolve(config)
local make = OpenAdditive.world(config, seed)
local style = config.style or {}
local renderOptions = {
	style = {
		wallThickness = (style.wallThickness or 1),
		budget = ((config.render or {}).budget or {}).parts or 8000,
		materials = style.materials,
	},
	enclosure = (config.render or {}).enclosure,
	worldChunks = size.chunks,
}

local layouts = {}
local parts, totalMs, detailCount = 0, 0, 0
for cz = 0, size.chunks - 1 do
	for cx = 0, size.chunks - 1 do
		local started = os.clock()
		local layout = OpenAdditive.layout(make, cx, cz, {
			enclosedPolicy = (config.generate and config.generate.enclosedPolicy) or "solidify",
		})
		totalMs += (os.clock() - started) * 1000
		layouts[cx .. ":" .. cz] = layout
		parts += #ChunkRenderer.describe(layout, renderOptions)
		detailCount += #layout.details
	end
end

local metrics = Metrics.compute(make, layouts, {
	largeRegionStuds = (config.verify and config.verify.largeRegionStuds) or 4000,
	maxSightlineStuds = math.min(
		(config.verify and config.verify.maxSightlineStuds) or 2000,
		size.studs
	),
	wallThickness = style.wallThickness or 1,
})

local lap, diagonal = World.crossing(size, config.world.walkSpeed or 16)
local perChunk = parts / (size.chunks * size.chunks)

print(
	string.format(
		"seed %d  world %d chunks (%d studs)  chunk %d cells  cell %d",
		seed,
		size.chunks,
		size.studs,
		make.n,
		make.cell
	)
)
print(
	string.format(
		"cells %d  open %.3f  walkable %.3f  large-region %.3f  enclosed %.3f (%d regions)",
		metrics.cells,
		metrics.openShare,
		metrics.walkableShare,
		metrics.largeShare,
		metrics.enclosedShare,
		metrics.enclosedRegions
	)
)
print(
	string.format(
		"regions %d  avg %.0f cells  largest %.0f cells  sightline mean %.0f / max %.0f studs",
		metrics.regions,
		metrics.averageRegion,
		metrics.largestRegion,
		metrics.sightlineMean,
		metrics.sightlineMax
	)
)
print(
	string.format(
		"wall faces %d (%.2f/cell)  parts %d (%.1f/chunk)  details %d  gen+render %.0f ms",
		metrics.wallFaces,
		metrics.wallFaces / metrics.cells,
		parts,
		perChunk,
		detailCount,
		totalMs
	)
)
print(string.format("crossing: lap %.0f s (%.1f h)  diagonal %.0f s", lap, lap / 3600, diagonal))

local centre = math.floor(size.chunks / 2)
local spawn = OpenAdditive.spawn(make, layouts[centre .. ":" .. centre])
if spawn ~= nil then
	print(
		string.format(
			"spawn cell %d,%d  world %.0f,%.0f  open faces %d  openness %d",
			spawn.cellX,
			spawn.cellZ,
			spawn.x,
			spawn.z,
			spawn.openFaces,
			spawn.openness or 0
		)
	)
else
	print("spawn: NO QUALIFYING CELL")
end

local radius = config.world.generationRadius or 2
local needed = World.requiredRadius(metrics.sightlineMax, size.chunkSize)
print(
	string.format(
		"visibility: sightline %.0f  radius %d  required %d  loaded parts ~%.0f",
		metrics.sightlineMax,
		radius,
		needed,
		World.loadedChunks(radius) * perChunk
	)
)
if needed > radius then
	print("WARNING: radius is smaller than the visible distance; the stream boundary is in view")
end

-- Map of the centre chunk, walls drawn.
local layout = layouts[centre .. ":" .. centre]
local n = layout.n
local function idx(i: number, j: number): number
	return i + (j - 1) * n
end
-- Faces are stored once (E/S); W/N are the neighbour's E/S, or the pure line
-- function at the chunk border.
local function west(i: number, j: number): boolean
	if i > 1 then
		return layout.sealedE[idx(i - 1, j)] == true
	end
	return OpenAdditive.faceV(make, layout.cx * n, layout.cz * n + j - 1)
end
local function north(i: number, j: number): boolean
	if j > 1 then
		return layout.sealedS[idx(i, j - 1)] == true
	end
	return OpenAdditive.faceH(make, layout.cx * n + i - 1, layout.cz * n)
end
print(string.format("\ncentre chunk %d,%d", centre, centre))
for j = 1, n do
	local top = {}
	for i = 1, n do
		top[#top + 1] = if north(i, j) then "+--" else "+  "
	end
	top[#top + 1] = "+"
	print(table.concat(top))
	local row = {}
	for i = 1, n do
		row[#row + 1] = if west(i, j) then "|" else " "
		row[#row + 1] = if layout.solid[idx(i, j)] then "##" else "  "
	end
	row[#row + 1] = if layout.sealedE[idx(n, j)] then "|" else " "
	print(table.concat(row))
end
local bottom = {}
for i = 1, n do
	bottom[#bottom + 1] = if layout.sealedS[idx(i, n)] then "+--" else "+  "
end
bottom[#bottom + 1] = "+"
print(table.concat(bottom))
