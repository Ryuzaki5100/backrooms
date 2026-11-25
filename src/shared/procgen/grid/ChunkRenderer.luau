--!strict

-- Merged chunk renderer (ADR 0024, ADR 0029).
--
-- The render unit is not the cell. A chunk gets merged floor rectangles per
-- height band, one ceiling slab per band, merged wall runs, merged solid runs,
-- and wedges for ramps. That is what makes cell layouts affordable in Roblox.
--
-- Terrain: `floorY` varies per cell. Floors are greedy rectangle merged per
-- level (a full-chunk slab at a raised level would float over lower cells).
-- Ceilings stay one slab per band because each cell's own band hides the higher
-- bands above it.
--
-- Pure: emits the same part specs `Geometry` emits, plus `wedge = true` for
-- ramps, so `Build.apply` needs one new instance type.

local LayoutModule = if script ~= nil
	then require(script.Parent.ChunkLayout)
	else require("./ChunkLayout")

local ChunkRenderer = {}

local FLOOR_THICKNESS = 0.5
local CEILING_THICKNESS = 0.5
local STEP_DEPTH = 4

type Part = {
	kind: string,
	owner: string,
	size: { number },
	position: { number },
	yaw: number,
	pitch: number,
	material: string,
	color: { number },
	canCollide: boolean,
	tag: string?,
	wedge: boolean?,
}

local DEFAULTS = {
	wallThickness = 1,
	budget = 1200,
	materials = {
		wall = { material = "Concrete", color = { 0.52, 0.5, 0.44 } },
		floor = { material = "Fabric", color = { 0.33, 0.3, 0.24 } },
		ceiling = { material = "SmoothPlastic", color = { 0.78, 0.77, 0.7 } },
	},
}

local function budgetOf(value: any): number
	if type(value) == "number" then
		return value
	end
	if value ~= nil and value.parts ~= nil then
		return value.parts
	end
	return 1200
end

local function styleOf(style: any): any
	local s = style or {}
	local materials = s.materials or {}
	return {
		wallThickness = s.wallThickness or DEFAULTS.wallThickness,
		budget = budgetOf(s.budget),
		materials = {
			wall = materials.wall or DEFAULTS.materials.wall,
			floor = materials.floor or DEFAULTS.materials.floor,
			ceiling = materials.ceiling or DEFAULTS.materials.ceiling,
		},
	}
end

local function add(
	parts: { Part },
	kind: string,
	owner: string,
	size: { number },
	position: { number },
	material: any,
	extra: any?
): ()
	local part: Part = {
		kind = kind,
		owner = owner,
		size = size,
		position = position,
		yaw = 0,
		pitch = 0,
		material = material.material,
		color = material.color,
		canCollide = true,
	}
	if extra ~= nil then
		for key, value in pairs(extra) do
			part[key] = value
		end
	end
	table.insert(parts, part)
end

local function idx(layout: any, i: number, j: number): number
	return LayoutModule.index(layout.n, i, j)
end

local function floorAt(layout: any, i: number, j: number): number
	return layout.floorY[idx(layout, i, j)] or 0
end

local function ceilingAt(layout: any, i: number, j: number): number
	return (layout.floorY[idx(layout, i, j)] or 0) + layout.height[idx(layout, i, j)]
end

local function ownerOf(layout: any): string
	return "chunk:" .. layout.cx .. ":" .. layout.cz
end

-- Floors: greedy rectangle merge per height level, skipping ramp cells (the
-- wedge replaces the floor there).
local function floors(
	parts: { Part },
	layout: any,
	originX: number,
	originZ: number,
	style: any
): ()
	local n, cell = layout.n, layout.cell
	local taken: { [number]: boolean } = {}
	for j = 1, n do
		for i = 1, n do
			local startIndex = idx(layout, i, j)
			if taken[startIndex] or layout.ramp[startIndex] ~= nil then
				continue
			end
			local level = floorAt(layout, i, j)
			local iEnd = i
			while iEnd + 1 <= n do
				local nextIndex = idx(layout, iEnd + 1, j)
				if
					taken[nextIndex]
					or layout.ramp[nextIndex] ~= nil
					or floorAt(layout, iEnd + 1, j) ~= level
				then
					break
				end
				iEnd += 1
			end
			local jEnd = j
			local canGrow = true
			while canGrow and jEnd + 1 <= n do
				for k = i, iEnd do
					local nextIndex = idx(layout, k, jEnd + 1)
					if
						taken[nextIndex]
						or layout.ramp[nextIndex] ~= nil
						or floorAt(layout, k, jEnd + 1) ~= level
					then
						canGrow = false
						break
					end
				end
				if canGrow then
					jEnd += 1
				end
			end
			for jj = j, jEnd do
				for ii = i, iEnd do
					taken[idx(layout, ii, jj)] = true
				end
			end
			local width = (iEnd - i + 1) * cell
			local depth = (jEnd - j + 1) * cell
			add(parts, "floor", ownerOf(layout), { width, FLOOR_THICKNESS, depth }, {
				originX + (i - 1) * cell + width / 2,
				level - FLOOR_THICKNESS / 2,
				originZ + (j - 1) * cell + depth / 2,
			}, style.materials.floor)
		end
	end
