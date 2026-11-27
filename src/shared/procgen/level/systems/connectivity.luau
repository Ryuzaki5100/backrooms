--!strict

-- Repair: seal open cliffs, join regions with walls then ramps until a repair
-- adds nothing, then settle unreachable pockets. The passes live in the strategy
-- (they share its grid helpers) and arrive through `ctx.passes`, which keeps
-- this module free of a require cycle with OpenAdditive.
--
-- Owns `strategy.params.spawn`: the spawn is picked from the main region this
-- pass establishes.

local Terrain = if script ~= nil
	then require(script.Parent.Parent.Parent.features.Terrain)
	else require("../../features/Terrain")

return {
	id = "connectivity",
	owns = { "strategy.params.spawn" },
	phase = "generate",
	stage = "repair",
	status = "active",
	hooks = {
		generate = function(make: any, layout: any, ctx: any): ()
			local passes = ctx.passes
			local n = layout.n
			local stepMax = Terrain.stepMax(make)
			layout.cliffsSealed = passes.sealOpenCliffs(layout, stepMax)
			-- Walls first, then ramps; a ramp can enlarge the main region, so walls
			-- are opened again until a repair adds nothing (flat worlds stop at once).
			local repaired = 0
			for _ = 1, n * n do
				passes.connect(layout, stepMax)
				local added = passes.repairRamps(make, layout, stepMax)
				repaired += added
				if added == 0 then
					break
				end
			end
			layout.rampsRepaired = repaired
			layout.solidified = passes.settlePockets(make, layout, ctx.enclosedPolicy, stepMax)
		end,
	},
}
