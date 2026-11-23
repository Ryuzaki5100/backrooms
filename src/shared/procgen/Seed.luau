--!strict

-- Seed codes are the only human-facing representation of a world. Six base36
-- characters, uppercase, zero-padded: short enough to type, wide enough for
-- ~2.18 billion seeds. The integer stays the internal truth.

local Seed = {}

local ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

Seed.LENGTH = 6
-- 36^6 - 1. Beyond this a code would need a seventh character.
Seed.MAX = 2176782335

function Seed.format(seed: number): string
	assert(seed % 1 == 0, "Seed.format: seed must be an integer")
	assert(seed >= 0 and seed <= Seed.MAX, "Seed.format: seed out of range")
	local digits = {}
	local n = seed
	for _ = 1, Seed.LENGTH do
		local d = n % 36
		table.insert(digits, 1, string.sub(ALPHABET, d + 1, d + 1))
		n = (n - d) / 36
	end
	return table.concat(digits)
end

-- Returns (seed, nil) or (nil, errorMessage). Accepts lowercase, internal
-- whitespace and a leading '#' so pasted codes just work.
function Seed.parse(code: string): (number?, string?)
	local cleaned = string.upper(string.gsub(code, "%s", ""))
	cleaned = string.gsub(cleaned, "^#", "")
	if #cleaned == 0 then
		return nil, "seed is empty"
	end
	if #cleaned > Seed.LENGTH then
		return nil, string.format("seed is longer than %d characters", Seed.LENGTH)
	end
	local value = 0
	for i = 1, #cleaned do
		local ch = string.sub(cleaned, i, i)
		local index = string.find(ALPHABET, ch, 1, true)
		if not index then
			return nil, string.format("invalid character '%s' in seed", ch)
		end
		value = value * 36 + (index - 1)
	end
	return value, nil
end

function Seed.random(rng: any): number
	return rng:nextInt(Seed.MAX + 1) - 1
end

-- World identity is the pair (generator version, seed). A layout is allowed to
-- change when the generator does; the code alone does not promise stability.
function Seed.identity(seed: number, genVersion: number): string
	return string.format("%s-v%d", Seed.format(seed), genVersion)
end

return Seed
