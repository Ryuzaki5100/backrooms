--!strict

local H = require("../harness")
local Streaming = require("../../src/shared/procgen/runtime/Streaming")

local CHUNK = 288

local function streamer(overrides: any?): any
	local opts: any = { chunkStuds = CHUNK, radius = 2, unloadRadius = 3 }
	for key, value in pairs(overrides or {}) do
		opts[key] = value
	end
	return Streaming.new(opts)
end

-- A position at the centre of chunk (cx, cz).
local function centre(cx: number, cz: number): { x: number, z: number }
	return { x = (cx + 0.5) * CHUNK, z = (cz + 0.5) * CHUNK }
end

local function count(set: { [string]: boolean }): number
	local n = 0
	for _ in pairs(set) do
		n += 1
	end
	return n
end

H.test("keys round-trip, negative coordinates included", function()
	H.eq(Streaming.key(-3, 7), "-3:7")
	local cx, cz = Streaming.parse("-12:-4")
	H.eq(cx, -12)
	H.eq(cz, -4)
	H.throws(function()
		Streaming.parse("nope")
	end, "bad key")
end)

H.test("desired is the square of radius around the player's chunk", function()
	local s = streamer()
	local set = s:desired({ centre(0, 0) })
	H.eq(count(set), 25, "5 x 5")
	for cz = -2, 2 do
		for cx = -2, 2 do
			H.ok(set[Streaming.key(cx, cz)] == true, "has " .. Streaming.key(cx, cz))
		end
	end
	H.ok(set["3:0"] == nil, "radius is a hard edge")
	H.ok(set["0:-3"] == nil, "radius is a hard edge")
end)

H.test("desired uses the chunk the player stands in, at the edges", function()
	local s = streamer({ radius = 1 })
	-- x = 287.9 is still chunk 0; x = 288 is chunk 1; x = -0.1 is chunk -1.
	H.ok(s:desired({ { x = 287.9, z = 0 } })["0:0"] == true)
	H.ok(s:desired({ { x = 287.9, z = 0 } })["2:0"] == nil)
	H.ok(s:desired({ { x = 288, z = 0 } })["2:0"] == true)
	H.ok(s:desired({ { x = -0.1, z = 0 } })["-2:0"] == true)
	H.ok(s:desired({ { x = -0.1, z = 0 } })["2:0"] == nil)
end)

