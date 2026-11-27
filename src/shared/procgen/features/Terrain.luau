--!strict

-- Terrain feature (ADR 0029): per-cell floor heights and the ramps/steps that
-- cross them. Level 0 ships flat (banded shares of 0), but the machinery is
-- here and testable, so a level that wants mezzanines/sunken areas only picks
-- a band.

local Common = if script ~= nil then require(script.Parent.Common) else require("./Common")
local Rng = if script ~= nil then require(script.Parent.Parent.Rng) else require("../Rng")
local Layout = if script ~= nil
	then require(script.Parent.Parent.grid.ChunkLayout)
	else require("../grid/ChunkLayout")

local Terrain = {}

Terrain.id = "terrain"

local DEFAULTS = {
	rise = 4,
	plateauShare = 0.10,
	sunkenShare = 0.10,
	rampChance = 1.0,
	secondRampFaces = 12,
	secondRampChance = 0.25,
	rampSpacing = 4,
	extraRampCells = 48,
	stepMax = 1,
	minHeadroom = 9,
}

-- Draw the banded shares once per seed.
function Terrain.drawShares(seed: number, terrain: any): any
	local rng = Rng.new(seed):fork("terrain")
	local t = terrain or {}
	return {
		plateau = Common.bandValue(rng, t.plateauShare, DEFAULTS.plateauShare),
		sunken = Common.bandValue(rng, t.sunkenShare, DEFAULTS.sunkenShare),
		rampChance = Common.bandValue(rng, t.rampChance, DEFAULTS.rampChance),
	}
end

-- Floor height of a world cell. A coarse zone field, not per-cell noise, so
-- plateaus and sunken areas are large enough to walk on.
function Terrain.terrainAt(make: any, gx: number, gz: number): number
	local terrain = make.params.terrain
	if terrain == nil then
		return 0
	end
	local x = Common.canonical(make, gx)
	local z = Common.canonical(make, gz)
	-- D63 ring rule (ADR 0031): vertical terrain stays off a chunk's outer ring of
	-- cells. This is a pure world function, so the two chunks sharing a border both
	-- see flat floor (0) on their own side without reading each other, and a rise
	-- can never straddle a chunk seam.
	local n = make.n
	local li = x % n
	local lj = z % n
	if li == 0 or li == n - 1 or lj == 0 or lj == n - 1 then
		return 0
	end
	local blocks = terrain.blocksPerZone or 2
	local span = make.block * blocks
	local bx = math.floor(x / span)
	local bz = math.floor(z / span)
	local roll = Common.hash01(make.seed, "terrain", bx, bz)
	local shares = make.terrainShares or { plateau = 0, sunken = 0 }
	local level = terrain.rise or DEFAULTS.rise
	if roll < shares.sunken then
		-- A sunken zone beside a plateau zone would only be enterable over an
		-- 8-stud face, which `tryRamp` refuses (one rise per ramp), and the
		-- D63 ring is flat so it cannot host the ramp either: such a zone stays
		-- flat instead of becoming an unreachable pit.
		for _, step in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
			local nx = math.floor(Common.canonical(make, x + step[1] * span) / span)
			local nz = math.floor(Common.canonical(make, z + step[2] * span) / span)
			local other = Common.hash01(make.seed, "terrain", nx, nz)
			if other >= shares.sunken and other < shares.sunken + shares.plateau then
				return 0
			end
		end
		return -level
	elseif roll < shares.sunken + shares.plateau then
		return level
	end
	return 0
end

-- Largest floor difference walked without a ramp (WalkGraph and the repair
-- pass use the same number the boundary rules do).
function Terrain.stepMax(make: any): number
	local terrain = make.params and make.params.terrain
	return (terrain and terrain.stepMax) or DEFAULTS.stepMax
end

-- Minimum distance (Manhattan, in cells) between two ramps of one region, and
-- the region size above which a component earns extra ramps (read by the
-- connectivity repair too).
function Terrain.rampSpacing(make: any): number
	local terrain = make.params and make.params.terrain
	return (terrain and terrain.rampSpacing) or DEFAULTS.rampSpacing
