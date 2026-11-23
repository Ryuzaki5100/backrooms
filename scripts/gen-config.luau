--!strict

-- Build-time config pipeline:
--
--   config/levels/*.json  ->  validate against config/schema.json
--                         ->  emit src/config/levels/<Module>.luau
--
--   lune run scripts/gen-config.luau            # write
--   lune run scripts/gen-config.luau --check    # verify committed output

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")

local Schema = require("../tools/Schema")
local ConfigGen = require("../tools/ConfigGen")

local SCHEMA_PATH = "config/schema.json"
local LEVELS_DIR = "config/levels"
local OUT_DIR = "src/config/levels"

local checkOnly = false
for _, argument in ipairs(process.args or {}) do
	if argument == "--check" then
		checkOnly = true
	end
end

local schema = serde.decode("json", fs.readFile(SCHEMA_PATH))

local entries = fs.readDir(LEVELS_DIR)
table.sort(entries)

if not checkOnly and not fs.isDir(OUT_DIR) then
	fs.writeDir(OUT_DIR)
end

local failures = 0
local written = 0

for _, name in ipairs(entries) do
	if string.match(name, "%.json$") then
		local path = LEVELS_DIR .. "/" .. name

		local decoded, config = pcall(function()
			return serde.decode("json", fs.readFile(path))
		end)
		if not decoded then
			print("[parse]  " .. path .. ": " .. tostring(config))
			failures += 1
			continue
		end

		local errors = Schema.validate(schema, config)
		for _, errorMessage in ipairs(Schema.checkRelations(config)) do
			table.insert(errors, errorMessage)
		end

		if #errors > 0 then
			for _, errorMessage in ipairs(errors) do
				print("[schema] " .. path .. " " .. errorMessage)
			end
			failures += 1
			continue
		end

		local rendered = ConfigGen.render(config, path)
		local moduleName = ConfigGen.moduleName(config.id)
		local outPath = OUT_DIR .. "/" .. moduleName .. ".luau"

		if checkOnly then
			local existing = if fs.isFile(outPath) then fs.readFile(outPath) else nil
			if existing ~= rendered then
				print("[drift]  " .. outPath .. " is out of date with " .. path)
				failures += 1
			end
		else
			fs.writeFile(outPath, rendered)
			written += 1
			print("[write]  " .. outPath)
		end
	end
end

if checkOnly then
	print(string.format("%d level config(s) checked, %d failure(s)", #entries, failures))
else
	print(string.format("%d level config(s) written, %d failure(s)", written, failures))
end

process.exit(if failures == 0 then 0 else 1)