H.test("negative chunk coordinates stream like positive ones", function()
	local s = streamer({ radius = 1 })
	local set = s:desired({ centre(-5, -9) })
	H.eq(count(set), 9)
	H.ok(set["-6:-10"] == true)
	H.ok(set["-4:-8"] == true)
	local load = s:step(1, { centre(-5, -9) })
	H.eq(#load, 9)
	H.eq(load[1], "-5:-9", "own chunk first")
end)

H.test("loads come nearest-first, ties broken by key", function()
	local s = streamer({ radius = 1 })
	local load = s:step(1, { centre(0, 0) })
	H.eq(#load, 9)
	H.eq(load[1], "0:0", "own chunk first")
	-- The four edge neighbours are equidistant, the four corners equidistant.
	local edges = { "-1:0", "0:-1", "0:1", "1:0" }
	table.sort(edges)
	for index = 1, 4 do
		H.eq(load[1 + index], edges[index], "edge tie " .. index)
	end
	local corners = { "-1:-1", "-1:1", "1:-1", "1:1" }
	table.sort(corners)
	for index = 1, 4 do
		H.eq(load[5 + index], corners[index], "corner tie " .. index)
	end

	-- A player near the east edge of the chunk gets the east side first.
	local t = streamer({ radius = 1 })
	local first = t:step(1, { { x = CHUNK - 1, z = CHUNK / 2 } })
	H.eq(first[1], "0:0")
	H.eq(first[2], "1:0", "the east neighbour is nearer than the west one")
end)

H.test("the order is deterministic across runs", function()
	local a = streamer():step(1, { centre(2, 3), centre(-4, 1) })
	local b = streamer():step(1, { centre(2, 3), centre(-4, 1) })
	H.eq(table.concat(a, ","), table.concat(b, ","))
end)

H.test("step does not repeat a chunk it already returned", function()
	local s = streamer({ radius = 1 })
	local first = s:step(1, { centre(0, 0) })
	H.eq(#first, 9)
	local again = s:step(1, { centre(0, 0) })
	H.eq(#again, 0)
	H.eq(s:loadedCount(), 9)
end)

H.test("maxPerFrame caps each step", function()
	local s = streamer({ maxPerFrame = 2 })
	local seen: { [string]: boolean } = {}
	local frames = 0
	while s:loadedCount() < 25 do
		local load = s:step(1, { centre(0, 0) })
		H.ok(#load <= 2, "at most 2 per frame")
		for _, key in ipairs(load) do
			H.ok(not seen[key], "never loaded twice")
			seen[key] = true
		end
		frames += 1
		H.ok(frames < 100, "must converge")
	end
	H.eq(frames, 13, "25 chunks at 2 per frame")
end)

H.test("maxPerSecond is a token bucket over simulated time", function()
	local s = streamer({ radius = 8, maxPerFrame = 4, maxPerSecond = 8 })
	local dt = 1 / 60
	local total = 0
	local perSecond: { number } = {}
	for frame = 1, 60 * 5 do
		local load = s:step(dt, { centre(0, 0) })
		total += #load
		local second = (frame - 1) // 60 + 1
		perSecond[second] = (perSecond[second] or 0) + #load
	end
	-- The bucket starts full (8), then refills at 8 per second: 8 + 5 * 8 at most.
	H.ok(total <= 8 + 5 * 8, "burst plus rate bound, got " .. total)
	H.ok(total >= 5 * 8, "and it keeps up with the rate, got " .. total)
	-- After the opening burst, each second stays within the rate.
	for second = 2, 5 do
		H.ok(perSecond[second] <= 9, "second " .. second .. " loaded " .. perSecond[second])
	end
end)

H.test("an empty bucket loads nothing until it refills", function()
	local s = streamer({ radius = 8, maxPerFrame = 100, maxPerSecond = 4 })
	H.eq(#s:step(0, { centre(0, 0) }), 4, "opening burst")
	H.eq(#s:step(0.1, { centre(0, 0) }), 0, "0.4 tokens is not a chunk")
	H.eq(#s:step(0.15, { centre(0, 0) }), 1, "1.0 tokens is one")
end)

H.test("hysteresis: unload only beyond unloadRadius", function()
	local s = streamer({ radius = 1, unloadRadius = 3 })
	s:step(1, { centre(0, 0) })
	H.ok(s:isLoaded("-1:0"))
	-- Move 3 chunks east. Chunk -1:0 is now 4 away (> 3): unloaded. Chunk 0:0 is 3
	-- away (between radius and unloadRadius): kept.
	local _, unload = s:step(1, { centre(3, 0) })
	H.ok(s:isLoaded("0:0"), "0:0 is inside the hysteresis band")
	H.ok(not s:isLoaded("-1:0"), "-1:0 is beyond unloadRadius")
	H.eq(table.concat(unload, ","), "-1:-1,-1:0,-1:1", "only the far column goes")
	-- One more chunk east pushes 0:0 out as well.
	local _, more = s:step(1, { centre(4, 0) })
	H.ok(not s:isLoaded("0:0"))
	H.ok(table.find(more, "0:0") ~= nil)
	H.ok(s:isLoaded("1:0"), "1:0 is 3 away, still inside the band")
end)

H.test("a chunk is never unloaded while any player is within unloadRadius", function()
	local s = streamer({ radius = 1, unloadRadius = 2 })
	s:step(1, { centre(0, 0) })
	local _, unload = s:step(1, { centre(10, 0), centre(1, 1) })
	H.ok(s:isLoaded("0:0"), "player two still near")
	H.ok(table.find(unload, "0:0") == nil)
end)

H.test("unloadRadius is never below radius", function()
	local s = streamer({ radius = 2, unloadRadius = 0 })
	H.eq(s.unloadRadius, 2)
	s:step(1, { centre(0, 0) })
	local _, unload = s:step(1, { centre(0, 0) })
	H.eq(#unload, 0, "a stationary player loses nothing")
end)

H.test("maxLoadedPerPlayer keeps the nearest chunks", function()
	local s = streamer({ radius = 2, maxLoadedPerPlayer = 9 })
	local set = s:desired({ centre(0, 0) })
	H.eq(count(set), 9)
	H.ok(set["0:0"] == true)
	-- The 3 x 3 block is nearer than the outer ring of the 5 x 5.
	for cz = -1, 1 do
		for cx = -1, 1 do
			H.ok(set[Streaming.key(cx, cz)] == true, "has " .. Streaming.key(cx, cz))
		end
	end
	H.ok(set["2:2"] == nil)
	local load = s:step(1, { centre(0, 0) })
	H.eq(#load, 9)
end)

H.test("two players: desired is the union, the cap applies per player", function()
	local s = streamer({ radius = 1, maxLoadedPerPlayer = 4 })
	local set = s:desired({ centre(0, 0), centre(20, 20) })
	H.eq(count(set), 8, "4 each, far apart")
	local overlap = s:desired({ centre(0, 0), centre(1, 0) })
	-- Each keeps its own 4 nearest; "0:0" and "1:0" are shared.
	H.ok(count(overlap) < 8, "overlapping players share chunks")
	H.ok(overlap["0:0"] == true and overlap["1:0"] == true)
end)

H.test("two players: loads interleave by nearest-to-any-player", function()
	local s = streamer({ radius = 1 })
	local load = s:step(1, { centre(0, 0), centre(10, 10) })
	H.eq(#load, 18)
	-- Both own chunks are at distance zero: they come before every neighbour.
	local head = { load[1], load[2] }
	table.sort(head)
	H.eq(head[1], "0:0")
	H.eq(head[2], "10:10")
end)

H.test("no players: nothing loads and nothing unloads", function()
	local s = streamer({ radius = 1 })
	s:step(1, { centre(0, 0) })
	local load, unload = s:step(1, {})
	H.eq(#load, 0)
	H.eq(#unload, 0)
	H.eq(s:loadedCount(), 9)
end)

H.test("markLoaded records a chunk built outside step", function()
	local s = streamer({ radius = 1 })
	s:markLoaded("0:0")
	s:markLoaded("0:0")
	H.eq(s:loadedCount(), 1)
	local load = s:step(1, { centre(0, 0) })
	H.eq(#load, 8, "0:0 is not offered again")
	H.ok(table.find(load, "0:0") == nil)
end)

H.test("an invalid chunk size is rejected", function()
	H.throws(function()
		Streaming.new({ chunkStuds = 0 })
	end, "chunkStuds 0")
end)
