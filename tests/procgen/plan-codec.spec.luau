--!strict

local H = require("../harness")
local Hash = require("../../src/shared/procgen/Hash")
local Plan = require("../../src/shared/procgen/Plan")
local PlanCodec = require("../../src/shared/procgen/PlanCodec")
local Version = require("../../src/shared/procgen/Version")
local golden = require("../fixtures/plan-golden")

local function hex(buffer: string): string
	local parts = {}
	for i = 1, #buffer do
		parts[i] = string.format("%02x", string.byte(buffer, i))
	end
	return table.concat(parts)
end

local function deepEqual(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for key, value in pairs(a) do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local function rejects(label: string, fn: () -> ())
	local ok, err = pcall(fn)
	H.ok(not ok, label .. " should have failed")
	if not ok then
		H.ok(type(err) == "string" and #err > 0, label .. " should explain why")
	end
end

H.test("golden plan round-trips", function()
	local plan = golden.plan
	local bytes = Plan.bytes(plan)
	H.eq(#bytes, golden.bytesLen, "golden byte length")
	H.eq(hex(bytes), golden.bytesHex, "golden bytes")
	H.eq(Plan.hash(plan), golden.hash, "golden hash")
	H.ok(deepEqual(PlanCodec.decode(bytes), plan), "decode(encode(plan)) == plan")
end)

H.test("re-encoding a decoded plan is byte-identical", function()
	local bytes = Plan.bytes(golden.plan)
	H.eq(Plan.bytes(PlanCodec.decode(bytes)), bytes)
end)

H.test("encoding is independent of construction order", function()
	local a = table.clone(golden.plan)
	local b = table.clone(golden.plan)
	b.nodes = { b.nodes[3], b.nodes[1], b.nodes[2] }
	H.eq(Plan.bytes(a), Plan.bytes(b))
end)

H.test("hash is the fingerprint of the encoded bytes", function()
	H.eq(Plan.hash(golden.plan), Hash.of(Plan.bytes(golden.plan)))
end)

H.test("negative integers survive the round trip", function()
	local params = golden.plan.nodes[1].params
	H.eq(params.offset, -2, "fixture sanity")
	local decoded = PlanCodec.decode(Plan.bytes(golden.plan))
	H.eq(decoded.nodes[1].params.offset, -2, "decoded negative param")
end)

H.test("encoder rejects floats", function()
	local plan = Plan.new(42, "level-0")
	local node = {
		id = 1,
		kind = "room",
		w = 12.5,
		h = 10,
		d = 8,
		level = 0,
		filler = "wfc",
		params = {},
		ports = {},
		tags = {},
	}
	plan.nodes = { node :: any }
	rejects("float width", function()
		Plan.bytes(plan)
	end)
end)

H.test("encoder rejects unknown sides and guards", function()
	local plan = Plan.new(42, "level-0")
	plan.nodes = {
		{
			id = 1,
			kind = "room",
			w = 8,
			h = 8,
			d = 8,
			level = 0,
			filler = "wfc",
			params = {},
			ports = {
				{
					id = 1,
					side = "X",
					offset = 0,
					width = 2,
					elevation = 0,
					kind = "door",
					guard = "auto",
				},
			},
			tags = {},
		} :: any,
	}
	rejects("unknown side", function()
		Plan.bytes(plan)
	end)
end)

H.test("decoder rejects an unknown schema version", function()
	local plan = table.clone(golden.plan)
	plan.schemaVersion = Version.PLAN_SCHEMA_VERSION + 1
	local bytes = PlanCodec.encode(plan)
	rejects("schema version", function()
		PlanCodec.decode(bytes)
	end)
end)

H.test("decoder rejects a foreign buffer", function()
	rejects("bad magic", function()
		PlanCodec.decode("not-a-plan")
	end)
end)

H.test("decoder rejects truncated input", function()
	local bytes = Plan.bytes(golden.plan)
	rejects("truncated", function()
		PlanCodec.decode(string.sub(bytes, 1, #bytes - 4))
	end)
end)

H.test("decoder rejects trailing bytes", function()
	local bytes = Plan.bytes(golden.plan)
	rejects("trailing", function()
		PlanCodec.decode(bytes .. "\0")
	end)
end)

H.test("decoder rejects duplicate node ids", function()
	local plan = Plan.new(42, "level-0", {
		{
			id = 1,
			kind = "room",
			w = 8,
			h = 8,
			d = 8,
			level = 0,
			filler = "wfc",
			params = {},
			ports = {},
			tags = {},
		},
		{
			id = 1,
			kind = "room",
			w = 8,
			h = 8,
			d = 8,
			level = 0,
			filler = "wfc",
			params = {},
			ports = {},
			tags = {},
		},
	})
	rejects("duplicate node", function()
		PlanCodec.decode(Plan.bytes(plan))
	end)
end)

H.test("decoder rejects an edge that points at a missing node", function()
	local plan = Plan.new(42, "level-0", {
		{
			id = 1,
			kind = "room",
			w = 8,
			h = 8,
			d = 8,
			level = 0,
			filler = "wfc",
			params = {},
			ports = {},
			tags = {},
		},
	})
	plan.edges = { { id = 1, a = 1, b = 9, aPort = 1, bPort = 1, kind = "passage" } }
	rejects("dangling edge", function()
		PlanCodec.decode(Plan.bytes(plan))
	end)
end)

H.test("decoder rejects a connector that points at a missing node", function()
	local plan = Plan.new(42, "level-0")
	plan.connectors = {
		{
			id = 1,
			kind = "stairs",
			fromNode = 1,
			fromPort = 1,
			toNode = 2,
			toPort = 1,
			params = {},
		},
	}
	rejects("dangling connector", function()
		PlanCodec.decode(Plan.bytes(plan))
	end)
end)
