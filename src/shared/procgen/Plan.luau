--!strict

-- The plan is the pure, serializable output of generation. It knows nothing
-- about Roblox instances, places, teleports or players, which is what lets the
-- whole generator be tested under Lune.
--
-- Milestone M1 only needs the identity surface: construction, canonical form and
-- hash. Node and edge types land in M3/M4.

local function sibling(name: string): any
	if script ~= nil then
		return require((script :: any).Parent[name])
	end
	return (require :: any)("./" .. name)
end

local Hash = sibling("Hash")
local Version = sibling("Version")
local Seed = sibling("Seed")

export type Plan = {
	schemaVersion: number,
	genVersion: number,
	seed: number,
	specId: string,
	nodes: { any },
	edges: { any },
}

local Plan = {}

function Plan.new(seed: number, specId: string, nodes: { any }?, edges: { any }?): Plan
	return {
		schemaVersion = Version.SCHEMA_VERSION,
		genVersion = Version.GEN_VERSION,
		seed = seed,
		specId = specId,
		nodes = nodes or {},
		edges = edges or {},
	}
end

-- Canonical form: versions first, then seed and spec, then the body. Changing
-- key order in the plan itself must not change the hash.
function Plan.canonical(plan: Plan): string
	return Hash.canonical({
		plan.schemaVersion,
		plan.genVersion,
		plan.seed,
		plan.specId,
		plan.nodes,
		plan.edges,
	})
end

function Plan.hash(plan: Plan): string
	return Hash.of(Plan.canonical(plan))
end

function Plan.identity(plan: Plan): string
	return Seed.identity(plan.seed, plan.genVersion)
end

return Plan
