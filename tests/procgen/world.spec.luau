--!strict

local H = require("../harness")
local World = require("../../src/shared/procgen/World")

local function level(world: any): any
	return {
		id = "test",
		strategy = { name = "open_additive", params = { cell = 16, chunkCells = 18 } },
		world = world,
	}
end

H.test("size tiers derive a finite world from a lap time", function()
	local tiny = World.resolve(level({ sizeTier = "tiny" }))
	H.eq(tiny.chunkSize, 288, "16 x 18")
	H.eq(tiny.chunks, 4, "60 s at 16 studs/s = 960 studs = 4 chunks")

	local vast = World.resolve(level({ sizeTier = "vast" }))
	H.eq(vast.chunks, 400, "2 h at 16 studs/s = 115200 studs = 400 chunks")
	H.eq(vast.studs, 115200)
end)

H.test("worldSizeChunks overrides the tier", function()
	local resolved = World.resolve(level({ sizeTier = "vast", worldSizeChunks = 3 }))
	H.eq(resolved.chunks, 3)
	H.eq(resolved.studs, 864)
end)

H.test("endless needs an explicit size or infinite boundary", function()
	H.ok(not pcall(World.resolve, level({ sizeTier = "endless" })), "must refuse")
end)

H.test("wrap is positive for negative coordinates", function()
	H.eq(World.wrap(-1, 10), 9)
	H.eq(World.wrap(-10, 10), 0)
	H.eq(World.wrap(12, 10), 2)
end)

H.test("distance is toroidal, not subtraction", function()
	-- 0 and 863 are neighbours on an 864-stud world.
	H.eq(World.distance(0, 0, 863, 0, 864), 1)
	H.eq(World.distance(10, 10, 20, 10, 864), 10)
	-- Half a world away is the maximum.
	H.eq(World.distance(0, 0, 432, 0, 864), 432)
end)

H.test("crossing time is derived from the resolved world", function()
	local size = World.resolve(level({ sizeTier = "tiny", worldSizeChunks = 3 }))
	local lap, diagonal = World.crossing(size, 16)
	H.eq(lap, 864 / 16)
	H.ok(diagonal > lap, "diagonal is longer")
end)

H.test("required radius covers the visible distance", function()
	H.eq(World.requiredRadius(300, 288), 3)
	H.eq(World.requiredRadius(288, 288), 2)
	H.eq(World.loadedChunks(1), 9)
	H.eq(World.loadedChunks(2), 25)
end)
