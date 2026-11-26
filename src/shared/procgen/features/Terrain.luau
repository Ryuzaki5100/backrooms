--!strict

-- Terrain feature (ADR 0029): per-cell floor heights and the ramps/steps that
-- cross them. Level 0 ships flat (banded shares of 0), but the machinery is
-- here and testable, so a level that wants mezzanines/sunken areas only picks
-- a band.

local Common = if script ~= nil then require(script.Parent.Common) else require("./Common")
local Rng = if script ~= nil then require(script.Parent.Parent.Rng) else require("../Rng")
local Layout = if script ~= nil
	then require(script.Parent.Parent.grid.ChunkLayout)
	else require("../grid/ChunkLayout")

local Terrain = {}

Terrain.id = "terrain"

local DEFAULTS = {
	rise = 4,
	plateauShare = 0.10,
	sunkenShare = 0.10,
	rampChance = 0.15,
	stepMax = 1,
	minHeadroom = 9,
}

-- Draw the banded shares once per seed.
function Terrain.drawShares(seed: number, terrain: any): any
	local rng = Rng.new(seed):fork("terrain")
	local t = terrain or {}
	return {
		plateau = Common.bandValue(rng, t.plateauShare, DEFAULTS.plateauShare),
		sunken = Common.bandValue(rng, t.sunkenShare, DEFAULTS.sunkenShare),
		rampChance = Common.bandValue(rng, t.rampChance, DEFAULTS.rampChance),
	}
end

-- Floor height of a world cell. A coarse zone field, not per-cell noise, so
-- plateaus and sunken areas are large enough to walk on.
function Terrain.terrainAt(make: any, gx: number, gz: number): number
	local terrain = make.params.terrain
	if terrain == nil then
		return 0
	end
	local blocks = terrain.blocksPerZone or 2
	local span = make.block * blocks
	local bx = math.floor(Common.canonical(make, gx) / span)
	local bz = math.floor(Common.canonical(make, gz) / span)
	local roll = Common.hash01(make.seed, "terrain", bx, bz)
	local shares = make.terrainShares or { plateau = 0, sunken = 0 }
	local level = terrain.rise or DEFAULTS.rise
	if roll < shares.sunken then
		return -level
	elseif roll < shares.sunken + shares.plateau then
		return level
	end
	return 0
end

-- Largest floor difference walked without a ramp (WalkGraph and the repair
-- pass use the same number the boundary rules do).
function Terrain.stepMax(make: any): number
	local terrain = make.params and make.params.terrain
	return (terrain and terrain.stepMax) or DEFAULTS.stepMax
end

-- Floor height at chunk-local cell (i, j); outside the chunk it is read from the
-- terrain field, so a chunk border agrees with its neighbour without reading it.
function Terrain.floorAt(make: any, layout: any, i: number, j: number): number
	local n = layout.n
	if i < 1 or j < 1 or i > n or j > n then
		return Terrain.terrainAt(make, layout.cx * n + i - 1, layout.cz * n + j - 1)
	end
	return layout.floorY[Layout.index(n, i, j)]
end

-- The one ramp rule (ADR 0029, shared by `apply` and the connectivity repair):
-- a ramp stands on the HIGH side of a boundary, in a cell that is free of ramp,
-- column, template and hanging wall, and only when the plateau continues at the
-- same level on the far side (`dir` points towards the high end, so the cell
-- beyond is at +dir along `axis`). Returns whether the ramp was placed; the
-- boundary face's sealed flag is the caller's business.
function Terrain.tryRamp(
	make: any,
	layout: any,
	i: number,
	j: number,
	axis: string,
	dir: number,
	lowY: number,
	highY: number
): boolean
	local n = layout.n
	if i < 1 or j < 1 or i > n or j > n then
		return false
	end
	local index = Layout.index(n, i, j)
	if
		layout.ramp[index] ~= nil
		or layout.column[index]
		or layout.templateCell[index]
		or layout.hangE[index]
		or layout.hangS[index]
		or (i > 1 and layout.hangE[Layout.index(n, i - 1, j)])
		or (j > 1 and layout.hangS[Layout.index(n, i, j - 1)])
	then
		return false
	end
	local beyondI = if axis == "x" then i + dir else i
	local beyondJ = if axis == "z" then j + dir else j
	if Terrain.floorAt(make, layout, beyondI, beyondJ) ~= layout.floorY[index] then
		-- The plateau does not continue: a ramp would end in mid-air.
		return false
	end
	layout.ramp[index] = { axis = axis, dir = dir, lowY = lowY, highY = highY }
	return true
end

-- Apply the boundary rules: a rise above one stud is a retaining edge unless a
-- ramp can stand on the higher side and continue into the plateau. Headroom is
-- raised wherever needed.
function Terrain.apply(make: any, layout: any): ()
	local terrain = make.params.terrain or {}
	local stepMax = terrain.stepMax or DEFAULTS.stepMax
	local minHeadroom = terrain.minHeadroom or DEFAULTS.minHeadroom
	local n = layout.n
	local originX = layout.cx * n
	local originZ = layout.cz * n

	local function floorOf(i: number, j: number): number
		return Terrain.floorAt(make, layout, i, j)
	end

	local rampChance = make.terrainShares and make.terrainShares.rampChance or DEFAULTS.rampChance

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
					local chosen = Common.hash01(
						make.seed,
						"ramp:x",
						Common.canonical(make, originX + i - 1),
						Common.canonical(make, originZ + j - 1)
					) < rampChance
					local placed = chosen
						and Terrain.tryRamp(
							make,
							layout,
							rampI,
							j,
							"x",
							if highIsHere then -1 else 1,
							math.min(here, east),
							math.max(here, east)
						)
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
					local chosen = Common.hash01(
						make.seed,
						"ramp:z",
						Common.canonical(make, originX + i - 1),
						Common.canonical(make, originZ + j - 1)
					) < rampChance
					local placed = chosen
						and Terrain.tryRamp(
							make,
							layout,
							i,
							rampJ,
							"z",
							if highIsHere then -1 else 1,
							math.min(here, south),
							math.max(here, south)
						)
					layout.sealedS[index] = not placed
				end
			end
		end
	end

	for index = 1, n * n do
		layout.height[index] = math.max(layout.height[index], minHeadroom)
	end
end

return Terrain
