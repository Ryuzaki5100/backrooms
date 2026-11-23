--!strict

-- Versions that participate in a plan hash. Bumping either invalidates every
-- previously generated plan on purpose: a silent change to the generator would
-- be worse than a loud one.

local Version = {
	SCHEMA_VERSION = 1,
	GEN_VERSION = 1,
}

export type Version = typeof(Version)

return Version
