--!strict

-- Macro graph: node inventory only.
--
-- ADR 0015 (pack-first): topology is *derived* from layout, not authored before
-- it. This module decides what exists — how many spaces, of which kinds and
-- sizes, on which levels — and which of them host the spawn and the transitions.
-- Embedding packs them, discovers which ones touch, and turns touching faces
-- into doors.
--
-- Why: an authored graph has no idea about space. We watched it demand doors
-- between rooms that could never touch. Packing first makes contact true by
-- construction.
--
-- Pure Luau: no Roblox APIs.

local Rng = if script ~= nil then require(script.Parent.Rng) else require("./Rng")
local Plan = if script ~= nil then require(script.Parent.Plan) else require("./Plan")
local Config = if script ~= nil then require(script.Parent.Config) else require("./Config")

local Macro = {}

local MAX_ATTEMPTS = 8

local KIND_MIX = {
	{ kind = "room", weight = 6 },
	{ kind = "corridor", weight = 3 },
	{ kind = "hall", weight = 1 },
}

local SIZE = {
	room = { w = { 24, 40 }, h = 18, d = { 24, 40 } },
	corridor = { w = { 10, 12 }, h = 14, d = { 24, 48 } },
	hall = { w = { 48, 72 }, h = 28, d = { 48, 72 } },
	shaft = { w = { 10, 10 }, h = 32, d = { 10, 10 } },
}

local FILLER = {
	room = "wfc",
	corridor = "grammar",
	hall = "recursive",
	shaft = "prefab",
}

local function randBetween(rng: any, low: number, high: number): number
	if high <= low then
		return low
	end
	return low + rng:nextInt(high - low + 1) - 1
end

