--!strict

-- Golden plan: the fixture M03/M04 round-trips and hashes. Keep it small but
-- shaped like a real level: two floors, a door, a sealed shaft, a guarded drop,
-- a stair connector, a deterministic exit and a volatile one with two outcomes.

return {
	plan = {
		schemaVersion = 2,
		genVersion = 1,
		macroEpoch = 1,
		seed = 42,
		specId = "level-0@0000000000000000",
		spawn = { nodeId = 1, surface = "floor" },
		nodes = {
			{
				id = 1,
				kind = "room",
				w = 20,
				h = 12,
				d = 18,
				level = 0,
				filler = "wfc",
				params = { cell = 4, offset = -2 },
				ports = {
					{
						id = 1,
						side = "N",
						offset = 8,
						width = 4,
						elevation = 0,
						kind = "door",
						guard = "auto",
					},
					{
						id = 2,
						side = "U",
						offset = 6,
						width = 3,
						elevation = 0,
						kind = "shaft",
						guard = "sealed",
						hazardId = "void",
					},
				},
				tags = { "lobby", "yellow" },
			},
			{
				id = 2,
				kind = "corridor",
				w = 8,
				h = 10,
				d = 24,
				level = 0,
				filler = "grammar",
				params = { turn = 1 },
				ports = {
					{
						id = 1,
						side = "S",
						offset = 2,
						width = 4,
						elevation = 0,
						kind = "door",
						guard = "auto",
					},
					{
						id = 2,
						side = "W",
						offset = 10,
						width = 6,
						elevation = 0,
						kind = "door",
						guard = "auto",
					},
				},
				tags = {},
			},
			{
				id = 3,
				kind = "room",
				w = 16,
				h = 12,
				d = 16,
				level = 1,
				filler = "prefab",
				params = {},
				ports = {
					{
						id = 1,
						side = "D",
						offset = 6,
						width = 3,
						elevation = 14,
						kind = "shaft",
						guard = "open",
						hazardId = "drop",
					},
				},
				tags = { "upper" },
			},
		},
		edges = {
			{ id = 1, a = 1, b = 2, aPort = 1, bPort = 1, kind = "passage" },
		},
		connectors = {
			{
				id = 1,
				kind = "stairs",
				fromNode = 2,
				fromPort = 2,
				toNode = 3,
				toPort = 1,
				params = { run = 16, rise = 14, width = 6, headroom = 10 },
			},
		},
		exits = {
			{
				id = "l0.holes",
				gate = "action:fall",
				resolve = "seed",
				anchor = { kind = "spatial", hostEdge = 1, surface = "floor" },
				outcomes = {
					{ kind = "node", node = 3, weight = 60 },
					{ kind = "void", weight = 40 },
				},
			},
			{
				id = "l0.vent",
				gate = "trigger:vent",
				resolve = "seed",
				anchor = { kind = "spatial", hostNode = 1, surface = "ceiling" },
				outcomes = {
					{ kind = "level", level = "level-0-1", weight = 100 },
				},
			},
		},
	},

	-- Filled from the first deterministic run; re-baselining is a deliberate act.
	bytesLen = 447,
	bytesHex = "4e504c4e0200010001002a000000186c6576656c2d3040303030303030303030303030303030300300010004726f6f6d14000c0012000003776663020463656c6c04000000066f6666736574feffffff0201010800040000000004646f6f7201000205060003000000000573686166740304766f696402056c6f6262790679656c6c6f77020008636f727269646f7208000a00180000076772616d6d617201047475726e010000000201030200040000000004646f6f72010002040a00060000000004646f6f72010000030004726f6f6d10000c0010000106707265666162000101060600030e000000057368616674020464726f70010575707065720100010001000200010107706173736167650100010006737461697273020002030001040868656164726f6f6d0a00000004726973650e0000000372756e1000000005776964746806000000010005666c6f6f720200086c302e686f6c65730b616374696f6e3a66616c6c010001010005666c6f6f72000102023c00000000030000042800000000000000076c302e76656e740c747269676765723a76656e740101010000076365696c696e670001010164000000096c6576656c2d302d31000000",
	hash = "9deed63cf8be68fa",
}
