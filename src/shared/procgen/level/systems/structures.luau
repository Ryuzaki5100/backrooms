--!strict

-- Gated structures: pillar grids and hanging walls, only when configured.

local Structures = if script ~= nil
	then require(script.Parent.Parent.Parent.features.Structures)
	else require("../../features/Structures")

return {
	id = "structures",
	owns = { "strategy.params.features" },
	phase = "generate",
	stage = "gated",
	status = "active",
	validate = function(section: any, _level: any): { string }
		return Structures.validate(section)
	end,
	hooks = {
		generate = function(make: any, layout: any, _ctx: any): ()
			if Structures.enabled(make) then
				Structures.apply(make, layout)
			end
		end,
	},
}
