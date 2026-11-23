--!strict

local H = require("../harness")
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Schema = require("../../tools/Schema")
local ConfigGen = require("../../tools/ConfigGen")
local Config = require("../../src/shared/procgen/Config")

local function loadJson(path: string): any
	return serde.decode("json", fs.readFile(path))
end

local schema = loadJson("config/schema.json")
local level0 = loadJson("config/levels/level-0.json")

local function clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in pairs(value) do
		copy[key] = clone(item)
	end
	return copy
end

local function errorsFor(config: any): { string }
	local errors = Schema.validate(schema, config)
	for _, relationError in ipairs(Schema.checkRelations(config)) do
		table.insert(errors, relationError)
	end
	return errors
end

local function joined(errors: { string }): string
	return table.concat(errors, " | ")
end

H.test("level-0 validates against the schema", function()
	local errors = errorsFor(level0)
	H.eq(#errors, 0, "level-0 errors: " .. joined(errors))
end)

H.test("an unknown key fails with its JSON path", function()
	local broken = clone(level0)
	broken.bogus = true
	local errors = errorsFor(broken)
	H.ok(
		joined(errors):find("$.bogus: unknown key", 1, true) ~= nil,
		"path in error: " .. joined(errors)
	)
end)

H.test("a missing required key fails with its path", function()
	local broken = clone(level0)
	broken.tileset = nil
	local errors = errorsFor(broken)
	H.ok(joined(errors):find("$.tileset: required", 1, true) ~= nil, joined(errors))
end)

H.test("an enum violation is reported", function()
	local broken = clone(level0)
	broken.tileset = "nope"
	local errors = errorsFor(broken)
	H.ok(joined(errors):find("$.tileset", 1, true) ~= nil, joined(errors))
end)

H.test("a range violation is reported with its path", function()
	local broken = clone(level0)
	broken.generate.tiles = 1
	local errors = errorsFor(broken)
	H.ok(joined(errors):find("$.generate.tiles: below minimum", 1, true) ~= nil, joined(errors))
end)

H.test("anyOf rejects an invalid gate", function()
	local broken = clone(level0)
	broken.transitions[1].gate = "nonsense"
	local errors = errorsFor(broken)
	H.ok(joined(errors):find("$.transitions[0].gate", 1, true) ~= nil, joined(errors))
end)

H.test("a level without transitions is rejected unless dead_end", function()
	local broken = clone(level0)
	broken.transitions = {}
	local errors = errorsFor(broken)
	H.ok(joined(errors):find("at least one transition", 1, true) ~= nil, joined(errors))

	broken.dead_end = true
	H.eq(#errorsFor(broken), 0, "dead_end should be allowed")
end)

H.test("duplicate transition ids are rejected", function()
	local broken = clone(level0)
	broken.transitions[2].id = broken.transitions[1].id
	local errors = errorsFor(broken)
	H.ok(joined(errors):find("duplicate", 1, true) ~= nil, joined(errors))
end)

H.test("a level cannot transition to itself", function()
	local broken = clone(level0)
	broken.transitions[1].to = broken.id
	local errors = errorsFor(broken)
	H.ok(joined(errors):find("cannot transition to itself", 1, true) ~= nil, joined(errors))
end)

H.test("codegen is deterministic and omits nulls", function()
	local first = ConfigGen.render(level0, "config/levels/level-0.json")
	local second = ConfigGen.render(level0, "config/levels/level-0.json")
	H.eq(first, second)
	H.eq(first:find("null", 1, true), nil, "no null literal")
	H.eq(first:find("style", 1, true), nil, "null style omitted")
end)

H.test("generated module name is stable and safe", function()
	H.eq(ConfigGen.moduleName("level-0"), "Level_0")
	H.eq(ConfigGen.moduleName("level-0.1"), "Level_0_1")
end)

H.test("the committed module loads and satisfies runtime invariants", function()
	local generated = require("../../src/config/levels/Level_0")
	local config = Config.load(generated)
	H.eq(config.id, "level-0")
	H.eq(#config.transitions, 3)
	H.eq(#Config.verify(generated), 0)
end)

H.test("runtime rejects a level without transitions", function()
	local broken = clone(level0)
	broken.transitions = {}
	H.ok(#Config.verify(broken) > 0, "should reject")
end)

H.test("mastery requires every declared transition", function()
	local config = Config.load(level0)
	H.eq(Config.isMastered(config, {}), false)
	H.eq(Config.isMastered(config, { "l0.phase-wall" }), false)
	H.eq(Config.isMastered(config, { "l0.phase-wall", "l0.vent", "l0.glass-doors" }), true)
end)
