--!strict

-- Resolves a level config against the system registry: who owns each section,
-- what each owner objects to, and which declared sections nothing consumes yet.
-- Pure and read-only; the config is returned as given.

local Registry = if script ~= nil then require(script.Parent.Registry) else require("./Registry")
local catalog = if script ~= nil then require(script.Parent.catalog) else require("./catalog")

export type Resolved = {
	config: any,
	registry: Registry.Registry,
	problems: { string },
	warnings: { string },
}

local Level = {}

local function sortedKeys(map: any): { string }
	local keys = {}
	for key in pairs(map) do
		table.insert(keys, tostring(key))
	end
	table.sort(keys)
	return keys
end

-- The default registry: every catalog system. Callers may pass their own.
function Level.defaultRegistry(): Registry.Registry
	local registry = Registry.new()
	for _, system in ipairs(catalog.systems()) do
		registry:register(system)
	end
	return registry
end

local function sectionOf(config: any, path: string): any
	local node = config
	for segment in string.gmatch(path, "[^%.]+") do
		if type(node) ~= "table" then
			return nil
		end
		node = node[segment]
	end
	return node
end

function Level.resolve(config: any, registry: Registry.Registry?): Resolved
	local reg = registry or Level.defaultRegistry()
	local problems: { string } = {}
	local warnings: { string } = {}

	for _, key in ipairs(sortedKeys(config)) do
		if not reg:covers(key) then
			table.insert(problems, `unowned config section {key}`)
		end
	end
	local params = if type(config.strategy) == "table" then config.strategy.params else nil
	if type(params) == "table" then
		for _, key in ipairs(sortedKeys(params)) do
			local path = "strategy.params." .. key
			if reg:owner(path) == nil then
				table.insert(problems, `unowned config section {path}`)
			end
		end
	end

	for _, system in ipairs(reg:systems()) do
		local present = false
		for _, path in ipairs(system.owns) do
			if sectionOf(config, path) ~= nil then
				present = true
				if system.validate ~= nil and #system.owns == 1 then
					for _, message in ipairs(system.validate(sectionOf(config, path), config)) do
						table.insert(problems, message)
					end
				end
			end
		end
		-- Multi-path owners validate once, against the whole level.
		if present and system.validate ~= nil and #system.owns > 1 then
			for _, message in ipairs(system.validate(nil, config)) do
				table.insert(problems, message)
			end
		end
		if present and system.status == "planned" then
			table.insert(warnings, `declared but not consumed yet: {system.id} (planned)`)
		end
	end

	return { config = config, registry = reg, problems = problems, warnings = warnings }
end

return Level
