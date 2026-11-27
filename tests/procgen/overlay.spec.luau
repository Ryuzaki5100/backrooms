--!strict

local H = require("../harness")
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local ConfigGen = require("../../tools/ConfigGen")
local Config = require("../../src/shared/procgen/Config")
local Overlay = require("../../src/shared/procgen/level/Overlay")

local function loadJson(path: string): any
	return serde.decode("json", fs.readFile(path))
end

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

local function addon(id: string, patch: any, extra: any?): any
	local result = { id = id, version = 1, title = id, patch = patch }
	if extra ~= nil then
		for key, value in pairs(extra) do
			result[key] = value
		end
	end
	return result
end

local function sample(): any
	return {
		name = "base",
		nested = { a = 1, b = { c = 2, d = 3 } },
		list = { { id = "x", n = 1 }, { id = "y", n = 2 }, { ref = "z", n = 3 } },
		plain = { 1, 2, 3 },
		gone = { keep = true },
	}
end

H.test("objects deep-merge and scalars replace", function()
	local merged =
		Overlay.apply(sample(), { addon("m", { name = "patched", nested = { b = { c = 9 } } }) })
	H.eq(merged.name, "patched", "scalar replaced")
	H.eq(merged.nested.a, 1, "sibling kept")
	H.eq(merged.nested.b.c, 9, "deep value replaced")
	H.eq(merged.nested.b.d, 3, "deep sibling kept")
end)

