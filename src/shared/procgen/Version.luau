--!strict

-- Versions that participate in a plan hash. Bumping one invalidates every
-- previously generated plan on purpose: a silent change to the generator would
-- be worse than a loud one.
--
-- Separate axes, because they answer different questions (ADR 0009, 0010):
--   CONFIG_SCHEMA_VERSION  level config format
--   PLAN_SCHEMA_VERSION    plan wire format
--   GEN_VERSION            the generator code
--   MACRO_EPOCH            the topology algorithm; bumped only when the graph
--                          changes, so dressing updates keep the same building.

local Version = {
	CONFIG_SCHEMA_VERSION = 2,
	PLAN_SCHEMA_VERSION = 4,
	GEN_VERSION = 1,
	MACRO_EPOCH = 1,
}

export type Version = typeof(Version)

return Version
