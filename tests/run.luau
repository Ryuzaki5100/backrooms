--!strict

local Harness = require("./harness")
local fs = require("@lune/fs")
local process = require("@lune/process")

-- Every tests/procgen/*.spec.luau runs, in sorted order, so adding a spec never
-- means editing this file. Run from the repository root (`lune run tests/run.luau`).
local specs = {}
for _, entry in ipairs(fs.readDir("tests/procgen")) do
	local name = string.match(entry, "^(.+)%.spec%.luau$")
	if name ~= nil then
		table.insert(specs, name)
	end
end
table.sort(specs)

for _, name in ipairs(specs) do
	require("./procgen/" .. name .. ".spec")
end

process.exit(Harness.run())
