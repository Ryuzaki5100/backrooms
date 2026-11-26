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

H.test("a chunk is one floor and merged ceilings per height level", function()
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
	-- Ceilings merge per level: the 12-stud cells form an L around the 10 and 14
	-- cells, so that level takes two rectangles (task 0003).
	H.eq(ceilings, 4, "one merged ceiling per height run (14, 10, and 12 in two)")
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
		-- Only the run's own plane; other planes may carry soffits.
		if part.kind == "wall" and part.position[1] == 3 * 16 and part.size[1] == 1 then
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

H.test("an open height step gets a soffit, a sealed one does not", function()
	local layout = empty(6, 16)
	for j = 1, 6 do
		for i = 1, 6 do
			layout.height[ChunkLayout.index(6, i, j)] = 10
		end
	end
	layout.height[ChunkLayout.index(6, 3, 3)] = 14

	-- Open face between (2,3) and (3,3): the 4-stud band must be closed.
	local openParts = ChunkRenderer.describe(layout, { style = { budget = 200 } })
	local soffit = nil
	for _, part in ipairs(openParts) do
		if part.kind == "wall" and part.position[1] == 2 * 16 and part.size[2] == 4 then
			soffit = part
		end
	end
	H.ok(soffit ~= nil, "soffit closes the open height step")
	H.eq(soffit.size[1], 1, "soffit is a wall slice")
	H.eq(soffit.size[3], 16, "soffit spans one cell")

	-- Seal the same face: the wall now spans the taller cell, no band is open.
	layout.sealedE[ChunkLayout.index(6, 2, 3)] = true
	local sealedParts = ChunkRenderer.describe(layout, { style = { budget = 200 } })
	for _, part in ipairs(sealedParts) do
		H.ok(
			not (part.kind == "wall" and part.position[1] == 2 * 16 and part.size[2] == 4),
			"a sealed face carries a full wall, not a soffit"
		)
	end
end)

H.test("perimeter walls close only the world edge", function()
	local layout = empty(6, 16)
	local plain = ChunkRenderer.describe(layout, { style = { budget = 200 } })

	layout.cx, layout.cz = 0, 0
	local corner = ChunkRenderer.describe(layout, {
		style = { budget = 200 },
		enclosure = "perimeter",
		worldChunks = 3,
	})
	H.eq(#corner - #plain, 2, "corner chunk closes west and north")

	layout.cx, layout.cz = 1, 1
	local interior = ChunkRenderer.describe(layout, {
		style = { budget = 200 },
		enclosure = "perimeter",
		worldChunks = 3,
	})
	H.eq(#interior, #plain, "interior chunk adds nothing")

	layout.cx, layout.cz = 2, 0
	local edge = ChunkRenderer.describe(layout, {
		style = { budget = 200 },
		enclosure = "perimeter",
		worldChunks = 3,
	})
	H.eq(#edge - #plain, 2, "east edge and north edge")

	-- The enclosure spans the chunk's mass, base to top, not just the ceiling.
	local lowest, highest = math.huge, -math.huge
	for _, part in ipairs(edge) do
		if part.kind == "floor" then
			lowest = math.min(lowest, part.position[2] - part.size[2] / 2)
		elseif part.kind == "ceiling" then
			highest = math.max(highest, part.position[2] + part.size[2] / 2)
		end
	end
	local spans = 0
	for _, part in ipairs(edge) do
		if
			part.kind == "wall"
			and (part.size[1] == 1 or part.size[3] == 1)
			and part.size[2] > 12
		then
			spans += 1
			H.eq(part.position[2] - part.size[2] / 2, lowest, "perimeter reaches the base")
			H.eq(part.position[2] + part.size[2] / 2, highest, "perimeter reaches the top")
		end
	end
	H.eq(spans, 2, "both perimeter walls are full height")
end)

H.test("a ramp is a wedge and replaces the floor under it", function()
	local layout = empty(6, 16)
	layout.floorY[ChunkLayout.index(6, 3, 3)] = 4
	layout.ramp[ChunkLayout.index(6, 3, 3)] = { axis = "x", dir = -1, lowY = 0, highY = 4 }
	local parts = ChunkRenderer.describe(layout, { style = { budget = 300 } })

	local ramp = nil
	for _, part in ipairs(parts) do
		if part.kind == "ramp" then
			ramp = part
		end
	end
	H.ok(ramp ~= nil, "has a ramp part")
	H.eq(ramp.wedge, true, "a true wedge, not a box")
	H.eq(ramp.size[2], 4, "rises exactly to the upper floor")
	H.eq(ramp.position[2], 2, "centred between the planes")

	-- Floor mass under the wedge stops at its low edge; the wedge fills the rest.
	local cx, cz = 2.5 * 16, 2.5 * 16
	local under = 0
	for _, part in ipairs(parts) do
		if part.kind == "floor" then
			local halfX, halfZ = part.size[1] / 2, part.size[3] / 2
			local inside = math.abs(part.position[1] - cx) < halfX
				and math.abs(part.position[3] - cz) < halfZ
			if inside then
				under += 1
				H.ok(
					part.position[2] + part.size[2] / 2 <= 0 + 1e-9,
					"floor mass under the ramp stops at the wedge's low edge"
				)
			end
		end
	end
	H.ok(under > 0, "there is floor mass under the ramp, not a hole down to the sky")
end)

-- Yaw is in degrees (`Build.apply` applies math.rad(yaw) as is), and a wedge at
-- yaw 0 rises towards +Z, so the mapping from `dir` (which points at the HIGH
-- end) is fixed. Build.apply only needs the degree convention, which cannot be
-- loaded under Lune (it requires Roblox services), so it is pinned here.
H.test("ramp yaw is in degrees and follows the documented mapping", function()
	local cases = {
		{ axis = "z", dir = 1, yaw = 0 },
		{ axis = "z", dir = -1, yaw = 180 },
		{ axis = "x", dir = 1, yaw = 90 },
		{ axis = "x", dir = -1, yaw = -90 },
	}
	for _, case in ipairs(cases) do
		local layout = empty(6, 16)
		layout.floorY[ChunkLayout.index(6, 3, 3)] = 4
		layout.ramp[ChunkLayout.index(6, 3, 3)] =
			{ axis = case.axis, dir = case.dir, lowY = 0, highY = 4 }
		local yaw = nil
		for _, part in ipairs(ChunkRenderer.describe(layout, { style = { budget = 300 } })) do
			if part.kind == "ramp" then
				yaw = part.yaw
			end
		end
		H.eq(yaw, case.yaw, "axis " .. case.axis .. " dir " .. case.dir)
		-- Rotating +Z by yaw lands on the high end (dir along the axis).
		local radians = math.rad(case.yaw)
		local highX = math.floor(math.sin(radians) + 0.5)
		local highZ = math.floor(math.cos(radians) + 0.5)
		H.eq(highX, if case.axis == "x" then case.dir else 0, "high end x, " .. case.axis)
		H.eq(highZ, if case.axis == "z" then case.dir else 0, "high end z, " .. case.axis)
	end
end)

H.test("floors and ceilings are mass from the chunk base to the chunk top", function()
	local layout = empty(6, 16)
	layout.floorY[ChunkLayout.index(6, 2, 2)] = -4
	layout.height[ChunkLayout.index(6, 5, 5)] = 16
	local parts = ChunkRenderer.describe(layout, { style = { budget = 300 } })
	local lowest, highest = math.huge, -math.huge
	for _, part in ipairs(parts) do
		if part.kind == "floor" then
			lowest = math.min(lowest, part.position[2] - part.size[2] / 2)
		elseif part.kind == "ceiling" then
			highest = math.max(highest, part.position[2] + part.size[2] / 2)
		end
	end
	H.eq(lowest, -14, "base is the lowest floor (-4) minus the 10-stud margin")
	H.eq(highest, 18, "top is the highest ceiling (16) plus the 2-stud margin")
	for _, part in ipairs(parts) do
		if part.kind == "floor" then
			H.eq(part.position[2] - part.size[2] / 2, -14, "every floor reaches the base")
		elseif part.kind == "ceiling" then
			H.eq(part.position[2] + part.size[2] / 2, 18, "every ceiling reaches the top")
		end
	end
end)

H.test("a one-stud rise gets a step, not a ramp", function()
	local layout = empty(6, 16)
	layout.floorY[ChunkLayout.index(6, 4, 3)] = 1
	local parts = ChunkRenderer.describe(layout, { style = { budget = 300 } })
	local steps, ramps = 0, 0
	for _, part in ipairs(parts) do
		if part.kind == "step" then
			steps += 1
			H.eq(part.size[2], 1, "step matches the rise")
		elseif part.kind == "ramp" then
			ramps += 1
		end
	end
	-- A one-cell plateau has four edges, so four steps.
	H.eq(steps, 4, "one step per edge of the raised cell")
	H.eq(ramps, 0, "no ramp for a step")
end)

H.test("a ceiling part only covers cells at its own level", function()
	local n, cell = 6, 16
	local layout = empty(n, cell)
	-- A tall block in one corner, a low strip along one edge, a raised cell, and
	-- a template cell that no ceiling may cover.
	for j = 1, 3 do
		for i = 1, 3 do
			layout.height[ChunkLayout.index(n, i, j)] = 20
		end
	end
	for i = 4, n do
		layout.height[ChunkLayout.index(n, i, n)] = 8
	end
	layout.floorY[ChunkLayout.index(n, 5, 2)] = 2
	layout.templateCell[ChunkLayout.index(n, 6, 2)] = true

	local parts = ChunkRenderer.describe(layout, { style = { budget = 400 } })
	local seen: { [number]: boolean } = {}
	local ceilings, covered = 0, 0
	for _, part in ipairs(parts) do
		if part.kind == "ceiling" then
			ceilings += 1
			local bottom = part.position[2] - part.size[2] / 2
			local i0 = math.floor((part.position[1] - part.size[1] / 2) / cell + 0.5) + 1
			local i1 = i0 + math.floor(part.size[1] / cell + 0.5) - 1
			local j0 = math.floor((part.position[3] - part.size[3] / 2) / cell + 0.5) + 1
			local j1 = j0 + math.floor(part.size[3] / cell + 0.5) - 1
			for j = j0, j1 do
				for i = i0, i1 do
					local index = ChunkLayout.index(n, i, j)
					H.eq(
						layout.templateCell[index] == true,
						false,
						"no ceiling over a template cell"
					)
					H.eq(
						(layout.floorY[index] or 0) + layout.height[index],
						bottom,
						"cell " .. i .. "," .. j .. " sits at the ceiling's level"
					)
					H.eq(seen[index] == true, false, "each cell is under one ceiling")
					seen[index] = true
					covered += 1
				end
			end
		end
	end
	H.eq(covered, n * n - 1, "every cell but the template cell has a ceiling")
	H.ok(ceilings > 3, "one rectangle per level run, not one slab per band: " .. ceilings)
end)
