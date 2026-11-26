--!strict

-- Cell-grid layout (ADR 0024).
--
-- A cell strategy describes a chunk as cells and faces, not as nodes and edges.
-- That is the whole reason this package exists: a 18x18 chunk is 324 cells and
-- ~350 faces, which is a few kilobytes, whereas the node plan would need 324
-- nodes with ids, ports and a codec. Rendering merges this into a few dozen
-- parts.
--
-- Face ownership: a face is built by the cell with the lower world coordinate.
-- Inside a chunk that means `sealedE` and `sealedS` always, and `sealedW` /
-- `sealedN` are only ever read as border information (never built), so no face
-- is built twice and no chunk needs its neighbour's content.

local Layout = {}

export type Detail = {
	id: string,
	cellX: number,
	cellZ: number,
	x: number,
	z: number,
}

-- An authored set piece reserved on the grid. `cellX`/`cellZ` is the
-- north-west cell of the footprint; `x`/`z` is its centre in chunk-local studs;
-- `modelId` is the asset's `noclipTemplateId` (see 20-assets/templates).
export type Template = {
	ref: string,
	modelId: string,
	cellX: number,
	cellZ: number,
	w: number,
	d: number,
	x: number,
	z: number,
}

export type Layout = {
	cx: number,
	cz: number,
	n: number,
	cell: number,
	-- 1..n, index = i + (j - 1) * n
	solid: { boolean },
	-- Interior height (ceilingY = floorY + height).
	height: { number },
	-- Top surface of the floor. 0 everywhere until terrain (ADR 0029).
	floorY: { number },
	-- nil, or { axis = "x"|"z", dir = 1|-1, lowY, highY }. The cell's floor is
	-- replaced by a wedge; the ramp belongs to the higher side.
	ramp: { any },
	-- A thin column at the cell centre (a pillar-grid zone).
	column: { boolean },
	-- A wall with a crouch gap under it: passable, but blocked above `clearance`.
	hangE: { boolean },
	hangS: { boolean },
	-- Only the owning side is stored: E and S. Storing the mirror (W/N) too let
	-- the connectivity pass open one copy and leave the other, so borders
	-- disagreed with themselves.
	sealedE: { boolean },
	sealedS: { boolean },
	-- Heights and floor levels across the east and south borders, for wall spans.
	outHeightE: { number },
	outHeightS: { number },
	outFloorE: { number },
	outFloorS: { number },
	details: { Detail },
	-- Cells reserved by a template footprint (task 0036). Nothing is built from
	-- them yet: the descriptor only reserves ground for a future model.
	templateCell: { boolean },
	templates: { Template },
}

function Layout.index(n: number, i: number, j: number): number
	return i + (j - 1) * n
end

function Layout.new(cx: number, cz: number, n: number, cell: number): Layout
	local layout: Layout = {
		cx = cx,
		cz = cz,
		n = n,
		cell = cell,
		solid = {},
		height = {},
		floorY = {},
		ramp = {},
		column = {},
		hangE = {},
		hangS = {},
		sealedE = {},
		sealedS = {},
		outHeightE = {},
		outHeightS = {},
		outFloorE = {},
		outFloorS = {},
		details = {},
		templateCell = {},
		templates = {},
	}
	for index = 1, n * n do
		layout.solid[index] = false
		layout.height[index] = 0
		layout.floorY[index] = 0
		layout.column[index] = false
		layout.hangE[index] = false
		layout.hangS[index] = false
		layout.sealedE[index] = false
		layout.sealedS[index] = false
		layout.templateCell[index] = false
	end
	for j = 1, n do
		layout.outHeightE[j] = 0
		layout.outHeightS[j] = 0
		layout.outFloorE[j] = 0
		layout.outFloorS[j] = 0
	end
	return layout
end

function Layout.get(layout: Layout, i: number, j: number): boolean
	return layout.solid[Layout.index(layout.n, i, j)] == true
end

function Layout.set(layout: Layout, i: number, j: number, solid: boolean): ()
	local index = Layout.index(layout.n, i, j)
	layout.solid[index] = solid
end

-- Origin of the chunk in world studs.
function Layout.origin(layout: Layout): (number, number)
	return layout.cx * layout.n * layout.cell, layout.cz * layout.n * layout.cell
end

function Layout.worldCell(layout: Layout, i: number, j: number): (number, number)
	return layout.cx * layout.n + i - 1, layout.cz * layout.n + j - 1
end

-- Whether a face is sealed. `axis` is "E" (between i and i+1) or "S" (between j
-- and j+1). Used by the connectivity pass, which is allowed to open faces.
function Layout.isSealed(layout: Layout, axis: string, i: number, j: number): boolean
	local index = Layout.index(layout.n, i, j)
	if axis == "E" then
		return layout.sealedE[index] == true
	end
	return layout.sealedS[index] == true
end

function Layout.seal(layout: Layout, axis: string, i: number, j: number, value: boolean): ()
	local index = Layout.index(layout.n, i, j)
	if axis == "E" then
		layout.sealedE[index] = value
	else
		layout.sealedS[index] = value
	end
end

-- Is the cell inside the chunk (not on the outer ring)?
function Layout.isInner(layout: Layout, i: number, j: number): boolean
	return i > 1 and j > 1 and i < layout.n and j < layout.n
end

return Layout
