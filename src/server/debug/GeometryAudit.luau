--!strict

-- Geometry audit (task 0032, issue #27): the Studio counterpart of the Lune
-- closure spec. It ray-casts the REAL instances of the streamed world and
-- separates three things that a plain "did the ray escape" test would lump
-- together:
--
--   * a defect: a gap (a sight line that leaves the loaded world through
--     geometry), a cell without floor or ceiling, a ramp that does not meet its
--     floors, is obstructed (`rampBlocked`) or has no headroom (`lowHeadroom`);
--   * a declared opening: any part tagged `NoclipOpening` (Build sets the tag and
--     the `NoclipOpening` attribute from `spec.opening`). Rays treat it as
--     transparent, and an escape whose segment crosses its volume is allowed;
--   * a stream-edge sightline: a near-horizontal ray that reaches the border of
--     the loaded chunks. Beyond that border nothing is built yet, so it is not a
--     defect, only reported (count, shortest, median length).
--
-- Studio, server side: `require(game.ServerScriptService.Debug.GeometryAudit)`.
-- `run` yields once per chunk (`task.wait`), so call it from a thread that may
-- yield. `selfTest` builds a closed room and proves the three verdicts.

local CollectionService = game:GetService("CollectionService")

local GeometryAudit = {}

local OPENING_TAG = "NoclipOpening"
local WORLD_FOLDER = "NoclipWorld"
local MARKER_FOLDER = "NoclipAudit"
local MAX_SAMPLES = 12
local MAX_MARKERS = 300
-- Probe height for the floor ray: below the lowest ceiling (a -4 floor with a 12
-- ceiling is 8) and above the highest floor (+4).
local FLOOR_PROBE_Y = 7
local FLOOR_PROBE_LENGTH = 20
-- A column cell has a post at its centre, so try the quarter points too.
local OFFSETS = { { 0, 0 }, { 4, 4 }, { -4, -4 }, { 4, -4 }, { -4, 4 } }
local RAMP_HEADROOM = 7
local RAMP_STEP_TOLERANCE = 0.1
local NO_EDGE = -1

export type Options = {
	folder: Instance?,
	cellStuds: number?,
	chunkCells: number?,
	eyeHeight: number?,
	azimuths: number?,
	elevations: { number }?,
	maxDistance: number?,
	markers: boolean?,
	around: Vector3?,
	radiusChunks: number?,
}

export type Sample = {
	kind: string,
	where: string,
	position: Vector3,
	direction: Vector3?,
	detail: string?,
}

export type Report = {
	seed: any,
	chunks: number,
	cells: number,
	skippedCells: number,
	rays: number,
	gaps: { count: number, samples: { Sample } },
	noFloor: number,
	noCeiling: number,
	streamEdge: { count: number, min: number, median: number },
	openings: { count: number, cells: number, rays: number },
	ramps: { count: number, failures: { count: number, samples: { Sample } } },
	samples: { Sample },
	seconds: number,
	ok: boolean,
}

type Volume = { cframe: CFrame, half: Vector3, part: BasePart }

local function chunkKeyOf(name: string): (number?, number?)
	local a, b = string.match(name, "^chunk_(-?%d+):(-?%d+)$")
	if a == nil or b == nil then
		return nil, nil
	end
	return tonumber(a), tonumber(b)
end

local function loadedKey(cx: number, cz: number): number
	return (cx + 4096) * 8192 + (cz + 4096)
end

-- Slab test of a segment against an (inflated) oriented box.
local function segmentHits(volume: Volume, origin: Vector3, dir: Vector3, length: number): boolean
	local o = volume.cframe:PointToObjectSpace(origin)
	local d = volume.cframe:VectorToObjectSpace(dir)
	local half = volume.half + Vector3.new(0.25, 0.25, 0.25)
	local tNear, tFar = 0, length
	local axes = {
		{ o.X, d.X, half.X },
		{ o.Y, d.Y, half.Y },
		{ o.Z, d.Z, half.Z },
	}
	for _, axis in ipairs(axes) do
		local oa, da, ha = axis[1], axis[2], axis[3]
		if math.abs(da) < 1e-9 then
			if math.abs(oa) > ha then
				return false
			end
		else
			local t0, t1 = (-ha - oa) / da, (ha - oa) / da
			if t0 > t1 then
				t0, t1 = t1, t0
			end
			tNear = math.max(tNear, t0)
			tFar = math.min(tFar, t1)
			if tNear > tFar then
				return false
			end
		end
	end
	return true
end

local function anySegmentHits(
	volumes: { Volume },
	origin: Vector3,
	dir: Vector3,
	length: number
): boolean
	for _, volume in ipairs(volumes) do
		if segmentHits(volume, origin, dir, length) then
			return true
		end
	end
	return false
end

-- Is the column over (x, z) inside a declared opening? Vertical extent is
-- ignored: a floor hole is a thin part but the hole is the whole column.
local function inOpeningColumn(volumes: { Volume }, x: number, z: number): boolean
	for _, volume in ipairs(volumes) do
		local p = volume.cframe:PointToObjectSpace(Vector3.new(x, volume.part.Position.Y, z))
		if math.abs(p.X) <= volume.half.X and math.abs(p.Z) <= volume.half.Z then
			return true
		end
	end
	return false
end

-- Openings are found by walking the audited folder, not through
-- CollectionService:GetTagged: a part is an opening when it carries the tag or
-- the `NoclipOpening` attribute, wherever the folder is parented. The tag query
-- is only consulted as a second source so a tag-only part is never missed.
local function collectOpenings(folder: Instance): ({ Volume }, { [Instance]: boolean })
	local volumes: { Volume } = {}
	local set: { [Instance]: boolean } = {}
	local function add(instance: Instance)
		if set[instance] or not instance:IsA("BasePart") then
			return
		end
		table.insert(volumes, {
			cframe = instance.CFrame,
			half = instance.Size / 2,
			part = instance,
		})
		set[instance] = true
	end
	for _, instance in ipairs(folder:GetDescendants()) do
		if
			instance:IsA("BasePart")
			and (
				CollectionService:HasTag(instance, OPENING_TAG)
				or instance:GetAttribute(OPENING_TAG) ~= nil
			)
		then
			add(instance)
		end
	end
	for _, instance in ipairs(CollectionService:GetTagged(OPENING_TAG)) do
		if instance:IsDescendantOf(folder) then
			add(instance)
		end
	end
	return volumes, set
end

-- Rays see the world minus declared openings. With none declared the whole
-- folder is the filter; otherwise the include list is built without them.
local function worldParams(
	folder: Instance,
	openingSet: { [Instance]: boolean },
	hasOpenings: boolean
): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	if not hasOpenings then
		params.FilterDescendantsInstances = { folder }
		return params
	end
	local list: { Instance } = {}
	for _, chunk in ipairs(folder:GetChildren()) do
		if not openingSet[chunk] then
			if chunk:IsA("Folder") then
				for _, child in ipairs(chunk:GetChildren()) do
					if not openingSet[child] then
						table.insert(list, child)
					end
				end
			else
				table.insert(list, chunk)
			end
		end
	end
	params.FilterDescendantsInstances = list
	return params
end

local function median(values: { number }): number
	if #values == 0 then
		return 0
	end
	table.sort(values)
	return values[(#values + 1) // 2]
end

-- One ramp: side rays hit within a cell, both ends meet a floor, headroom.
-- Geometry-agnostic about which end is high: it measures the surface.
local function checkRamp(part: BasePart, params: RaycastParams, folder: Instance): { Sample }
	local failures: { Sample } = {}
	local cf, size = part.CFrame, part.Size
	local hy, hz = size.Y / 2, size.Z / 2
	local cy = cf.Position.Y
	local where = part:GetFullName()
	local function fail(kind: string, position: Vector3, detail: string)
		table.insert(failures, { kind = kind, where = where, position = position, detail = detail })
	end

	local ownParams = RaycastParams.new()
	ownParams.FilterType = Enum.RaycastFilterType.Include
	ownParams.FilterDescendantsInstances = { part }
	local function topAt(z: number): number?
		local origin = cf:PointToWorldSpace(Vector3.new(0, hy + 1, z))
		local hit = workspace:Raycast(origin, Vector3.new(0, -(size.Y + 4), 0), ownParams)
		if hit == nil then
			return nil
		end
		return hit.Position.Y
	end
	local a, b = topAt(hz - 0.5), topAt(-hz + 0.5)
	if a == nil or b == nil then
		fail("rampSurface", cf.Position, "no surface found on the wedge")
		return failures
	end
	local highSign = if a > b then 1 else -1

	-- Surface height at local z, and a world point over the wedge centre line.
	local function surfaceY(z: number): number
		return cy - hy + size.Y * (z * highSign + hz) / size.Z
	end
	local function world(z: number, y: number): Vector3
		local p = cf:PointToWorldSpace(Vector3.new(0, 0, z))
		return Vector3.new(p.X, y, p.Z)
	end

	-- Sides: from just above the surface, a wall within one cell (16 studs).
	local mid = world(0, cy + 0.5)
	for _, dir in ipairs({ cf.RightVector, -cf.RightVector }) do
		local flat = Vector3.new(dir.X, 0, dir.Z).Unit
		if workspace:Raycast(mid, flat * 16, params) == nil then
			fail("sideOpen", mid, "no wall within 16 studs beside the ramp")
		end
	end

	-- Ends: a floor at the matching height one stud beyond each edge.
	local function checkEnd(label: string, z: number, expected: number)
		local point = world(z, cy + hy + 1)
		local hit = workspace:Raycast(point, Vector3.new(0, -12, 0), params)
		if hit == nil or math.abs(hit.Position.Y - expected) > RAMP_STEP_TOLERANCE then
			fail(
				"endStep",
				point,
				string.format(
					"%s end floor %s, ramp %.2f",
					label,
					if hit then string.format("%.2f", hit.Position.Y) else "missing",
					expected
				)
			)
		end
	end
	checkEnd("low", -highSign * (hz + 1), cy - hy)
	checkEnd("high", highSign * (hz + 1), cy + hy)

	-- Obstructions: any other part standing in the space above the ramp surface
	-- (a pillar in the middle of the stair). Side walls are centred on the cell
	-- border, so they reach half their thickness into the ramp's width; the
	-- footprint is therefore narrowed by 1.5 studs per side (and 0.5 along the
	-- slope) so walls and floor slabs that merely close the ramp never count.
	local blocker: BasePart? = nil
	local boxHeight = size.Y + RAMP_HEADROOM
	local boxCenter = Vector3.new(cf.Position.X, cy - hy + boxHeight / 2, cf.Position.Z)
	local box = CFrame.new(boxCenter) * (cf - cf.Position)
	local query = OverlapParams.new()
	query.FilterType = Enum.RaycastFilterType.Include
	query.FilterDescendantsInstances = { folder }
	local footprint =
		Vector3.new(math.max(size.X - 3, 0.5), boxHeight - 0.5, math.max(size.Z - 1, 0.5))
	for _, other in ipairs(workspace:GetPartBoundsInBox(box, footprint, query)) do
		if other ~= part then
			-- Surface height under the other part's centre, clamped to the wedge.
			local localZ = cf:PointToObjectSpace(other.Position).Z
			local y = surfaceY(math.clamp(localZ, -hz, hz))
			local bottom = other.Position.Y - other.Size.Y / 2
			local top = other.Position.Y + other.Size.Y / 2
			if top > y + 0.5 and bottom < y + RAMP_HEADROOM - 0.25 then
				blocker = other
				break
			end
		end
	end
	if blocker ~= nil then
		fail("rampBlocked", blocker.Position, "blocked by " .. blocker.Name)
		return failures
	end

	-- Headroom at the middle and near the high end. A sample whose down-ray does
	-- not land on the ramp itself is skipped rather than measured from another part.
	for _, z in ipairs({ 0, highSign * (hz - 1) }) do
		local y = surfaceY(z)
		local origin = world(z, y + 0.2)
		local down = workspace:Raycast(world(z, y + 1), Vector3.new(0, -3, 0), ownParams)
		if down ~= nil and math.abs(down.Position.Y - y) < 0.3 then
			local hit = workspace:Raycast(origin, Vector3.new(0, 40, 0), params)
			if hit ~= nil and hit.Position.Y - y < RAMP_HEADROOM then
				fail(
					"lowHeadroom",
					origin,
					string.format("%.2f studs of headroom", hit.Position.Y - y)
				)
			end
		end
	end
	return failures
end

function GeometryAudit.run(opts: Options?): Report
	local started = os.clock()
	local o: Options = opts or {}
	local folder: Instance? = o.folder or workspace:FindFirstChild(WORLD_FOLDER)
	if folder == nil then
		error("GeometryAudit.run: no world folder (Workspace." .. WORLD_FOLDER .. ")", 2)
	end
	local cell = o.cellStuds or 16
	local chunkCells = o.chunkCells or 18
	local chunkStuds = cell * chunkCells
	local eyeHeight = o.eyeHeight or 5
	local azimuths = o.azimuths or 8
	local elevations = o.elevations or { -20, 0, 25, 55 }
	local maxDistance = o.maxDistance or 2000

	local volumes, openingSet = collectOpenings(folder)
	local params = worldParams(folder, openingSet, #volumes > 0)
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Include
	overlap.FilterDescendantsInstances = { folder }
	overlap.MaxParts = 1

	-- Loaded chunks.
	local loaded: { [number]: boolean } = {}
	local chunkFolders: { { cx: number, cz: number, folder: Instance } } = {}
	for _, child in ipairs(folder:GetChildren()) do
		local cx, cz = chunkKeyOf(child.Name)
		if cx ~= nil and cz ~= nil then
			loaded[loadedKey(cx, cz)] = true
			table.insert(chunkFolders, { cx = cx, cz = cz, folder = child })
		end
	end
	table.sort(chunkFolders, function(a, b)
		if a.cx ~= b.cx then
			return a.cx < b.cx
		end
		return a.cz < b.cz
	end)

	local aroundCx: number? = nil
	local aroundCz: number? = nil
	if o.around ~= nil then
		aroundCx = math.floor(o.around.X / chunkStuds)
		aroundCz = math.floor(o.around.Z / chunkStuds)
	end
	local radius = o.radiusChunks or 2

	-- Directions: azimuths x elevations; the straight-up ray is handled apart
	-- (a miss there is `noCeiling`, not a gap).
	local dirs: { { dir: Vector3, ax: number, az: number, h: number, azimuth: number } } = {}
	for k = 0, azimuths - 1 do
		local a = math.rad(k * 360 / azimuths)
		for _, elevation in ipairs(elevations) do
			local e = math.rad(elevation)
			table.insert(dirs, {
				dir = Vector3.new(
					math.cos(e) * math.cos(a),
					math.sin(e),
					math.cos(e) * math.sin(a)
				),
				ax = math.cos(a),
				az = math.sin(a),
				h = math.cos(e),
				azimuth = k + 1,
			})
		end
	end
	local up = Vector3.new(0, 1, 0)

	local report: Report = {
		seed = workspace:GetAttribute("NoclipActiveSeed"),
		chunks = 0,
		cells = 0,
		skippedCells = 0,
		rays = 0,
		gaps = { count = 0, samples = {} },
		noFloor = 0,
		noCeiling = 0,
		streamEdge = { count = 0, min = 0, median = 0 },
		openings = { count = 0, cells = 0, rays = 0 },
		ramps = { count = 0, failures = { count = 0, samples = {} } },
		samples = {},
		seconds = 0,
		ok = false,
	}
	local edgeLengths: { number } = {}

	-- Markers (optional, never inside the world folder).
	local markerFolder: Folder? = nil
	local markerCount = 0
	if o.markers == true then
		local old = workspace:FindFirstChild(MARKER_FOLDER)
		if old ~= nil then
			old:Destroy()
		end
		local created = Instance.new("Folder")
		created.Name = MARKER_FOLDER
		created.Parent = workspace
		markerFolder = created
	end
	local function mark(color: Color3, position: Vector3)
		if markerFolder == nil or markerCount >= MAX_MARKERS then
			return
		end
		markerCount += 1
		local part = Instance.new("Part")
		part.Size = Vector3.new(1.5, 1.5, 1.5)
		part.Shape = Enum.PartType.Ball
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Material = Enum.Material.Neon
		part.Color = color
		part.Position = position
		part.Parent = markerFolder
	end
	local RED, GREEN = Color3.new(1, 0.1, 0.1), Color3.new(0.1, 1, 0.2)

	local function cast(origin: Vector3, dir: Vector3, length: number): RaycastResult?
		report.rays += 1
		return workspace:Raycast(origin, dir * length, params)
	end

	local function addSample(list: { Sample }, sample: Sample)
		if #list < MAX_SAMPLES then
			table.insert(list, sample)
		end
	end
	local function defect(sample: Sample)
		addSample(report.samples, sample)
		mark(RED, sample.position)
	end
	local function openingRay(at: Vector3)
		report.openings.rays += 1
		report.openings.count += 1
		mark(GREEN, at)
	end

	-- Distance (in the xz plane) until a ray along (ax, az) from (x, z) enters a
	-- chunk that is not loaded; NO_EDGE when it does not within `maxDistance`.
	local function edgeDistance(x: number, z: number, ax: number, az: number): number
		local r = cell
		while r <= maxDistance do
			local cx = math.floor((x + ax * r) / chunkStuds)
			local cz = math.floor((z + az * r) / chunkStuds)
			if not loaded[loadedKey(cx, cz)] then
				return r
			end
			r += cell
		end
		return NO_EDGE
	end

	-- Floor probe for one cell: the eye point, or why there is none.
	local function findEye(baseX: number, baseZ: number, where: string): (Vector3?, boolean)
		for _, offset in ipairs(OFFSETS) do
			local x, z = baseX + offset[1], baseZ + offset[2]
			local probe = Vector3.new(x, FLOOR_PROBE_Y, z)
			if #workspace:GetPartBoundsInRadius(probe, 0.5, overlap) == 0 then
				local down = cast(probe, Vector3.new(0, -1, 0), FLOOR_PROBE_LENGTH)
				if down ~= nil then
					local candidate = Vector3.new(x, down.Position.Y + eyeHeight, z)
					if #workspace:GetPartBoundsInRadius(candidate, 0.5, overlap) == 0 then
						return candidate, true
					end
				elseif inOpeningColumn(volumes, x, z) then
					report.openings.cells += 1
					report.openings.count += 1
					mark(GREEN, probe)
					return nil, true
				else
					report.noFloor += 1
					defect({ kind = "noFloor", where = where, position = probe })
					return nil, true
				end
			end
		end
		return nil, false
	end

	for _, entry in ipairs(chunkFolders) do
		local skip = false
		if aroundCx ~= nil and aroundCz ~= nil then
			skip = math.abs(entry.cx - aroundCx) > radius or math.abs(entry.cz - aroundCz) > radius
		end
		if not skip then
			report.chunks += 1
			for j = 1, chunkCells do
				for i = 1, chunkCells do
					report.cells += 1
					local baseX = entry.cx * chunkStuds + (i - 0.5) * cell
					local baseZ = entry.cz * chunkStuds + (j - 0.5) * cell
					local where = string.format("chunk %d:%d cell %d,%d", entry.cx, entry.cz, i, j)
					local origin, resolved = findEye(baseX, baseZ, where)
					if not resolved then
						report.skippedCells += 1
					end
					if origin ~= nil then
						-- Straight up: must reach a ceiling.
						if cast(origin, up, maxDistance) == nil then
							if anySegmentHits(volumes, origin, up, maxDistance) then
								openingRay(origin)
							else
								report.noCeiling += 1
								defect({
									kind = "noCeiling",
									where = where,
									position = origin,
									direction = up,
								})
							end
						end

						local edges: { [number]: number } = {}
						for _, d in ipairs(dirs) do
							local edge = edges[d.azimuth]
							if edge == nil then
								edge = edgeDistance(origin.X, origin.Z, d.ax, d.az)
								edges[d.azimuth] = edge
							end
							local length = maxDistance
							local limited = false
							if edge ~= NO_EDGE and edge / d.h < maxDistance then
								length = edge / d.h
								limited = true
							end
							if cast(origin, d.dir, length) == nil then
								if anySegmentHits(volumes, origin, d.dir, length) then
									openingRay(origin + d.dir * 4)
								elseif limited and math.abs(d.dir.Y) < 0.5 then
									report.streamEdge.count += 1
									table.insert(edgeLengths, length)
								else
									report.gaps.count += 1
									local sample: Sample = {
										kind = "gap",
										where = where,
										position = origin,
										direction = d.dir,
									}
									addSample(report.gaps.samples, sample)
									defect(sample)
								end
							end
						end
					end
				end
			end

			-- Ramps of this chunk.
			for _, child in ipairs(entry.folder:GetChildren()) do
				if child:IsA("WedgePart") and child:GetAttribute("noclipKind") == "ramp" then
					report.ramps.count += 1
					for _, item in ipairs(checkRamp(child, params, folder)) do
						report.ramps.failures.count += 1
						addSample(report.ramps.failures.samples, item)
						defect(item)
					end
				end
			end
			task.wait()
		end
	end

	if #edgeLengths > 0 then
		local shortest = math.huge
		for _, length in ipairs(edgeLengths) do
			if length < shortest then
				shortest = length
			end
		end
		report.streamEdge.min = shortest
		report.streamEdge.median = median(edgeLengths)
	end
	report.seconds = os.clock() - started
	report.ok = report.gaps.count == 0
		and report.noFloor == 0
		and report.noCeiling == 0
		and report.ramps.failures.count == 0
	return report
end

function GeometryAudit.format(report: Report): string
	local lines: { string } = {}
	local function add(text: string)
		table.insert(lines, text)
	end
	add(
		string.format(
			"[audit] %s  seed %s  %d chunks, %d cells (%d skipped), %d rays, %.1f s",
			if report.ok then "OK" else "FAIL",
			tostring(report.seed),
			report.chunks,
			report.cells,
			report.skippedCells,
			report.rays,
			report.seconds
		)
	)
	add(
		string.format(
			"[audit] gaps %d, noFloor %d, noCeiling %d, ramps %d (failures %d)",
			report.gaps.count,
			report.noFloor,
			report.noCeiling,
			report.ramps.count,
			report.ramps.failures.count
		)
	)
	add(
		string.format(
			"[audit] stream-edge sightlines %d (min %.0f, median %.0f studs); declared openings %d (%d cells, %d rays)",
			report.streamEdge.count,
			report.streamEdge.min,
			report.streamEdge.median,
			report.openings.count,
			report.openings.cells,
			report.openings.rays
		)
	)
	for _, sample in ipairs(report.samples) do
		local direction = ""
		if sample.direction ~= nil then
			direction = string.format(
				" dir (%.2f, %.2f, %.2f)",
				sample.direction.X,
				sample.direction.Y,
				sample.direction.Z
			)
		end
		add(
			string.format(
				"[audit]   %s at %s (%.1f, %.1f, %.1f)%s%s",
				sample.kind,
				sample.where,
				sample.position.X,
				sample.position.Y,
				sample.position.Z,
				direction,
				if sample.detail then " " .. sample.detail else ""
			)
		)
	end
	return table.concat(lines, "\n")
end

-- One-line form for the Workspace attribute.
function GeometryAudit.summary(report: Report): string
	return string.format(
		"%s gaps=%d noFloor=%d noCeiling=%d ramps=%d/%d edge=%d openings=%d chunks=%d",
		if report.ok then "ok" else "FAIL",
		report.gaps.count,
		report.noFloor,
		report.noCeiling,
		report.ramps.count,
		report.ramps.failures.count,
		report.streamEdge.count,
		report.openings.count,
		report.chunks
	)
end

-- Self-test ---------------------------------------------------------------------

export type SelfTestResult = {
	ok: boolean,
	cases: { { name: string, ok: boolean, detail: string } },
	summary: string,
}

-- A closed room exactly one chunk big (288 x 288 x 12) far from the real world,
-- audited three ways. The floor is split so a 16 x 16 hole part exists; the
-- ceiling is two halves so one can be removed.
function GeometryAudit.selfTest(): SelfTestResult
	local cx, cz = 500, 500
	local size = 288
	local ox, oz = cx * size, cz * size
	local root = Instance.new("Folder")
	root.Name = "NoclipAuditSelfTest"
	local chunk = Instance.new("Folder")
	chunk.Name = string.format("chunk_%d:%d", cx, cz)
	chunk.Parent = root

	local function box(name: string, extent: Vector3, center: Vector3): Part
		local part = Instance.new("Part")
		part.Name = name
		part.Anchored = true
		part.Size = extent
		part.Position = center
		part.Parent = chunk
		return part
	end
	local half = size / 2
	box(
		"FloorA",
		Vector3.new(size - 16, 1, size),
		Vector3.new(ox + 16 + (size - 16) / 2, -0.5, oz + half)
	)
	box(
		"FloorB",
		Vector3.new(16, 1, size - 16),
		Vector3.new(ox + 8, -0.5, oz + 16 + (size - 16) / 2)
	)
	local hole = box("FloorHole", Vector3.new(16, 1, 16), Vector3.new(ox + 8, -0.5, oz + 8))
	box("CeilingA", Vector3.new(half, 1, size), Vector3.new(ox + size / 4, 12.5, oz + half))
	local ceilingB =
		box("CeilingB", Vector3.new(half, 1, size), Vector3.new(ox + size * 3 / 4, 12.5, oz + half))
	box("WallW", Vector3.new(2, 14, size + 4), Vector3.new(ox - 1, 6, oz + half))
	box("WallE", Vector3.new(2, 14, size + 4), Vector3.new(ox + size + 1, 6, oz + half))
	box("WallN", Vector3.new(size + 4, 14, 2), Vector3.new(ox + half, 6, oz - 1))
	box("WallS", Vector3.new(size + 4, 14, 2), Vector3.new(ox + half, 6, oz + size + 1))
	root.Parent = workspace

	local cases: { { name: string, ok: boolean, detail: string } } = {}
	local function record(name: string, ok: boolean, report: Report)
		table.insert(cases, { name = name, ok = ok, detail = GeometryAudit.summary(report) })
	end

	local pass, err = pcall(function()
		local opts: Options = { folder = root }
		local closed = GeometryAudit.run(opts)
		record("closed room is ok", closed.ok and closed.cells > 0, closed)

		ceilingB.Parent = nil
		local broken = GeometryAudit.run(opts)
		record(
			"missing ceiling is reported",
			not broken.ok and broken.gaps.count > 0 and broken.noCeiling > 0,
			broken
		)
		ceilingB.Parent = chunk

		hole:SetAttribute(OPENING_TAG, "hole")
		CollectionService:AddTag(hole, OPENING_TAG)
		local opened = GeometryAudit.run(opts)
		record("declared hole is allowed", opened.ok and opened.openings.count > 0, opened)
	end)
	root:Destroy()
	if not pass then
		table.insert(cases, { name = "self-test ran", ok = false, detail = tostring(err) })
	end

	local ok = pass
	local lines: { string } = {}
	for _, case in ipairs(cases) do
		ok = ok and case.ok
		table.insert(
			lines,
			string.format("%s: %s (%s)", if case.ok then "PASS" else "FAIL", case.name, case.detail)
		)
	end
	return { ok = ok, cases = cases, summary = table.concat(lines, "\n") }
end

return GeometryAudit
