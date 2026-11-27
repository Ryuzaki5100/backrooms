--!strict

-- Feature registry (ADR 0030): a level's structural gimmicks are named features,
-- each with params, placement and geometry. The strategy composes them; it does
-- not contain them.
--
-- Two kinds of pass:
--   * base passes run for every cell world (Terrain applies floor heights and
--     headroom even when the level is flat);
--   * gated features run only when the config lists them (Structures,
--     Template).

local Terrain = if script ~= nil then require(script.Parent.Terrain) else require("./Terrain")
local Structures = if script ~= nil
	then require(script.Parent.Structures)
	else require("./Structures")
local Template = if script ~= nil then require(script.Parent.Template) else require("./Template")
local World = if script ~= nil then require(script.Parent.Parent.World) else require("../World")

local Features = {}

-- Base passes, in order. Gated features follow via `applyGated`.
function Features.applyBase(make: any, layout: any): ()
	Terrain.apply(make, layout)
end

function Features.applyGated(make: any, layout: any): ()
	if Structures.enabled(make) then
		Structures.apply(make, layout)
	end
	-- Templates reserve ground last, so a set piece is never placed on a pillar
	-- or under a hanging wall.
	if Template.enabled(make) then
		Template.apply(make, layout)
	end
end

-- Run everything the config asks for, in a fixed order.
function Features.apply(make: any, layout: any): ()
	Features.applyBase(make, layout)
	Features.applyGated(make, layout)
end

-- Terrain params that exist in code defaults and now in the schema.
local TERRAIN_DEFAULT_RISE = 4
local TERRAIN_DEFAULT_STEP_MAX = 1
local TERRAIN_DEFAULT_MIN_HEADROOM = 9
-- Cells per ceiling/terrain block (OpenAdditive.DEFAULTS.block; not configurable).
local BLOCK_CELLS = 6
-- Review R1: a player crouching under a hanging wall needs this much clear air.
local MIN_HANGING_CLEARANCE = 6

local function isPositiveInteger(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0
end

local function validateTerrainParams(problems: { string }, terrain: any): ()
	local prefix = "strategy.params.terrain."
	for _, key in ipairs({ "rampSpacing", "extraRampCells", "secondRampFaces" }) do
		local value = terrain[key]
		if value ~= nil and not isPositiveInteger(value) then
			table.insert(problems, prefix .. key .. ": must be a positive integer")
		end
	end
	local chance = terrain.secondRampChance
	if chance ~= nil and (type(chance) ~= "number" or chance < 0 or chance > 1) then
		table.insert(problems, prefix .. "secondRampChance: must be a number within [0,1]")
	end
	if terrain.stepMax ~= nil and type(terrain.stepMax) ~= "number" then
		table.insert(problems, prefix .. "stepMax: must be a number")
	end
	if terrain.rise ~= nil and type(terrain.rise) ~= "number" then
		table.insert(problems, prefix .. "rise: must be a number")
	end
	if
		(terrain.stepMax ~= nil or terrain.rise ~= nil)
		and type(terrain.stepMax or 0) == "number"
		and type(terrain.rise or 0) == "number"
	then
		local stepMax = terrain.stepMax or TERRAIN_DEFAULT_STEP_MAX
		local rise = terrain.rise or TERRAIN_DEFAULT_RISE
		if stepMax >= rise then
			table.insert(
				problems,
				prefix
					.. "stepMax: must be less than terrain.rise (stepMax "
					.. stepMax
					.. ", rise "
					.. rise
					.. ")"
			)
		end
	end
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

-- Readable validation for feature params.
function Features.validate(config: any): { string }
	local problems = {}
	local terrain = (config.strategy and config.strategy.params and config.strategy.params.terrain)
		or {}
	local function band(prefix: string, value: any): ()
		if type(value) == "table" then
			if
				value[1] == nil
				or value[2] == nil
				or value[1] < 0
				or value[2] < value[1]
				or value[2] > 1
			then
				table.insert(
					problems,
					prefix .. ": must be a number or [min,max] band within [0,1]"
				)
			end
		elseif type(value) == "number" then
			if value < 0 or value > 1 then
				table.insert(problems, prefix .. ": must be within [0,1]")
			end
		elseif value ~= nil then
			table.insert(problems, prefix .. ": must be a number or a band")
		end
	end
	band("strategy.params.terrain.plateauShare", terrain.plateauShare)
	band("strategy.params.terrain.sunkenShare", terrain.sunkenShare)
	band("strategy.params.terrain.rampChance", terrain.rampChance)

	local features = (
		config.strategy
		and config.strategy.params
		and config.strategy.params.features
	) or {}
	if features.pillarGrid ~= nil and (features.pillarGrid.spacing or 0) < 1 then
		table.insert(problems, "features.pillarGrid.spacing: must be >= 1")
	end
	if features.hangingWall ~= nil and (features.hangingWall.depth or 0) < 1 then
		table.insert(problems, "features.hangingWall.depth: must be >= 1")
	end

	validateTerrainParams(problems, terrain)
	validateCeiling(problems, config, terrain, features)
	return problems
end

function Features.names(): { string }
	return { "terrain", "structures", "template" }
end

return Features
