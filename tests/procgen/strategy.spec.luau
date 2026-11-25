--!strict

local H = require("../harness")
local Strategy = require("../../src/shared/procgen/Strategy")
local Macro = require("../../src/shared/procgen/Macro")
local Embedding = require("../../src/shared/procgen/Embedding")
local Plan = require("../../src/shared/procgen/Plan")
local Level0 = require("../../src/config/levels/Level_0")

local function clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value) do
		copy[k] = clone(v)
	end
	return copy
end

H.test("the legacy strategy is byte-identical to calling the pipeline", function()
	local config = clone(Level0)
	config.strategy = { name = "rooms_and_corridors" }

	local generate = config.generate
	local direct = Embedding.embed(Macro.build(config, 42), {
		loops = generate.loops,
		loopShare = generate.loopShare,
		loopPreference = generate.loopPreference,
		connectivity = generate.connectivity,
		openings = generate.openings,
		exitSeparationShare = generate.exitSeparationShare,
	})

	H.eq(Plan.bytes(Strategy.build(config, 42)), Plan.bytes(direct), "same plan bytes")
end)

H.test("strategy name defaults to rooms_and_corridors", function()
	local config = clone(Level0)
	config.strategy = nil
	H.eq(Strategy.nameOf(config), "rooms_and_corridors")
	H.eq(Strategy.kind(config), "plan")
end)

H.test("an unknown strategy fails with a readable error", function()
	local config = clone(Level0)
	config.strategy = { name = "does_not_exist" }
	local ok, err = pcall(Strategy.build, config, 42)
	H.ok(not ok)
	H.ok(string.find(tostring(err), "unknown strategy", 1, true) ~= nil, tostring(err))
end)

H.test("open_additive dispatches and returns a grid world", function()
	local config = clone(Level0)
	local world = Strategy.build(config, 42)
	H.eq(Strategy.kind(config), "grid")
	H.eq(world.n, 18)
	H.eq(world.cell, 16)
	H.eq(world.period, world.chunks * world.n)
end)

H.test("validation explains bad params", function()
	local config = clone(Level0)
	config.strategy = clone(Level0.strategy)
	config.strategy.params = clone(Level0.strategy.params)
	config.strategy.params.chunkCells = 17 -- 17 % 6 ~= 0
	local problems = Strategy.validate(config)
	H.ok(#problems > 0, "chunkCells must be rejected")
	H.ok(
		table.concat(problems, ";"):find("multiple of block", 1, true) ~= nil,
		table.concat(problems, ";")
	)
end)

H.test("validation rejects an unknown size tier", function()
	local config = clone(Level0)
	config.world = clone(Level0.world)
	config.world.sizeTier = "gigantic"
	local problems = Strategy.validate(config)
	H.ok(
		table.concat(problems, ";"):find("unknown tier", 1, true) ~= nil,
		table.concat(problems, ";")
	)
end)

H.test("validation rejects a reversed run length", function()
	local config = clone(Level0)
	config.strategy = clone(Level0.strategy)
	config.strategy.params = clone(Level0.strategy.params)
	config.strategy.params.runLength = { 6, 2 }
	local problems = Strategy.validate(config)
	H.ok(table.concat(problems, ";"):find("runLength", 1, true) ~= nil, table.concat(problems, ";"))
end)

H.test("the shipped Level 0 config validates", function()
	H.eq(#Strategy.validate(Level0), 0, table.concat(Strategy.validate(Level0), "; "))
end)
