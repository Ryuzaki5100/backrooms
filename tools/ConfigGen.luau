--!strict

-- Deterministic JSON -> Luau emitter. Determinism matters because the generated
-- file is committed and compared byte-for-byte in `--check` mode: object keys
-- are sorted, arrays keep their order, nulls are omitted (Luau has no null).

local Schema = require("./Schema")
local Overlay = require("../src/shared/procgen/level/Overlay")

local ConfigGen = {}

local function isArray(value: any): boolean
	local count = #value
	if count == 0 then
		return false -- empty table: emit as an object, which is also {}
	end
	local seen = 0
	for _ in pairs(value) do
		seen += 1
	end
	return seen == count
end

local function formatNumber(value: number): string
	if value % 1 == 0 then
		return string.format("%.0f", value)
	end
	return (string.format("%.10g", value))
end

local function quote(value: string): string
	return string.format("%q", value)
end

local emit: (any, number) -> string

emit = function(value: any, depth: number): string
	local kind = type(value)
	if kind == "string" then
		return quote(value)
	elseif kind == "number" then
		return formatNumber(value)
	elseif kind == "boolean" then
		return tostring(value)
	elseif kind ~= "table" then
		error("ConfigGen: cannot emit " .. kind)
	end

	local padding = string.rep("\t", depth)
	local inner = string.rep("\t", depth + 1)

	if isArray(value) then
		if #value == 0 then
			return "{}"
		end
		local parts = {}
		for _, item in ipairs(value) do
			table.insert(parts, inner .. emit(item, depth + 1) .. ",")
		end
		return "{\n" .. table.concat(parts, "\n") .. "\n" .. padding .. "}"
	end

	local keys = {}
	for key in pairs(value) do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)

	local parts = {}
	for _, key in ipairs(keys) do
		local item = value[key]
		if item ~= nil then
			table.insert(
				parts,
				inner .. "[" .. quote(tostring(key)) .. "] = " .. emit(item, depth + 1) .. ","
			)
		end
	end
	if #parts == 0 then
		return "{}"
	end
	return "{\n" .. table.concat(parts, "\n") .. "\n" .. padding .. "}"
end

function ConfigGen.moduleName(id: string): string
	local name = string.gsub(id, "^%l", string.upper)
	name = string.gsub(name, "[^%w]", "_")
	return name
end

function ConfigGen.render(config: any, sourcePath: string): string
	local header = table.concat({
		"--!strict",
		"--",
		"-- Generated from " .. sourcePath .. " by scripts/gen-config.luau.",
		"-- Do not edit by hand: edit the JSON and run `lune run scripts/gen-config.luau`.",
		"",
	}, "\n")
	return header .. "return " .. emit(config, 0) .. "\n"
end

-- Validates every add-on, applies the enabled ones to `base` and validates the
-- merged config. Returns the merged config (nil on failure), the applied list
-- and a list of error strings, each prefixed with `label`.
function ConfigGen.resolve(
	schema: any,
	addonSchema: any,
	base: any,
	addons: { any },
	label: string,
	enabled: { [string]: boolean }?
): (any, { Overlay.Applied }, { string })
	local errors: { string } = {}
	for index, addon in ipairs(addons) do
		for _, message in ipairs(Schema.validate(addonSchema, addon)) do
			table.insert(errors, `{label} add-on #{index} {message}`)
		end
	end
	if #errors > 0 then
		return nil, {}, errors
	end

	local ok, merged, applied = pcall(Overlay.apply, base, addons, enabled)
	if not ok then
		return nil, {}, { `{label} {tostring(merged)}` }
	end

	for _, message in ipairs(Schema.validate(schema, merged)) do
		table.insert(errors, `{label} merged {message}`)
	end
	for _, message in ipairs(Schema.checkRelations(merged)) do
		table.insert(errors, `{label} merged {message}`)
	end
	if #errors > 0 then
		return nil, applied, errors
	end
	return merged, applied, errors
end

-- The `<Module>_Addons` file: the unmerged base plus every add-on file, so the
-- runtime can re-merge with different toggles.
function ConfigGen.renderAddons(base: any, addons: { any }, sourcePath: string): string
	local header = table.concat({
		"--!strict",
		"--",
		"-- Generated from " .. sourcePath .. " (and its addons/ directory) by",
		"-- scripts/gen-config.luau. Do not edit by hand.",
		"",
	}, "\n")
	return header .. "return " .. emit({ base = base, addons = addons }, 0) .. "\n"
end

return ConfigGen
