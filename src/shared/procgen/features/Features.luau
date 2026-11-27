--!strict

-- Feature validation (ADR 0030, ADR 0033): the per-section rules live with their
-- owning systems; this module aggregates them for callers that lint a bare
-- config. The generation passes themselves run from the system registry
-- (level/systems/), not from here.

local Terrain = if script ~= nil then require(script.Parent.Terrain) else require("./Terrain")
local Structures = if script ~= nil
	then require(script.Parent.Structures)
	else require("./Structures")
local World = if script ~= nil then require(script.Parent.Parent.World) else require("../World")

local Features = {}

-- Defaults mirrored from Terrain for the ceiling headroom check.
local TERRAIN_DEFAULT_MIN_HEADROOM = 9
-- Cells per ceiling/terrain block (OpenAdditive.DEFAULTS.block; not configurable).
local BLOCK_CELLS = 6
-- Review R1: a player crouching under a hanging wall needs this much clear air.
local MIN_HANGING_CLEARANCE = 6

local function isPositiveInteger(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0
end

-- Ceiling bands, or the legacy `heights` list read as equal-weight bands.
local function validateCeiling(problems: { string }, config: any, terrain: any, features: any): ()
	local params = (config.strategy and config.strategy.params) or {}
	local headroom = terrain.minHeadroom or TERRAIN_DEFAULT_MIN_HEADROOM
	local heights: { any } = {}
	local label: string
	local ceiling = params.ceiling

	if ceiling ~= nil then
		local prefix = "strategy.params.ceiling"
		if type(ceiling) ~= "table" then
			table.insert(problems, prefix .. ": must be an object with bands")
			return
		end
		if ceiling.zoneBlocks ~= nil and not isPositiveInteger(ceiling.zoneBlocks) then
			table.insert(problems, prefix .. ".zoneBlocks: must be a positive integer")
		end
		-- On a wrapping world a zone must tile the period, or the last zone is cut
		-- at the seam and the two sides of the wrap disagree about its band.
		local boundary = (config.world and config.world.boundaryMode) or "wrap"
		if boundary == "wrap" and isPositiveInteger(ceiling.zoneBlocks) then
			local ok, size = pcall(World.resolve, config)
			if ok then
				local chunkCells = (params.chunkCells or (config.world and config.world.chunkCells))
					or 18
				local blocksPerAxis = size.chunks * chunkCells / BLOCK_CELLS
				if blocksPerAxis % ceiling.zoneBlocks ~= 0 then
					table.insert(
						problems,
						prefix
							.. ".zoneBlocks: must divide the blocks per axis of a wrapping world ("
							.. blocksPerAxis
							.. " blocks = "
							.. size.chunks
							.. " chunks x "
							.. chunkCells
							.. " cells / "
							.. BLOCK_CELLS
							.. "), got "
							.. ceiling.zoneBlocks
					)
				end
			end
		end
		local bands = ceiling.bands
		if type(bands) ~= "table" or #bands == 0 then
			table.insert(problems, prefix .. ".bands: must be a non-empty list")
			return
		end
		for index, entry in ipairs(bands) do
			local bandPrefix = prefix .. ".bands[" .. index .. "]"
			if type(entry) ~= "table" then
				table.insert(problems, bandPrefix .. ": must be an object with height and weight")
				continue
			end
			if type(entry.weight) ~= "number" or entry.weight <= 0 then
				table.insert(problems, bandPrefix .. ".weight: must be a number > 0")
			end
			heights[index] = entry.height
		end
		label = prefix .. ".bands"
	elseif params.heights ~= nil then
		if type(params.heights) ~= "table" or #params.heights == 0 then
			table.insert(problems, "strategy.params.heights: must be a non-empty list")
			return
		end
		heights = params.heights
		label = "strategy.params.heights"
	else
		return
	end

	local lowest: number? = nil
	for index = 1, #heights do
		local height = heights[index]
		local where = if ceiling ~= nil
			then label .. "[" .. index .. "].height"
			else label .. "[" .. index .. "]"
		if type(height) ~= "number" then
			table.insert(problems, where .. ": must be a number")
		else
			if height < headroom then
				table.insert(
					problems,
					where .. ": must be >= terrain.minHeadroom (" .. headroom .. ")"
				)
			end
			if lowest == nil or height < lowest then
				lowest = height
			end
		end
	end

	local hangingWall = features.hangingWall
	if lowest ~= nil and hangingWall ~= nil and type(hangingWall.depth) == "number" then
		local clearance = lowest - hangingWall.depth
		if clearance < MIN_HANGING_CLEARANCE then
			table.insert(
				problems,
				label
					.. ": lowest height "
					.. lowest
					.. " minus features.hangingWall.depth "
					.. hangingWall.depth
					.. " leaves "
					.. clearance
					.. " studs, need >= "
					.. MIN_HANGING_CLEARANCE
			)
		end
	end
end

-- Ceiling bands (or legacy heights) against terrain headroom and hanging walls.
-- Owned by the `strategy` system, which holds `ceiling`.
function Features.validateCeiling(config: any): { string }
	local problems: { string } = {}
	local params = (config.strategy and config.strategy.params) or {}
	validateCeiling(problems, config, params.terrain or {}, params.features or {})
	return problems
end

-- Everything the feature sections object to, in one list. The per-section rules
-- live with their owning systems (Terrain, Structures, ceiling here); this is
-- the aggregate for callers that lint a bare config.
function Features.validate(config: any): { string }
	local params = (config.strategy and config.strategy.params) or {}
	local problems: { string } = {}
	for _, list in ipairs({
		Terrain.validate(params.terrain),
		Structures.validate(params.features),
		Features.validateCeiling(config),
	}) do
		for _, problem in ipairs(list) do
			table.insert(problems, problem)
		end
	end
	return problems
end

function Features.names(): { string }
	return { "terrain", "structures", "template" }
end

return Features
