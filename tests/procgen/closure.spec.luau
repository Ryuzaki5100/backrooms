--!strict

-- Closure (task 0009, ADR 0032 D67): the world is closed. From standing eye
-- height, no sight line may leave the geometry: nothing under a floor, nothing
-- over a ceiling, no slit at a wall, a soffit, a template or a ramp.
--
-- Pure Lune: ray casting against `ChunkRenderer.describe` output. Parts are
-- axis-aligned boxes, except ramps, which are tested as their triangular prism
-- (an AABB would hide every leak beside a slope). A template is a clone order,
-- not geometry; the authored model is sealed (template contract), so it is
-- modelled here as a solid box over its authored envelope (depth below the floor
-- plane to roof top).
--
-- Yaw: a wedge with yaw 0 rises towards +Z; `Build.apply` rotates by
-- `CFrame.Angles(0, math.rad(yaw), 0)`, so yaw 90 rises towards +X, -90 towards
-- -X and 180 towards -Z (the mapping `ChunkRenderer.ramps` documents).

local H = require("../harness")
local ChunkRenderer = require("../../src/shared/procgen/grid/ChunkRenderer")
local WalkGraph = require("../../src/shared/procgen/grid/WalkGraph")
local OpenAdditive = require("../../src/shared/procgen/strategies/OpenAdditive")
local Level0 = require("../../src/config/levels/Level_0")

local EYE = 5
local AZIMUTHS = 12
local ELEVATIONS = { -40, -15, 0, 20, 50 }
local WORLD_CHUNKS = 3
local MAX_REPORTED = 4
local BUCKET = 16

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

-- Level 0 as shipped (templates included), walled, with terrain bands on.
local function closedWorld(seed: number): any
	local config = clone(Level0)
	config.world = clone(Level0.world)
	config.world.worldSizeChunks = WORLD_CHUNKS
	config.world.boundaryMode = "wall"
	config.strategy = clone(Level0.strategy)
	config.strategy.params = clone(Level0.strategy.params)
	config.strategy.params.terrain = {
		rise = 4,
		plateauShare = 0.15,
		sunkenShare = 0.15,
		rampChance = 0.30,
		minHeadroom = 9,
	}
	return OpenAdditive.world(config, seed)
end

type Solid = {
	minX: number,
	maxX: number,
	minY: number,
	maxY: number,
	minZ: number,
	maxZ: number,
	-- Wedge only: local rotation (cos, sin of yaw) and the size.
	wedge: boolean,
	cosY: number,
	sinY: number,
	cx: number,
	cy: number,
	cz: number,
	w: number,
	h: number,
	d: number,
	stamp: number,
}

local function boxSolid(minX, maxX, minY, maxY, minZ, maxZ): Solid
	return {
		minX = minX,
		maxX = maxX,
		minY = minY,
		maxY = maxY,
		minZ = minZ,
		maxZ = maxZ,
		wedge = false,
		cosY = 1,
		sinY = 0,
		cx = 0,
		cy = 0,
		cz = 0,
		w = 0,
		h = 0,
		d = 0,
		stamp = 0,
	}
end

local function solidOf(part: any): Solid?
	if part.canCollide == false then
		return nil
	end
	local px, py, pz = part.position[1], part.position[2], part.position[3]
	if part.template ~= nil then
		return boxSolid(
			px,
			px + part.size[1],
			py - ChunkRenderer.templateDepth(part.template),
			py + ChunkRenderer.templateHeight(part.template),
			pz,
			pz + part.size[3]
		)
	end
	local sx, sy, sz = part.size[1], part.size[2], part.size[3]
	if part.wedge == true then
		local radians = math.rad(part.yaw)
		local c, s = math.floor(math.cos(radians) + 0.5), math.floor(math.sin(radians) + 0.5)
		-- Yaws are multiples of 90, so the AABB is the footprint of the rotated box.
		local ex = (math.abs(c) * sx + math.abs(s) * sz) / 2
		local ez = (math.abs(s) * sx + math.abs(c) * sz) / 2
		local solid = boxSolid(px - ex, px + ex, py - sy / 2, py + sy / 2, pz - ez, pz + ez)
		solid.wedge = true
		solid.cosY, solid.sinY = c, s
		solid.cx, solid.cy, solid.cz = px, py, pz
		solid.w, solid.h, solid.d = sx, sy, sz
		return solid
	end
	return boxSolid(px - sx / 2, px + sx / 2, py - sy / 2, py + sy / 2, pz - sz / 2, pz + sz / 2)
end

