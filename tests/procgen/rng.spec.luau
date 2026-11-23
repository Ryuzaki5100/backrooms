--!strict

local H = require("../harness")
local Hash = require("../../src/shared/procgen/Hash")
local Rng = require("../../src/shared/procgen/Rng")

local function draw(rng: any, count: number): string
	local parts = {}
	for i = 1, count do
		parts[i] = string.format("%.0f", rng:nextU32())
	end
	return table.concat(parts, ",")
end

H.test("same seed produces the same sequence", function()
	H.eq(draw(Rng.new(42), 1000), draw(Rng.new(42), 1000))
end)

H.test("different seeds produce different sequences", function()
	H.neq(draw(Rng.new(42), 100), draw(Rng.new(43), 100))
end)

H.test("forks are stable for the same label and seed", function()
	H.eq(draw(Rng.new(7):fork("layout"), 200), draw(Rng.new(7):fork("layout"), 200))
end)

H.test("forks differ between labels", function()
	H.neq(draw(Rng.new(7):fork("layout"), 200), draw(Rng.new(7):fork("props"), 200))
end)

H.test("forking does not advance the parent", function()
	local a = Rng.new(7)
	a:fork("layout")
	H.eq(draw(a, 50), draw(Rng.new(7), 50))
end)

H.test("nextInt stays in range and covers it", function()
	local rng = Rng.new(99)
	local seen = {}
	for _ = 1, 10000 do
		local value = rng:nextInt(6)
		H.ok(value >= 1 and value <= 6, "range")
		seen[value] = true
	end
	for face = 1, 6 do
		H.ok(seen[face] == true, "every face appears")
	end
end)

H.test("nextFloat stays within [0, 1)", function()
	local rng = Rng.new(5)
	for _ = 1, 5000 do
		local value = rng:nextFloat()
		H.ok(value >= 0 and value < 1, "range")
	end
end)

H.test("nextBool honours its bounds", function()
	local rng = Rng.new(11)
	for _ = 1, 100 do
		H.eq(rng:nextBool(0), false, "p=0")
		H.eq(rng:nextBool(1), true, "p=1")
	end
end)

H.test("golden vector for seed 42 (cross-runtime check)", function()
	-- These four values must also hold inside Roblox. If this test fails after a
	-- refactor, determinism broke; if it fails only in Studio, the runtime is the
	-- problem, not the algorithm.
	local rng = Rng.new(42)
	H.eq(rng:nextU32(), 1307303867)
	H.eq(rng:nextU32(), 2421854157)
	H.eq(rng:nextU32(), 2361216204)
	H.eq(rng:nextU32(), 738650163)
end)

H.test("10k seeds produce distinct short sequences", function()
	local seen = {}
	for seed = 0, 9999 do
		local fingerprint = Hash.of(draw(Rng.new(seed), 3))
		H.ok(seen[fingerprint] == nil, "collision at seed " .. tostring(seed))
		seen[fingerprint] = true
	end
end)
