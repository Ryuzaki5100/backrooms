--!strict
--
-- Generated from config/levels/level-0.json by scripts/gen-config.luau.
-- Do not edit by hand: edit the JSON and run `lune run scripts/gen-config.luau`.
return {
	["dead_end"] = false,
	["details"] = {
		{
			["chance"] = 0.05,
			["densityCap"] = {
				["perChunk"] = 8,
			},
			["hallMinCells"] = 30,
			["id"] = "ceiling_light",
			["minSpacing"] = 40,
			["prefab"] = "ceiling_light",
			["where"] = {
				"open_hall",
			},
		},
		{
			["chance"] = 0.1,
			["densityCap"] = {
				["perChunk"] = 10,
			},
			["id"] = "wall_stain",
			["minSpacing"] = 24,
			["prefab"] = "wall_stain",
			["where"] = {
				"near_wall",
			},
		},
	},
	["entities"] = {},
	["generate"] = {
		["anchors"] = {
			["max"] = 5,
			["min"] = 3,
		},
		["connectivity"] = {
			["corridorBias"] = 0.6,
			["extraChance"] = 0,
			["roomToRoom"] = 0.55,
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
			["maxShare"] = 0.14,
			["minShare"] = 0.06,
		},
		["deadEnds"] = 3,
		["decoys"] = {
			["share"] = 0.25,
			["trapShare"] = 0.25,
		},
		["exitSeparationShare"] = 0.2,
		["genMs"] = 1500,
		["kindMix"] = {
			["corridor"] = 0.09,
			["hall"] = 0.01,
			["room"] = 0.9,
		},
		["loopPreference"] = {
			["corridor_corridor"] = 3,
			["corridor_hall"] = 2,
			["room_room"] = 1,
			["vertical"] = 2,
		},
		["loopShare"] = 0.35,
		["loops"] = 4,
		["maxLevels"] = 1,
		["openings"] = {
			["height"] = 9,
			["width"] = 10,
		},
		["regions"] = {
			380,
			460,
		},
		["sizes"] = {
			["corridor"] = {
				["d"] = {
					24,
					56,
				},
				["h"] = {
					10,
					12,
				},
				["w"] = {
					8,
					12,
				},
			},
			["hall"] = {
				["d"] = {
					20,
					32,
				},
				["h"] = {
					12,
					14,
				},
				["w"] = {
					24,
					36,
				},
			},
			["room"] = {
				["d"] = {
					14,
					24,
				},
				["h"] = {
					10,
					12,
				},
				["w"] = {
					16,
					28,
				},
			},
			["shaft"] = {
				["d"] = {
					10,
					10,
				},
				["h"] = 32,
				["w"] = {
					10,
					10,
				},
			},
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
	["render"] = {
		["budget"] = {
			["parts"] = 8000,
		},
		["ceiling"] = "slab",
		["enclosure"] = "none",
		["maxLoadedParts"] = 8000,
	},
	["schema"] = 7,
	["source"] = {
		["note"] = "60-lore/levels/level-0.md",
		["revid"] = 1397338,
	},
	["strategy"] = {
		["name"] = "open_additive",
		["params"] = {
			["block"] = 6,
			["cell"] = 16,
			["chunkCells"] = 18,
			["hallBlocks"] = 2,
			["hallShare"] = 0.22,
			["heights"] = {
				10,
				12,
				14,
			},
			["pillarShare"] = 0.25,
			["pillarSize"] = 2,
			["runCount"] = {
				2,
				5,
			},
			["runLength"] = {
				2,
				6,
			},
			["spawn"] = {
				["minOpenFaces"] = 3,
				["openRadiusCells"] = 4,
			},
			["terrain"] = {
				["blocksPerZone"] = 2,
				["level"] = 4,
				["minHeadroom"] = 9,
				["plateauShare"] = 0.16,
				["rampChance"] = 0.35,
				["shallowShare"] = 0.22,
				["stepMax"] = 1,
				["sunkenShare"] = 0.12,
			},
		},
	},
	["style"] = {
		["budget"] = {
			["parts"] = 6000,
		},
	},
	["tileset"] = "lobby",
	["title"] = "Level 0: The Lobby",
	["transitions"] = {
		{
			["gate"] = "phenomenon:phase_wall",
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
	["visibility"] = {
		["farPlane"] = 5000,
		["occluders"] = true,
	},
	["world"] = {
		["boundaryMode"] = "wrap",
		["generationRadius"] = 2,
		["maxChunksPerFrame"] = 2,
		["maxChunksPerSecond"] = 8,
		["maxLoadedChunksPerPlayer"] = 25,
		["sizeTier"] = "vast",
		["unloadRadius"] = 3,
		["walkSpeed"] = 16,
		["wrapMarginChunks"] = 1,
	},
}