-- Entry distance of the ray into the solid, nil on a miss. Cyrus-Beck clipping
-- against the box slabs, plus the slope plane for a wedge. Misses behind the
-- origin are discarded.
local function hit(
	solid: Solid,
	ox: number,
	oy: number,
	oz: number,
	dx: number,
	dy: number,
	dz: number
): number?
	local tNear, tFar = 0, math.huge
	if solid.wedge then
		-- Into the wedge's local frame: R^-1 (p - centre), R = Angles(0, yaw, 0).
		local rx, ry, rz = ox - solid.cx, oy - solid.cy, oz - solid.cz
		local c, s = solid.cosY, solid.sinY
		local lox, loy, loz = rx * c - rz * s, ry, rx * s + rz * c
		local ldx, ldy, ldz = dx * c - dz * s, dy, dx * s + dz * c
		local hx, hy, hz = solid.w / 2, solid.h / 2, solid.d / 2
		local function clip(o: number, d: number, lo: number, hi: number): boolean
			if math.abs(d) < 1e-12 then
				return o >= lo and o <= hi
			end
			local t0, t1 = (lo - o) / d, (hi - o) / d
			if t0 > t1 then
				t0, t1 = t1, t0
			end
			tNear = math.max(tNear, t0)
			tFar = math.min(tFar, t1)
			return tNear <= tFar
		end
		if
			not (clip(lox, ldx, -hx, hx) and clip(loy, ldy, -hy, hy) and clip(loz, ldz, -hz, hz))
		then
			return nil
		end
		-- Solid below the slope: y + h/2 <= h * (z + d/2) / d, rising towards +z.
		local slope = solid.h / solid.d
		local f0 = (loy + hy) - slope * (loz + hz)
		local fd = ldy - slope * ldz
		if math.abs(fd) < 1e-12 then
			if f0 > 0 then
				return nil
			end
		elseif fd > 0 then
			tFar = math.min(tFar, -f0 / fd)
		else
			tNear = math.max(tNear, -f0 / fd)
		end
		if tNear <= tFar then
			return tNear
		end
		return nil
	end

	local function clip(o: number, d: number, lo: number, hi: number): boolean
		if math.abs(d) < 1e-12 then
			return o >= lo and o <= hi
		end
		local t0, t1 = (lo - o) / d, (hi - o) / d
		if t0 > t1 then
			t0, t1 = t1, t0
		end
		tNear = math.max(tNear, t0)
		tFar = math.min(tFar, t1)
		return tNear <= tFar
	end
	if
		clip(ox, dx, solid.minX, solid.maxX)
		and clip(oy, dy, solid.minY, solid.maxY)
		and clip(oz, dz, solid.minZ, solid.maxZ)
	then
		return tNear
	end
	return nil
end

local function contains(solid: Solid, x: number, y: number, z: number): boolean
	if
		x <= solid.minX
		or x >= solid.maxX
		or y <= solid.minY
		or y >= solid.maxY
		or z <= solid.minZ
		or z >= solid.maxZ
	then
		return false
	end
	if not solid.wedge then
		return true
	end
	local rx, rz = x - solid.cx, z - solid.cz
	local c, s = solid.cosY, solid.sinY
	local lz = rx * s + rz * c
	return (y - solid.cy) + solid.h / 2 < solid.h * (lz + solid.d / 2) / solid.d
end

type Scene = {
	solids: { Solid },
	buckets: { [number]: { number } },
	cellsX: number,
	cellsZ: number,
	stamp: number,
	span: number,
}

local function bucketKey(scene: Scene, bx: number, bz: number): number
	return bx + bz * scene.cellsX
end

local function buildScene(make: any, layouts: { any }): Scene
	local span = WORLD_CHUNKS * make.n * make.cell
	local cellsAxis = math.ceil(span / BUCKET) + 2
	local scene: Scene = {
		solids = {},
		buckets = {},
		cellsX = cellsAxis,
		cellsZ = cellsAxis,
		stamp = 0,
		span = span,
	}
	local options = {
		style = { budget = 9000 },
		enclosure = "perimeter",
		worldChunks = WORLD_CHUNKS,
	}
	for _, layout in ipairs(layouts) do
		for _, part in ipairs(ChunkRenderer.describe(layout, options)) do
			local solid = solidOf(part)
			if solid ~= nil then
				table.insert(scene.solids, solid)
				local id = #scene.solids
				-- Bucket coordinates are offset by one so the perimeter walls, which
				-- straddle the world edge, land inside the grid.
				local b0x = math.floor(solid.minX / BUCKET) + 1
				local b1x = math.floor(solid.maxX / BUCKET) + 1
				local b0z = math.floor(solid.minZ / BUCKET) + 1
				local b1z = math.floor(solid.maxZ / BUCKET) + 1
				for bz = math.max(b0z, 0), math.min(b1z, scene.cellsZ - 1) do
					for bx = math.max(b0x, 0), math.min(b1x, scene.cellsX - 1) do
						local key = bucketKey(scene, bx, bz)
						local list = scene.buckets[key]
						if list == nil then
							list = {}
							scene.buckets[key] = list
						end
						table.insert(list, id)
					end
				end
			end
		end
	end
	return scene
