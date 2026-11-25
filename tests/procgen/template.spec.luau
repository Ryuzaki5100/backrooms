--!strict

local H = require("../harness")
local OpenAdditive = require("../../src/shared/procgen/strategies/OpenAdditive")
local ChunkLayout = require("../../src/shared/procgen/grid/ChunkLayout")
local ChunkRenderer = require("../../src/shared/procgen/grid/ChunkRenderer")
local Template = require("../../src/shared/procgen/features/Template")
local Level0 = require("../../src/config/levels/Level_0")

local function clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in pairs(value) do
		copy[key] = clone(item)
	end
	return copy
end

-- Level 0 shipped config, with the template list under test injected.
local function demo(seed: number, templates: any): any
	local config = clone(Level0)
	config.world = clone(Level0.world)
	config.world.worldSizeChunks = 3
	config.world.boundaryMode = "wrap"
	config.templates = templates
	return OpenAdditive.world(config, seed)
end

-- A flat, open, empty chunk: every cell is walkable floor at one level.
local function openLayout(n: number, cell: number): any
	local layout = ChunkLayout.new(0, 0, n, cell)
	for index = 1, n * n do
		layout.height[index] = 12
	end
	return layout
end

local function worldFor(config: { templates: any }, seed: number): any
	return { seed = seed, config = config }
end

local function placement(layout: any): string
	local parts = {}
	for _, template in ipairs(layout.templates) do
		table.insert(parts, template.ref .. ":" .. template.cellX .. ":" .. template.cellZ)
	end
	return table.concat(parts, ",")
end

-- Chebyshev gap in cells, the same measure the feature uses.
local function gap(a: any, b: any): number
	local gapX = math.max(b.cellX - (a.cellX + a.w), a.cellX - (b.cellX + b.w))
	local gapZ = math.max(b.cellZ - (a.cellZ + a.d), a.cellZ - (b.cellZ + b.d))
	return math.max(0, math.max(gapX, gapZ))
end

H.test("template placement is deterministic per seed", function()
	local spec = { { ref = "manila", footprint = { w = 3, d = 3 }, count = 1, spacing = 6 } }
	local a = OpenAdditive.layout(demo(42, spec), 1, 1)
	local b = OpenAdditive.layout(demo(42, spec), 1, 1)
	H.eq(placement(a), placement(b), "same seed, same placement")

	-- Chunk order cannot matter: the pass reads only the seed and this chunk.
	local alone = OpenAdditive.layout(demo(42, spec), 2, 1)
	local make = demo(42, spec)
	OpenAdditive.layout(make, 0, 0)
	OpenAdditive.layout(make, 1, 0)
	local after = OpenAdditive.layout(make, 2, 1)
	H.eq(placement(alone), placement(after), "chunk order independence")

	local other = OpenAdditive.layout(demo(1337, spec), 1, 1)
	H.neq(placement(other), placement(a), "a different seed can move the patch")
end)

H.test("every footprint is in bounds, open, flat and reserved", function()
	local spec = {
		{ ref = "manila", footprint = { w = 3, d = 3 }, count = 2, spacing = 1 },
	}
	local make = demo(42, spec)
	for cz = 0, 2 do
		for cx = 0, 2 do
			local layout = OpenAdditive.layout(make, cx, cz)
			local n = layout.n
			local reserved = 0
			for _, template in ipairs(layout.templates) do
				H.ok(template.w == 3 and template.d == 3, "footprint is the authored one")
				H.ok(template.cellX >= 1 and template.cellZ >= 1, "top-left inside the chunk")
				H.ok(template.cellX + template.w - 1 <= n, "east edge inside the chunk")
				H.ok(template.cellZ + template.d - 1 <= n, "south edge inside the chunk")
				local level = nil
				for jj = template.cellZ, template.cellZ + template.d - 1 do
					for ii = template.cellX, template.cellX + template.w - 1 do
						local index = ChunkLayout.index(n, ii, jj)
						H.eq(layout.solid[index], false, "footprint cell is not solid")
						H.eq(layout.templateCell[index], true, "footprint cell is reserved")
						H.eq(layout.ramp[index], nil, "no ramp under a template")
						H.eq(layout.column[index], false, "no pillar inside a template")
						local floor = layout.floorY[index]
						if level == nil then
							level = floor
						else
							H.eq(floor, level, "footprint floor is flat")
						end
						if ii < template.cellX + template.w - 1 then
							H.eq(layout.sealedE[index], false, "no wall inside the footprint")
						end
						if jj < template.cellZ + template.d - 1 then
							H.eq(layout.sealedS[index], false, "no wall inside the footprint")
						end
						reserved += 1
					end
				end
			end
			-- Reserved cells are marked once, so a footprint can never overlap.
			local marked = 0
			for index = 1, n * n do
				if layout.templateCell[index] then
					marked += 1
				end
			end
			H.eq(marked, reserved, "no two footprints share a cell")
			for first = 1, #layout.templates do
				for second = first + 1, #layout.templates do
					H.ok(
						gap(layout.templates[first], layout.templates[second]) > 0,
						"footprints do not touch"
					)
				end
			end
		end
	end
end)

