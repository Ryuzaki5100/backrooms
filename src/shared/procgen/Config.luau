--!strict

-- Runtime side of the config pipeline. The generated Luau is already
-- schema-validated at build time, so this only enforces the invariants that
-- matter at boot, where failing fast beats generating a broken level.

-- Two static requires instead of a computed path: luau-lsp cannot resolve
-- `require("./" .. name)`, and a computed path also erases the module's types.
local Version = if script ~= nil then require(script.Parent.Version) else require("./Version")
local Hash = if script ~= nil then require(script.Parent.Hash) else require("./Hash")

export type Outcome = {
	weight: number,
	kind: string, -- level | node | class | void
	level: string?,
	node: number?,
	predicate: string?,
}

export type Transition = {
	id: string,
	gate: string,
	resolve: string?, -- seed | run | event (default seed)
	outcomes: { Outcome },
}

export type LevelConfig = {
	schema: number,
	id: string,
	title: string,
	dead_end: boolean?,
	source: { note: string, revid: number? },
	generate: {
		regions: { number },
		tiles: number,
		genMs: number,
		loops: number,
		deadEnds: number?,
		maxLevels: number?,
	},
	tileset: string,
	transitions: { Transition },
	style: any?,
	props: { any },
	hazards: { any },
	entities: { any },
	lighting: any,
	seams: { any }?,
}

local Config = {}

-- Fingerprint of the generation-relevant projection of a config. Display text
-- and style are excluded on purpose: rewriting a description must not change a
-- layout's identity (ADR 0009 Q4).
function Config.fingerprint(config: any): string
	local parts: { string } = { tostring(config.schema), tostring(config.id) }
	local generate = config.generate or {}
	local regions = generate.regions or {}

	parts[#parts + 1] = "r:" .. tostring(regions[1]) .. "," .. tostring(regions[2])
	parts[#parts + 1] = "t:" .. tostring(generate.tiles)
	parts[#parts + 1] = "g:" .. tostring(generate.genMs)
	parts[#parts + 1] = "l:" .. tostring(generate.loops)
	parts[#parts + 1] = "d:" .. tostring(generate.deadEnds or 0)
	parts[#parts + 1] = "m:" .. tostring(generate.maxLevels or 1)

	for _, form in ipairs(generate.connectorForms or {}) do
		parts[#parts + 1] = "cf:" .. tostring(form.kind) .. ":" .. tostring(form.weight)
	end

	local transitions = table.clone(config.transitions or {})
	table.sort(transitions, function(a: any, b: any)
		return a.id < b.id
	end)
	for _, transition in ipairs(transitions) do
		parts[#parts + 1] = table.concat({
			"x",
			transition.id,
			transition.gate,
			transition.resolve or "seed",
		}, ":")
		for _, outcome in ipairs(transition.outcomes or {}) do
			parts[#parts + 1] = table.concat({
				"o",
				outcome.kind,
				tostring(outcome.weight),
				outcome.level or "",
				tostring(outcome.node or 0),
				outcome.predicate or "",
			}, ":")
		end
	end

	return Hash.of(table.concat(parts, "|"))
end

-- Returns a list of human-readable problems. Empty means loadable.
function Config.verify(raw: any): { string }
	local errors: { string } = {}

	if type(raw) ~= "table" then
		return { "config is not a table" }
	end
	if raw.schema ~= Version.CONFIG_SCHEMA_VERSION then
		table.insert(
			errors,
			string.format(
				"schema version %s does not match runtime %d",
				tostring(raw.schema),
				Version.CONFIG_SCHEMA_VERSION
			)
		)
	end
	if type(raw.id) ~= "string" or not string.match(raw.id, "^level-") then
		table.insert(errors, "id must be a level-* string")
	end
	if type(raw.title) ~= "string" or #raw.title == 0 then
		table.insert(errors, "title is required")
	end

	local transitions = raw.transitions
	if type(transitions) ~= "table" then
		table.insert(errors, "transitions must be a list")
	else
		local seen = {}
		for index, transition in ipairs(transitions) do
			if type(transition) ~= "table" or type(transition.id) ~= "string" then
				table.insert(errors, string.format("transitions[%d] is malformed", index))
			elseif seen[transition.id] then
				table.insert(
					errors,
					string.format("transition id '%s' is duplicated", transition.id)
				)
			else
				seen[transition.id] = true
			end
		end
		if #transitions == 0 and raw.dead_end ~= true then
			table.insert(errors, "a level needs at least one transition unless dead_end is set")
		end
	end

	local generate = raw.generate
	if type(generate) ~= "table" or type(generate.regions) ~= "table" or #generate.regions ~= 2 then
		table.insert(errors, "generate.regions must be a two-element range")
	elseif generate.regions[1] > generate.regions[2] then
		table.insert(errors, "generate.regions minimum is greater than maximum")
	end

	if type(raw.lighting) ~= "table" or type(raw.lighting.clockTime) ~= "number" then
		table.insert(errors, "lighting.clockTime is required")
	end

	return errors
end

function Config.load(raw: any): LevelConfig
	local errors = Config.verify(raw)
	if #errors > 0 then
		error("invalid level config: " .. table.concat(errors, "; "), 2)
	end
	return raw :: LevelConfig
end

-- True when every declared transition has been taken. A dead end has no
-- transitions to master, so mastery does not apply (ADR 0006).
function Config.isMastered(config: LevelConfig, taken: { string }): boolean
	if #config.transitions == 0 then
		return false
	end
	local seen = {}
	for _, id in ipairs(taken) do
		seen[id] = true
	end
	for _, transition in ipairs(config.transitions) do
		if not seen[transition.id] then
			return false
		end
	end
	return true
end

return Config