end

-- Nearest hit distance along the ray, nil if it leaves the world unobstructed.
local function cast(
	scene: Scene,
	ox: number,
	oy: number,
	oz: number,
	dx: number,
	dy: number,
	dz: number
): number?
	scene.stamp += 1
	local stamp = scene.stamp
	local solids = scene.solids
	-- Offset by one bucket (see buildScene).
	local gx, gz = ox / BUCKET + 1, oz / BUCKET + 1
	local bx, bz = math.floor(gx), math.floor(gz)
	local stepX = if dx > 0 then 1 elseif dx < 0 then -1 else 0
	local stepZ = if dz > 0 then 1 elseif dz < 0 then -1 else 0
	local tMaxX, tMaxZ = math.huge, math.huge
	local tDeltaX, tDeltaZ = math.huge, math.huge
	if stepX ~= 0 then
		tDeltaX = BUCKET / math.abs(dx)
		tMaxX = ((if stepX > 0 then bx + 1 - gx else gx - bx) * BUCKET) / math.abs(dx)
	end
	if stepZ ~= 0 then
		tDeltaZ = BUCKET / math.abs(dz)
		tMaxZ = ((if stepZ > 0 then bz + 1 - gz else gz - bz) * BUCKET) / math.abs(dz)
	end
	local best = math.huge
	while bx >= 0 and bz >= 0 and bx < scene.cellsX and bz < scene.cellsZ do
		local list = scene.buckets[bucketKey(scene, bx, bz)]
		if list ~= nil then
			for k = 1, #list do
				local id = list[k]
				local solid = solids[id]
				if solid.stamp ~= stamp then
					solid.stamp = stamp
					local t = hit(solid, ox, oy, oz, dx, dy, dz)
					if t ~= nil and t < best then
						best = t
					end
				end
			end
		end
		local exit = math.min(tMaxX, tMaxZ)
		if best <= exit then
			return best
		end
		if tMaxX < tMaxZ then
			bx += stepX
			tMaxX += tDeltaX
		else
			bz += stepZ
			tMaxZ += tDeltaZ
		end
	end
	if best < math.huge then
		return best
	end
	return nil
end

-- Unit directions: 12 azimuths x the elevations, plus straight up (61 total).
local function directions(): { { number } }
	local out = {}
	for k = 0, AZIMUTHS - 1 do
		local azimuth = math.rad(k * 360 / AZIMUTHS)
		for _, elevation in ipairs(ELEVATIONS) do
			local e = math.rad(elevation)
			table.insert(out, {
				math.cos(e) * math.cos(azimuth),
				math.sin(e),
				math.cos(e) * math.sin(azimuth),
			})
		end
	end
	table.insert(out, { 0, 1, 0 })
	return out
end

type Eye = { x: number, y: number, z: number, cx: number, cz: number, i: number, j: number }

-- Every open, walkable cell centre at standing eye height. A pillar-grid cell
-- has a post at its centre, so its eye is offset to a quarter of the cell.
local function eyes(layouts: { any }): { Eye }
	local out = {}
	for _, layout in ipairs(layouts) do
		local n, cell = layout.n, layout.cell
		local graph = WalkGraph.build(layout)
		local originX = layout.cx * n * cell
		local originZ = layout.cz * n * cell
		for j = 1, n do
			for i = 1, n do
				local index = i + (j - 1) * n
				if graph.walkable[index] then
					local ramp = layout.ramp[index]
					local surface = if ramp ~= nil
						then (ramp.lowY + ramp.highY) / 2
						else layout.floorY[index]
					local x = originX + (i - 0.5) * cell
					local z = originZ + (j - 0.5) * cell
					if layout.column[index] then
						x += cell / 4
						z += cell / 4
					end
					table.insert(out, {
						x = x,
						y = surface + EYE,
						z = z,
						cx = layout.cx,
						cz = layout.cz,
						i = i,
						j = j,
					})
				end
			end
		end
	end
	return out
end

