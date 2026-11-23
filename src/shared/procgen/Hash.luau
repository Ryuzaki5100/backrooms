--!strict

-- FNV-1a 32-bit applied twice with different basis constants, giving a 64-bit
-- fingerprint as 16 hex characters. Also owns `mul32`, because Luau numbers are
-- doubles and there is no native 32-bit multiply.
--
-- No dependencies on purpose: this module is the bottom of the kernel and must
-- be requireable from anywhere.

local Hash = {}

local MOD32 = 4294967296
local FNV_PRIME = 16777619
local BASIS_A = 2166136261
local BASIS_B = 3735928559

-- (a * b) mod 2^32 without losing precision: split into 16-bit halves so every
-- intermediate stays below 2^53.
function Hash.mul32(a: number, b: number): number
	local aLo = a % 65536
	local aHi = (a - aLo) / 65536
	local bLo = b % 65536
	local bHi = (b - bLo) / 65536
	local lo = aLo * bLo
	local mid = (aHi * bLo + aLo * bHi) % 65536
	return (lo + mid * 65536) % MOD32
end

local function fnv1a32(text: string, basis: number): number
	local h = basis
	for i = 1, #text do
		h = bit32.bxor(h, string.byte(text, i))
		h = Hash.mul32(h, FNV_PRIME)
	end
	return h
end

-- Low 32 bits of the fingerprint. Used where a number is needed (seeding).
function Hash.u32(text: string, basis: number?): number
	return fnv1a32(text, basis or BASIS_A)
end

-- 64-bit fingerprint, high half first.
function Hash.of(text: string): string
	return string.format("%08x%08x", fnv1a32(text, BASIS_B), fnv1a32(text, BASIS_A))
end

-- Deterministic string form of a value. Integers only: floats in a plan are a
-- determinism trap, so they are rejected rather than rounded.
function Hash.canonical(value: any): string
	local kind = type(value)
	if kind == "nil" or kind == "boolean" or kind == "string" then
		return kind .. ":" .. tostring(value)
	elseif kind == "number" then
		if value % 1 ~= 0 then
			error("Hash.canonical: non-integer number " .. tostring(value), 2)
		end
		return "n:" .. string.format("%.0f", value)
	elseif kind == "table" then
		local keys = {}
		for key in pairs(value) do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		local parts = {}
		for _, key in ipairs(keys) do
			table.insert(parts, Hash.canonical(key) .. "=" .. Hash.canonical(value[key]))
		end
		return "t{" .. table.concat(parts, ",") .. "}"
	end
	error("Hash.canonical: unsupported type " .. kind, 2)
end

return Hash