end

function Terrain.extraRampCells(make: any): number
	local terrain = make.params and make.params.terrain
	return (terrain and terrain.extraRampCells) or DEFAULTS.extraRampCells
end

-- Whether cell (i, j) is at least `spacing` cells (Manhattan) from every
-- { i, j } in `others`.
function Terrain.farFrom(others: { { number } }, i: number, j: number, spacing: number): boolean
	for _, other in ipairs(others) do
		if math.abs(other[1] - i) + math.abs(other[2] - j) < spacing then
			return false
		end
	end
	return true
end

-- Floor height at chunk-local cell (i, j); outside the chunk it is read from the
-- terrain field, so a chunk border agrees with its neighbour without reading it.
function Terrain.floorAt(make: any, layout: any, i: number, j: number): number
	local n = layout.n
	if i < 1 or j < 1 or i > n or j > n then
		return Terrain.terrainAt(make, layout.cx * n + i - 1, layout.cz * n + j - 1)
	end
	return layout.floorY[Layout.index(n, i, j)]
end

-- The one ramp rule (ADR 0029, shared by `apply` and the connectivity repair):
-- a ramp stands on the HIGH side of a boundary, in a cell that is free of ramp,
-- column, template and hanging wall, bridges at most one `terrain.rise`, neither
-- of its two end cells is a template cell, and only when the plateau continues at the
-- same level on the far side as open floor (`dir` points towards the high end,
-- so the cell beyond is at +dir along `axis`). Returns whether the ramp was placed; the
-- boundary face's sealed flag is the caller's business.
function Terrain.tryRamp(
	make: any,
	layout: any,
	i: number,
	j: number,
	axis: string,
	dir: number,
	lowY: number,
	highY: number
): boolean
	local n = layout.n
	if i < 1 or j < 1 or i > n or j > n then
		return false
	end
	if highY - lowY > ((make.params.terrain and make.params.terrain.rise) or DEFAULTS.rise) then
		-- One ramp bridges at most one rise: a plateau beside a sunken area would
		-- need a ramp twice as steep as the others, so that face stays a sealed
		-- retaining edge.
		return false
	end
	if i == 1 or j == 1 or i == n or j == n then
		-- D63: the ring is flat and belongs to both chunks of a border, so no ramp
		-- stands on it (its high end would open onto a cell this chunk cannot see).
		return false
	end
	local index = Layout.index(n, i, j)
	-- The low end (-dir) must not open onto another ramp or a wall (review R5).
	-- Outside the chunk the ring rule already makes it flat open floor.
	local lowI = if axis == "x" then i - dir else i
	local lowJ = if axis == "z" then j - dir else j
	if lowI >= 1 and lowJ >= 1 and lowI <= n and lowJ <= n then
		local lowIndex = Layout.index(n, lowI, lowJ)
		if
			layout.ramp[lowIndex] ~= nil
			or layout.solid[lowIndex]
			or layout.templateCell[lowIndex]
		then
			return false
		end
	end
	if
		layout.ramp[index] ~= nil
		or layout.column[index]
		or layout.templateCell[index]
		or layout.hangE[index]
		or layout.hangS[index]
		or (i > 1 and layout.hangE[Layout.index(n, i - 1, j)])
		or (j > 1 and layout.hangS[Layout.index(n, i, j - 1)])
	then
		return false
	end
	local beyondI = if axis == "x" then i + dir else i
	local beyondJ = if axis == "z" then j + dir else j
	if Terrain.floorAt(make, layout, beyondI, beyondJ) ~= layout.floorY[index] then
		-- The plateau does not continue: a ramp would end in mid-air.
		return false
	end
	if
		beyondI >= 1
		and beyondJ >= 1
		and beyondI <= n
		and beyondJ <= n
		and (
			layout.solid[Layout.index(n, beyondI, beyondJ)]
			or layout.templateCell[Layout.index(n, beyondI, beyondJ)]
		)
	then
		-- ...or in a wall or a set piece: the high end must open onto floor.
		return false
	end
	layout.ramp[index] = { axis = axis, dir = dir, lowY = lowY, highY = highY }
	return true
