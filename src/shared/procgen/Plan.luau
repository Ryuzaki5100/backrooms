--!strict

-- The plan is the pure, serializable output of generation. It knows nothing
-- about Roblox instances, places, teleports or players, which is what lets the
-- whole generator be tested under Lune.
--
-- Shape (ADR 0009):
--   nodes       spaces; a corridor is a node, not an edge
--   ports       6-faced boundaries: N/E/S/W/U/D, with width, offset and guard
--   edges       connections between ports
--   connectors  vertical movers (stairs, ramps, drops, shafts) as objects with
--               their own footprint and params
--
-- Sizes are integer studs. No floats anywhere: the codec rejects them, because a
-- float makes "same plan" ambiguous.
--
-- Canonical form is the codec's byte string, and `hash` fingerprints exactly
-- those bytes. There is no second serialization to drift out of sync.

-- Two static requires instead of a computed path: luau-lsp cannot resolve
-- `require("./" .. name)`, and a computed path also erases the module's types.
local Hash = if script ~= nil then require(script.Parent.Hash) else require("./Hash")
local Version = if script ~= nil then require(script.Parent.Version) else require("./Version")
local Seed = if script ~= nil then require(script.Parent.Seed) else require("./Seed")
local Codec = if script ~= nil then require(script.Parent.PlanCodec) else require("./PlanCodec")

export type Side = "N" | "E" | "S" | "W" | "U" | "D"
export type Guard = "auto" | "open" | "sealed"

export type Port = {
	id: number,
	side: Side,
	offset: number,
	width: number,
	height: number, -- opening height in studs
	elevation: number,
	kind: string,
	guard: Guard,
	hazardId: string?,
}

export type Node = {
	id: number,
	kind: string,
	w: number,
	h: number,
	d: number,
	level: number,
	x: number,
	y: number,
	z: number,
	rotation: number, -- yaw in 90-degree steps; port sides are relative to it
	filler: string,
	params: { [string]: number },
	ports: { Port },
	tags: { string },
}

export type Edge = {
	id: number,
	a: number,
	b: number,
	aPort: number,
	bPort: number,
	kind: string,
}

export type Connector = {
	id: number,
	kind: string,
	fromNode: number,
	fromPort: number,
	toNode: number,
	toPort: number,
	params: { [string]: number },
}

export type Outcome = {
	weight: number,
	kind: string, -- level | node | class | void
	level: string?,
	node: number?,
	predicate: string?,
}

export type Anchor = {
	kind: string, -- spatial | object | actor | global
	hostNode: number?,
	hostEdge: number?,
	surface: string?,
	ref: string?,
}

export type Exit = {
	id: string,
	gate: string,
	resolve: string, -- seed | run | event
	anchor: Anchor,
	outcomes: { Outcome },
}

export type Spawn = {
	nodeId: number, -- 0 means unset (tooling/tests only)
	surface: string,
}

export type Plan = {
	schemaVersion: number,
	genVersion: number,
	macroEpoch: number,
	seed: number,
	specId: string,
	floorHeight: number,
	plenum: number,
	nodes: { Node },
	edges: { Edge },
	connectors: { Connector },
	exits: { Exit },
	spawn: Spawn,
}

local Plan = {}

function Plan.new(
	seed: number,
	specId: string,
	nodes: { Node }?,
	edges: { Edge }?,
	connectors: { Connector }?,
	exits: { Exit }?,
	spawn: Spawn?,
	floorHeight: number?,
	plenum: number?
): Plan
	return {
		schemaVersion = Version.PLAN_SCHEMA_VERSION,
		genVersion = Version.GEN_VERSION,
		macroEpoch = Version.MACRO_EPOCH,
		seed = seed,
		specId = specId,
		floorHeight = floorHeight or 0,
		plenum = plenum or 0,
		nodes = nodes or {},
		edges = edges or {},
		connectors = connectors or {},
		exits = exits or {},
		spawn = spawn or { nodeId = 0, surface = "floor" },
	}
end

-- Canonical bytes from the codec: everything that identifies a plan is in them.
function Plan.bytes(plan: Plan): string
	return Codec.encode(plan)
end

function Plan.hash(plan: Plan): string
	return Hash.of(Plan.bytes(plan))
end

-- Human/debug identity: the seed code the player typed plus the generator
-- version. Not a fingerprint of the layout; `hash` is that.
function Plan.identity(plan: Plan): string
	return Seed.identity(plan.seed, plan.genVersion)
end

return Plan
