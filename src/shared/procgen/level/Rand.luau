--!strict

-- Namespaced randomness. Every system draws from streams keyed by its own id, so
-- two systems never share a stream and adding a system never shifts another's
-- draws. Features that predate this contract keep their current draws
-- (grandfathered); they migrate in a later task.

local Rng = if script ~= nil then require(script.Parent.Parent.Rng) else require("../Rng")
local Hash = if script ~= nil then require(script.Parent.Parent.Hash) else require("../Hash")
local Common = if script ~= nil
	then require(script.Parent.Parent.features.Common)
	else require("../features/Common")

local Rand = {}

local function namespace(systemId: string, keys: { any }): string
	assert(type(systemId) == "string" and systemId ~= "", "Rand: systemId must be a string")
	local parts = { systemId }
	for _, key in ipairs(keys) do
		table.insert(parts, tostring(key))
	end
	return table.concat(parts, "/")
end

-- A fresh Rng for (seed, systemId, keys). Same inputs, same stream, every run.
function Rand.stream(seed: number, systemId: string, ...: any): Rng.Rng
	local name = namespace(systemId, { ... })
	return Rng.new(Hash.u32("rand:" .. name .. "|" .. string.format("%.0f", seed)))
end

-- One uniform draw in [0, 1) for (seed, systemId, keys), independent of any stream.
function Rand.hash01(seed: number, systemId: string, ...: any): number
	return Common.hash01(seed, "rand:" .. namespace(systemId, { ... }), 0, 0)
end

return Rand
