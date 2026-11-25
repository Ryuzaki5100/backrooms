--!strict

-- Macro graph: the skeleton of a level, before any geometry exists.
--
-- Pure topology: no Roblox APIs, so it runs under Lune and in CI (ADR 0010 §8).
--
-- What it produces (ADR 0010):
--   nodes       spaces with nominal dimensions and 6-faced ports
--   edges       deterministic connections; the only thing connectivity counts
--   connectors  physical movers for vertical links that need one
--   exits       anchors (node or edge) with weighted outcomes
--   spawn       one deterministic entry point per seed
--
-- Floors are `node.level`. Vertical links are edges (a hole) or, when the
-- connector form says so, a connector node with its own interior. The form is a
-- weighted generation-time choice, so the topology stays provable while the
-- fiction stays "maybe it's just a hole".

local Rng = if script ~= nil then require(script.Parent.Rng) else require("./Rng")
local Plan = if script ~= nil then require(script.Parent.Plan) else require("./Plan")
local Config = if script ~= nil then require(script.Parent.Config) else require("./Config")

local Macro = {}

local MAX_ATTEMPTS = 8

-- Region mix. Weights, not counts: the count comes from the config range.
local KIND_MIX = {
	{ kind = "room", weight = 6 },
	{ kind = "corridor", weight = 3 },
	{ kind = "hall", weight = 1 },
}

local MAX_DEGREE = {
	room = 4,
	corridor = 3,
	hall = 6,
	shaft = 2,
}

local SIZE = {
	room = { w = { 16, 24 }, h = 12, d = { 16, 24 } },
	corridor = { w = { 8, 8 }, h = 10, d = { 16, 32 } },
	hall = { w = { 32, 48 }, h = 16, d = { 32, 48 } },
	shaft = { w = { 8, 8 }, h = 24, d = { 8, 8 } },
}

local FILLER = {
	room = "wfc",
	corridor = "grammar",
	hall = "recursive",
	shaft = "prefab",
}

local HORIZONTAL_SIDES = { "N", "E", "S", "W" }

-- ----------------------------------------------------------------- helpers

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

local function degreeOf(node: any): number
	return #node.ports
end

local function canConnect(node: any): boolean
	return degreeOf(node) < (MAX_DEGREE[node.kind] or 4)
end

local function makeNode(rng: any, id: number, kind: string, level: number): any
	local size = SIZE[kind] or SIZE.room
	return {
		id = id,
		kind = kind,
		w = randBetween(rng, size.w[1], size.w[2]),
		h = size.h,
		d = randBetween(rng, size.d[1], size.d[2]),
		level = level,
		x = 0,
		y = 0,
		z = 0,
		rotation = 0,
		filler = FILLER[kind] or "wfc",
		params = {},
		ports = {},
		tags = {},
	}
end

local function portHeight(kind: string, node: any, openings: any): number
	if kind == "shaft" or kind == "drop" then
		return node.h -- full face: a hole, not a doorway
	end
	return (openings and openings[kind]) or (openings and openings.door) or 8
end

local function addPort(node: any, side: string, kind: string, height: number): number
	local elevated = side == "U" or side == "D"
	local width = if elevated then 3 else 4
	local span = if elevated then 0 elseif side == "N" or side == "S" then node.w else node.d
	local port = {
		id = #node.ports + 1,
		side = side,
		offset = if elevated then 0 else math.max(0, math.floor((span - width) / 2)),
		width = width,
		height = math.min(height, node.h),
		elevation = 0,
		kind = kind,
		guard = "auto",
	}
	table.insert(node.ports, port)
	return port.id
end

