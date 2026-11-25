--!strict

-- Canonical wire format for a generation plan. One logical plan <-> exactly one
-- byte string, which is also what `Plan.hash` fingerprints: the bytes we store
-- are the bytes we hash are the bytes we decode.
--
-- Rules that keep it deterministic:
--   * integers only (floats are rejected, not rounded)
--   * every collection sorted by id, every map sorted by key
--   * lengths are explicit, so a truncated buffer fails instead of misparsing
--
-- The codec is deliberately untyped at its boundary (it takes and returns
-- tables): `Plan` owns the types, this module owns the bytes. That keeps the
-- type alias in one place instead of duplicating it across the module shim.
--
-- Pure Luau: no Roblox APIs, so it runs under Lune.

-- Two static requires instead of a computed path: luau-lsp cannot resolve
-- `require("./" .. name)`, and a computed path also erases the module's types.
local Version = if script ~= nil then require(script.Parent.Version) else require("./Version")

local PlanCodec = {}

local MAGIC = "NPLN"

-- Wire limits. A decode error should be a clear message, not an overflow.
local MAX_NODES = 4096
local MAX_EDGES = 16384
local MAX_CONNECTORS = 4096
local MAX_PORTS = 64
local MAX_PARAMS = 32
local MAX_TAGS = 32
local MAX_STR = 255

local SIDES = { N = 1, E = 2, S = 3, W = 4, U = 5, D = 6 }
local SIDE_BY_INDEX = { "N", "E", "S", "W", "U", "D" }
local GUARDS = { auto = 1, open = 2, sealed = 3 }
local GUARD_BY_INDEX = { "auto", "open", "sealed" }
local ANCHORS = { spatial = 1, object = 2, actor = 3, global = 4 }
local ANCHOR_BY_INDEX = { "spatial", "object", "actor", "global" }
local OUTCOMES = { level = 1, node = 2, class = 3, void = 4, none = 5 }
local OUTCOME_BY_INDEX = { "level", "node", "class", "void", "none" }
local RESOLVES = { seed = 1, run = 2, event = 3 }
local RESOLVE_BY_INDEX = { "seed", "run", "event" }

-- ------------------------------------------------------------------ encoding

local function checkInt(value: any, what: string): number
	if type(value) ~= "number" then
		error(string.format("PlanCodec: %s must be a number, got %s", what, type(value)), 3)
	end
	if value % 1 ~= 0 then
		error(string.format("PlanCodec: %s must be an integer, got %s", what, tostring(value)), 3)
	end
	if value ~= value or value == math.huge or value == -math.huge then
		error(string.format("PlanCodec: %s must be finite", what), 3)
	end
	return value :: number
end

local function u8(value: any, what: string): string
	local n = checkInt(value, what)
	if n < 0 or n > 255 then
		error(string.format("PlanCodec: %s out of u8 range: %s", what, tostring(n)), 3)
	end
	return string.char(n)
end

local function u16(value: any, what: string): string
	local n = checkInt(value, what)
	if n < 0 or n > 65535 then
		error(string.format("PlanCodec: %s out of u16 range: %s", what, tostring(n)), 3)
	end
	local lo = n % 256
	local hi = (n - lo) / 256
	return string.char(lo, hi)
end

local function i32(value: any, what: string): string
	local n = checkInt(value, what)
	if n < -2147483648 or n > 2147483647 then
		error(string.format("PlanCodec: %s out of i32 range: %s", what, tostring(n)), 3)
	end
	if n < 0 then
		n = n + 4294967296
	end
	local lo = n % 65536
	local hi = (n - lo) / 65536
	return u16(lo, what) .. u16(hi, what)
end

