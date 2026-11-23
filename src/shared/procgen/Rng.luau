--!strict

-- Deterministic PRNG: xoshiro128** over bit32, seeded through a murmur-style
-- mixer. We do not use Roblox's `Random` because its algorithm is an
-- implementation detail, and Lune does not guarantee the same implementation.
-- Owning the generator is what makes "same seed, same plan" provable across
-- Lune, Studio and any future machine.
--
-- Methods take an explicit `self` parameter so `rng:nextInt(6)` works, while
-- the state stays in closures rather than fields.

local function sibling(name: string): any
	if script ~= nil then
		return require((script :: any).Parent[name])
	end
	return (require :: any)("./" .. name)
end

local Hash = sibling("Hash")

local MOD32 = 4294967296

export type Rng = {
	seed: number,
	nextU32: (self: Rng) -> number,
	nextInt: (self: Rng, n: number) -> number,
	nextFloat: (self: Rng) -> number,
	nextBool: (self: Rng, p: number) -> boolean,
	fork: (self: Rng, label: string) -> Rng,
}

local Rng = {}

local function mix(z: number): number
	z = Hash.mul32(z + 2654435769, 2246822507)
	z = bit32.bxor(z, (z - z % 65536) / 65536)
	z = Hash.mul32(z, 3266489909)
	z = bit32.bxor(z, (z - z % 65536) / 65536)
	return z
end

local function initialState(seed: number): (number, number, number, number)
	local state = seed % MOD32
	local words = {}
	for i = 1, 4 do
		state = (state + 2654435769) % MOD32
		words[i] = mix(state + i)
	end
	if words[1] + words[2] + words[3] + words[4] == 0 then
		words[1] = 1
	end
	return words[1], words[2], words[3], words[4]
end

function Rng.new(seed: number): Rng
	assert(seed % 1 == 0, "Rng.new: seed must be an integer")

	local s0, s1, s2, s3 = initialState(seed % MOD32)

	local function nextU32(_self: Rng): number
		local result = Hash.mul32(bit32.lrotate(Hash.mul32(s1, 5), 7), 9)
		local t = bit32.lshift(s1, 9)
		s2 = bit32.bxor(s2, s0)
		s3 = bit32.bxor(s3, s1)
		s1 = bit32.bxor(s1, s2)
		s0 = bit32.bxor(s0, s3)
		s2 = bit32.bxor(s2, t)
		s3 = bit32.lrotate(s3, 11)
		return result
	end

	local function nextInt(_self: Rng, n: number): number
		assert(n >= 1 and n % 1 == 0, "Rng.nextInt: n must be a positive integer")
		-- Rejection sampling keeps the distribution flat; a plain modulo biases
		-- the low range for non-powers of two.
		local limit = MOD32 - (MOD32 % n)
		while true do
			local r = nextU32(_self)
			if r < limit then
				return (r % n) + 1
			end
		end
	end

	local function nextFloat(self: Rng): number
		return nextU32(self) / MOD32
	end

	local function nextBool(self: Rng, p: number): boolean
		assert(p >= 0 and p <= 1, "Rng.nextBool: p must be within [0, 1]")
		return nextFloat(self) < p
	end

	return {
		seed = seed,
		nextU32 = nextU32,
		nextInt = nextInt,
		nextFloat = nextFloat,
		nextBool = nextBool,
		-- Derived from the root seed and a stable label, never from the current
		-- state: adding a stage later must not shift the other stages.
		fork = function(_self: Rng, label: string): Rng
			return Rng.new(Hash.u32(label .. "|" .. string.format("%.0f", seed)))
		end,
	}
end

return Rng
