--!strict

-- Strategy registry (ADR 0025).
--
-- Config selects the layout approach by name. Nothing in the engine may ask
-- "which level is this"; it asks "which strategy", and the strategy gets its
-- parameters from the same config table.
--
-- `rooms_and_corridors` is the legacy pipeline (Macro + Embedding) kept behind
-- this interface so it can be proved unchanged: same config, same bytes.

local Strategy = {}

local REGISTRY: { [string]: any } = {
	rooms_and_corridors = function()
		return require("./strategies/RoomsAndCorridors")
	end,
	open_additive = function()
		return require("./strategies/OpenAdditive")
	end,
}

local DEFAULT = "rooms_and_corridors"

function Strategy.names(): { string }
	local names = {}
	for name in pairs(REGISTRY) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

function Strategy.nameOf(config: any): string
	return (config.strategy and config.strategy.name) or DEFAULT
end

function Strategy.module(name: string): any
	local loader = REGISTRY[name]
	if loader == nil then
		error(
			string.format(
				"Strategy: unknown strategy %q (known: %s)",
				tostring(name),
				table.concat(Strategy.names(), ", ")
			),
			3
		)
	end
	return loader()
end

-- Dispatch. A strategy returns either a node plan (rooms_and_corridors) or a
-- grid world object (open_additive); `Strategy.kind` says which.
function Strategy.build(config: any, seed: number, options: any?): any
	local name = Strategy.nameOf(config)
	local module = Strategy.module(name)
	return module.build(config, seed, options)
end

function Strategy.kind(config: any): string
	local name = Strategy.nameOf(config)
	if name == "open_additive" then
		return "grid"
	end
	return "plan"
end

-- Validation with readable errors, run at load. JSON Schema cannot switch on the
-- strategy name, so the deep checks live here.
function Strategy.validate(config: any): { string }
	local problems = {}
	local name = Strategy.nameOf(config)
	if REGISTRY[name] == nil then
		table.insert(problems, "strategy.name: unknown strategy " .. tostring(name))
		return problems
	end

	local params = (config.strategy and config.strategy.params) or {}
	local world = config.world or {}
	if world.sizeTier ~= nil then
		local World = require("./World")
		if not World.isTier(world.sizeTier) then
			table.insert(problems, "world.sizeTier: unknown tier " .. tostring(world.sizeTier))
		end
	end
	if
		world.boundaryMode ~= nil
		and world.boundaryMode ~= "wrap"
		and world.boundaryMode ~= "wall"
		and world.boundaryMode ~= "infinite"
	then
		table.insert(problems, "world.boundaryMode: must be wrap, wall or infinite")
	end

	local visibility = config.visibility or {}
	if visibility.backdrop ~= nil and visibility.backdrop ~= "horizon" then
		table.insert(problems, "visibility.backdrop: only 'horizon' is defined")
	end

	if name == "open_additive" then
		for _, key in ipairs({ "cell", "chunkCells", "block" }) do
			local value = params[key]
			if value ~= nil and (type(value) ~= "number" or value <= 0 or value % 1 ~= 0) then
				table.insert(problems, "strategy.params." .. key .. ": must be a positive integer")
			end
		end
		local block = params.block or 6
		local chunkCells = params.chunkCells or 18
		if chunkCells % block ~= 0 then
			table.insert(
				problems,
				"strategy.params.chunkCells: must be a multiple of block (" .. block .. ")"
			)
		end
		for _, key in ipairs({ "runCount", "runLength" }) do
			local range = params[key]
			if range ~= nil then
				if type(range) ~= "table" or #range ~= 2 or range[1] > range[2] then
					table.insert(
						problems,
						"strategy.params." .. key .. ": must be [min, max] with min <= max"
					)
				end
			end
		end
	end

	local details = config.details or {}
	local detailIds: { [string]: boolean } = {}
	for index, detail in ipairs(details) do
		local prefix = "details[" .. index .. "]"
		if detail.id == nil or detail.id == "" then
			table.insert(problems, prefix .. ".id: required")
		elseif detailIds[detail.id] then
			table.insert(problems, prefix .. ".id: duplicate " .. detail.id)
		else
			detailIds[detail.id] = true
		end
		if detail.chance ~= nil and (detail.chance < 0 or detail.chance > 1) then
			table.insert(problems, prefix .. ".chance: must be within [0,1]")
		end
		if detail.minSpacing ~= nil and detail.minSpacing < 0 then
			table.insert(problems, prefix .. ".minSpacing: must be >= 0")
		end
	end

	return problems
end

return Strategy
