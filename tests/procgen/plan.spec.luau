--!strict

local H = require("../harness")
local Hash = require("../../src/shared/procgen/Hash")
local Plan = require("../../src/shared/procgen/Plan")
local Seed = require("../../src/shared/procgen/Seed")
local Version = require("../../src/shared/procgen/Version")

H.test("new stamps the schema and generator versions", function()
	local plan = Plan.new(42, "level-0")
	H.eq(plan.schemaVersion, Version.SCHEMA_VERSION)
	H.eq(plan.genVersion, Version.GEN_VERSION)
	H.eq(plan.seed, 42)
	H.eq(#plan.nodes, 0)
	H.eq(#plan.edges, 0)
end)

H.test("hash ignores table key order", function()
	local a = Plan.new(42, "level-0", { { id = "r1", type = "room", size = 8 } }, {})
	local b = Plan.new(42, "level-0", { { size = 8, type = "room", id = "r1" } }, {})
	H.eq(Plan.hash(a), Plan.hash(b))
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

H.test("hash changes when the body changes", function()
	local a = Plan.new(42, "level-0", { { id = "r1" } }, {})
	local b = Plan.new(42, "level-0", { { id = "r2" } }, {})
	H.neq(Plan.hash(a), Plan.hash(b))
end)

H.test("identity is seed code plus generator version", function()
	local plan = Plan.new(42, "level-0")
	H.eq(Plan.identity(plan), Seed.identity(42, Version.GEN_VERSION))
end)

H.test("canonical form is stable across two constructions", function()
	H.eq(Plan.canonical(Plan.new(7, "x")), Plan.canonical(Plan.new(7, "x")))
	H.ok(Hash.of(Plan.canonical(Plan.new(7, "x"))) == Plan.hash(Plan.new(7, "x")), "hash matches")
end)
