--!strict

-- Versions that participate in a plan hash. Bumping one invalidates every
-- previously generated plan on purpose: a silent change to the generator would
-- be worse than a loud one.
--
-- Three separate axes, because they answer different questions (ADR 0009):
--   SCHEMA_VERSION  the wire format
--   GEN_VERSION     the generator code
--   MACRO_EPOCH     the topology algorithm; bumped only when the graph changes,
--                   so dressing and tile updates keep the same building.

local Version = {
	SCHEMA_VERSION = 1,
	GEN_VERSION = 1,
	MACRO_EPOCH = 1,
}

export type Version = typeof(Version)

return Version
