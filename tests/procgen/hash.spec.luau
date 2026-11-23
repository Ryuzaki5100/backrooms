--!strict

local H = require("../harness")
local Hash = require("../../src/shared/procgen/Hash")

H.test("fnv1a32 of an empty string is the basis constant", function()
	H.eq(Hash.u32(""), 2166136261)
end)

H.test("fingerprint is 16 lowercase hex characters", function()
	local fingerprint = Hash.of("level-0")
	H.eq(#fingerprint, 16, "length")
	H.ok(string.match(fingerprint, "^[0-9a-f]+$") ~= nil, "hex alphabet")
end)

H.test("fingerprint is stable for the same input", function()
	H.eq(Hash.of("level-0|seed"), Hash.of("level-0|seed"))
end)

H.test("fingerprint changes with the input", function()
	H.neq(Hash.of("level-0"), Hash.of("level-1"))
end)

H.test("canonical form ignores table key order", function()
	local a = Hash.canonical({ alpha = 1, beta = 2, gamma = 3 })
	local b = Hash.canonical({ gamma = 3, alpha = 1, beta = 2 })
	H.eq(a, b)
end)

H.test("canonical form distinguishes array order", function()
	H.neq(Hash.canonical({ 1, 2 }), Hash.canonical({ 2, 1 }))
end)

H.test("canonical form rejects floats", function()
	H.throws(function()
		Hash.canonical(1.5)
	end, "float")
end)

H.test("canonical form distinguishes 1 from '1'", function()
	H.neq(Hash.canonical(1), Hash.canonical("1"))
end)

H.test("mul32 is exact at the 32-bit boundary", function()
	H.eq(Hash.mul32(4294967295, 1), 4294967295)
	H.eq(Hash.mul32(4294967295, 2), 4294967294)
	H.eq(Hash.mul32(65536, 65536), 0)
end)
