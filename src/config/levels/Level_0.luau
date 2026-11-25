--!strict
--
-- Generated from config/levels/level-0.json by scripts/gen-config.luau.
-- Do not edit by hand: edit the JSON and run `lune run scripts/gen-config.luau`.
return {
	["dead_end"] = false,
	["entities"] = {},
	["generate"] = {
		["connectivity"] = {
			["corridorBias"] = 0.85,
			["extraChance"] = 0,
			["roomToRoom"] = 0.15,
			["sealedShare"] = 0,
		},
		["connectorForms"] = {
			{
				["kind"] = "hole",
				["weight"] = 70,
			},
			{
				["kind"] = "shaft",
				["weight"] = 30,
			},
		},
		["corridors"] = {
			["maxShare"] = 0.3,
			["minShare"] = 0.2,
		},
		["deadEnds"] = 3,
		["genMs"] = 1500,
		["loopPreference"] = {
			["corridor_corridor"] = 3,
			["corridor_hall"] = 2,
			["room_room"] = 1,
			["vertical"] = 2,
		},
		["loops"] = 4,
		["maxLevels"] = 1,
		["regions"] = {
			14,
			22,
		},
		["tiles"] = 900,
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
	["schema"] = 4,
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
			["outcomes"] = {
				{
					["kind"] = "level",
					["level"] = "level-1",
					["weight"] = 80,
				},
				{
					["kind"] = "level",
					["level"] = "level-0-1",
					["weight"] = 20,
				},
			},
			["resolve"] = "seed",
		},
		{
			["gate"] = "trigger:vent",
			["id"] = "l0.vent",
			["outcomes"] = {
				{
					["kind"] = "level",
					["level"] = "level-0-1",
					["weight"] = 100,
				},
			},
			["resolve"] = "seed",
		},
		{
			["gate"] = "trigger:glass_doors",
			["id"] = "l0.glass-doors",
			["outcomes"] = {
				{
					["kind"] = "level",
					["level"] = "level-13",
					["weight"] = 70,
				},
				{
					["kind"] = "void",
					["weight"] = 30,
				},
			},
			["resolve"] = "seed",
		},
	},
}
