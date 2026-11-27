--!strict

-- Descriptor-only systems: one per config section a level file carries today, so
-- ownership is total. Nothing here calls into the pipeline yet; later tasks give
-- each system its hooks and migrate the hard-wired call sites onto them.
--
-- `active` sections are consumed by the current pipeline. `planned` sections are
-- declared in level files but nothing reads them yet; Level.resolve reports them
-- as warnings and checks only their shape.

local System = if script ~= nil then require(script.Parent.System) else require("./System")
local Features = if script ~= nil
	then require(script.Parent.Parent.features.Features)
	else require("../features/Features")

local catalog = {}

local function isList(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	for key in pairs(value) do
		if type(key) ~= "number" then
			return false
		end
	end
	return true
end

local function shape(label: string, expected: string): (any, any) -> { string }
	return function(section: any, _level: any): { string }
		local kind = type(section)
		local ok = if expected == "list" then isList(section) else kind == expected
		if ok then
			return {}
		end
		return { `{label}: expected a {expected}, got {kind}` }
	end
end

local function strategyValidate(_section: any, level: any): { string }
	return Features.validate(level)
end

local specs: { any } = {
	{
		id = "core",
		owns = { "schema", "id", "title", "source", "revision", "dead_end" },
		phase = "generate",
		stage = "field",
		status = "active",
	},
	{
		id = "strategy",
		owns = {
			"strategy.name",
			"strategy.params.cell",
			"strategy.params.chunkCells",
			"strategy.params.block",
			"strategy.params.pillarShare",
			"strategy.params.pillarSize",
			"strategy.params.runCount",
			"strategy.params.runLength",
			"strategy.params.hallShare",
			"strategy.params.hallBlocks",
			"strategy.params.spawn",
			"strategy.params.features",
			"strategy.params.terrain",
			"strategy.params.ceiling",
		},
		phase = "generate",
		stage = "base",
		status = "active",
		validate = strategyValidate,
	},
	{
		id = "templates",
		owns = { "templates" },
		phase = "generate",
		stage = "gated",
		status = "active",
	},
	{
		id = "details",
		owns = { "details" },
		phase = "generate",
		stage = "decorate",
		status = "active",
	},
	{
		id = "world",
		owns = { "world" },
		phase = "runtime",
		stage = "world",
		status = "active",
	},
	{
		id = "visibility",
		owns = { "visibility" },
		phase = "runtime",
		stage = "world",
		status = "active",
	},
	{
		id = "render",
		owns = { "render" },
		phase = "render",
		stage = "surfaces",
		status = "active",
	},
	{
		id = "style",
		owns = { "style" },
		phase = "render",
		stage = "surfaces",
		status = "active",
	},
	{
		id = "lighting",
		owns = { "lighting" },
		phase = "render",
		stage = "fixtures",
		status = "planned",
		validate = shape("lighting", "table"),
	},
	{
		id = "props",
		owns = { "props" },
		phase = "render",
		stage = "props",
		status = "planned",
		validate = shape("props", "list"),
	},
	{
		id = "tileset",
		owns = { "tileset" },
		phase = "render",
		stage = "surfaces",
		status = "planned",
		validate = shape("tileset", "string"),
	},
	{
		id = "hazards",
		owns = { "hazards" },
		phase = "runtime",
		stage = "zone",
		status = "planned",
		validate = shape("hazards", "list"),
	},
	{
		id = "entities",
		owns = { "entities" },
		phase = "runtime",
		stage = "zone",
		status = "planned",
		validate = shape("entities", "list"),
	},
	{
		id = "transitions",
		owns = { "transitions" },
		phase = "runtime",
		stage = "player",
		status = "planned",
		validate = shape("transitions", "list"),
	},
	-- Legacy node pipeline, superseded by `strategy`; kept so old files still resolve.
	{
		id = "generate",
		owns = { "generate" },
		phase = "generate",
		stage = "field",
		status = "planned",
		validate = shape("generate", "table"),
	},
}

-- Fresh System values on every call, so callers may mutate their registry freely.
function catalog.systems(): { System.System }
	local out = {}
	for _, spec in ipairs(specs) do
		table.insert(out, System.define(spec))
	end
	return out
end

return catalog
