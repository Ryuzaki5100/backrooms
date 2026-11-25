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
	return problems
end

function Features.names(): { string }
	return { "terrain", "structures", "template" }
end

return Features
