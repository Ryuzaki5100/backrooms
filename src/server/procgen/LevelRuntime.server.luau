--!strict

-- Level runtime (ADR 0032 A1): the first thing in the game that calls the
-- generator. Loads Level 0, seeds it, builds the spawn block, puts every
-- character on the spawn floor and streams chunks around the players.
--
-- Chunk keys are absolute ("cx:cz", no wrapping); chunk (cx, cz) is placed at
-- (cx * chunkStuds, cz * chunkStuds). Generation wraps by itself, so walking past
-- the world period just meets new absolute keys that generate like old ones.
--
-- Studio-only overrides (never read in a published server):
--   Workspace attribute NoclipSeed (number)       fixes the seed
--   Workspace attribute NoclipTerrainPreview      turns on terrain bands, a preview
--
-- Deliberately minimal: no client code, no teleport on wrap, no transitions.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Build = require(script.Parent.Build)

local Procgen = ReplicatedStorage:WaitForChild("Procgen")
local Config = require(Procgen:WaitForChild("Config"))
local Strategy = require(Procgen:WaitForChild("Strategy"))
local World = require(Procgen:WaitForChild("World"))
local ChunkLayout = require(Procgen:WaitForChild("grid"):WaitForChild("ChunkLayout"))
local ChunkRenderer = require(Procgen:WaitForChild("grid"):WaitForChild("ChunkRenderer"))
local Streaming = require(Procgen:WaitForChild("runtime"):WaitForChild("Streaming"))
local LevelZero =
	ReplicatedStorage:WaitForChild("Config"):WaitForChild("levels"):WaitForChild("Level_0")

local IS_STUDIO = RunService:IsStudio()
local WORLD_FOLDER = "NoclipWorld"
local STATS_INTERVAL = 10
local MAX_SEED = 2147483647

local TERRAIN_PREVIEW = {
	rise = 4,
	plateauShare = 0.15,
	sunkenShare = 0.15,
	rampChance = 0.30,
	minHeadroom = 9,
}

local function clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, inner in pairs(value) do
		copy[key] = clone(inner)
	end
	return copy
end

-- Config, strategy and seed -------------------------------------------------

local config = clone(Config.load(require(LevelZero :: ModuleScript) :: any))

local seed: number = Random.new():NextInteger(1, MAX_SEED)
if IS_STUDIO then
	local override = workspace:GetAttribute("NoclipSeed")
	if type(override) == "number" then
		seed = override
	end
	if workspace:GetAttribute("NoclipTerrainPreview") == true then
		config.strategy.params.terrain = clone(TERRAIN_PREVIEW)
		print("[noclip] terrain bands ON: preview override, not the shipped Level 0 config")
	end
end
workspace:SetAttribute("NoclipActiveSeed", seed)
print(string.format("[noclip] level 0 seed %d", seed))

local strategyName = Strategy.nameOf(config)
if strategyName ~= "open_additive" then
	error(
		"[noclip] LevelRuntime: level 0 uses strategy "
			.. strategyName
			.. ", expected open_additive"
	)
end
local OpenAdditive = Strategy.module(strategyName)
local make = Strategy.build(config, seed)
local size = World.resolve(config)
local chunkStuds = size.chunkSize

local style = config.style or {}
local render = config.render or {}
local renderOptions = {
	style = {
		wallThickness = style.wallThickness or 1,
		budget = (render.budget or {}).parts or 8000,
		materials = style.materials,
	},
	enclosure = render.enclosure,
	worldChunks = size.chunks,
}
local layoutOptions = {
	enclosedPolicy = (config.generate and config.generate.enclosedPolicy) or "solidify",
}

-- World container ------------------------------------------------------------

Build.clear() -- stale Workspace.NoclipBuild from a hand build
local oldWorld = workspace:FindFirstChild(WORLD_FOLDER)
if oldWorld ~= nil then
	oldWorld:Destroy()
end
local worldFolder = Instance.new("Folder")
worldFolder.Name = WORLD_FOLDER
worldFolder.Parent = workspace

-- Chunk building ---------------------------------------------------------------

local worldCfg = config.world or {}
local streamer = Streaming.new({
	chunkStuds = chunkStuds,
	radius = worldCfg.generationRadius,
	unloadRadius = worldCfg.unloadRadius,
	maxPerFrame = worldCfg.maxChunksPerFrame,
	maxPerSecond = worldCfg.maxChunksPerSecond,
	maxLoadedPerPlayer = worldCfg.maxLoadedChunksPerPlayer,
})

local partsByKey: { [string]: number } = {}
local failed: { [string]: boolean } = {}
local totalParts = 0
local builds = 0
local buildSeconds = 0