local function nextHorizontalSide(node: any): string
	local used = 0
	for _, port in ipairs(node.ports) do
		if port.side == "N" or port.side == "E" or port.side == "S" or port.side == "W" then
			used += 1
		end
	end
	return HORIZONTAL_SIDES[(used % #HORIZONTAL_SIDES) + 1]
end

local function connect(
	edges: { any },
	a: any,
	b: any,
	kind: string,
	vertical: boolean,
	openings: any
): boolean
	if not canConnect(a) or not canConnect(b) then
		return false
	end
	local aKind = if vertical then "shaft" else "door"
	local bKind = if vertical then "drop" else "door"
	local aPort = addPort(
		a,
		if vertical then "U" else nextHorizontalSide(a),
		aKind,
		portHeight(aKind, a, openings)
	)
	local bPort = addPort(
		b,
		if vertical then "D" else nextHorizontalSide(b),
		bKind,
		portHeight(bKind, b, openings)
	)
	table.insert(edges, {
		id = #edges + 1,
		a = a.id,
		b = b.id,
		aPort = aPort,
		bPort = bPort,
		kind = kind,
	})
	return true
end

local function adjacent(edges: { any }, a: number, b: number): boolean
	for _, edge in ipairs(edges) do
		if (edge.a == a and edge.b == b) or (edge.a == b and edge.b == a) then
			return true
		end
	end
	return false
end

local function isRoomish(node: any): boolean
	return node.kind == "room" or node.kind == "hall"
end

-- ---------------------------------------------------------------- outcomes

local function resolveOutcome(seed: number, transition: any): any
	local resolve = transition.resolve or "seed"
	local outcomes = transition.outcomes or {}
	if resolve ~= "seed" or #outcomes == 0 then
		return outcomes
	end
	-- Choose one destination now, from a fork that depends only on seed + id.
	local rng = Rng.new(seed):fork("exit:" .. transition.id)
	local chosen = pickWeighted(rng, outcomes, function(outcome)
		return outcome.weight
	end)
	return { chosen }
end

-- ----------------------------------------------------------------- growing

local function buildOnce(config: any, seed: number, attempt: number): (any?, string?)
	local rng = if attempt == 0
		then Rng.new(seed):fork("macro")
		else Rng.new(seed):fork("macro:retry:" .. attempt)

	local generate = config.generate or {}
	local regions = generate.regions or { 8, 14 }
	local maxLevels = generate.maxLevels or 1
	local loopTarget = generate.loops or 0
	local deadEndTarget = generate.deadEnds or 0
	local openings = (config.style and config.style.openings) or nil

	local nodes: { any } = {}
	local edges: { any } = {}
	local connectors: { any } = {}

	local count = randBetween(rng, regions[1], regions[2])
	for id = 1, count do
		local mix = pickWeighted(rng, KIND_MIX, function(option)
			return option.weight
		end)
		local level = 0
		if maxLevels >= 2 and id > 1 and rng:nextBool(0.3) then
			level = 1
		end
		table.insert(nodes, makeNode(rng, id, mix.kind, level))
	end

	-- Spawn: first room-ish node on the ground floor.
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

	-- Spanning growth: every new node attaches to an earlier reachable one.
	for index = 2, count do
		local child = nodes[index]
		local attached = false
		for _ = 1, 12 do
			local parent = nodes[rng:nextInt(index - 1)]
			if parent ~= nil and canConnect(parent) and canConnect(child) then
				local vertical = parent.level ~= child.level
				if
					connect(
						edges,
						parent,
						child,
						if vertical then "drop" else "passage",
						vertical,
						openings
					)
				then
					attached = true
					break
				end
			end
		end
		if not attached then
			return nil, "could not attach node " .. tostring(child.id)
		end
	end

	-- Dead ends: extra leaves that exist to be wrong turns.
	for _ = 1, deadEndTarget do
		local workspace = nil
		for _ = 1, 12 do
			local candidate = nodes[rng:nextInt(#nodes)]
			if canConnect(candidate) then
				workspace = candidate
				break
			end
		end
		if workspace == nil then
			break -- not fatal; the level just has fewer dead ends
		end
		local leaf = makeNode(rng, #nodes + 1, "room", workspace.level)
		table.insert(leaf.tags, "dead-end")
		table.insert(nodes, leaf)
		if not connect(edges, workspace, leaf, "passage", false, openings) then
			table.remove(nodes)
		end
	end

	-- Loop edges: exactly the configured count, never breaking degree bounds.
	for _ = 1, loopTarget do
		local added = false
		for _ = 1, 64 do
			local a = nodes[rng:nextInt(#nodes)]
			local b = nodes[rng:nextInt(#nodes)]
			if
				a ~= nil
				and b ~= nil
				and a.id ~= b.id
				and a.level == b.level
				and not adjacent(edges, a.id, b.id)
				and canConnect(a)
				and canConnect(b)
			then
				if connect(edges, a, b, "passage", false, openings) then
					added = true
					break
				end
			end
		end
		if not added then
			return nil, "could not add loop " .. tostring(loopTarget)
		end
	end

	-- Exits: one anchor per declared transition, on a reachable host.
	local usedHosts: { [number]: boolean } = {}
	local exits: { any } = {}
	local transitions = table.clone(config.transitions or {})
	table.sort(transitions, function(a: any, b: any)
		return a.id < b.id
	end)

	for _, transition in ipairs(transitions) do
		local host = nil
		for _ = 1, 64 do
			local candidate = nodes[rng:nextInt(#nodes)]
			if isRoomish(candidate) and not usedHosts[candidate.id] then
				host = candidate
				break
			end
		end
		if host == nil then
			return nil, "no free host for transition " .. tostring(transition.id)
		end
		usedHosts[host.id] = true

		local surface = "wall"
		if string.find(transition.gate, "vent", 1, true) then
			surface = "ceiling"
		elseif string.find(transition.gate, "fall", 1, true) then
			surface = "floor"
		end

		local resolved = resolveOutcome(seed, transition)
		table.insert(exits, {
			id = transition.id,
			gate = transition.gate,
			resolve = transition.resolve or "seed",
			anchor = { kind = "spatial", hostNode = host.id, surface = surface },
			outcomes = resolved,
		})
	end

	return {
		config = config,
		seed = seed,
		nodes = nodes,
		edges = edges,
		connectors = connectors,
		exits = exits,
		spawn = { nodeId = spawnNode.id, surface = "floor" },
	}
end

-- -------------------------------------------------------------- validation

local function reachableFrom(nodes: { any }, edges: { any }, startId: number): { [number]: boolean }
	local adjacency: { [number]: { number } } = {}
	for _, node in ipairs(nodes) do
		adjacency[node.id] = {}
	end
	for _, edge in ipairs(edges) do
		if adjacency[edge.a] and adjacency[edge.b] then
			table.insert(adjacency[edge.a], edge.b)
			table.insert(adjacency[edge.b], edge.a)
		end
	end

	local seen: { [number]: boolean } = { [startId] = true }
	local queue = { startId }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, neighbour in ipairs(adjacency[current] or {}) do
			if not seen[neighbour] then
				seen[neighbour] = true
				table.insert(queue, neighbour)
			end
		end
	end
	return seen
end

function Macro.validate(plan: any): { string }
	local problems: { string } = {}
	local nodesById: { [number]: any } = {}
	for _, node in ipairs(plan.nodes) do
		if nodesById[node.id] then
			table.insert(problems, "duplicate node id " .. tostring(node.id))
		end
		nodesById[node.id] = node
		if degreeOf(node) > (MAX_DEGREE[node.kind] or 4) then
			table.insert(problems, "node " .. tostring(node.id) .. " exceeds its degree bound")
		end
	end

	for _, edge in ipairs(plan.edges) do
		local a = nodesById[edge.a]
		local b = nodesById[edge.b]
		if a == nil or b == nil then
			table.insert(problems, "edge " .. tostring(edge.id) .. " references a missing node")
		else
			if a.ports[edge.aPort] == nil or b.ports[edge.bPort] == nil then
				table.insert(problems, "edge " .. tostring(edge.id) .. " references a missing port")
			end
		end
	end

	local spawn = plan.spawn
	if spawn == nil or spawn.nodeId == 0 or nodesById[spawn.nodeId] == nil then
		table.insert(problems, "spawn node is missing")
		return problems
	end

	local seen = reachableFrom(plan.nodes, plan.edges, spawn.nodeId)
	for _, node in ipairs(plan.nodes) do
		if not seen[node.id] then
			table.insert(problems, "node " .. tostring(node.id) .. " is unreachable")
		end
	end

	if not isRoomish(nodesById[spawn.nodeId]) then
		table.insert(problems, "spawn must be a room or hall")
	end

	local exitIds: { [string]: boolean } = {}
	for _, exit in ipairs(plan.exits) do
		if exitIds[exit.id] then
			table.insert(problems, "duplicate exit id " .. tostring(exit.id))
		end
		exitIds[exit.id] = true
		if exit.anchor.hostNode ~= nil and not seen[exit.anchor.hostNode] then
			table.insert(problems, "exit " .. exit.id .. " is anchored to an unreachable node")
		end
		if #exit.outcomes == 0 then
			table.insert(problems, "exit " .. exit.id .. " has no outcomes")
		end
		for _, outcome in ipairs(exit.outcomes) do
			if outcome.kind == "node" and nodesById[outcome.node] == nil then
				table.insert(problems, "exit " .. exit.id .. " points at a missing node")
			end
		end
	end

	return problems
end

-- -------------------------------------------------------------------- entry

function Macro.build(config: any, seed: number): any
	if config.dead_end ~= true and #(config.transitions or {}) == 0 then
		error("Macro.build: a level needs a transition unless dead_end is true", 2)
	end

	local lastError = "unknown"
	for attempt = 0, MAX_ATTEMPTS - 1 do
		local built, failure = buildOnce(config, seed, attempt)
		if built ~= nil then
			local problems = Macro.validate(built)
			if #problems == 0 then
				local specId = tostring(config.id) .. "@" .. Config.fingerprint(config)
				return Plan.new(
					seed,
					specId,
					built.nodes,
					built.edges,
					built.connectors,
					built.exits,
					built.spawn
				)
			end
			lastError = table.concat(problems, "; ")
		else
			lastError = tostring(failure)
		end
	end

	error("Macro.build: no valid graph after " .. MAX_ATTEMPTS .. " attempts: " .. lastError, 2)
end

return Macro
