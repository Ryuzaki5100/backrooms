--!strict

local H = require("../harness")
local Rng = require("../../src/shared/procgen/Rng")
local Seed = require("../../src/shared/procgen/Seed")

H.test("round-trips boundary values", function()
	local cases = { 0, 1, 35, 36, 1295, Seed.MAX }
	for _, value in ipairs(cases) do
		local parsed, err = Seed.parse(Seed.format(value))
		H.eq(err, nil, "parse error for " .. tostring(value))
		H.eq(parsed, value, "round-trip " .. tostring(value))
	end
end)

H.test("codes are six uppercase base36 characters", function()
	local code = Seed.format(12345)
	H.eq(#code, Seed.LENGTH, "length")
	H.ok(string.match(code, "^[0-9A-Z]+$") ~= nil, "alphabet")
end)

H.test("parses lowercase, whitespace and a leading hash", function()
	local value = Seed.parse("# 00 00 7q") :: number
	H.eq(value, Seed.parse("00007Q") :: number)
end)

H.test("round-trips 5000 pseudo-random seeds", function()
	local rng = Rng.new(2024)
	for _ = 1, 5000 do
		local value = Seed.random(rng)
		local parsed, err = Seed.parse(Seed.format(value))
		H.eq(err, nil)
		H.eq(parsed, value)
	end
end)

H.test("rejects invalid codes", function()
	local cases = { "", "!!!!!!", "7QK2M9X" }
	for _, code in ipairs(cases) do
		local parsed, err = Seed.parse(code)
		H.eq(parsed, nil, "should not parse: " .. code)
		H.ok(err ~= nil, "expected an error message for: " .. code)
	end
end)

H.test("format rejects out-of-range and fractional values", function()
	H.throws(function()
		Seed.format(-1)
	end, "negative")
	H.throws(function()
		Seed.format(Seed.MAX + 1)
	end, "too large")
	H.throws(function()
		Seed.format(1.5)
	end, "fractional")
end)

H.test("identity pairs the code with the generator version", function()
	H.eq(Seed.identity(42, 1), Seed.format(42) .. "-v1")
end)
