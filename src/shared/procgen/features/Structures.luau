--!strict

-- Structures feature: what a flat zone gets standing on it — a pillar grid or
-- hanging walls. They share one zone hash with two bands (a zone is one or the
-- other), which is what keeps their placement stable and cheap.

local Common = if script ~= nil then require(script.Parent.Common) else require("./Common")
local Layout = if script ~= nil
	then require(script.Parent.Parent.grid.ChunkLayout)
	else require("../grid/ChunkLayout")

local Structures = {}

Structures.id = "structures"

local DEFAULTS = {
	pillar = { share = 0.06, spacing = 2, columnStuds = 2 },
	hang = { share = 0.02, depth = 4, density = 0.35 },
}

-- Whether any structure is configured, so the caller can skip the pass cheaply.
function Structures.enabled(make: any): boolean
	local features = make.params.features or {}
	return features.pillarGrid ~= nil or features.hangingWall ~= nil
end

function Structures.apply(make: any, layout: any): ()
	local features = make.params.features or {}
	if features.pillarGrid == nil and features.hangingWall == nil then
		return
	end
	local pillar = features.pillarGrid or {}
	local hang = features.hangingWall or {}
	local pillarShare = pillar.share or DEFAULTS.pillar.share
	local hangShare = hang.share or DEFAULTS.hang.share
	local n = layout.n
	local originX = layout.cx * n
	local originZ = layout.cz * n

	for j = 1, n do
		for i = 1, n do
			local index = Layout.index(n, i, j)
			local gx = originX + i - 1
			local gz = originZ + j - 1
			local bx = math.floor(Common.canonical(make, gx) / make.block)
			local bz = math.floor(Common.canonical(make, gz) / make.block)
			local roll = Common.hash01(make.seed, "feature", bx, bz)
			-- Mirror of Terrain.tryRamp's structure checks (terrain runs first): all
			-- draws below stay as they are, a ramp cell or a face onto one just
			-- never receives the result. Ramps are off the ring, so a neighbour
			-- outside the chunk is never a ramp.
			local onRamp = layout.ramp[index] ~= nil
			local rampEast = i < n and layout.ramp[Layout.index(n, i + 1, j)] ~= nil
			local rampSouth = j < n and layout.ramp[Layout.index(n, i, j + 1)] ~= nil
			if roll < pillarShare and not layout.solid[index] then
				local spacing = pillar.spacing or DEFAULTS.pillar.spacing
				if (i - 1) % spacing == 0 and (j - 1) % spacing == 0 and not onRamp then
					layout.column[index] = true
				end
				if layout.columnStuds == nil then
					layout.columnStuds = pillar.columnStuds or DEFAULTS.pillar.columnStuds
				end
			elseif roll < pillarShare + hangShare and not layout.solid[index] then
				if layout.hangDepth == nil then
					layout.hangDepth = hang.depth or DEFAULTS.hang.depth
				end
				local density = hang.density or DEFAULTS.hang.density
				if
					not onRamp
					and not rampEast
					and not layout.sealedE[index]
					and Common.hash01(
							make.seed,
							"hang:x",
							Common.canonical(make, gx),
							Common.canonical(make, gz)
						)
						< density
				then
					layout.hangE[index] = true
				end
				if
					not onRamp
					and not rampSouth
					and not layout.sealedS[index]
					and Common.hash01(
							make.seed,
							"hang:z",
							Common.canonical(make, gx),
							Common.canonical(make, gz)
						)
						< density
				then
					layout.hangS[index] = true
				end
			end
		end
	end
end

-- Validation for `strategy.params.features` (moved here from Features, messages
-- unchanged).
function Structures.validate(features: any?): { string }
	local problems: { string } = {}
	local section = features or {}
	if section.pillarGrid ~= nil and (section.pillarGrid.spacing or 0) < 1 then
		table.insert(problems, "features.pillarGrid.spacing: must be >= 1")
	end
	if section.hangingWall ~= nil and (section.hangingWall.depth or 0) < 1 then
		table.insert(problems, "features.hangingWall.depth: must be >= 1")
	end
	return problems
end

return Structures
