--!strict

-- Chunk streaming policy (ADR 0027, ADR 0032 A1).
--
-- Decides WHICH chunks should exist around the players and in what order to
-- build them. It owns no geometry and touches no Roblox service: the caller
-- passes player positions in and gets load/unload key lists out, so the policy
-- is testable under Lune.
--
-- Keys are ABSOLUTE chunk coordinates, "cx:cz", with no wrapping. Generation
-- wraps by itself (a chunk at cx + worldChunks generates identically to cx), so
-- the runtime places chunk (cx, cz) at (cx * chunkStuds, cz * chunkStuds) and a
-- player walking past the period simply keeps meeting new absolute keys.
--
-- Chunk (cx, cz) covers x in [cx * chunkStuds, (cx + 1) * chunkStuds), same for z.
--
-- Shape: a SQUARE of `radius` chunks around each player's chunk (radius 2 is the
-- 5 x 5 block, 25 chunks). Load and unload use the same Chebyshev metric, so
-- hysteresis is a plain band: a chunk at Chebyshev distance in (radius,
-- unloadRadius] from its nearest player is neither wanted nor evicted.
--
-- Budgets. `maxPerFrame` bounds the loads one `step` returns; `maxPerSecond` is a
-- token bucket (capacity `maxPerSecond`, refilled by `dt * maxPerSecond`, full at
-- the start) so a burst never exceeds the long-run rate. Unloads are not
-- budgeted: removing a Folder is cheap and delaying it only costs memory.
--
-- A chunk returned by `step` is recorded as loaded at once. If the caller's build
-- fails it stays recorded (no retry storm); the caller reports it once.

local Streaming = {}
Streaming.__index = Streaming

export type Options = {
	chunkStuds: number,
	radius: number?, -- generationRadius, in chunks (default 2)
	unloadRadius: number?, -- in chunks, never below radius (default radius + 1)
	maxPerFrame: number?, -- loads per step (default unlimited)
	maxPerSecond: number?, -- loads per second, token bucket (default unlimited)
	maxLoadedPerPlayer: number?, -- cap on chunks wanted around one player
}

export type Position = { x: number, z: number }

export type Streamer = typeof(setmetatable(
	{} :: {
		chunkStuds: number,
		radius: number,
		unloadRadius: number,
		maxPerFrame: number,
		maxPerSecond: number,
		maxLoadedPerPlayer: number,
		tokens: number,
		loaded: { [string]: boolean },
		count: number,
	},
	Streaming
))

function Streaming.key(cx: number, cz: number): string
	return cx .. ":" .. cz
end

function Streaming.parse(key: string): (number, number)
	local a, b = string.match(key, "^(-?%d+):(-?%d+)$")
	if a == nil or b == nil then
		error("Streaming.parse: bad chunk key " .. tostring(key), 2)
	end
	return tonumber(a) :: number, tonumber(b) :: number
end

-- Chunk containing a world coordinate (absolute, negative-safe).
function Streaming.chunkOf(coord: number, chunkStuds: number): number
	return math.floor(coord / chunkStuds)
end

function Streaming.new(opts: Options): Streamer
	if type(opts.chunkStuds) ~= "number" or opts.chunkStuds <= 0 then
		error("Streaming.new: chunkStuds must be a positive number", 2)
	end
	local radius = math.max(0, math.floor(opts.radius or 2))
	local unloadRadius = math.max(radius, math.floor(opts.unloadRadius or radius + 1))
	local maxPerSecond = opts.maxPerSecond or math.huge
	local self = {
		chunkStuds = opts.chunkStuds,
		radius = radius,
		unloadRadius = unloadRadius,
		maxPerFrame = opts.maxPerFrame or math.huge,
		maxPerSecond = maxPerSecond,
		maxLoadedPerPlayer = opts.maxLoadedPerPlayer or math.huge,
		tokens = maxPerSecond,
		loaded = {},
		count = 0,
	}
	return setmetatable(self, Streaming)
end

-- Squared distance from a position to the centre of a chunk, in studs.
local function distanceSq(self: Streamer, p: Position, cx: number, cz: number): number
	local half = self.chunkStuds / 2
	local dx = (cx * self.chunkStuds + half) - p.x
	local dz = (cz * self.chunkStuds + half) - p.z
	return dx * dx + dz * dz
end

-- Smallest squared distance from any player to the chunk centre.
local function nearest(self: Streamer, positions: { Position }, cx: number, cz: number): number
	local best = math.huge
	for _, p in ipairs(positions) do
		best = math.min(best, distanceSq(self, p, cx, cz))
	end
	return best
