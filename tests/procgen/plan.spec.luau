--!strict

local H = require("../harness")
local Hash = require("../../src/shared/procgen/Hash")
local Plan = require("../../src/shared/procgen/Plan")
local Seed = require("../../src/shared/procgen/Seed")
local Version = require("../../src/shared/procgen/Version")

local function mkNode(id: number, kind: string?): Plan.Node
	return {
		id = id,
		kind = kind or "room",
		w = 8,
		h = 10,
		d = 8,
		level = 0,
		filler = "wfc",
		params = {},
		ports = {},
		tags = {},
	}
end

H.test("new stamps the schema, generator and macro versions", function()
	local plan = Plan.new(42, "level-0")
	H.eq(plan.schemaVersion, Version.SCHEMA_VERSION)
	H.eq(plan.genVersion, Version.GEN_VERSION)
	H.eq(plan.macroEpoch, Version.MACRO_EPOCH)
	H.eq(plan.seed, 42)
	H.eq(#plan.nodes, 0)
	H.eq(#plan.edges, 0)
	H.eq(#plan.connectors, 0)
end)

H.test("hash ignores the order fields were written in", function()
	local a = mkNode(1, "room")
	local b: Plan.Node = {
		tags = {},
		ports = {},
		params = {},
		filler = "wfc",
		level = 0,
		d = 8,
		h = 10,
		w = 8,
		kind = "room",
		id = 1,
	}
	H.eq(Plan.hash(Plan.new(42, "level-0", { a })), Plan.hash(Plan.new(42, "level-0", { b })))
end)

H.test("hash ignores node list order", function()
	local one = Plan.new(42, "level-0", { mkNode(1), mkNode(2) })
	local two = Plan.new(42, "level-0", { mkNode(2), mkNode(1) })
	H.eq(Plan.hash(one), Plan.hash(two))
end)

H.test("hash changes with the seed", function()
	H.neq(Plan.hash(Plan.new(42, "level-0")), Plan.hash(Plan.new(43, "level-0")))
end)

H.test("hash changes with the spec id", function()
	H.neq(Plan.hash(Plan.new(42, "level-0")), Plan.hash(Plan.new(42, "level-1")))
end)

H.test("hash changes when the generator version changes", function()
	local plan = Plan.new(42, "level-0")
	local bumped = table.clone(plan)
	bumped.genVersion = plan.genVersion + 1
	H.neq(Plan.hash(plan), Plan.hash(bumped))
end)

H.test("hash changes when the macro epoch changes", function()
	local plan = Plan.new(42, "level-0")
	local bumped = table.clone(plan)
	bumped.macroEpoch = plan.macroEpoch + 1
	H.neq(Plan.hash(plan), Plan.hash(bumped))
end)

H.test("hash changes when the body changes", function()
	local a = Plan.new(42, "level-0", { mkNode(1) })
	local b = Plan.new(42, "level-0", { mkNode(2) })
	H.neq(Plan.hash(a), Plan.hash(b))
end)

H.test("identity is seed code plus generator version", function()
	local plan = Plan.new(42, "level-0")
	H.eq(Plan.identity(plan), Seed.identity(42, Version.GEN_VERSION))
end)

H.test("bytes and hash agree", function()
	local plan = Plan.new(7, "x")
	H.eq(Hash.of(Plan.bytes(plan)), Plan.hash(plan))
end)
