--!strict

-- Shared helpers for feature modules: coordinate hashing and the wrap helper.
-- Kept here so feature modules do not depend on a strategy, and so the hash
-- finalizer (ADR 0029 note) lives in one place.

local Hash = if script ~= nil then require(script.Parent.Parent.Hash) else require("../Hash")
local World = if script ~= nil then require(script.Parent.Parent.World) else require("../World")

local Common = {}

-- FNV over a coordinate string has poor avalanche; a murmur-style finalizer
-- fixes the low-entropy input without a new hash.
function Common.hash01(seed: number, salt: string, a: number, b: number): number
	local h = Hash.u32(seed .. ":" .. salt .. ":" .. a .. ":" .. b)
	h = Hash.mul32(bit32.bxor(h, bit32.rshift(h, 16)), 2246822507)
	h = Hash.mul32(bit32.bxor(h, bit32.rshift(h, 13)), 3266489909)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h / 4294967296
end

-- A config value is a number or a {min,max} band, drawn once per seed.
function Common.bandValue(rng: any, value: any, fallback: number): number
	if type(value) == "number" then
		return value
	end
	if type(value) == "table" and value[1] ~= nil and value[2] ~= nil then
		return value[1] + rng:nextFloat() * (value[2] - value[1])
	end
	return fallback
end

function Common.canonical(make: any, value: number): number
	if make.boundary == "wrap" then
		return World.wrap(value, make.period)
	end
	return value
end

return Common
