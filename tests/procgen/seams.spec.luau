--!strict

-- Seams (task 0020, ADR 0031 D63): vertical terrain stays off a chunk's outer
-- ring, so neighbouring chunks agree on their shared border without reading each
-- other, and no ramp opens onto another ramp or a wall.

local H = require("../harness")
local OpenAdditive = require("../../src/shared/procgen/strategies/OpenAdditive")
local WalkGraph = require("../../src/shared/procgen/grid/WalkGraph")
local Terrain = require("../../src/shared/procgen/features/Terrain")
local Level0 = require("../../src/config/levels/Level_0")

local WORLD_CHUNKS = 4

local function clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in pairs(value) do
		copy[key] = clone(item)
	end
	return copy
end

-- Level 0 as shipped, wrapping 4 x 4 chunks, terrain bands on.
local function terrainWorld(seed: number): any
	local config = clone(Level0)
	config.world.worldSizeChunks = WORLD_CHUNKS
	config.world.boundaryMode = "wrap"
	config.strategy.params.terrain = {
		rise = 4,
		plateauShare = 0.15,
		sunkenShare = 0.15,
		rampChance = 1,
		minHeadroom = 9,
	}
	return OpenAdditive.world(config, seed)
end

H.test("terrain stays off chunk borders and ramps keep clear ends (D63, R5)", function()
	local totalRamps, totalCells, plateauCells, sunkenCells = 0, 0, 0, 0
	local borderPairs, tailChunks = 0, 0
	for seed = 1, 10 do
		local make = terrainWorld(seed)
		local n = make.n
		local stepMax = Terrain.stepMax(make)
		local layouts: { [string]: any } = {}
		for cz = 0, WORLD_CHUNKS - 1 do
			for cx = 0, WORLD_CHUNKS - 1 do
				layouts[cx .. "," .. cz] = OpenAdditive.layout(make, cx, cz)
			end
		end
		for cz = 0, WORLD_CHUNKS - 1 do
			for cx = 0, WORLD_CHUNKS - 1 do
				local layout = layouts[cx .. "," .. cz]
				local where = "seed " .. seed .. " chunk " .. cx .. "," .. cz
				-- (a) borders agree and are flat, E (incl. wrap) and S.
				local east = layouts[((cx + 1) % WORLD_CHUNKS) .. "," .. cz]
				local south = layouts[cx .. "," .. ((cz + 1) % WORLD_CHUNKS)]
				for k = 1, n do
					local eastHere = layout.floorY[n + (k - 1) * n]
					local eastThere = east.floorY[1 + (k - 1) * n]
					H.eq(eastHere, eastThere, where .. " E border row " .. k)
					H.eq(eastHere, 0, where .. " E border flat, row " .. k)
					local southHere = layout.floorY[k + (n - 1) * n]
					local southThere = south.floorY[k]
					H.eq(southHere, southThere, where .. " S border col " .. k)
					H.eq(southHere, 0, where .. " S border flat, col " .. k)
					borderPairs += 2
				end
				for index = 1, n * n do
					local i, j = (index - 1) % n + 1, (index - 1) // n + 1
					local ring = i == 1 or j == 1 or i == n or j == n
					totalCells += 1
					local y = layout.floorY[index]
					if y > 0 then
						plateauCells += 1
					elseif y < 0 then
						sunkenCells += 1
					end
					if ring then
						H.eq(y, 0, where .. " ring cell " .. i .. "," .. j .. " is flat")
					end
					local ramp = layout.ramp[index]
					if ramp ~= nil then
						totalRamps += 1
						-- (b) no ramp on the ring.
						H.ok(not ring, where .. " ramp on ring cell " .. i .. "," .. j)
						-- (c) the low end is neither a ramp nor solid.
						local li = if ramp.axis == "x" then i - ramp.dir else i
						local lj = if ramp.axis == "z" then j - ramp.dir else j
						if li >= 1 and lj >= 1 and li <= n and lj <= n then
							local low = li + (lj - 1) * n
							H.ok(
								layout.ramp[low] == nil,
								where .. " ramp " .. i .. "," .. j .. " low end is a ramp"
							)
							H.ok(
								not layout.solid[low],
								where .. " ramp " .. i .. "," .. j .. " low end is solid"
							)
						end
					end
				end
				-- (d) every walkable cell is one component, except a border tail: a
				-- component that runs onto the ring continues into the neighbour chunk,
				-- which this chunk may not decide (the same contract as the sweep in
				-- open-additive.spec). Anything else is a pocket.
				local graph = WalkGraph.build(layout, { stepMax = stepMax })
				local comps = WalkGraph.components(graph)
				if #comps > 1 then
					local main = 1
					for index = 2, #comps do
						if comps[index].size > comps[main].size then
							main = index
						end
					end
					for index, comp in ipairs(comps) do
						if index ~= main then
							local onRing = false
							for _, cell in ipairs(comp.cells) do
								local i, j = (cell - 1) % n + 1, (cell - 1) // n + 1
								onRing = onRing or i == 1 or j == 1 or i == n or j == n
							end
							tailChunks += 1
							H.ok(
								onRing,
								where .. " pocket of " .. comp.size .. " cells off the ring"
							)
						end
					end
				end
			end
		end
	end
	print(
		string.format(
			"  [seams] 10 seeds x %d chunks: %d border cell pairs, %d ramps, %d cells (%.1f%% plateau, %.1f%% sunken), %d border tails",
			WORLD_CHUNKS * WORLD_CHUNKS,
			borderPairs,
			totalRamps,
			totalCells,
			100 * plateauCells / totalCells,
			100 * sunkenCells / totalCells,
			tailChunks
		)
	)
	-- (e) the terrain is really on.
	H.ok(totalRamps > 0, "at least one ramp over the sweep")
	H.ok(plateauCells > 0 and sunkenCells > 0, "plateaus and sunken areas both occur")
end)