end

local function ceilings(
	parts: { Part },
	layout: any,
	originX: number,
	originZ: number,
	style: any
): ()
	local span = layout.n * layout.cell
	local cx = originX + span / 2
	local cz = originZ + span / 2
	local seen: { [number]: boolean } = {}
	for j = 1, layout.n do
		for i = 1, layout.n do
			local level = ceilingAt(layout, i, j)
			if level > 0 and not seen[level] then
				seen[level] = true
				add(
					parts,
					"ceiling",
					ownerOf(layout),
					{ span, CEILING_THICKNESS, span },
					{ cx, level + CEILING_THICKNESS / 2, cz },
					style.materials.ceiling
				)
			end
		end
	end
end

local function solids(
	parts: { Part },
	layout: any,
	originX: number,
	originZ: number,
	style: any
): ()
	local n, cell = layout.n, layout.cell
	for j = 1, n do
		local i = 1
		while i <= n do
			local startIndex = idx(layout, i, j)
			if not layout.solid[startIndex] then
				i += 1
				continue
			end
			local level = floorAt(layout, i, j)
			local height = layout.height[startIndex]
			local start = i
			while i + 1 <= n do
				local nextIndex = idx(layout, i + 1, j)
				if
					not layout.solid[nextIndex]
					or layout.height[nextIndex] ~= height
					or floorAt(layout, i + 1, j) ~= level
				then
					break
				end
				i += 1
			end
			local finish = i
			local length = (finish - start + 1) * cell
			add(parts, "wall", ownerOf(layout), { length, height, cell }, {
				originX + (start - 1) * cell + length / 2,
				level + height / 2,
				originZ + (j - 0.5) * cell,
			}, style.materials.wall)
			i += 1
		end
	end
end

-- A wall spans from the lower floor to the higher ceiling, so a retaining edge
-- under a plateau is closed and a 1-stud step still has a back face.
local function wallSpanE(layout: any, i: number, j: number): (number, number)
	local floorA, ceilA = floorAt(layout, i, j), ceilingAt(layout, i, j)
	local floorB, ceilB
	if i == layout.n then
		floorB = layout.outFloorE[j] or 0
		ceilB = floorB + (layout.outHeightE[j] or 0)
	else
		floorB = floorAt(layout, i + 1, j)
		ceilB = ceilingAt(layout, i + 1, j)
	end
	return math.min(floorA, floorB), math.max(ceilA, ceilB)
end

local function wallSpanS(layout: any, i: number, j: number): (number, number)
	local floorA, ceilA = floorAt(layout, i, j), ceilingAt(layout, i, j)
	local floorB, ceilB
	if j == layout.n then
		floorB = layout.outFloorS[i] or 0
		ceilB = floorB + (layout.outHeightS[i] or 0)
	else
		floorB = floorAt(layout, i, j + 1)
		ceilB = ceilingAt(layout, i, j + 1)
	end
	return math.min(floorA, floorB), math.max(ceilA, ceilB)
end

