--!strict

-- Base terrain: floor heights, ramps and headroom, for every cell world (a flat
-- level still gets its headroom clamp). Draws are unchanged from before the
-- registry (grandfathered, ADR 0033 D74).

local Terrain = if script ~= nil
	then require(script.Parent.Parent.Parent.features.Terrain)
	else require("../../features/Terrain")

return {
	id = "terrain",
	owns = { "strategy.params.terrain" },
	phase = "generate",
	stage = "base",
	status = "active",
	validate = function(section: any, _level: any): { string }
		return Terrain.validate(section)
	end,
	hooks = {
		generate = function(make: any, layout: any, _ctx: any): ()
			Terrain.apply(make, layout)
		end,
	},
}
