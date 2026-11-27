--!strict

-- Build-time config pipeline:
--
--   config/levels/*.json  ->  validate against config/schema.json
--                         ->  apply config/levels/<id>/addons/*.json (if any)
--                         ->  validate the merged config
--                         ->  emit src/config/levels/<Module>.luau
--                             (+ <Module>_Addons.luau when add-ons exist)
--
--   lune run scripts/gen-config.luau            # write
--   lune run scripts/gen-config.luau --check    # verify committed output

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")

local Schema = require("../tools/Schema")
local ConfigGen = require("../tools/ConfigGen")

local SCHEMA_PATH = "config/schema.json"
local ADDON_SCHEMA_PATH = "config/addon.schema.json"
local LEVELS_DIR = "config/levels"
local OUT_DIR = "src/config/levels"

local checkOnly = false
for _, argument in ipairs(process.args or {}) do
	if argument == "--check" then
		checkOnly = true
	end
end

local schema = serde.decode("json", fs.readFile(SCHEMA_PATH))
local addonSchema = serde.decode("json", fs.readFile(ADDON_SCHEMA_PATH))

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

		-- Add-ons: config/levels/<level-id>/addons/*.json, when present.
		local addonsDir = LEVELS_DIR .. "/" .. string.gsub(name, "%.json$", "") .. "/addons"
		local hasAddons = fs.isDir(addonsDir)
		local addons: { any } = {}
		local addonsOk = true
		if hasAddons then
			local files = fs.readDir(addonsDir)
			table.sort(files)
			for _, file in ipairs(files) do
				if string.match(file, "%.json$") then
					local addonPath = addonsDir .. "/" .. file
					local addonDecoded, addon = pcall(function()
						return serde.decode("json", fs.readFile(addonPath))
					end)
					if addonDecoded then
						table.insert(addons, addon)
					else
						print("[parse]  " .. addonPath .. ": " .. tostring(addon))
						addonsOk = false
					end
				end
			end
		end
		if not addonsOk then
			failures += 1
			continue
		end

		local merged = config
		if hasAddons then
			local resolved, _, resolveErrors =
				ConfigGen.resolve(schema, addonSchema, config, addons, addonsDir)
			if resolved == nil then
				for _, errorMessage in ipairs(resolveErrors) do
					print("[addon]  " .. errorMessage)
				end
				failures += 1
				continue
			end
			merged = resolved
		end

		local outputs: { { path: string, text: string, source: string } } = {}
		local moduleName = ConfigGen.moduleName(config.id)
		table.insert(outputs, {
			path = OUT_DIR .. "/" .. moduleName .. ".luau",
			text = ConfigGen.render(merged, path),
			source = path,
		})
		if hasAddons then
			table.insert(outputs, {
				path = OUT_DIR .. "/" .. moduleName .. "_Addons.luau",
				text = ConfigGen.renderAddons(config, addons, path),
				source = addonsDir,
			})
		end

		for _, output in ipairs(outputs) do
			if checkOnly then
				local existing = if fs.isFile(output.path) then fs.readFile(output.path) else nil
				if existing ~= output.text then
					print("[drift]  " .. output.path .. " is out of date with " .. output.source)
					failures += 1
				end
			else
				fs.writeFile(output.path, output.text)
				written += 1
				print("[write]  " .. output.path)
			end
		end
	end
end

if checkOnly then
	print(string.format("%d level config(s) checked, %d failure(s)", #entries, failures))
else
	print(string.format("%d level config(s) written, %d failure(s)", written, failures))
end

process.exit(if failures == 0 then 0 else 1)