local function walls(parts: { Part }, layout: any, originX: number, originZ: number, style: any): ()
	local n, cell, thickness = layout.n, layout.cell, style.wallThickness

	for i = 1, n do
		local j = 1
		while j <= n do
			local startIndex = idx(layout, i, j)
			if not layout.sealedE[startIndex] then
				j += 1
				continue
			end
			local bottom, top = wallSpanE(layout, i, j)
			local start = j
			while j + 1 <= n do
				local nextIndex = idx(layout, i, j + 1)
				if not layout.sealedE[nextIndex] then
					break
				end
				local nextBottom, nextTop = wallSpanE(layout, i, j + 1)
				if nextBottom ~= bottom or nextTop ~= top then
					break
				end
				j += 1
			end
			local finish = j
			local length = (finish - start + 1) * cell
			add(parts, "wall", ownerOf(layout), { thickness, top - bottom, length }, {
				originX + i * cell,
				bottom + (top - bottom) / 2,
				originZ + (start - 1) * cell + length / 2,
			}, style.materials.wall)
			j += 1
		end
	end

	for j = 1, n do
		local i = 1
		while i <= n do
			local startIndex = idx(layout, i, j)
			if not layout.sealedS[startIndex] then
				i += 1
				continue
			end
			local bottom, top = wallSpanS(layout, i, j)
			local start = i
			while i + 1 <= n do
				local nextIndex = idx(layout, i + 1, j)
				if not layout.sealedS[nextIndex] then
					break
				end
				local nextBottom, nextTop = wallSpanS(layout, i + 1, j)
				if nextBottom ~= bottom or nextTop ~= top then
					break
				end
				i += 1
			end
			local finish = i
			local length = (finish - start + 1) * cell
			add(parts, "wall", ownerOf(layout), { length, top - bottom, thickness }, {
				originX + (start - 1) * cell + length / 2,
				bottom + (top - bottom) / 2,
				originZ + j * cell,
			}, style.materials.wall)
			i += 1
		end
	end
end

-- Soffits close the band between two ceilings on an open face (ADR 0028).
local function soffits(
	parts: { Part },
	layout: any,
	originX: number,
	originZ: number,
	style: any
): ()
	local n, cell, thickness = layout.n, layout.cell, style.wallThickness

	local function ceilE(i: number, j: number): (number, number)
		local own = ceilingAt(layout, i, j)
		local other
		if i == n then
			local floorOut = layout.outFloorE[j] or 0
			other = floorOut + (layout.outHeightE[j] or 0)
		else
			other = ceilingAt(layout, i + 1, j)
		end
		return own, other
	end

	local function ceilS(i: number, j: number): (number, number)
		local own = ceilingAt(layout, i, j)
		local other
		if j == n then
			local floorOut = layout.outFloorS[i] or 0
			other = floorOut + (layout.outHeightS[i] or 0)
		else
			other = ceilingAt(layout, i, j + 1)
		end
		return own, other
	end

	for i = 1, n do
		local j = 1
		while j <= n do
			local own, other = ceilE(i, j)
			local index = idx(layout, i, j)
			if
				layout.sealedE[index]
				or layout.hangE[index]
				or own == other
				or own == 0
				or other == 0
			then
				j += 1
				continue
			end
			local low, high = math.min(own, other), math.max(own, other)
			local start = j
			while j + 1 <= n do
				local nextOwn, nextOther = ceilE(i, j + 1)
				local nextIndex = idx(layout, i, j + 1)
				if
					layout.sealedE[nextIndex]
					or nextOwn == nextOther
					or nextOwn == 0
					or nextOther == 0
					or math.min(nextOwn, nextOther) ~= low
					or math.max(nextOwn, nextOther) ~= high
				then
					break
				end
				j += 1
			end
			local finish = j
			local length = (finish - start + 1) * cell
			add(parts, "wall", ownerOf(layout), { thickness, high - low, length }, {
				originX + i * cell,
				low + (high - low) / 2,
				originZ + (start - 1) * cell + length / 2,
			}, style.materials.wall)
			j += 1
		end
	end

	for j = 1, n do
		local i = 1
		while i <= n do
			local own, other = ceilS(i, j)
			local index = idx(layout, i, j)
			if
				layout.sealedS[index]
				or layout.hangS[index]
				or own == other
				or own == 0
				or other == 0
			then
				i += 1
				continue
			end
			local low, high = math.min(own, other), math.max(own, other)
			local start = i
			while i + 1 <= n do
				local nextOwn, nextOther = ceilS(i + 1, j)
				local nextIndex = idx(layout, i + 1, j)
				if
					layout.sealedS[nextIndex]
					or nextOwn == nextOther
					or nextOwn == 0
					or nextOther == 0
					or math.min(nextOwn, nextOther) ~= low
					or math.max(nextOwn, nextOther) ~= high
				then
					break
				end
				i += 1
			end
			local finish = i
			local length = (finish - start + 1) * cell
			add(parts, "wall", ownerOf(layout), { length, high - low, thickness }, {
				originX + (start - 1) * cell + length / 2,
				low + (high - low) / 2,
				originZ + j * cell,
			}, style.materials.wall)
			i += 1
		end
	end
end

