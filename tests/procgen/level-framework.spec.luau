--!strict

-- Level framework core (task 0026): system contract, registry ordering and
-- ownership, Level.resolve against Level 0, namespaced randomness.

local H = require("../harness")
local System = require("../../src/shared/procgen/level/System")
local Registry = require("../../src/shared/procgen/level/Registry")
local Rand = require("../../src/shared/procgen/level/Rand")
local Level = require("../../src/shared/procgen/level/Level")
local OpenAdditive = require("../../src/shared/procgen/strategies/OpenAdditive")
local ChunkRenderer = require("../../src/shared/procgen/grid/ChunkRenderer")
local Hash = require("../../src/shared/procgen/Hash")
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

H.test("framework: after and before reorder within a stage", function()
	local registry = registryOf({
		sys("a", { stage = "base", after = { "b" } }),
		sys("b", { stage = "base" }),
		sys("c", { stage = "decorate", after = { "d" } }),
		sys("d", { stage = "decorate" }),
		sys("e", { stage = "decorate", before = { "d" } }),
		sys("f", { stage = "field", before = { "a" } }),
	})
	H.eq(ids(registry:order("generate")), "f,b,a,e,d,c")
end)

H.test("framework: a dependency that contradicts stage order is a readable error", function()
	local afterEarlier = registryOf({
		sys("late", { stage = "decorate" }),
		sys("early", { stage = "field", after = { "late" } }),
	})
	local message = errorOf(function()
		afterEarlier:order("generate")
	end)
	H.ok(
		string.find(message, "'early' (stage 'field') is ordered after 'late'", 1, true) ~= nil,
		message
	)
	H.ok(string.find(message, "only order systems within one stage", 1, true) ~= nil, message)

	local beforeEarlier = registryOf({
		sys("early", { stage = "field" }),
		sys("late", { stage = "decorate", before = { "early" } }),
	})
	local mirrored = errorOf(function()
		beforeEarlier:order("generate")
	end)
	H.ok(
		string.find(mirrored, "'early' (stage 'field') is ordered after 'late'", 1, true) ~= nil,
		mirrored
	)

	-- A dependency across phases is not a stage comparison.
	local crossPhase = registryOf({
		sys("g", { stage = "decorate", after = { "r" } }),
		sys("r", { phase = "render", stage = "surfaces" }),
	})
	H.eq(ids(crossPhase:order("generate")), "g")
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

local function generateIds(registry: Registry.Registry): string
	local out = {}
	for _, system in ipairs(registry:order("generate")) do
		if system.hooks.generate ~= nil then
			table.insert(out, system.id)
		end
	end
	return table.concat(out, ",")
end

H.test(
	"framework: Level 0 generates terrain, structures, templates, connectivity, details",
	function()
		H.eq(
			generateIds(Level.defaultRegistry()),
			"terrain,structures,templates,connectivity,details"
		)
		local make = OpenAdditive.world(Level0, 42)
		local live = {}
		for _, system in ipairs(make.generators) do
			table.insert(live, system.id)
		end
		H.eq(table.concat(live, ","), "terrain,structures,templates,connectivity,details")
	end
)

local function pinFingerprint(seed: number, extra: System.System?): (string, number)
	local config = table.clone(Level0) :: any
	config.world = table.clone(Level0.world)
	config.world.worldSizeChunks = 3
	local make = OpenAdditive.world(config, seed)
	if extra ~= nil then
		local registry = Level.defaultRegistry()
		registry:register(extra)
		local generators = {}
		for _, system in ipairs(registry:order("generate")) do
			if system.hooks.generate ~= nil then
				table.insert(generators, system)
			end
		end
		make.generators = generators
	end
	local lines = {}
	for cz = 0, 2 do
		for cx = 0, 2 do
			local layout = OpenAdditive.layout(make, cx, cz)
			for _, part in ipairs(ChunkRenderer.describe(layout, { style = { budget = 9000 } })) do
				lines[#lines + 1] = table.concat({
					part.kind,
					part.owner,
					tostring(part.size[1]),
					tostring(part.size[2]),
					tostring(part.size[3]),
					tostring(part.position[1]),
					tostring(part.position[2]),
					tostring(part.position[3]),
					tostring(part.yaw),
					tostring(part.wedge or false),
				}, "|")
			end
		end
	end
	table.sort(lines)
	return Hash.of(table.concat(lines, "\n")), #lines
end

H.test("framework: an extra no-op generate system leaves both pins unchanged", function()
	local calls = 0
	local noop = System.define({
		id = "noop",
		owns = { "own_noop" },
		phase = "generate",
		stage = "gated",
		hooks = {
			generate = function(_make: any, _layout: any, _ctx: any)
				calls += 1
			end,
		},
	})
	local fp42, count42 = pinFingerprint(42, noop)
	H.eq(fp42, "d10a18340f67f4ae", "seed 42 fingerprint")
	H.eq(count42, 603, "seed 42 part count")
	local fp1337, count1337 = pinFingerprint(1337, noop)
	H.eq(fp1337, "d9f25dc6bdb27cc0", "seed 1337 fingerprint")
	H.eq(count1337, 569, "seed 1337 part count")
	H.eq(calls, 18, "the extra system ran once per chunk")
end)
