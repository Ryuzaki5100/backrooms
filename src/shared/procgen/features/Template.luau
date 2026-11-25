--!strict

-- Template feature (task 0036): authored set pieces placed from config.
--
-- A spec is `{ ref, footprint: { w, d }, count, spacing }` in whole cells. Each
-- instance needs a rectangular patch of floor that is flat, open and unclaimed,
-- and it reserves that patch so nothing else lands on it.
--
-- Determinism: the scan starts at a cell hashed from the seed, then takes the
-- first candidate in raster order with wraparound. That is stable per seed but
-- puts the patch wherever the hash lands, instead of always in the corner that
-- a raster scan starting at (1,1) would fill first.
--
-- Placement is chunk-local: a chunk only knows the templates it placed itself,
-- which is what keeps chunk generation order-independent. Model insertion is a
-- follow-up (the descriptor reserves ground, nothing is built yet).

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

-- Whether the config asks for any template, so the pass can be skipped cheaply.
function Template.enabled(make: any): boolean
	local specs = make.config and make.config.templates
	return type(specs) == "table" and #specs > 0
end

-- A footprint is placeable when every cell is open floor at one level, with no
-- wall, pillar or hanging wall inside it.
local function fits(layout: any, i: number, j: number, w: number, d: number): boolean
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
			if layout.ramp[index] ~= nil then
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

	for specIndex, spec in ipairs(specs) do
		local w = (spec.footprint and spec.footprint.w) or 0
		local d = (spec.footprint and spec.footprint.d) or 0
		local count = spec.count or DEFAULTS.count
		local spacing = spec.spacing or DEFAULTS.spacing

		-- One hashed start per spec, then first-fit with wraparound.
		local start = math.floor(
			Common.hash01(make.seed, "template:" .. specIndex .. ":" .. tostring(spec.ref), 0, 0)
				* total
		)
		local placed = 0
		for step = 0, total - 1 do
			if placed >= count then
				break
			end
			local cell = (start + step) % total
			local i = cell % n + 1
			local j = math.floor(cell / n) + 1
			if fits(layout, i, j, w, d) and spaced(layout, i, j, w, d, spacing) then
				for jj = j, j + d - 1 do
					for ii = i, i + w - 1 do
						layout.templateCell[Layout.index(n, ii, jj)] = true
					end
				end
				table.insert(layout.templates, {
					ref = spec.ref,
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