end

-- Apply the boundary rules: a rise above one stud is a retaining edge unless a
-- ramp can stand on the higher side and continue into the plateau. Headroom is
-- raised wherever needed.
--
-- Ramps are sparse and chosen per REGION BOUNDARY, never per face (ADR 0031 D68).
-- A terrain region is a chunk-local set of touching cells of equal floorY
-- (partition walls do not split it: the connectivity pass opens them). Every rise above stepMax is sealed first;
-- then for each pair (high region, adjacent lower region, or lower floor outside
-- the chunk) the candidate faces where `tryRamp` accepts a ramp are sorted by
-- `hash01(seed, "ramp:pick", canonical owner gx, gz)` (ties: east before south,
-- then cell index), and the first one is opened with a ramp. A second ramp is
-- placed only when the shared boundary has more than `secondRampFaces` faces and
-- a hash roll is below `secondRampChance`. Every ramp of a high region stays at
-- least `rampSpacing` cells (Manhattan) from the others in that region.
--
-- Params (make.params.terrain, defaults in brackets):
--   rampChance        [1.0]  probability that a region pair gets a ramp from
--                            this pass at all (was: per boundary face). The
--                            connectivity repair covers anything left unjoined.
--   secondRampFaces   [12]   boundary faces needed before a second ramp is
--                            considered.
--   secondRampChance  [0.25] probability of that second ramp.
--   rampSpacing       [4]    minimum distance between ramps of one region.
function Terrain.apply(make: any, layout: any): ()
	local terrain = make.params.terrain or {}
	local stepMax = terrain.stepMax or DEFAULTS.stepMax
	local minHeadroom = terrain.minHeadroom or DEFAULTS.minHeadroom
	local secondFaces = terrain.secondRampFaces or DEFAULTS.secondRampFaces
	local secondChance = terrain.secondRampChance or DEFAULTS.secondRampChance
	local spacing = Terrain.rampSpacing(make)
	local n = layout.n
	local originX = layout.cx * n
	local originZ = layout.cz * n

	local function floorOf(i: number, j: number): number
		return Terrain.floorAt(make, layout, i, j)
	end

	local rampChance = make.terrainShares and make.terrainShares.rampChance or DEFAULTS.rampChance

	-- Terrain regions: equal floorY, non-solid, non-template cells that touch.
	-- Partition walls do not split a region: `connect` opens walls between pieces
	-- of one level, so a plateau cut into rooms still needs only one way up (a
	-- ramp per room would put several side by side on one edge).
	local regionOf: { [number]: number } = {}
	local regionSize: { [number]: number } = {}
	local regionCount = 0
	for start = 1, n * n do
		if
			regionOf[start] == nil
			and not layout.solid[start]
			and not layout.templateCell[start]
		then
			regionCount += 1
			local level = layout.floorY[start]
			regionOf[start] = regionCount
			regionSize[regionCount] = 1
			local queue = { start }
			local head = 1
			while head <= #queue do
				local current = queue[head]
				head += 1
				local ci, cj = (current - 1) % n + 1, (current - 1) // n + 1
				for _, step in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
					local ni, nj = ci + step[1], cj + step[2]
					if ni >= 1 and nj >= 1 and ni <= n and nj <= n then
						local other = Layout.index(n, ni, nj)
						if
							regionOf[other] == nil
							and not layout.solid[other]
							and not layout.templateCell[other]
							and layout.floorY[other] == level
						then
							regionOf[other] = regionCount
							regionSize[regionCount] += 1
							table.insert(queue, other)
						end
					end
				end
			end
		end
	end

	-- Pairs of (high region, lower side) with their candidate rise faces, in scan
	-- order (deterministic).
	local pairs_: { any } = {}
	local pairByKey: { [string]: any } = {}

	local function consider(i: number, j: number, axis: string, here: number, there: number)
		local diff = there - here
		local owner = Layout.index(n, i, j)
		local sealedMap = if axis == "x" then layout.sealedE else layout.sealedS
		if diff == 0 then
			return
		end
		if math.abs(diff) <= stepMax then
			sealedMap[owner] = false
			return
		end
		-- A rise above stepMax is a retaining edge until a ramp opens it.
		sealedMap[owner] = true
		local oi = if axis == "x" then i + 1 else i
		local oj = if axis == "z" then j + 1 else j
		local highIsHere = diff < 0
		local rampI = if highIsHere then i else oi
		local rampJ = if highIsHere then j else oj
		if rampI < 1 or rampJ < 1 or rampI > n or rampJ > n then
			-- Unreachable for a rise since the D63 ring rule (the ring is always flat,
			-- so the high cell of a rise is never outside the chunk); kept as a guard.
			return
		end
		local highIndex = Layout.index(n, rampI, rampJ)
		local lowI = if highIsHere then oi else i
		local lowJ = if highIsHere then oj else j
		local lowKey = if lowI >= 1
				and lowJ >= 1
				and lowI <= n
				and lowJ <= n
			then "r" .. (regionOf[Layout.index(n, lowI, lowJ)] or 0)
			else "o" .. math.min(here, there)
		local highRegion = regionOf[highIndex]
		if highRegion == nil then
			return -- solid or template ground: no ramp stands here
		end
		local key = highRegion .. ":" .. lowKey
		local entry = pairByKey[key]
		if entry == nil then
			entry = { region = highRegion, faces = {} }
			pairByKey[key] = entry
			table.insert(pairs_, entry)
		end
		local gx = Common.canonical(make, originX + i - 1)
		local gz = Common.canonical(make, originZ + j - 1)
		table.insert(entry.faces, {
			i = i,
			j = j,
			axis = axis,
			order = if axis == "x" then 0 else 1,
			index = owner,
			rampI = rampI,
			rampJ = rampJ,
			dir = if highIsHere then -1 else 1,
			lowY = math.min(here, there),
			highY = math.max(here, there),
			gx = gx,
			gz = gz,
			key = Common.hash01(make.seed, "ramp:pick", gx, gz),
		})
	end

	for j = 1, n do
		for i = 1, n do
			local here = layout.floorY[Layout.index(n, i, j)]
			consider(i, j, "x", here, floorOf(i + 1, j))
			consider(i, j, "z", here, floorOf(i, j + 1))
		end
	end

	-- A region takes at most round(size / extraRampCells) ramps from this pass,
	-- and never fewer than two (one per boundary, "rarely two"), so a small
	-- plateau ringed by several lower regions is still sparse; the repair joins
	-- whatever the cap leaves apart.
	local extraCells = Terrain.extraRampCells(make)
	local placedByRegion: { [number]: { { number } } } = {}
	for _, entry in ipairs(pairs_) do
		table.sort(entry.faces, function(a: any, b: any): boolean
			if a.key ~= b.key then
				return a.key < b.key
			end
			if a.order ~= b.order then
				return a.order < b.order
			end
			return a.index < b.index
		end)
	end

	-- Open the next acceptable face of `entry`; false when none qualifies.
	local function place(entry: any): boolean
		local placed = placedByRegion[entry.region]
		if placed == nil then
			placed = {}
			placedByRegion[entry.region] = placed
		end
		local cap = math.max(2, math.floor(regionSize[entry.region] / extraCells + 0.5))
		if #placed >= cap then
			return false
		end
		for _, face in ipairs(entry.faces) do
			if
				Terrain.farFrom(placed, face.rampI, face.rampJ, spacing)
				and Terrain.tryRamp(
					make,
					layout,
					face.rampI,
					face.rampJ,
					if face.axis == "x" then "x" else "z",
					face.dir,
					face.lowY,
					face.highY
				)
			then
				local sealedMap = if face.axis == "x" then layout.sealedE else layout.sealedS
				sealedMap[face.index] = false
				table.insert(placed, { face.rampI, face.rampJ })
				return true
			end
		end
		return false
	end

	-- One ramp per region pair first, so no boundary is starved by another's
	-- second ramp; then the rare second ramps.
	local rolled: { any } = {}
	for _, entry in ipairs(pairs_) do
		local first = entry.faces[1]
		if Common.hash01(make.seed, "ramp:pair", first.gx, first.gz) < rampChance then
			if place(entry) then
				table.insert(rolled, entry)
			end
		end
	end
	for _, entry in ipairs(rolled) do
		local first = entry.faces[1]
		if
			#entry.faces > secondFaces
			and Common.hash01(make.seed, "ramp:second", first.gx, first.gz) < secondChance
		then
			place(entry)
		end
	end

	for index = 1, n * n do
		layout.height[index] = math.max(layout.height[index], minHeadroom)
	end
