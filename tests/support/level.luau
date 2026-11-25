--!strict

-- One source of truth for "how do the tests ask the generator to build Level 0".
-- Duplicating these tables per spec is how the exit-separation check silently
-- stopped running: QA was told a style but never told the separation.

local Level0 = require("../../src/config/levels/Level_0")

local Level = {}

Level.config = Level0

function Level.embedOptions(overrides: any?): any
	local generate = Level0.generate
	local options = {
		loops = generate.loops,
		loopShare = generate.loopShare,
		loopPreference = generate.loopPreference,
		connectivity = generate.connectivity,
		openings = generate.openings,
		exitSeparationShare = generate.exitSeparationShare,
	}
	for key, value in pairs(overrides or {}) do
		options[key] = value
	end
	return options
end

function Level.qaOptions(overrides: any?): any
	local options = {
		style = Level0.style,
		transitions = Level0.transitions,
		separationShare = Level0.generate.exitSeparationShare,
	}
	for key, value in pairs(overrides or {}) do
		options[key] = value
	end
	return options
end

return Level