-- Ramps: a true prism (WedgePart). The high edge meets the upper floor plane,
-- the low edge the lower one, and the cell has no floor slab.
-- Thin columns on a lattice (a pillar-grid zone). A column is one small part,
-- not a solid cell.
local function columns(
	parts: { Part },
	layout: any,
	originX: number,
	originZ: number,
	style: any
): ()
	local n, cell = layout.n, layout.cell
	local col = layout.columnStuds or 2
	for j = 1, n do
		for i = 1, n do
			local index = idx(layout, i, j)
			if layout.column[index] then
				local level = floorAt(layout, i, j)
				local height = layout.height[index]
				add(parts, "column", ownerOf(layout), { col, height, col }, {
					originX + (i - 0.5) * cell,
					level + height / 2,
					originZ + (j - 0.5) * cell,
				}, style.materials.wall)
			end
		end
	end
end

-- Hanging walls: a wall from `clearance` to the ceiling, so you crouch under it.
local function hangWalls(
	parts: { Part },
	layout: any,
	originX: number,
	originZ: number,
	style: any
): ()
	local n, cell, thickness = layout.n, layout.cell, style.wallThickness
	local clearance = layout.hangClearance or 3

	for i = 1, n do
		local j = 1
		while j <= n do
			local startIndex = idx(layout, i, j)
			if not layout.hangE[startIndex] then
				j += 1
				continue
			end
			local bottom, top = wallSpanE(layout, i, j)
			local hangBottom = bottom + clearance
			local start = j
			while j + 1 <= n do
				local nextIndex = idx(layout, i, j + 1)
				if not layout.hangE[nextIndex] then
					break
				end
				local nextBottom, nextTop = wallSpanE(layout, i, j + 1)
				if nextBottom + clearance ~= hangBottom or nextTop ~= top then
					break
				end
				j += 1
			end
			local finish = j
			local length = (finish - start + 1) * cell
			add(parts, "wall", ownerOf(layout), { thickness, top - hangBottom, length }, {
				originX + i * cell,
				hangBottom + (top - hangBottom) / 2,
				originZ + (start - 1) * cell + length / 2,
			}, style.materials.wall)
			j += 1
		end
	end

	for j = 1, n do
		local i = 1
		while i <= n do
			local startIndex = idx(layout, i, j)
			if not layout.hangS[startIndex] then
				i += 1
				continue
			end
			local bottom, top = wallSpanS(layout, i, j)
			local hangBottom = bottom + clearance
			local start = i
			while i + 1 <= n do
				local nextIndex = idx(layout, i + 1, j)
				if not layout.hangS[nextIndex] then
					break
				end
				local nextBottom, nextTop = wallSpanS(layout, i + 1, j)
				if nextBottom + clearance ~= hangBottom or nextTop ~= top then
					break
				end
				i += 1
			end
			local finish = i
			local length = (finish - start + 1) * cell
			add(parts, "wall", ownerOf(layout), { length, top - hangBottom, thickness }, {
				originX + (start - 1) * cell + length / 2,
				hangBottom + (top - hangBottom) / 2,
				originZ + j * cell,
			}, style.materials.wall)
			i += 1
		end
	end
end

local function ramps(parts: { Part }, layout: any, originX: number, originZ: number, style: any): ()
	local cell = layout.cell
	for j = 1, layout.n do
		for i = 1, layout.n do
			local ramp = layout.ramp[idx(layout, i, j)]
			if ramp ~= nil then
				local low, high = ramp.lowY, ramp.highY
				local yaw = 0
				if ramp.axis == "x" then
					yaw = if ramp.dir > 0 then 90 else -90
				elseif ramp.dir < 0 then
					yaw = 180
				end
				add(parts, "ramp", ownerOf(layout), { cell, high - low, cell }, {
					originX + (i - 0.5) * cell,
					(high + low) / 2,
					originZ + (j - 0.5) * cell,
				}, style.materials.floor, { yaw = yaw, wedge = true })
			end
		end
	end
end

