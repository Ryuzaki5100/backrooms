--!strict

-- Legacy strategy: Macro inventory + Embedding (ADR 0025).
--
-- This is not a rewrite. It calls the existing pipeline with exactly the
-- options it used before, so `Plan.bytes` is unchanged and the old levels keep
-- their layouts. Its existence is what lets Level 0 switch strategies without
-- deleting the room/corridor approach.

local Macro = if script ~= nil then require(script.Parent.Parent.Macro) else require("../Macro")
local Embedding = if script ~= nil
	then require(script.Parent.Parent.Embedding)
	else require("../Embedding")

local RoomsAndCorridors = {}

function RoomsAndCorridors.build(config: any, seed: number, options: any?): any
	local generate = config.generate or {}
	local opts = {
		loops = generate.loops,
		loopShare = generate.loopShare,
		loopPreference = generate.loopPreference,
		connectivity = generate.connectivity,
		openings = generate.openings,
		exitSeparationShare = generate.exitSeparationShare,
	}
	for key, value in pairs(options or {}) do
		opts[key] = value
	end
	return Embedding.embed(Macro.build(config, seed), opts)
end

return RoomsAndCorridors
