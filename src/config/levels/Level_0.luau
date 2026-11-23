--!strict
--
-- Generated from config/levels/level-0.json by scripts/gen-config.luau.
-- Do not edit by hand: edit the JSON and run `lune run scripts/gen-config.luau`.
return {
	["dead_end"] = false,
	["entities"] = {},
	["generate"] = {
		["deadEnds"] = 2,
		["genMs"] = 1500,
		["loops"] = 3,
		["maxLevels"] = 2,
		["regions"] = {
			8,
			14,
		},
		["tiles"] = 480,
	},
	["hazards"] = {
		{
			["gain"] = -24,
			["id"] = "l0.fluorescent-hum",
			["kind"] = "ambient",
		},
	},
	["id"] = "level-0",
	["lighting"] = {
		["ambient"] = "#3a3620",
		["bloom"] = 0.2,
		["clockTime"] = 13,
		["fogEnd"] = 80,
	},
	["props"] = {
		{
			["access"] = "walk",
			["anchor"] = "wall",
			["asset"] = "procedural:wall_outlet",
			["weight"] = 6,
		},
		{
			["access"] = "item:mask",
			["anchor"] = "ceiling",
			["asset"] = "procedural:ceiling_vent",
			["weight"] = 2,
		},
		{
			["access"] = "sealed",
			["anchor"] = "volume",
			["asset"] = "procedural:void_room",
			["weight"] = 1,
		},
	},
	["schema"] = 1,
	["source"] = {
		["note"] = "60-lore/levels/level-0.md",
		["revid"] = 1397338,
	},
	["tileset"] = "lobby",
	["title"] = "Level 0: The Lobby",
	["transitions"] = {
		{
			["gate"] = "phase_wall",
			["id"] = "l0.phase-wall",
			["to"] = "level-1",
		},
		{
			["gate"] = "trigger:vent",
			["id"] = "l0.vent",
			["to"] = "level-0-1",
		},
		{
			["gate"] = "trigger:glass_doors",
			["id"] = "l0.glass-doors",
			["to"] = "level-13",
		},
	},
}