H.test("count and spacing are respected", function()
	local layout = openLayout(14, 16)
	local spec = { { ref = "manila", footprint = { w = 3, d = 3 }, count = 3, spacing = 2 } }
	Template.apply(worldFor({ templates = spec }, 42), layout)
	H.eq(#layout.templates, 3, "count placed on open ground")
	for first = 1, #layout.templates do
		for second = first + 1, #layout.templates do
			H.ok(
				gap(layout.templates[first], layout.templates[second]) >= 2,
				"spacing respected between templates"
			)
		end
	end
end)

H.test("a crowded chunk places fewer than count instead of overlapping", function()
	local layout = openLayout(6, 16)
	local spec = { { ref = "manila", footprint = { w = 5, d = 5 }, count = 3, spacing = 1 } }
	Template.apply(worldFor({ templates = spec }, 42), layout)
	H.eq(#layout.templates, 1, "only one 5x5 footprint fits a 6x6 chunk")
end)

H.test("solid cells are never covered", function()
	local spec = { { ref = "manila", footprint = { w = 3, d = 3 }, count = 1, spacing = 0 } }
	for seed = 1, 24 do
		local layout = openLayout(8, 16)
		for j = 1, 3 do
			for i = 1, 3 do
				layout.solid[ChunkLayout.index(8, i + 2, j + 2)] = true
			end
		end
		Template.apply(worldFor({ templates = spec }, seed), layout)
		for _, template in ipairs(layout.templates) do
			local overlaps = template.cellX <= 4
				and template.cellX + template.w - 1 >= 3
				and template.cellZ <= 4
				and template.cellZ + template.d - 1 >= 3
			H.eq(overlaps, false, "seed " .. seed .. " avoids the solid block")
		end
	end
end)

H.test("placement follows a hashed start, not a corner-first scan", function()
	local positions: { [string]: boolean } = {}
	local distinct = 0
	local awayFromCorner = 0
	local spec = { { ref = "manila", footprint = { w = 3, d = 3 }, count = 1, spacing = 0 } }
	for seed = 1, 48 do
		local layout = openLayout(12, 16)
		Template.apply(worldFor({ templates = spec }, seed), layout)
		local template = layout.templates[1]
		H.ok(template ~= nil, "seed " .. seed .. " has open ground to place on")
		local key = template.cellX .. ":" .. template.cellZ
		if not positions[key] then
			positions[key] = true
			distinct += 1
		end
		if template.cellX > 3 or template.cellZ > 3 then
			awayFromCorner += 1
		end
	end
	H.ok(distinct >= 8, "start offsets are spread over the chunk: " .. distinct)
	H.ok(awayFromCorner >= 24, "most seeds do not place in the corner: " .. awayFromCorner)
end)

H.test("templates are a debug marker in production nothing is emitted", function()
	local spec = { { ref = "manila", footprint = { w = 3, d = 3 }, count = 1, spacing = 6 } }
	local make = demo(42, spec)
	local decorated = nil
	for cz = 0, 2 do
		for cx = 0, 2 do
			local layout = OpenAdditive.layout(make, cx, cz)
			if #layout.templates > 0 and decorated == nil then
				decorated = layout
			end
		end
	end
	H.ok(decorated ~= nil, "level 0 places the manila template somewhere")

	local production = ChunkRenderer.describe(decorated, { style = { budget = 9000 } })
	for _, part in ipairs(production) do
		H.neq(part.kind, "template", "production emits no template part")
	end

	local markers = {}
	for _, part in
		ipairs(ChunkRenderer.describe(decorated, {
			style = { budget = 9000 },
			debug = true,
		}))
	do
		if part.kind == "template" then
			table.insert(markers, part)
		end
	end
	H.eq(#markers, #decorated.templates, "one marker per template")

	local template = decorated.templates[1]
	local marker = markers[1]
	H.eq(marker.owner, "template:" .. template.ref)
	H.eq(marker.size[1], template.w * decorated.cell)
	H.eq(marker.size[3], template.d * decorated.cell)
	H.eq(marker.canCollide, false)
	H.eq(
		marker.position[1],
		decorated.cx * decorated.n * decorated.cell + template.x,
		"marker sits at the footprint centre"
	)
	H.eq(
		marker.position[3],
		decorated.cz * decorated.n * decorated.cell + template.z,
		"marker sits at the footprint centre"
	)
end)
