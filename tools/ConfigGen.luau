--!strict

-- Deterministic JSON -> Luau emitter. Determinism matters because the generated
-- file is committed and compared byte-for-byte in `--check` mode: object keys
-- are sorted, arrays keep their order, nulls are omitted (Luau has no null).

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

return ConfigGen
