--!strict

local H = require("../harness")
local ChunkLayout = require("../../src/shared/procgen/grid/ChunkLayout")
local ChunkRenderer = require("../../src/shared/procgen/grid/ChunkRenderer")

local function empty(n: number, cell: number): any
	local layout = ChunkLayout.new(0, 0, n, cell)
	for j = 1, n do
		for i = 1, n do
			layout.height[ChunkLayout.index(n, i, j)] = 12
		end
	end
	return layout
end

H.test("layout indexing is row-major", function()
	local layout = empty(4, 16)
	H.eq(ChunkLayout.index(4, 1, 1), 1)
	H.eq(ChunkLayout.index(4, 4, 1), 4)
	H.eq(ChunkLayout.index(4, 1, 2), 5)
	H.eq(ChunkLayout.get(layout, 1, 1), false, "new cells are open")
end)

H.test("a chunk is one floor and one ceiling per height band", function()
	local layout = empty(6, 16)
	layout.height[ChunkLayout.index(6, 1, 1)] = 14
	layout.height[ChunkLayout.index(6, 2, 1)] = 10
	local parts = ChunkRenderer.describe(layout, { style = { budget = 100 } })
	local floors, ceilings = 0, 0
	for _, part in ipairs(parts) do
		if part.kind == "floor" then
			floors += 1
		elseif part.kind == "ceiling" then
			ceilings += 1
		end
	end
	H.eq(floors, 1, "one floor slab per chunk")
	H.eq(ceilings, 3, "one ceiling per distinct height (10, 12, 14)")
end)

H.test("a run of sealed faces becomes one wall part", function()
	local layout = empty(8, 16)
	for j = 2, 6 do
		layout.sealedE[ChunkLayout.index(8, 3, j)] = true
	end
	local parts = ChunkRenderer.describe(layout, { style = { budget = 100 } })
	local walls = {}
	for _, part in ipairs(parts) do
		if part.kind == "wall" then
			table.insert(walls, part)
		end
	end
	H.eq(#walls, 1, "one merged run")
	H.eq(walls[1].size[3], 5 * 16, "run length in studs")
	H.eq(walls[1].size[1], 1, "wall thickness")
end)

H.test("a height change splits a wall run", function()
	local layout = empty(8, 16)
	for j = 2, 6 do
		layout.sealedE[ChunkLayout.index(8, 3, j)] = true
	end
	layout.height[ChunkLayout.index(8, 3, 4)] = 16
	local parts = ChunkRenderer.describe(layout, { style = { budget = 200 } })
	local walls = 0
	for _, part in ipairs(parts) do
		if part.kind == "wall" then
			walls += 1
		end
	end
	H.eq(walls, 3, "merged only where the height agrees")
end)

H.test("solid mass merges along a row", function()
	local layout = empty(8, 16)
	for i = 2, 5 do
		layout.solid[ChunkLayout.index(8, i, 3)] = true
	end
	local parts = ChunkRenderer.describe(layout, { style = { budget = 100 } })
	local blocks = 0
	for _, part in ipairs(parts) do
		if part.kind == "wall" and part.size[3] == 16 then
			blocks += 1
		end
	end
	H.eq(blocks, 1, "one block for four cells")
end)

H.test("the budget is enforced", function()
	local layout = empty(18, 16)
	H.ok(pcall(function()
		return ChunkRenderer.describe(layout, { style = { budget = 0 } })
	end) == false, "over budget must fail")
end)

H.test("a 18x18 chunk stays inside the part budget", function()
	-- The whole point of merging: a dense chunk is still tens of parts, not
	-- hundreds.
	local layout = empty(18, 16)
	for j = 1, 18 do
		for i = 1, 18 do
			if i % 3 == 0 then
				layout.sealedE[ChunkLayout.index(18, i, j)] = true
			end
			if j % 4 == 0 then
				layout.sealedS[ChunkLayout.index(18, i, j)] = true
			end
		end
	end
	local parts = ChunkRenderer.describe(layout, { style = { budget = 400 } })
	H.ok(#parts <= 200, "dense chunk parts: " .. #parts)
end)
