--!strict

-- Level framework core (task 0026): system contract, registry ordering and
-- ownership, Level.resolve against Level 0, namespaced randomness.

local H = require("../harness")
local System = require("../../src/shared/procgen/level/System")
local Registry = require("../../src/shared/procgen/level/Registry")
local Rand = require("../../src/shared/procgen/level/Rand")
local Level = require("../../src/shared/procgen/level/Level")
local Level0 = require("../../src/config/levels/Level_0")

local function sys(id: string, extra: any?): System.System
	local spec: any = { id = id, owns = { "own_" .. id }, phase = "generate", stage = "base" }
	for key, value in pairs(extra or {}) do
		spec[key] = value
	end
	return System.define(spec)
end

local function ids(list: { System.System }): string
	local out = {}
	for _, system in ipairs(list) do
		table.insert(out, system.id)
	end
	return table.concat(out, ",")
end

local function registryOf(list: { System.System }): Registry.Registry
	local registry = Registry.new()
	for _, system in ipairs(list) do
		registry:register(system)
	end
	return registry
end

local function errorOf(fn: () -> ()): string
	local ok, err = pcall(fn)
	H.ok(not ok, "expected an error")
	return tostring(err)
end

H.test("framework: System.define fills defaults and rejects bad shapes", function()
	local s = System.define({ id = "x", owns = { "x" }, phase = "render" })
	H.eq(s.status, "active")
	H.eq(#(s.after :: { string }), 0)
	H.throws(function()
		System.define({ id = "x", owns = {}, phase = "render" })
	end, "empty owns")
	H.throws(function()
		System.define({ id = "x", owns = { "x" }, phase = "nope" })
	end, "bad phase")
	H.throws(function()
		System.define({ id = "x", owns = { "x" }, phase = "render", stage = "base" })
	end, "stage of another phase")
end)

H.test("framework: order sorts by stage, then id", function()
	local registry = registryOf({
		sys("zeta", { stage = "base" }),
		sys("alpha", { stage = "decorate" }),
		sys("mid", { stage = "base" }),
		sys("first", { stage = "field" }),
		sys("other", { phase = "render", stage = "surfaces" }),
	})
	H.eq(ids(registry:order("generate")), "first,mid,zeta,alpha")
	H.eq(ids(registry:order("render")), "other")
end)

H.test("framework: after and before reorder within and across stages", function()
	local registry = registryOf({
		sys("a", { stage = "base", after = { "b" } }),
		sys("b", { stage = "base" }),
		sys("c", { stage = "field", after = { "d" } }),
		sys("d", { stage = "decorate" }),
		sys("e", { stage = "decorate", before = { "d" } }),
	})
	H.eq(ids(registry:order("generate")), "b,a,e,d,c")
end)

H.test("framework: a dependency cycle is a readable error", function()
	local registry = registryOf({
		sys("a", { after = { "b" } }),
		sys("b", { after = { "c" } }),
		sys("c", { after = { "a" } }),
	})
	local message = errorOf(function()
		registry:order("generate")
	end)
	H.ok(string.find(message, "dependency cycle", 1, true) ~= nil, message)
	H.ok(string.find(message, "a, b, c", 1, true) ~= nil, message)
end)

H.test("framework: an unknown dependency is a readable error", function()
	local registry = registryOf({ sys("a", { before = { "ghost" } }) })
	local message = errorOf(function()
		registry:order("generate")
	end)
	H.ok(string.find(message, "unknown dependency 'ghost'", 1, true) ~= nil, message)
end)

H.test("framework: duplicate id and duplicate owned path are errors", function()
	local registry = registryOf({ sys("a") })
	local dupId = errorOf(function()
		registry:register(sys("a", { owns = { "other" } }))
	end)
	H.ok(string.find(dupId, "duplicate system id 'a'", 1, true) ~= nil, dupId)
	local dupPath = errorOf(function()
		registry:register(sys("b", { owns = { "own_a" } }))
	end)
	H.ok(string.find(dupPath, "'own_a' is owned by both 'a' and 'b'", 1, true) ~= nil, dupPath)
end)

H.test("framework: owner resolves the longest prefix on segment boundaries", function()
	local registry = registryOf({
		sys("whole", { owns = { "strategy" } }),
		sys("terrain", { owns = { "strategy.params.terrain" } }),
	})
	H.eq((registry:owner("strategy.params.terrain.plateauShare") :: System.System).id, "terrain")
	H.eq((registry:owner("strategy.params.terrain") :: System.System).id, "terrain")
	H.eq((registry:owner("strategy.params.cell") :: System.System).id, "whole")
	H.eq(registry:owner("strategyx"), nil)
	H.eq(registry:owner("lighting"), nil)
end)

H.test("framework: Level 0 resolves with no problems and warns about planned sections", function()
	local resolved = Level.resolve(Level0)
	H.eq(#resolved.problems, 0, table.concat(resolved.problems, "; "))
	local warned = {}
	for _, warning in ipairs(resolved.warnings) do
		warned[warning] = true
	end
	for _, id in ipairs({
		"lighting",
		"hazards",
		"props",
		"entities",
		"transitions",
		"tileset",
		"generate",
	}) do
		H.ok(
			warned[`declared but not consumed yet: {id} (planned)`] == true,
			"missing warning for " .. id
		)
	end
	H.eq(#resolved.warnings, 7)
	print("  [framework] Level 0 warnings: " .. table.concat(resolved.warnings, " | "))
end)

H.test("framework: an unowned top-level key or strategy param is a problem", function()
	local config = table.clone(Level0) :: any
	config.weather = { rain = true }
	local strategy = table.clone(Level0.strategy) :: any
	local params = table.clone(Level0.strategy.params) :: any
	params.mystery = 1
	strategy.params = params
	config.strategy = strategy
	local problems = Level.resolve(config).problems
	H.eq(#problems, 2, table.concat(problems, "; "))
	H.eq(problems[1], "unowned config section weather")
	H.eq(problems[2], "unowned config section strategy.params.mystery")
end)

H.test("framework: owner validation and planned-shape problems surface", function()
	local config = table.clone(Level0) :: any
	config.lighting = "dusk"
	local problems = Level.resolve(config).problems
	H.eq(#problems, 1, table.concat(problems, "; "))
	H.ok(string.find(problems[1], "lighting: expected a table", 1, true) ~= nil, problems[1])
end)

H.test("framework: Rand streams are namespaced per system and stable", function()
	local function draws(systemId: string, ...: any): string
		local rng = Rand.stream(42, systemId, ...)
		local out = {}
		for _ = 1, 4 do
			table.insert(out, rng:nextU32())
		end
		return table.concat(out, ",")
	end
	H.eq(draws("lighting"), draws("lighting"), "stable across calls")
	H.neq(draws("lighting"), draws("props"), "different systems")
	H.neq(draws("lighting", "a"), draws("lighting", "b"), "different keys")
	H.neq(draws("lighting"), draws("lighting", "a"), "keys extend the namespace")
	H.neq(Rand.stream(42, "lighting"):nextU32(), Rand.stream(43, "lighting"):nextU32(), "seed")
end)

H.test("framework: Rand.hash01 is in range, stable and namespaced", function()
	local a = Rand.hash01(42, "props", 3, 4)
	H.eq(a, Rand.hash01(42, "props", 3, 4))
	H.ok(a >= 0 and a < 1, "range")
	H.neq(a, Rand.hash01(42, "hazards", 3, 4), "different systems")
	H.neq(a, Rand.hash01(42, "props", 4, 3), "different keys")
	local sum = 0
	for i = 1, 200 do
		sum += Rand.hash01(7, "props", i)
	end
	H.ok(sum / 200 > 0.4 and sum / 200 < 0.6, "roughly uniform")
end)