local function buildChunk(key: string): boolean
	local cx, cz = Streaming.parse(key)
	local started = os.clock()
	local ok, result = pcall(function()
		local layout = OpenAdditive.layout(make, cx, cz, layoutOptions)
		local specs = ChunkRenderer.describe(layout, renderOptions)
		Build.applyChunk(key, specs, worldFolder)
		return #specs
	end)
	if not ok then
		if not failed[key] then
			failed[key] = true
			warn(string.format("[noclip] chunk %s failed: %s", key, tostring(result)))
		end
		return false
	end
	buildSeconds += os.clock() - started
	builds += 1
	partsByKey[key] = result :: number
	totalParts += result :: number
	return true
end

local function unloadChunk(key: string)
	Build.removeChunk(key, worldFolder)
	local count = partsByKey[key]
	if count ~= nil then
		totalParts -= count
		partsByKey[key] = nil
	end
	failed[key] = nil
end

-- Spawn --------------------------------------------------------------------------

local cell = make.cell
local spawnChunkX, spawnChunkZ = 0, 0
local spawnLayout = OpenAdditive.layout(make, spawnChunkX, spawnChunkZ, layoutOptions)
local spawn = OpenAdditive.spawn(make, spawnLayout)
local spawnX, spawnZ, spawnFloorY
if spawn ~= nil then
	spawnX, spawnZ = spawn.x, spawn.z
	local i = spawn.cellX - spawnChunkX * make.n + 1
	local j = spawn.cellZ - spawnChunkZ * make.n + 1
	spawnFloorY = spawnLayout.floorY[ChunkLayout.index(make.n, i, j)] or 0
	print(
		string.format(
			"[noclip] spawn cell %d,%d at %.0f, %.0f (floor %.1f)",
			spawn.cellX,
			spawn.cellZ,
			spawnX,
			spawnZ,
			spawnFloorY
		)
	)
else
	warn("[noclip] no qualifying spawn cell in chunk 0:0; spawning at its centre cell")
	local centre = make.n // 2
	spawnX = (spawnChunkX * make.n + centre + 0.5) * cell
	spawnZ = (spawnChunkZ * make.n + centre + 0.5) * cell
	spawnFloorY = 0
end

-- The 3 x 3 block around the spawn chunk, built before any character is placed.
for dz = -1, 1 do
	for dx = -1, 1 do
		local key = Streaming.key(spawnChunkX + dx, spawnChunkZ + dz)
		buildChunk(key)
		streamer:markLoaded(key)
	end
end

-- Workspace.SpawnLocation is Rojo-managed, so it stays; it only stops being the
-- spawn point and stops being an obstacle inside the level.
local spawnLocation = workspace:FindFirstChild("SpawnLocation")
if spawnLocation ~= nil and spawnLocation:IsA("SpawnLocation") then
	spawnLocation.Enabled = false
	spawnLocation.CanCollide = false
	spawnLocation.CanTouch = false
	spawnLocation.Transparency = 1
end

local function placeCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if
		humanoid == nil
		or root == nil
		or not humanoid:IsA("Humanoid")
		or not root:IsA("BasePart")
	then
		return
	end
	-- Feet on the floor: the root's centre sits HipHeight + half its height above.
	local lift = humanoid.HipHeight + root.Size.Y / 2 + 0.25
	character:PivotTo(CFrame.new(spawnX, spawnFloorY + lift, spawnZ))
end

local function watch(player: Player)
	player.CharacterAdded:Connect(placeCharacter)
	if player.Character ~= nil then
		task.spawn(placeCharacter, player.Character)
	end
end

Players.PlayerAdded:Connect(watch)
for _, player in ipairs(Players:GetPlayers()) do
	watch(player)
end

-- Streaming loop -------------------------------------------------------------------

local sinceStats = 0

RunService.Heartbeat:Connect(function(dt: number)
	local positions = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
		if root ~= nil and root:IsA("BasePart") then
			table.insert(positions, { x = root.Position.X, z = root.Position.Z })
		end
	end

	local toLoad, toUnload = streamer:step(dt, positions)
	for _, key in ipairs(toUnload) do
		unloadChunk(key)
	end
	for _, key in ipairs(toLoad) do
		buildChunk(key)
	end

	if IS_STUDIO then
		sinceStats += dt
		if sinceStats >= STATS_INTERVAL then
			sinceStats = 0
			print(
				string.format(
					"[noclip] loaded %d chunks, %d parts, %.1f ms avg build",
					streamer:loadedCount(),
					totalParts,
					if builds > 0 then buildSeconds / builds * 1000 else 0
				)
			)
		end
	end
end)
