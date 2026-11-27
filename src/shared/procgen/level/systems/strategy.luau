--!strict

-- The strategy section minus the parts a generation system owns itself
-- (`terrain`, `features`, `spawn`; see terrain, structures and connectivity).
-- Validates the ceiling bands, which read both of those sections.

local Features = if script ~= nil
	then require(script.Parent.Parent.Parent.features.Features)
	else require("../../features/Features")

return {
	id = "strategy",
	owns = {
		"strategy.name",
		"strategy.params.cell",
		"strategy.params.chunkCells",
		"strategy.params.block",
		"strategy.params.pillarShare",
		"strategy.params.pillarSize",
		"strategy.params.runCount",
		"strategy.params.runLength",
		"strategy.params.hallShare",
		"strategy.params.hallBlocks",
		"strategy.params.heights",
		"strategy.params.ceiling",
	},
	phase = "generate",
	stage = "base",
	status = "active",
	validate = function(_section: any, level: any): { string }
		return Features.validateCeiling(level)
	end,
}