local function str(value: any, what: string): string
	if type(value) ~= "string" then
		error(string.format("PlanCodec: %s must be a string, got %s", what, type(value)), 3)
	end
	if #value > MAX_STR then
		error(string.format("PlanCodec: %s longer than %d bytes", what, MAX_STR), 3)
	end
	return u8(#value, what .. ".len") .. value
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys = {}
	for key in pairs(map) do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function sortedById(items: { any }): { any }
	local copy = table.clone(items)
	table.sort(copy, function(a: any, b: any)
		return a.id < b.id
	end)
	return copy
end

local function encodePort(port: any): string
	local sideIndex = SIDES[port.side]
	if sideIndex == nil then
		error(string.format("PlanCodec: unknown port side %q", tostring(port.side)), 3)
	end
	local guardIndex = GUARDS[port.guard or "auto"]
	if guardIndex == nil then
		error(string.format("PlanCodec: unknown guard %q", tostring(port.guard)), 3)
	end
	return table.concat({
		u8(port.id, "port.id"),
		u8(sideIndex, "port.side"),
		u16(port.offset, "port.offset"),
		u8(port.width, "port.width"),
		u16(port.height, "port.height"),
		i32(port.elevation, "port.elevation"),
		str(port.kind, "port.kind"),
		u8(guardIndex, "port.guard"),
		str(port.hazardId or "", "port.hazardId"),
	})
end

local function encodeParams(params: { [string]: number }?): string
	local map = params or {}
	local keys = sortedKeys(map)
	if #keys > MAX_PARAMS then
		error(string.format("PlanCodec: too many params (%d > %d)", #keys, MAX_PARAMS), 2)
	end
	local parts = { u8(#keys, "params.count") }
	for _, key in ipairs(keys) do
		table.insert(parts, str(key, "params.key"))
		table.insert(parts, i32(map[key], "params." .. key))
	end
	return table.concat(parts)
end

local function encodeNode(node: any): string
	local ports = sortedById(node.ports or {})
	local tags: { string } = table.clone(node.tags or {})
	table.sort(tags)
	if #ports > MAX_PORTS then
		error(string.format("PlanCodec: node %s has too many ports", tostring(node.id)), 2)
	end
	if #tags > MAX_TAGS then
		error(string.format("PlanCodec: node %s has too many tags", tostring(node.id)), 2)
	end
	local parts = {
		u16(node.id, "node.id"),
		str(node.kind, "node.kind"),
		u16(node.w, "node.w"),
		u16(node.h, "node.h"),
		u16(node.d, "node.d"),
		u8(node.level, "node.level"),
		i32(node.x or 0, "node.x"),
		i32(node.y or 0, "node.y"),
		i32(node.z or 0, "node.z"),
		u8(node.rotation or 0, "node.rotation"),
		str(node.filler or "none", "node.filler"),
		encodeParams(node.params),
		u8(#ports, "node.ports"),
	}
	for _, port in ipairs(ports) do
		table.insert(parts, encodePort(port))
	end
	table.insert(parts, u8(#tags, "node.tags"))
	for _, tag in ipairs(tags) do
		table.insert(parts, str(tag, "node.tag"))
	end
	return table.concat(parts)
end

local function encodeEdge(edge: any): string
	return table.concat({
		u16(edge.id, "edge.id"),
		u16(edge.a, "edge.a"),
		u16(edge.b, "edge.b"),
		u8(edge.aPort, "edge.aPort"),
		u8(edge.bPort, "edge.bPort"),
		str(edge.kind or "passage", "edge.kind"),
	})
end

local function encodeConnector(connector: any): string
	return table.concat({
		u16(connector.id, "connector.id"),
		str(connector.kind, "connector.kind"),
		u16(connector.fromNode, "connector.fromNode"),
		u8(connector.fromPort, "connector.fromPort"),
		u16(connector.toNode, "connector.toNode"),
		u8(connector.toPort, "connector.toPort"),
		encodeParams(connector.params),
	})
end

local function encodeSpawn(spawn: any): string
	local value = spawn or { nodeId = 0, surface = "floor" }
	return u16(value.nodeId or 0, "spawn.nodeId") .. str(value.surface or "", "spawn.surface")
end

local function encodeAnchor(anchor: any): string
	local kindIndex = ANCHORS[anchor.kind]
	if kindIndex == nil then
		error(string.format("PlanCodec: unknown anchor kind %q", tostring(anchor.kind)), 3)
	end
	local hasNode = anchor.hostNode ~= nil and 1 or 0
	local hasEdge = anchor.hostEdge ~= nil and 1 or 0
	local parts = { u8(kindIndex, "anchor.kind"), u8(hasNode, "anchor.hasNode") }
	if hasNode == 1 then
		table.insert(parts, u16(anchor.hostNode, "anchor.hostNode"))
	end
	table.insert(parts, u8(hasEdge, "anchor.hasEdge"))
	if hasEdge == 1 then
		table.insert(parts, u16(anchor.hostEdge, "anchor.hostEdge"))
	end
	table.insert(parts, str(anchor.surface or "", "anchor.surface"))
	table.insert(parts, str(anchor.ref or "", "anchor.ref"))
	return table.concat(parts)
end

local function encodeOutcome(outcome: any): string
	local kindIndex = OUTCOMES[outcome.kind]
	if kindIndex == nil then
		error(string.format("PlanCodec: unknown outcome kind %q", tostring(outcome.kind)), 3)
	end
	return table.concat({
		u8(kindIndex, "outcome.kind"),
		i32(outcome.weight, "outcome.weight"),
		str(outcome.level or "", "outcome.level"),
		u16(outcome.node or 0, "outcome.node"),
		str(outcome.predicate or "", "outcome.predicate"),
	})
end

local function encodeExit(exit: any): string
	local kindIndex = RESOLVES[exit.resolve or "seed"]
	if kindIndex == nil then
		error(string.format("PlanCodec: unknown resolve mode %q", tostring(exit.resolve)), 3)
	end
	local outcomes = exit.outcomes or {}
	if #outcomes > 4 then
		error(string.format("PlanCodec: exit %s has too many outcomes", tostring(exit.id)), 3)
	end
	local parts = {
		str(exit.id, "exit.id"),
		str(exit.gate, "exit.gate"),
		encodeAnchor(exit.anchor),
		u8(kindIndex, "exit.resolve"),
		u8(if exit.decoy then 1 else 0, "exit.decoy"),
		u8(#outcomes, "exit.outcomes"),
	}
	for _, outcome in ipairs(outcomes) do
		table.insert(parts, encodeOutcome(outcome))
	end
	return table.concat(parts)
end

function PlanCodec.encode(plan: any): string
	local nodes: { any } = sortedById(plan.nodes or {})
	local edges: { any } = sortedById(plan.edges or {})
	local connectors: { any } = sortedById(plan.connectors or {})

	if #nodes > MAX_NODES then
		error("PlanCodec: too many nodes", 2)
	end
	if #edges > MAX_EDGES then
		error("PlanCodec: too many edges", 2)
	end
	if #connectors > MAX_CONNECTORS then
		error("PlanCodec: too many connectors", 2)
	end

	local parts = {
		MAGIC,
		u16(plan.schemaVersion, "schemaVersion"),
		u16(plan.genVersion, "genVersion"),
		u16(plan.macroEpoch or 1, "macroEpoch"),
		i32(plan.seed, "seed"),
		str(plan.specId, "specId"),
		u16(plan.floorHeight or 0, "floorHeight"),
		u16(plan.plenum or 0, "plenum"),
		u16(#nodes, "nodes.count"),
	}
	for _, node in ipairs(nodes) do
		table.insert(parts, encodeNode(node))
	end
	table.insert(parts, u16(#edges, "edges.count"))
	for _, edge in ipairs(edges) do
		table.insert(parts, encodeEdge(edge))
	end
	table.insert(parts, u16(#connectors, "connectors.count"))
	for _, connector in ipairs(connectors) do
		table.insert(parts, encodeConnector(connector))
	end
	table.insert(parts, encodeSpawn(plan.spawn))
	local exits: { any } = sortedById(plan.exits or {})
	table.insert(parts, u16(#exits, "exits.count"))
	for _, exit in ipairs(exits) do
		table.insert(parts, encodeExit(exit))
	end
	return table.concat(parts)
end

-- ------------------------------------------------------------------ decoding

function PlanCodec.decode(buffer: string): any
	if type(buffer) ~= "string" then
		error("PlanCodec: decode expects a string", 2)
	end

	local pos = 1
	local function take(count: number): string
		if pos + count - 1 > #buffer then
			error(string.format("PlanCodec: truncated at byte %d (needed %d)", pos, count), 2)
		end
		local slice = string.sub(buffer, pos, pos + count - 1)
		pos = pos + count
		return slice
	end

	local function readU8(): number
		return string.byte(take(1)) :: number
	end

	local function readU16(): number
		local lo, hi = string.byte(take(2), 1, 2)
		return (lo :: number) + (hi :: number) * 256
	end

	local function readI32(): number
		local lo = readU16()
		local hi = readU16()
		local value = lo + hi * 65536
		if value >= 2147483648 then
			value = value - 4294967296
		end
		return value
	end

	local function readStr(what: string): string
		local length = readU8()
		if length > MAX_STR then
			error(string.format("PlanCodec: %s longer than %d bytes", what, MAX_STR), 2)
		end
		return take(length)
	end

	local function readParams(what: string): { [string]: number }
		local count = readU8()
		if count > MAX_PARAMS then
			error(string.format("PlanCodec: %s has too many params", what), 2)
		end
		local params: { [string]: number } = {}
		for _ = 1, count do
			local key = readStr(what .. ".key")
			params[key] = readI32()
		end
		return params
	end

	local magic = take(#MAGIC)
	if magic ~= MAGIC then
		error("PlanCodec: not a plan buffer", 2)
	end

	local schemaVersion = readU16()
	if schemaVersion ~= Version.PLAN_SCHEMA_VERSION then
		error(
			string.format(
				"PlanCodec: unsupported schema version %d (this build understands %d)",
				schemaVersion,
				Version.PLAN_SCHEMA_VERSION
			),
			2
		)
	end

	local plan: any = {
		schemaVersion = schemaVersion,
		genVersion = readU16(),
		macroEpoch = readU16(),
		seed = readI32(),
		specId = readStr("specId"),
		floorHeight = readU16(),
		plenum = readU16(),
		nodes = {},
		edges = {},
		connectors = {},
		exits = {},
	}

	local nodeCount = readU16()
	if nodeCount > MAX_NODES then
		error("PlanCodec: too many nodes", 2)
	end
	local seenNodes: { [number]: boolean } = {}
	for _ = 1, nodeCount do
		local node: any = {
			id = readU16(),
			kind = readStr("node.kind"),
			w = readU16(),
			h = readU16(),
			d = readU16(),
			level = readU8(),
			x = readI32(),
			y = readI32(),
			z = readI32(),
			rotation = readU8(),
			filler = readStr("node.filler"),
			params = readParams("node.params"),
			ports = {},
			tags = {},
		}
		if seenNodes[node.id] then
			error(string.format("PlanCodec: duplicate node id %d", node.id), 2)
		end
		seenNodes[node.id] = true

		local portCount = readU8()
		if portCount > MAX_PORTS then
			error("PlanCodec: too many ports on a node", 2)
		end
		local seenPorts: { [number]: boolean } = {}
		for _ = 1, portCount do
			local portId = readU8()
			local sideIndex = readU8()
			local side = SIDE_BY_INDEX[sideIndex]
			if side == nil then
				error(string.format("PlanCodec: unknown port side index %d", sideIndex), 2)
			end
			local offset = readU16()
			local width = readU8()
			local height = readU16()
			local elevation = readI32()
			local portKind = readStr("port.kind")
			local guardIndex = readU8()
			local guard = GUARD_BY_INDEX[guardIndex]
			if guard == nil then
				error(string.format("PlanCodec: unknown guard index %d", guardIndex), 2)
			end
			local port: any = {
				id = portId,
				side = side,
				offset = offset,
				width = width,
				height = height,
				elevation = elevation,
				kind = portKind,
				guard = guard,
			}
			local hazardId = readStr("port.hazardId")
			if hazardId ~= "" then
				port.hazardId = hazardId
			end
			if seenPorts[port.id] then
				error(
					string.format("PlanCodec: duplicate port id %d on node %d", port.id, node.id),
					2
				)
			end
			seenPorts[port.id] = true
			table.insert(node.ports, port)
		end

		local tagCount = readU8()
		if tagCount > MAX_TAGS then
			error("PlanCodec: too many tags on a node", 2)
		end
		for _ = 1, tagCount do
			table.insert(node.tags, readStr("node.tag"))
		end
		table.insert(plan.nodes, node)
	end

	local edgeCount = readU16()
	if edgeCount > MAX_EDGES then
		error("PlanCodec: too many edges", 2)
	end
	for _ = 1, edgeCount do
		local edge: any = {
			id = readU16(),
			a = readU16(),
			b = readU16(),
			aPort = readU8(),
			bPort = readU8(),
			kind = readStr("edge.kind"),
		}
		if not seenNodes[edge.a] or not seenNodes[edge.b] then
			error(string.format("PlanCodec: edge %d references a missing node", edge.id), 2)
		end
		table.insert(plan.edges, edge)
	end

	local connectorCount = readU16()
	if connectorCount > MAX_CONNECTORS then
		error("PlanCodec: too many connectors", 2)
	end
	for _ = 1, connectorCount do
		local connector: any = {
			id = readU16(),
			kind = readStr("connector.kind"),
			fromNode = readU16(),
			fromPort = readU8(),
			toNode = readU16(),
			toPort = readU8(),
			params = readParams("connector.params"),
		}
		if not seenNodes[connector.fromNode] or not seenNodes[connector.toNode] then
			error(
				string.format("PlanCodec: connector %d references a missing node", connector.id),
				2
			)
		end
		table.insert(plan.connectors, connector)
	end

	local spawnNode = readU16()
	local spawnSurface = readStr("spawn.surface")
	plan.spawn = { nodeId = spawnNode, surface = spawnSurface }

	local exitCount = readU16()
	local seenExits: { [string]: boolean } = {}
	for _ = 1, exitCount do
		local exitId = readStr("exit.id")
		if seenExits[exitId] then
			error(string.format("PlanCodec: duplicate exit id %q", exitId), 2)
		end
		seenExits[exitId] = true
		local gate = readStr("exit.gate")

		local anchorKindIndex = readU8()
		local anchorKind = ANCHOR_BY_INDEX[anchorKindIndex]
		if anchorKind == nil then
			error(string.format("PlanCodec: unknown anchor kind index %d", anchorKindIndex), 2)
		end
		local anchor: any = { kind = anchorKind }
		if readU8() == 1 then
			anchor.hostNode = readU16()
		end
		if readU8() == 1 then
			anchor.hostEdge = readU16()
		end
		local surface = readStr("anchor.surface")
		if surface ~= "" then
			anchor.surface = surface
		end
		local ref = readStr("anchor.ref")
		if ref ~= "" then
			anchor.ref = ref
		end

		local resolveIndex = readU8()
		local resolve = RESOLVE_BY_INDEX[resolveIndex]
		if resolve == nil then
			error(string.format("PlanCodec: unknown resolve index %d", resolveIndex), 2)
		end
		local decoyFlag = readU8() == 1

		local outcomes = {}
		local outcomeCount = readU8()
		if outcomeCount > 4 then
			error("PlanCodec: too many outcomes on an exit", 2)
		end
		for _ = 1, outcomeCount do
			local outcomeKindIndex = readU8()
			local outcomeKind = OUTCOME_BY_INDEX[outcomeKindIndex]
			if outcomeKind == nil then
				error(
					string.format("PlanCodec: unknown outcome kind index %d", outcomeKindIndex),
					2
				)
			end
			local outcome: any = {
				kind = outcomeKind,
				weight = readI32(),
			}
			local level = readStr("outcome.level")
			if level ~= "" then
				outcome.level = level
			end
			local node = readU16()
			if node ~= 0 then
				outcome.node = node
			end
			local predicate = readStr("outcome.predicate")
			if predicate ~= "" then
				outcome.predicate = predicate
			end
			table.insert(outcomes, outcome)
		end

		local exit = {
			id = exitId,
			gate = gate,
			resolve = resolve,
			anchor = anchor,
			outcomes = outcomes,
		}
		-- Only present when true, so a decoded plan is deep-equal to the source.
		if decoyFlag then
			exit.decoy = true
		end
		table.insert(plan.exits, exit)
	end

	if pos <= #buffer then
		error(string.format("PlanCodec: %d trailing bytes", #buffer - pos + 1), 2)
	end

	return plan
end

return PlanCodec
