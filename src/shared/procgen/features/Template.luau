--!strict

-- Template feature (task 0036): authored set pieces placed from config.
--
-- A spec is `{ ref, footprint: { w, d }, count, spacing }` in whole cells. Each
-- instance needs a rectangular patch of floor that is flat, open and unclaimed,
-- and it reserves that patch so nothing else lands on it.
--
-- Determinism: the scan starts at a cell hashed from the seed and the chunk's
-- canonical coordinates, then takes the first candidate in raster order with
-- wraparound. The chunk coordinates are part of the hash so every chunk tries a
-- different relative cell first; hashing the seed alone sent every chunk to the
-- same cell and tiled the template in a lattice. The coordinates are canonical
-- (wrapped, derived from cell coordinates), so a chunk and its wrapped copy
-- start at the same cell and place identically.
--
-- Placement is chunk-local: a chunk only knows the templates it placed itself,
-- which is what keeps chunk generation order-independent. The descriptor carries
-- the asset id; `ChunkRenderer` turns it into a clone order and `Build.apply`
-- clones the model (task 0038). Chunk-manager integration is M19.

local Common = if script ~= nil then require(script.Parent.Common) else require("./Common")
local Layout = if script ~= nil
	then require(script.Parent.Parent.grid.ChunkLayout)
	else require("../grid/ChunkLayout")

local Template = {}

Template.id = "template"

local DEFAULTS = {
	count = 1,
	spacing = 0,
}

-- A level names a `ref`; the asset carries a stable `noclipTemplateId`. The two
-- are mapped explicitly, not by a string convention, so an id that does not
-- derive from its ref still resolves (`20-assets/templates/contract.md`).
local MODELS: { [string]: string } = {
	manila = "manila_room",
	stairwell = "stairwell_mezzanine",
	sunken = "sunken_pool",
}

-- The model id for a config ref. An unmapped ref is its own id, so a template
-- named like its ref needs no table row.
function Template.modelId(ref: string): string
	return MODELS[ref] or ref
end

-- Whether the config asks for any template, so the pass can be skipped cheaply.
function Template.enabled(make: any): boolean
	local specs = make.config and make.config.templates
	return type(specs) == "table" and #specs > 0
end

-- Cells a footprint may not cover: every ramp cell and both end cells of every
-- ramp (the high end at +dir and the low end at -dir), so a set piece never sits
-- at the mouth of a ramp. Terrain runs before this pass, so the ramps are known.
local function rampEnds(layout: any): { [number]: boolean }
	local n = layout.n
	local blocked: { [number]: boolean } = {}
	for index, ramp in pairs(layout.ramp) do
		blocked[index] = true
		local i, j = (index - 1) % n + 1, (index - 1) // n + 1
		for _, sign in ipairs({ 1, -1 }) do
			local ei = if ramp.axis == "x" then i + sign * ramp.dir else i
			local ej = if ramp.axis == "z" then j + sign * ramp.dir else j
			if ei >= 1 and ej >= 1 and ei <= n and ej <= n then
				blocked[Layout.index(n, ei, ej)] = true
			end
		end
	end
	return blocked
end

-- A footprint is placeable when every cell is open floor at one level, with no
-- wall, pillar, hanging wall or ramp end inside it.
local function fits(
	layout: any,
	blocked: { [number]: boolean },
	i: number,
	j: number,
	w: number,
	d: number
): boolean
	local n = layout.n
	if w < 1 or d < 1 then
		return false
	end
	if i < 1 or j < 1 or i + w - 1 > n or j + d - 1 > n then
		return false
	end

	local level = nil
	for jj = j, j + d - 1 do
		for ii = i, i + w - 1 do
			local index = Layout.index(n, ii, jj)
			if layout.solid[index] or layout.templateCell[index] then
				return false
			end
			if layout.column[index] or layout.hangE[index] or layout.hangS[index] then
				return false
			end
			if layout.ramp[index] ~= nil or blocked[index] then
				return false
			end
			local floor = layout.floorY[index] or 0
			if level == nil then
				level = floor
			elseif floor ~= level then
				return false
			end
		end
	end

	-- The patch must be one open area: a partition between two footprint cells
	-- would run through the set piece.
	for jj = j, j + d - 1 do
		for ii = i, i + w - 1 do
			local index = Layout.index(n, ii, jj)
			if ii < i + w - 1 and layout.sealedE[index] then
				return false
			end
			if jj < j + d - 1 and layout.sealedS[index] then
				return false
			end
		end
	end
	return true
end

-- Chebyshev gap between two cell rectangles, in cells: 0 when they touch or
-- overlap, positive when there is that many empty cells along the wider axis.
local function gapBetween(
	ai: number,
	aj: number,
	aw: number,
	ad: number,
	bi: number,
	bj: number,
	bw: number,
	bd: number
): number
	local gapX = math.max(bi - (ai + aw), ai - (bi + bw))
	local gapZ = math.max(bj - (aj + ad), aj - (bj + bd))
	return math.max(0, math.max(gapX, gapZ))
end

local function spaced(
	layout: any,
	i: number,
	j: number,
	w: number,
	d: number,
	spacing: number
): boolean
	if spacing <= 0 then
		return true
	end
	for _, other in ipairs(layout.templates) do
		if gapBetween(i, j, w, d, other.cellX, other.cellZ, other.w, other.d) < spacing then
			return false
		end
	end
	return true
end

function Template.apply(make: any, layout: any): ()
	local specs = make.config and make.config.templates
	if type(specs) ~= "table" then
		return
	end
	local n = layout.n
	local total = n * n
	local chunkX = math.floor(Common.canonical(make, layout.cx * n) / n)
	local chunkZ = math.floor(Common.canonical(make, layout.cz * n) / n)
	local blocked = rampEnds(layout)

	for specIndex, spec in ipairs(specs) do
		local w = (spec.footprint and spec.footprint.w) or 0
		local d = (spec.footprint and spec.footprint.d) or 0
		local count = spec.count or DEFAULTS.count
		local spacing = spec.spacing or DEFAULTS.spacing

		-- One hashed start per spec and chunk, then first-fit with wraparound.
		local start = math.floor(
			Common.hash01(
				make.seed,
				"template:" .. specIndex .. ":" .. tostring(spec.ref),
				chunkX,
				chunkZ
			) * total
		)
		local placed = 0
		for step = 0, total - 1 do
			if placed >= count then
				break
			end
			local cell = (start + step) % total
			local i = cell % n + 1
			local j = math.floor(cell / n) + 1
			if fits(layout, blocked, i, j, w, d) and spaced(layout, i, j, w, d, spacing) then
				for jj = j, j + d - 1 do
					for ii = i, i + w - 1 do
						layout.templateCell[Layout.index(n, ii, jj)] = true
					end
				end
				table.insert(layout.templates, {
					ref = spec.ref,
					modelId = Template.modelId(spec.ref),
					cellX = i,
					cellZ = j,
					w = w,
					d = d,
					x = (i - 1 + w / 2) * layout.cell,
					z = (j - 1 + d / 2) * layout.cell,
				})
				placed += 1
			end
		end
	end
end

return Template
