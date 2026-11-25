--!strict

-- World shape: size tiers, wrap arithmetic, chunk addressing (ADR 0026).
--
-- Every number here is derived from config. A level picks a tier and a chunk
-- size; the world size in chunks follows from "how long should one lap take at
-- walk speed", which is the only definition of "enormous" that means anything.
--
-- Pure: no Roblox APIs.

local World = {}

export type Size = {
	tier: string,
	chunks: number,
	chunkSize: number,
	studs: number,
}

-- Target lap time per tier, in seconds. `endless` has no finite size and needs
-- `boundaryMode = "infinite"`.
local TARGET_SECONDS = {
	tiny = 60,
	small = 180,
	medium = 600,
	large = 1800,
	vast = 7200,
}

local TIERS = { "tiny", "small", "medium", "large", "vast", "endless" }

function World.isTier(name: string): boolean
	for _, tier in ipairs(TIERS) do
		if tier == name then
			return true
		end
	end
	return false
end

function World.tiers(): { string }
	return table.clone(TIERS)
end

-- Resolve the configured world into studs and chunks.
function World.resolve(config: any): Size
	local world = config.world or {}
	local cell = (config.strategy and config.strategy.params and config.strategy.params.cell)
		or world.cell
		or 16
	local chunkCells = world.chunkCells or 18
	local chunkSize = cell * chunkCells
	local walkSpeed = world.walkSpeed or 16
	local tier = world.sizeTier or "medium"

	local chunks = world.worldSizeChunks
	if chunks == nil then
		local seconds = TARGET_SECONDS[tier]
		if seconds == nil then
			-- `endless` is unbounded by definition; a boundary mode that wraps
			-- still needs a finite period, so require an explicit override.
			error(
				"World.resolve: sizeTier 'endless' needs boundaryMode 'infinite' or worldSizeChunks",
				2
			)
		end
		chunks = math.max(3, math.ceil(walkSpeed * seconds / chunkSize))
	end
	if chunks < 3 then
		error("World.resolve: worldSizeChunks must be at least 3", 2)
	end

	return {
		tier = tier,
		chunks = chunks,
		chunkSize = chunkSize,
		studs = chunks * chunkSize,
	}
end

function World.wrap(value: number, period: number): number
	return ((value % period) + period) % period
end

-- Minimum toroidal distance between two points. On a wrapped world x = 0 and
-- x = W - 1 are neighbours, so every spatial rule must use this, not subtraction.
function World.distance(ax: number, az: number, bx: number, bz: number, period: number): number
	local dx = math.abs(ax - bx)
	local dz = math.abs(az - bz)
	dx = math.min(dx, period - dx)
	dz = math.min(dz, period - dz)
	return math.sqrt(dx * dx + dz * dz)
end

function World.chunkOf(cell: number, chunkCells: number): number
	return math.floor(cell / chunkCells)
end

-- Canonical cell coordinate for a wrapped world.
function World.wrapCell(value: number, chunks: number, chunkCells: number): number
	return World.wrap(value, chunks * chunkCells)
end

-- Crossing time in seconds for one lap and for the diagonal.
function World.crossing(world: Size, walkSpeed: number?): (number, number)
	local speed = walkSpeed or 16
	local lap = world.studs / speed
	return lap, lap * math.sqrt(2)
end

-- Radius required so the streaming boundary is never inside the visible range,
-- and the parts that costs at a given per-chunk part count.
function World.requiredRadius(visibleStuds: number, chunkSize: number): number
	return math.ceil(visibleStuds / chunkSize) + 1
end

function World.loadedChunks(radius: number): number
	return (radius * 2 + 1) ^ 2
end

return World
