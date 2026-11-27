--!strict

local H = require("../harness")
local Strategy = require("../../src/shared/procgen/Strategy")
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

H.test("strategy name defaults to open_additive", function()
	local config = clone(Level0)
	config.strategy = nil
	H.eq(Strategy.nameOf(config), "open_additive")
	H.eq(Strategy.kind(config), "grid")
end)

H.test("rooms_and_corridors is retired and fails with a readable error", function()
	local config = clone(Level0)
	config.strategy = { name = "rooms_and_corridors" }
	local ok, err = pcall(Strategy.build, config, 42)
	H.ok(not ok)
	H.ok(string.find(tostring(err), "retired (ADR 0032 A2)", 1, true) ~= nil, tostring(err))
	H.ok(
		string.find(tostring(err), "reserved for a future graph strategy", 1, true) ~= nil,
		tostring(err)
	)
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