end

-- Chunks one player wants: the square of `radius`, nearest-first, cut to the cap.
local function wantedAround(self: Streamer, p: Position): { string }
	local pcx = Streaming.chunkOf(p.x, self.chunkStuds)
	local pcz = Streaming.chunkOf(p.z, self.chunkStuds)
	local list: { { key: string, d: number } } = {}
	for dz = -self.radius, self.radius do
		for dx = -self.radius, self.radius do
			local cx, cz = pcx + dx, pcz + dz
			table.insert(list, { key = Streaming.key(cx, cz), d = distanceSq(self, p, cx, cz) })
		end
	end
	table.sort(list, function(a, b)
		if a.d ~= b.d then
			return a.d < b.d
		end
		return a.key < b.key
	end)
	local keys = {}
	for index = 1, math.min(#list, self.maxLoadedPerPlayer) do
		keys[index] = list[index].key
	end
	return keys
end

-- The set of chunk keys that should be loaded for these players.
function Streaming.desired(self: Streamer, positions: { Position }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, p in ipairs(positions) do
		for _, key in ipairs(wantedAround(self, p)) do
			set[key] = true
		end
	end
	return set
end

function Streaming.isLoaded(self: Streamer, key: string): boolean
	return self.loaded[key] == true
end

function Streaming.loadedCount(self: Streamer): number
	return self.count
end

-- Loaded keys, sorted (a copy).
function Streaming.loadedKeys(self: Streamer): { string }
	local keys = {}
	for key in pairs(self.loaded) do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

-- Record a chunk the caller built outside `step` (the synchronous spawn block).
function Streaming.markLoaded(self: Streamer, key: string): ()
	if not self.loaded[key] then
		self.loaded[key] = true
		self.count += 1
	end
end

-- Chebyshev distance, in chunks, from a chunk to the nearest player's chunk.
local function chunkDistance(
	self: Streamer,
	positions: { Position },
	cx: number,
	cz: number
): number
	local best = math.huge
	for _, p in ipairs(positions) do
		local pcx = Streaming.chunkOf(p.x, self.chunkStuds)
		local pcz = Streaming.chunkOf(p.z, self.chunkStuds)
		best = math.min(best, math.max(math.abs(cx - pcx), math.abs(cz - pcz)))
	end
	return best
end

-- Advance by `dt` seconds. Returns (toLoad, toUnload): keys the caller must build
-- and remove, already recorded as loaded and unloaded.
--
-- Loads: wanted but not loaded, nearest to any player first (ties by key), cut to
-- min(maxPerFrame, whole tokens). Unloads: loaded chunks farther than
-- `unloadRadius` chunks from every player, farthest first (ties by key). With no
-- players nothing changes: there is no one to measure distance from, and a
-- respawn gap must not wipe the world.
function Streaming.step(
	self: Streamer,
	dt: number,
	positions: { Position }
): ({ string }, { string })
	local limited = self.maxPerSecond ~= math.huge
	if limited then
		self.tokens = math.min(self.maxPerSecond, self.tokens + dt * self.maxPerSecond)
	end
	if #positions == 0 then
		return {}, {}
	end

	local pending: { { key: string, d: number } } = {}
	for key in pairs(Streaming.desired(self, positions)) do
		if not self.loaded[key] then
			local cx, cz = Streaming.parse(key)
			table.insert(pending, { key = key, d = nearest(self, positions, cx, cz) })
		end
	end
	table.sort(pending, function(a, b)
		if a.d ~= b.d then
			return a.d < b.d
		end
		return a.key < b.key
	end)

	local allowed = math.min(self.maxPerFrame, #pending)
	if limited then
		allowed = math.min(allowed, math.floor(self.tokens))
	end
	local toLoad = {}
	for index = 1, allowed do
		local key = pending[index].key
		toLoad[index] = key
		self.loaded[key] = true
		self.count += 1
	end
	if limited then
		self.tokens -= allowed
	end

	local far: { { key: string, d: number } } = {}
	for key in pairs(self.loaded) do
		local cx, cz = Streaming.parse(key)
		local distance = chunkDistance(self, positions, cx, cz)
		if distance > self.unloadRadius then
			table.insert(far, { key = key, d = distance })
		end
	end
	table.sort(far, function(a, b)
		if a.d ~= b.d then
			return a.d > b.d
		end
		return a.key < b.key
	end)
	local toUnload = {}
	for index, entry in ipairs(far) do
		toUnload[index] = entry.key
		self.loaded[entry.key] = nil
		self.count -= 1
	end

	return toLoad, toUnload
end

return Streaming