local function layoutsOf(make: any): { any }
	local layouts = {}
	for cz = 0, WORLD_CHUNKS - 1 do
		for cx = 0, WORLD_CHUNKS - 1 do
			table.insert(
				layouts,
				OpenAdditive.layout(make, cx, cz, { enclosedPolicy = "solidify" })
			)
		end
	end
	return layouts
end

local function insideAny(scene: Scene, eye: Eye): boolean
	local list = scene.buckets[bucketKey(
		scene,
		math.floor(eye.x / BUCKET) + 1,
		math.floor(eye.z / BUCKET) + 1
	)]
	if list == nil then
		return false
	end
	for _, id in ipairs(list) do
		if contains(scene.solids[id], eye.x, eye.y, eye.z) then
			return true
		end
	end
	return false
end

H.test("the world is closed: no sight line from an eye point leaves the geometry", function()
	local started = os.clock()
	local dirs = directions()
	H.eq(#dirs, 61, "12 azimuths x 5 elevations + up")
	local totalEscapes, totalRays, totalEyes = 0, 0, 0
	local reports: { string } = {}
	for seed = 1, 5 do
		local make = closedWorld(seed)
		local layouts = layoutsOf(make)
		local scene = buildScene(make, layouts)
		local points = eyes(layouts)
		local escapes, inside = 0, 0
		for _, eye in ipairs(points) do
			if insideAny(scene, eye) then
				inside += 1
			end
			for _, d in ipairs(dirs) do
				totalRays += 1
				if cast(scene, eye.x, eye.y, eye.z, d[1], d[2], d[3]) == nil then
					escapes += 1
					if #reports < MAX_REPORTED then
						table.insert(
							reports,
							string.format(
								"seed %d chunk %d,%d cell %d,%d eye (%.1f, %.1f, %.1f) dir (%.2f, %.2f, %.2f)",
								seed,
								eye.cx,
								eye.cz,
								eye.i,
								eye.j,
								eye.x,
								eye.y,
								eye.z,
								d[1],
								d[2],
								d[3]
							)
						)
					end
				end
			end
		end
		H.eq(inside, 0, "seed " .. seed .. ": eye points inside a part")
		totalEscapes += escapes
		totalEyes += #points
		print(
			string.format("  [closure] seed %d: %d eye points, %d escapes", seed, #points, escapes)
		)
	end
	print(
		string.format(
			"  [closure] %d eye points, %d rays, %d escapes, %.1f s",
			totalEyes,
			totalRays,
			totalEscapes,
			os.clock() - started
		)
	)
	H.ok(totalEyes > 1000, "enough eye points: " .. totalEyes)
	H.eq(totalEscapes, 0, "escaping rays; first: " .. table.concat(reports, " | "))
end)

H.test("the ray caster treats a ramp as a prism rising towards its high end", function()
	local function wedge(yaw: number): Solid
		local solid = solidOf({
			kind = "ramp",
			size = { 16, 4, 16 },
			position = { 0, 2, 0 },
			yaw = yaw,
			wedge = true,
		})
		H.ok(solid ~= nil, "wedge solid")
		return solid :: Solid
	end
	-- A level ray at y = 3 along +x. Yaw 90 rises towards +x, so the slope is at
	-- y = 3 where 4 * (x + 8) / 16 = 3, that is x = 4.
	local rising = hit(wedge(90), -100, 3, 0, 1, 0, 0)
	H.ok(rising ~= nil and math.abs(rising - 104) < 1e-6, "yaw 90 meets the slope at x = 4")
	-- Yaw -90 rises towards -x: the high wall at x = -8 is 4 tall, so the ray
	-- is stopped by it at once.
	local falling = hit(wedge(-90), -100, 3, 0, 1, 0, 0)
	H.ok(falling ~= nil and math.abs(falling - 92) < 1e-6, "yaw -90 is solid from x = -8")
	-- The same along z: yaw 0 rises towards +z, yaw 180 towards -z.
	local north = hit(wedge(0), 0, 3, -100, 0, 0, 1)
	H.ok(north ~= nil and math.abs(north - 104) < 1e-6, "yaw 0 rises towards +z")
	local south = hit(wedge(180), 0, 3, -100, 0, 0, 1)
	H.ok(south ~= nil and math.abs(south - 92) < 1e-6, "yaw 180 rises towards -z")
	-- Straight down: near the low edge the prism is thin, near the high edge tall.
	local lowEdge = hit(wedge(90), -7.9, 10, 0, 0, -1, 0)
	local highEdge = hit(wedge(90), 7.9, 10, 0, 0, -1, 0)
	H.ok(lowEdge ~= nil and lowEdge > 7.9, "the low edge is thin")
	H.ok(highEdge ~= nil and highEdge < 6.5, "the high edge is tall")
end)
