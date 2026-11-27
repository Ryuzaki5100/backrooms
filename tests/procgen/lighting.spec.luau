--!strict

-- Lighting system (task 0029): profile resolver defaults, validation, Level 0.

local H = require("../harness")
local lighting = require("../../src/shared/procgen/level/systems/lighting") :: any
local Level0 = require("../../src/config/levels/Level_0")

local function has(problems: { string }, needle: string): boolean
	for _, message in ipairs(problems) do
		if string.find(message, needle, 1, true) ~= nil then
			return true
		end
	end
	return false
end

H.test("lighting: resolve fills defaults for missing keys", function()
	local p = lighting.resolve({ clockTime = 9 })
	H.eq(p.clockTime, 9)
	H.eq(p.brightness, 2)
	H.eq(p.ambient, "#000000")
	H.eq(p.outdoorAmbient, "#000000", "follows ambient")
	H.eq(p.fogStart, 0)
	H.eq(p.fogEnd, 100000)
	H.eq(p.fogColor, "#000000", "follows ambient")
	H.eq(p.exposure, 0)
	H.eq(p.globalShadows, true)
	H.eq(p.environmentDiffuseScale, 0)
	H.eq(p.environmentSpecularScale, 0)
	H.eq(p.bloom, 0)
	H.eq(p.atmosphere, nil)
	H.eq(p.colorCorrection, nil)
end)

H.test("lighting: nested groups resolve with defaults", function()
	local p = lighting.resolve({
		clockTime = 1,
		ambient = "#102030",
		atmosphere = { density = 0.5 },
		colorCorrection = { saturation = -0.2 },
	})
	H.eq(p.outdoorAmbient, "#102030")
	H.eq(p.atmosphere.density, 0.5)
	H.eq(p.atmosphere.haze, 0)
	H.eq(p.atmosphere.color, "#c7c7c7")
	H.eq(p.colorCorrection.saturation, -0.2)
	H.eq(p.colorCorrection.tintColor, "#ffffff")
end)

H.test("lighting: Level 0 resolves to its declared values", function()
	local p = lighting.resolve(Level0.lighting)
	H.eq(p.clockTime, 13)
	H.eq(p.fogEnd, 80)
	H.eq(p.bloom, 0.2)
	H.eq(p.ambient, "#3a3620")
	H.eq(p.outdoorAmbient, "#3a3620")
	H.eq(p.fogColor, "#3a3620")
	H.eq(#lighting.validate(Level0.lighting), 0)
	print(
		string.format(
			"  [lighting] Level 0: clock %s bright %s ambient %s outdoor %s fog %s..%s %s exp %s shadows %s diff %s spec %s bloom %s",
			p.clockTime,
			p.brightness,
			p.ambient,
			p.outdoorAmbient,
			p.fogStart,
			p.fogEnd,
			p.fogColor,
			p.exposure,
			tostring(p.globalShadows),
			p.environmentDiffuseScale,
			p.environmentSpecularScale,
			p.bloom
		)
	)
end)

H.test("lighting: validation reports bad hex, ranges, types and fog order", function()
	H.ok(has(lighting.validate({ clockTime = 12, ambient = "3a3620" }), "lighting.ambient"), "hex")
	H.ok(
		has(lighting.validate({ clockTime = 12, fogColor = "#12345" }), "lighting.fogColor"),
		"hex"
	)
	H.ok(has(lighting.validate({ clockTime = 25 }), "lighting.clockTime"), "range")
	H.ok(has(lighting.validate({ clockTime = 1, bloom = 3 }), "lighting.bloom"), "range")
	H.ok(has(lighting.validate({ clockTime = "noon" }), "expected a number"), "type")
	H.ok(has(lighting.validate({ clockTime = 1, globalShadows = 1 }), "globalShadows"), "bool")
	H.ok(has(lighting.validate("dusk"), "lighting: expected a table"), "section type")
	H.ok(
		has(lighting.validate({ clockTime = 1, fogStart = 90, fogEnd = 80 }), "fogStart"),
		"fogStart >= fogEnd"
	)
	H.ok(
		has(
			lighting.validate({ clockTime = 1, atmosphere = { color = "red" } }),
			"atmosphere.color"
		),
		"nested hex"
	)
	H.eq(#lighting.validate({ clockTime = 1, fogStart = 10, fogEnd = 80 }), 0, "valid fog")
end)