-- Steps: a 1-stud rise on an open face gets a tread on the low side. The floor
-- slabs already sit at their own levels, so the tread only has to fill the band.
local function steps(parts: { Part }, layout: any, originX: number, originZ: number, style: any): ()
	local n, cell = layout.n, layout.cell
	for i = 1, n do
		for j = 1, n do
			if i < n and not layout.sealedE[idx(layout, i, j)] then
				local low = math.min(floorAt(layout, i, j), floorAt(layout, i + 1, j))
				local high = math.max(floorAt(layout, i, j), floorAt(layout, i + 1, j))
				if high - low == 1 then
					local lowSide = if floorAt(layout, i, j) < floorAt(layout, i + 1, j)
						then i
						else i + 1
					local x = originX
						+ if lowSide == i
							then i * cell - STEP_DEPTH / 2
							else (i + 1) * cell + STEP_DEPTH / 2
					add(
						parts,
						"step",
						ownerOf(layout),
						{ STEP_DEPTH, high - low, cell },
						{ x, low + (high - low) / 2, originZ + (j - 0.5) * cell },
						style.materials.floor
					)
				end
			end
			if j < n and not layout.sealedS[idx(layout, i, j)] then
				local low = math.min(floorAt(layout, i, j), floorAt(layout, i, j + 1))
				local high = math.max(floorAt(layout, i, j), floorAt(layout, i, j + 1))
				if high - low == 1 then
					local lowSide = if floorAt(layout, i, j) < floorAt(layout, i, j + 1)
						then j
						else j + 1
					local z = originZ
						+ if lowSide == j
							then j * cell - STEP_DEPTH / 2
							else (j + 1) * cell + STEP_DEPTH / 2
					add(
						parts,
						"step",
						ownerOf(layout),
						{ cell, high - low, STEP_DEPTH },
						{ originX + (i - 0.5) * cell, low + (high - low) / 2, z },
						style.materials.floor
					)
				end
			end
		end
	end
end

local function perimeter(
	parts: { Part },
	layout: any,
	originX: number,
	originZ: number,
	style: any,
	worldChunks: number
): ()
	if worldChunks == nil then
		return
	end
	local span = layout.n * layout.cell
	local tallest = 0
	for index = 1, layout.n * layout.n do
		tallest = math.max(tallest, layout.floorY[index] + layout.height[index])
	end
	local owner = ownerOf(layout)
	local thickness = style.wallThickness
	if layout.cx == 0 then
		add(
			parts,
			"wall",
			owner,
			{ thickness, tallest, span },
			{ originX, tallest / 2, originZ + span / 2 },
			style.materials.wall
		)
	end
	if layout.cx == worldChunks - 1 then
		add(
			parts,
			"wall",
			owner,
			{ thickness, tallest, span },
			{ originX + span, tallest / 2, originZ + span / 2 },
			style.materials.wall
		)
	end
	if layout.cz == 0 then
		add(
			parts,
			"wall",
			owner,
			{ span, tallest, thickness },
			{ originX + span / 2, tallest / 2, originZ },
			style.materials.wall
		)
	end
	if layout.cz == worldChunks - 1 then
		add(
			parts,
			"wall",
			owner,
			{ span, tallest, thickness },
			{ originX + span / 2, tallest / 2, originZ + span },
			style.materials.wall
		)
	end
end

local function details(
	parts: { Part },
	layout: any,
	originX: number,
	originZ: number,
	style: any
): ()
	for _, detail in ipairs(layout.details) do
		local index = idx(layout, detail.cellX, detail.cellZ)
		local level = (layout.floorY[index] or 0) + layout.height[index]
		add(
			parts,
			"detail",
			"detail:" .. detail.id,
			{ 2, 0.2, 2 },
			{ originX + detail.x, detail.y or (level - 0.3), originZ + detail.z },
			style.materials.ceiling,
			{ canCollide = false }
		)
	end
end

function ChunkRenderer.describe(layout: any, options: any?): { Part }
	local style = styleOf(options and options.style)
	local parts: { Part } = {}
	local originX, originZ = LayoutModule.origin(layout)
	local debug = options ~= nil and options.debug == true

	floors(parts, layout, originX, originZ, style)
	ceilings(parts, layout, originX, originZ, style)
	solids(parts, layout, originX, originZ, style)
	walls(parts, layout, originX, originZ, style)
	soffits(parts, layout, originX, originZ, style)
	hangWalls(parts, layout, originX, originZ, style)
	columns(parts, layout, originX, originZ, style)
	ramps(parts, layout, originX, originZ, style)
	steps(parts, layout, originX, originZ, style)
	if options ~= nil and options.enclosure == "perimeter" then
		perimeter(parts, layout, originX, originZ, style, options.worldChunks)
	end
	if debug then
		details(parts, layout, originX, originZ, style)
	end

	if #parts > style.budget then
		error(
			string.format("ChunkRenderer: %d parts exceeds the budget of %d", #parts, style.budget),
			2
		)
	end
	return parts
end

return ChunkRenderer
