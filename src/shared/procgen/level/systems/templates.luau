--!strict

-- Gated set-piece templates. They reserve ground after structures, so a set
-- piece is never placed on a pillar or under a hanging wall.

local Template = if script ~= nil
	then require(script.Parent.Parent.Parent.features.Template)
	else require("../../features/Template")

return {
	id = "templates",
	owns = { "templates" },
	phase = "generate",
	stage = "gated",
	after = { "structures" },
	status = "active",
	hooks = {
		generate = function(make: any, layout: any, _ctx: any): ()
			if Template.enabled(make) then
				Template.apply(make, layout)
			end
		end,
	},
}