local function pickWeighted(rng: any, options: { any }, weightOf: (any) -> number): any
	local total = 0
	for _, option in ipairs(options) do
		total += weightOf(option)
	end
	if total <= 0 then
		return options[1]
	end
	local roll = rng:nextInt(total)
	local cursor = 0
	for _, option in ipairs(options) do
		cursor += weightOf(option)
		if roll <= cursor then
			return option
		end
	end
	return options[#options]
end

local function conform(rng: any, node: any, kind: string): ()
	local size = SIZE[kind] or SIZE.room
	node.kind = kind
	node.w = randBetween(rng, size.w[1], size.w[2])
	node.d = randBetween(rng, size.d[1], size.d[2])
	node.h = size.h
	node.filler = FILLER[kind] or "wfc"
	node.params = node.params or {}
end

local function isRoomish(node: any): boolean
	return node.kind == "room" or node.kind == "hall"
end

local function ensureCorridorShare(rng: any, nodes: { any }, generate: any): ()
	local share = generate.corridors
	local minShare, maxShare
	if type(share) == "number" then
		minShare = math.max(0, share - 0.05)
		maxShare = math.min(0.6, share + 0.05)
	else
		minShare = (share and share.minShare) or 0.2
		maxShare = (share and share.maxShare) or 0.3
	end
	local count = #nodes

	local function corridors(): number
		local total = 0
		for _, node in ipairs(nodes) do
			if node.kind == "corridor" then
				total += 1
			end
		end
		return total
	end

	local guard = count * 4
	local low = math.ceil(count * minShare)
	local high = math.max(low, math.floor(count * maxShare))
	while corridors() < low and guard > 0 do
		guard -= 1
		local candidate = nodes[rng:nextInt(count)]
		if candidate.kind == "room" then
			conform(rng, candidate, "corridor")
		end
	end
	while corridors() > high and guard > 0 do
		guard -= 1
		local candidate = nodes[rng:nextInt(count)]
		if candidate.kind == "corridor" then
			conform(rng, candidate, "room")
		end
	end
end

local function resolveOutcome(seed: number, transition: any): any
	local resolve = transition.resolve or "seed"
	local outcomes = transition.outcomes or {}
	if resolve ~= "seed" or #outcomes == 0 then
		return outcomes
	end
	local rng = Rng.new(seed):fork("exit:" .. transition.id)
	local chosen = pickWeighted(rng, outcomes, function(outcome)
		return outcome.weight
	end)
	return { chosen }
end

local function buildOnce(config: any, seed: number, attempt: number): (any?, string?)
	local rng = if attempt == 0
		then Rng.new(seed):fork("macro")
		else Rng.new(seed):fork("macro:retry:" .. attempt)

	local generate = config.generate or {}
	local regions = generate.regions or { 8, 14 }
	local maxLevels = generate.maxLevels or 1

	local count = randBetween(rng, regions[1], regions[2])
	local nodes: { any } = {}
	for id = 1, count do
		local mix = pickWeighted(rng, KIND_MIX, function(option)
			return option.weight
		end)
		-- Upper floors are sparse in v1: only some nodes are raised.
		local level = 0
		if maxLevels >= 2 and id > 1 and rng:nextBool(0.25) then
			level = 1
		end
		local size = SIZE[mix.kind] or SIZE.room
		table.insert(nodes, {
			id = id,
			kind = mix.kind,
			w = randBetween(rng, size.w[1], size.w[2]),
			h = size.h,
			d = randBetween(rng, size.d[1], size.d[2]),
			level = level,
			x = 0,
			y = 0,
			z = 0,
			rotation = 0,
			filler = FILLER[mix.kind] or "wfc",
			params = {},
			ports = {},
			tags = {},
		})
	end

	ensureCorridorShare(rng, nodes, generate)

	local spawnNode = nil
	for _, node in ipairs(nodes) do
		if isRoomish(node) and node.level == 0 then
			spawnNode = node
			break
		end
	end
	if spawnNode == nil then
		return nil, "no room or hall on level 0 for a spawn"
	end
	table.insert(spawnNode.tags, "spawn")

	local exits: { any } = {}
	local transitions = table.clone(config.transitions or {})
	table.sort(transitions, function(a: any, b: any)
		return a.id < b.id
	end)

	local generateOpts = config.generate or {}
	local anchorRange = generateOpts.anchors or { min = 1, max = 1 }
	local decoyPolicy = generateOpts.decoys or { share = 0, trapShare = 0 }

	local hostLoad: { [number]: number } = {}
	local rooms: { any } = {}
	for _, node in ipairs(nodes) do
		if isRoomish(node) and node.level == 0 then
			table.insert(rooms, node)
			hostLoad[node.id] = 0
		end
	end

	-- Pick the least-loaded host that is not already carrying one of this
	-- transition's anchors. Spreading is what makes "keep wandering and you will
	-- find another one" true; on a small level the pool runs out, and then we
	-- reuse the emptiest room rather than failing.
	local function pickHost(exclude: { [number]: boolean }?): any
		local best: { any } = {}
		local bestLoad = math.huge
		for _, node in ipairs(rooms) do
			if not (exclude and exclude[node.id]) then
				local load = hostLoad[node.id] or 0
				if load < bestLoad then
					bestLoad = load
					best = { node }
				elseif load == bestLoad then
					table.insert(best, node)
				end
			end
		end
		if #best == 0 then
			for _, node in ipairs(rooms) do
				local load = hostLoad[node.id] or 0
				if load < bestLoad then
					bestLoad = load
					best = { node }
				elseif load == bestLoad then
					table.insert(best, node)
				end
			end
		end
		if #best == 0 then
			return nil
		end
		local host = best[rng:nextInt(#best)]
		hostLoad[host.id] = (hostLoad[host.id] or 0) + 1
		return host
	end

	local function surfaceFor(gate: string): string
		if string.find(gate, "vent", 1, true) then
			return "ceiling"
		elseif string.find(gate, "fall", 1, true) then
			return "floor"
		end
		return "wall"
	end

	-- Real anchors: several instances per transition, so a run does not depend
	-- on finding one specific place. Every transition keeps at least one.
	for _, transition in ipairs(transitions) do
		local anchorCount =
			randBetween(rng, anchorRange.min or 1, anchorRange.max or (anchorRange.min or 1))
		local used: { [number]: boolean } = {}
		for _ = 1, anchorCount do
			local host = pickHost(used)
			if host == nil then
				return nil, "no host for transition " .. tostring(transition.id)
			end
			used[host.id] = true
			table.insert(exits, {
				id = transition.id,
				gate = transition.gate,
				resolve = transition.resolve or "seed",
				anchor = {
					kind = "spatial",
					hostNode = host.id,
					surface = surfaceFor(transition.gate),
				},
				outcomes = resolveOutcome(seed, transition),
			})
		end
	end

	-- Decoys: exit-shaped features with no binding. They resolve to nothing or,
	-- rarely, to a trap. They never grant mastery. They deliberately may share a
	-- room with a real anchor: one of the two is a lie, and that is the point.
	local decoyCount = math.floor(#nodes * (decoyPolicy.share or 0))
	local trapShare = decoyPolicy.trapShare or 0
	local trapWeight = math.max(1, math.floor(100 * trapShare))
	for index = 1, decoyCount do
		local host = pickHost()
		if host == nil then
			break
		end
		local outcomes = { { kind = "none", weight = 100 - trapWeight } }
		if trapShare > 0 then
			table.insert(outcomes, { kind = "void", weight = trapWeight })
		end
		table.insert(exits, {
			id = "decoy-" .. tostring(index),
			gate = "decoy",
			resolve = "event",
			decoy = true,
			anchor = { kind = "spatial", hostNode = host.id, surface = "wall" },
			outcomes = outcomes,
		})
	end

	return {
		config = config,
		seed = seed,
		nodes = nodes,
		exits = exits,
		spawn = { nodeId = spawnNode.id, surface = "floor" },
	}
end

function Macro.build(config: any, seed: number): any
	if config.dead_end ~= true and #(config.transitions or {}) == 0 then
		error("Macro.build: a level needs a transition unless dead_end is true", 2)
	end

	local lastError = "unknown"
	for attempt = 0, MAX_ATTEMPTS - 1 do
		local built, failure = buildOnce(config, seed, attempt)
		if built ~= nil then
			local specId = tostring(config.id) .. "@" .. Config.fingerprint(config)
			local plan = Plan.new(
				seed,
				specId,
				built.nodes,
				{}, -- edges are derived by Embedding from real adjacency
				{},
				built.exits,
				built.spawn
			)
			return plan
		end
		lastError = tostring(failure)
	end

	error("Macro.build: no valid inventory after " .. MAX_ATTEMPTS .. " attempts: " .. lastError, 2)
end

return Macro