end

-- Validation for `strategy.params.terrain` (moved here from Features, messages
-- unchanged). Accepts the terrain section, or nil for "none configured".
local VALIDATE_DEFAULT_RISE = 4
local VALIDATE_DEFAULT_STEP_MAX = 1

local function isPositiveInteger(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0
end

local function validateBand(problems: { string }, prefix: string, value: any): ()
	if type(value) == "table" then
		if
			value[1] == nil
			or value[2] == nil
			or value[1] < 0
			or value[2] < value[1]
			or value[2] > 1
		then
			table.insert(problems, prefix .. ": must be a number or [min,max] band within [0,1]")
		end
	elseif type(value) == "number" then
		if value < 0 or value > 1 then
			table.insert(problems, prefix .. ": must be within [0,1]")
		end
	elseif value ~= nil then
		table.insert(problems, prefix .. ": must be a number or a band")
	end
end

local function validateTerrainParams(problems: { string }, terrain: any): ()
	local prefix = "strategy.params.terrain."
	for _, key in ipairs({ "rampSpacing", "extraRampCells", "secondRampFaces" }) do
		local value = terrain[key]
		if value ~= nil and not isPositiveInteger(value) then
			table.insert(problems, prefix .. key .. ": must be a positive integer")
		end
	end
	local chance = terrain.secondRampChance
	if chance ~= nil and (type(chance) ~= "number" or chance < 0 or chance > 1) then
		table.insert(problems, prefix .. "secondRampChance: must be a number within [0,1]")
	end
	if terrain.stepMax ~= nil and type(terrain.stepMax) ~= "number" then
		table.insert(problems, prefix .. "stepMax: must be a number")
	end
	if terrain.rise ~= nil and type(terrain.rise) ~= "number" then
		table.insert(problems, prefix .. "rise: must be a number")
	end
	if
		(terrain.stepMax ~= nil or terrain.rise ~= nil)
		and type(terrain.stepMax or 0) == "number"
		and type(terrain.rise or 0) == "number"
	then
		local stepMax = terrain.stepMax or VALIDATE_DEFAULT_STEP_MAX
		local rise = terrain.rise or VALIDATE_DEFAULT_RISE
		if stepMax >= rise then
			table.insert(
				problems,
				prefix
					.. "stepMax: must be less than terrain.rise (stepMax "
					.. stepMax
					.. ", rise "
					.. rise
					.. ")"
			)
		end
	end
end

function Terrain.validate(terrain: any?): { string }
	local problems: { string } = {}
	local section = terrain or {}
	validateBand(problems, "strategy.params.terrain.plateauShare", section.plateauShare)
	validateBand(problems, "strategy.params.terrain.sunkenShare", section.sunkenShare)
	validateBand(problems, "strategy.params.terrain.rampChance", section.rampChance)
	validateTerrainParams(problems, section)
	return problems
end

return Terrain
