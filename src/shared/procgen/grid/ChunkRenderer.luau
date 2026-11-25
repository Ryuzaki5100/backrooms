--!strict

-- Merged chunk renderer (ADR 0024).
--
-- The render unit is not the cell. A whole chunk gets one floor slab, one
-- ceiling per height band, merged wall runs and merged solid runs. That is what
-- makes cell-sized layouts affordable in Roblox, where there is no instancing:
-- 324 cells become ~90 parts instead of ~330.
--
-- Pure: emits the same part specs `Geometry` emits, so `Build.apply` is unchanged.

local LayoutModule = if script ~= nil
	then require(script.Parent.ChunkLayout)
	else require("./ChunkLayout")

local ChunkRenderer = {}

local FLOOR_THICKNESS = 0.5
local CEILING_THICKNESS = 0.5

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
}

local DEFAULTS = {
	wallThickness = 1,
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
	collide: boolean?
): ()
	table.insert(parts, {
		kind = kind,
		owner = owner,
		size = size,
		position = position,
		yaw = 0,
		pitch = 0,
		material = material.material,
		color = material.color,
		canCollide = if collide == nil then true else collide,
	})
end

-- Floor and one ceiling per distinct height, each a single slab covering the
-- chunk. A ceiling slab at the wrong height for a cell is hidden above that
-- cell's own slab, so this stays correct with varying heights.
local function slabs(parts: { Part }, layout: any, originX: number, originZ: number, style: any): ()
	local span = layout.n * layout.cell
	local cx = originX + span / 2
	local cz = originZ + span / 2

	add(
		parts,
		"floor",
		"chunk:" .. layout.cx .. ":" .. layout.cz,
		{ span, FLOOR_THICKNESS, span },
		{ cx, -FLOOR_THICKNESS / 2, cz },
		style.materials.floor
	)

	local seen: { [number]: boolean } = {}
	for index = 1, layout.n * layout.n do
		local height = layout.height[index]
		if height > 0 and not seen[height] then
			seen[height] = true
			add(
				parts,
				"ceiling",
				"chunk:" .. layout.cx .. ":" .. layout.cz,
				{ span, CEILING_THICKNESS, span },
				{ cx, height + CEILING_THICKNESS / 2, cz },
				style.materials.ceiling
			)
		end
	end
end

-- Solid mass merged along rows.
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
			local index = LayoutModule.index(n, i, j)
			if not layout.solid[index] then
				i += 1
				continue
			end
			local height = layout.height[index]
			local start = i
			while i + 1 <= n do
				local nextIndex = LayoutModule.index(n, i + 1, j)
				if not layout.solid[nextIndex] or layout.height[nextIndex] ~= height then
					break
				end
				i += 1
			end
			local finish = i
			local length = (finish - start + 1) * cell
			add(
				parts,
				"wall",
				"chunk:" .. layout.cx .. ":" .. layout.cz,
				{ length, height, cell },
				{
					originX + (start - 1) * cell + length / 2,
					height / 2,
					originZ + (j - 0.5) * cell,
				},
				style.materials.wall
			)
			i += 1
		end
	end
end

-- Wall runs: east faces merge along z, south faces merge along x. A run only
-- merges where the two sides agree on height, so the wall is exactly as tall as
-- the taller neighbour and no floating band is left.
local function walls(parts: { Part }, layout: any, originX: number, originZ: number, style: any): ()
	local n, cell, thickness = layout.n, layout.cell, style.wallThickness

	local function wallHeightE(i: number, j: number): number
		local own = layout.height[LayoutModule.index(n, i, j)]
		local other = if i == n
			then layout.outHeightE[j]
			else layout.height[LayoutModule.index(n, i + 1, j)]
		return math.max(own, other)
	end

	local function wallHeightS(i: number, j: number): number
		local own = layout.height[LayoutModule.index(n, i, j)]
		local other = if j == n
			then layout.outHeightS[i]
			else layout.height[LayoutModule.index(n, i, j + 1)]
		return math.max(own, other)
	end

	-- East faces: fixed i, run over j.
	for i = 1, n do
		local j = 1
		while j <= n do
			local index = LayoutModule.index(n, i, j)
			if not layout.sealedE[index] then
				j += 1
				continue
			end
			local height = wallHeightE(i, j)
			local start = j
			while j + 1 <= n do
				local nextIndex = LayoutModule.index(n, i, j + 1)
				if not layout.sealedE[nextIndex] or wallHeightE(i, j + 1) ~= height then
					break
				end
				j += 1
			end
			local finish = j
			local length = (finish - start + 1) * cell
			add(
				parts,
				"wall",
				"chunk:" .. layout.cx .. ":" .. layout.cz,
				{ thickness, height, length },
				{
					originX + i * cell,
					height / 2,
					originZ + (start - 1) * cell + length / 2,
				},
				style.materials.wall
			)
			j += 1
		end
	end

	-- South faces: fixed j, run over i.
	for j = 1, n do
		local i = 1
		while i <= n do
			local index = LayoutModule.index(n, i, j)
			if not layout.sealedS[index] then
				i += 1
				continue
			end
			local height = wallHeightS(i, j)
			local start = i
			while i + 1 <= n do
				local nextIndex = LayoutModule.index(n, i + 1, j)
				if not layout.sealedS[nextIndex] or wallHeightS(i + 1, j) ~= height then
					break
				end
				i += 1
			end
			local finish = i
			local length = (finish - start + 1) * cell
			add(
				parts,
				"wall",
				"chunk:" .. layout.cx .. ":" .. layout.cz,
				{ length, height, thickness },
				{
					originX + (start - 1) * cell + length / 2,
					height / 2,
					originZ + j * cell,
				},
				style.materials.wall
			)
			i += 1
		end
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
		local height = layout.height[LayoutModule.index(layout.n, detail.cellX, detail.cellZ)] or 12
		local y = detail.y or (height - 0.3)
		add(
			parts,
			"detail",
			"detail:" .. detail.id,
			{ 2, 0.2, 2 },
			{ originX + detail.x, y, originZ + detail.z },
			style.materials.ceiling,
			false
		)
	end
end

function ChunkRenderer.describe(layout: any, options: any?): { Part }
	local style = styleOf(options and options.style)
	local parts: { Part } = {}
	local originX, originZ = LayoutModule.origin(layout)

	slabs(parts, layout, originX, originZ, style)
	solids(parts, layout, originX, originZ, style)
	walls(parts, layout, originX, originZ, style)
	-- Details are layout data first: they are counted and reported whether or
	-- not they have a prefab yet. Rendering them as bare plates in production
	-- would put floating squares in the level, so they are debug-only until a
	-- prefab exists (M21).
	if options ~= nil and options.debug == true then
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