H.test("a plain array in a patch replaces the array", function()
	local merged = Overlay.apply(sample(), { addon("m", { plain = { 7 } }) })
	H.eq(#merged.plain, 1, "length")
	H.eq(merged.plain[1], 7, "value")
end)

H.test("$append adds to the end", function()
	local merged = Overlay.apply(sample(), { addon("m", { plain = { ["$append"] = { 4, 5 } } }) })
	H.eq(#merged.plain, 5, "length")
	H.eq(merged.plain[5], 5, "last")
end)

H.test("$append creates a missing array", function()
	local merged = Overlay.apply(sample(), { addon("m", { fresh = { ["$append"] = { "a" } } }) })
	H.eq(merged.fresh[1], "a", "created")
end)

H.test("$remove drops elements by id and by ref", function()
	local merged =
		Overlay.apply(sample(), { addon("m", { list = { ["$remove"] = { "x", "z" } } }) })
	H.eq(#merged.list, 1, "length")
	H.eq(merged.list[1].id, "y", "survivor")
end)

H.test("$replace swaps the whole array", function()
	local merged =
		Overlay.apply(sample(), { addon("m", { list = { ["$replace"] = { { id = "only" } } } }) })
	H.eq(#merged.list, 1, "length")
	H.eq(merged.list[1].id, "only", "value")
end)

H.test("$remove and $append combine as replace-by-id", function()
	local merged = Overlay.apply(
		sample(),
		{ addon("m", { list = { ["$remove"] = { "x" }, ["$append"] = { { id = "x", n = 10 } } } }) }
	)
	H.eq(#merged.list, 3, "length")
	H.eq(merged.list[3].n, 10, "re-added at the end")
end)

H.test("$delete removes a key", function()
	local merged = Overlay.apply(sample(), { addon("m", { gone = { ["$delete"] = true } }) })
	H.eq(merged.gone, nil, "deleted")
	H.eq(merged.name, "base", "others untouched")
end)

H.test("a malformed $delete is an error", function()
	H.throws(function()
		Overlay.apply(sample(), { addon("m", { gone = { ["$delete"] = false } }) })
	end, "$delete false")
end)

H.test("an unknown op is an error naming the add-on", function()
	local ok, message = pcall(function()
		Overlay.apply(sample(), { addon("typo-addon", { plain = { ["$prepend"] = { 0 } } }) })
	end)
	H.ok(not ok, "raised")
	H.ok(string.find(tostring(message), "typo-addon", 1, true) ~= nil, "names add-on")
	H.ok(string.find(tostring(message), "$prepend", 1, true) ~= nil, "names op")
end)

H.test("an op on a non-array target is an error", function()
	H.throws(function()
		Overlay.apply(sample(), { addon("m", { nested = { ["$append"] = { 1 } } }) })
	end, "append onto object")
end)

H.test("add-ons apply in (order, id) order, not input order", function()
	local first = addon("b", { name = "b" }, { order = 5 })
	local second = addon("a", { name = "a" }, { order = 5 })
	local third = addon("c", { name = "c" }) -- default order 100
	local early = addon("z", { name = "z" }, { order = 1 })
	local merged, applied = Overlay.apply(sample(), { third, first, early, second })
	H.eq(merged.name, "c", "last applied wins")
	local ids = {}
	for _, entry in ipairs(applied) do
		table.insert(ids, entry.id)
	end
	H.eq(table.concat(ids, ","), "z,a,b,c", "apply order")
end)

H.test("enabled flags: own flag, and the override map beats it", function()
	local on = addon("on", { name = "on" })
	local off = addon("off", { name = "off" }, { enabled = false, order = 200 })

	local _, applied = Overlay.apply(sample(), { on, off })
	H.eq(#applied, 1, "own flags")
	H.eq(applied[1].id, "on", "only the enabled one")

	local merged, forced = Overlay.apply(sample(), { on, off }, { off = true, on = false })
	H.eq(#forced, 1, "override count")
	H.eq(forced[1].id, "off", "override flips both")
	H.eq(merged.name, "off", "override applied")
end)

H.test("applied carries versions", function()
	local _, applied = Overlay.apply(sample(), { addon("v", {}, { version = 4 }) })
	H.eq(applied[1].version, 4, "version")
end)

H.test("the base is never mutated", function()
	local base = sample()
	local before = serde.encode("json", base)
	Overlay.apply(base, {
		addon("m", {
			nested = { b = { c = 1 } },
			list = { ["$remove"] = { "x" } },
			plain = { ["$append"] = { 9 } },
			gone = { ["$delete"] = true },
		}),
	})
	H.eq(serde.encode("json", base), before, "base unchanged")
end)

H.test("patch values are copied, not aliased", function()
	local patch = { plain = { ["$append"] = { { id = "p" } } } }
	local merged = Overlay.apply(sample(), { addon("m", patch) })
	merged.plain[4].id = "changed"
	H.eq(patch.plain["$append"][1].id, "p", "patch unchanged")
end)

H.test("duplicate add-on ids are an error", function()
	H.throws(function()
		Overlay.apply(sample(), { addon("d", {}), addon("d", {}) })
	end, "duplicate id")
end)

H.test("fingerprint is unchanged without add-ons and changes with them", function()
	local level0 = loadJson("config/levels/level-0.json")
	local plain = Config.fingerprint(level0)
	H.eq(Config.fingerprint(level0, {}), plain, "empty applied list")
	H.eq(Config.fingerprint(level0, nil), plain, "nil applied list")
	local one = Config.fingerprint(level0, { { id = "a", version = 1 } })
	local bumped = Config.fingerprint(level0, { { id = "a", version = 2 } })
	H.neq(one, plain, "add-on changes identity")
	H.neq(bumped, one, "version changes identity")
end)

-- Fixture level: a Level 0 clone with three add-ons (one disabled by default).
local FIXTURE = "tests/fixtures/addons"
local schema = loadJson("config/schema.json")
local addonSchema = loadJson("config/addon.schema.json")

local function fixtureAddons(): { any }
	local files = fs.readDir(FIXTURE .. "/level-fixture/addons")
	table.sort(files)
	local addons = {}
	for _, file in ipairs(files) do
		table.insert(addons, loadJson(FIXTURE .. "/level-fixture/addons/" .. file))
	end
	return addons
end

H.test("fixture add-ons validate and merge into a valid config", function()
	local base = loadJson(FIXTURE .. "/level-fixture.json")
	local merged, applied, errors =
		ConfigGen.resolve(schema, addonSchema, base, fixtureAddons(), "fixture")
	H.eq(#errors, 0, table.concat(errors, " | "))
	H.eq(#applied, 2, "c-disabled is off by default")
	H.eq(applied[1].id, "a-fog", "order")
	H.eq(applied[2].id, "b-transitions", "order")
	H.eq(merged.lighting.fogEnd, 40, "deep merge")
	H.eq(merged.lighting.bloom, base.lighting.bloom, "untouched sibling")
	H.eq(merged.generate.loops, 6, "nested scalar")
	H.eq(#merged.transitions, #base.transitions, "one removed, one appended")
	local ids = {}
	for _, transition in ipairs(merged.transitions) do
		ids[transition.id] = true
	end
	H.ok(ids["l0.fixture-gate"] == true and ids["l0.vent"] == nil, "transition ops")
	H.eq(#merged.props, #base.props + 1, "prop appended")
end)

H.test("fixture: enabling the disabled add-on applies replace and delete", function()
	local base = loadJson(FIXTURE .. "/level-fixture.json")
	local merged, applied, errors = ConfigGen.resolve(
		schema,
		addonSchema,
		base,
		fixtureAddons(),
		"fixture",
		{ ["c-disabled"] = true }
	)
	H.eq(#errors, 0, table.concat(errors, " | "))
	H.eq(#applied, 3, "all three")
	H.eq(#merged.props, 1, "props replaced")
	H.eq(merged.hazards, nil, "hazards deleted")
end)

H.test("a merged config that breaks the schema is reported", function()
	local base = loadJson(FIXTURE .. "/level-fixture.json")
	local broken = addon("breaks", { tileset = { ["$delete"] = true } })
	local merged, _, errors = ConfigGen.resolve(schema, addonSchema, base, { broken }, "fixture")
	H.eq(merged, nil, "no merged config")
	H.ok(#errors > 0 and string.find(errors[1], "merged", 1, true) ~= nil, "merged error")
end)

H.test("an add-on that breaks addon.schema.json is reported", function()
	local base = loadJson(FIXTURE .. "/level-fixture.json")
	local bad = { id = "Bad Id", version = 0, title = "t", patch = {}, extra = true }
	local merged, _, errors = ConfigGen.resolve(schema, addonSchema, base, { bad }, "fixture")
	H.eq(merged, nil, "no merged config")
	H.ok(#errors >= 3, "id, version and unknown key: " .. table.concat(errors, " | "))
end)

H.test("an unknown op surfaces through resolve", function()
	local base = loadJson(FIXTURE .. "/level-fixture.json")
	local bad = addon("typo", { props = { ["$bogus"] = {} } })
	local merged, _, errors = ConfigGen.resolve(schema, addonSchema, base, { bad }, "fixture")
	H.eq(merged, nil, "no merged config")
	H.ok(string.find(errors[1], "$bogus", 1, true) ~= nil, "names the op")
end)

H.test("rendering is deterministic and the add-ons module carries base and add-ons", function()
	local base = loadJson(FIXTURE .. "/level-fixture.json")
	local addons = fixtureAddons()
	local merged = ConfigGen.resolve(schema, addonSchema, base, addons, "fixture")
	local first = ConfigGen.render(merged, "x.json")
	H.eq(ConfigGen.render(merged, "x.json"), first, "stable")
	H.ok(string.find(first, "l0.fixture-gate", 1, true) ~= nil, "merged content rendered")

	local addonsModule = ConfigGen.renderAddons(base, addons, "x.json")
	H.ok(string.find(addonsModule, '["base"]', 1, true) ~= nil, "base key")
	H.ok(string.find(addonsModule, '["addons"]', 1, true) ~= nil, "addons key")
	H.ok(string.find(addonsModule, "c-disabled", 1, true) ~= nil, "disabled add-on kept")
	H.ok(string.find(addonsModule, "l0.vent", 1, true) ~= nil, "base keeps the vent")
end)

H.test("Level 0 renders byte-identically to the committed module", function()
	local level0 = loadJson("config/levels/level-0.json")
	H.ok(not fs.isDir("config/levels/level-0"), "level 0 has no add-ons")
	local rendered = ConfigGen.render(level0, "config/levels/level-0.json")
	H.eq(rendered, fs.readFile("src/config/levels/Level_0.luau"), "Level_0.luau unchanged")
	local merged, applied = Overlay.apply(level0, {})
	H.eq(#applied, 0, "nothing applied")
	H.eq(
		ConfigGen.render(merged, "config/levels/level-0.json"),
		rendered,
		"empty merge is identity"
	)
	H.eq(Config.fingerprint(merged, applied), Config.fingerprint(level0), "fingerprint")
	H.ok(clone(level0) ~= level0, "sanity")
end)
