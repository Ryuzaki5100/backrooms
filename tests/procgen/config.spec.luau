--!strict

local H = require("../harness")
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Schema = require("../../tools/Schema")
local ConfigGen = require("../../tools/ConfigGen")
local Config = require("../../src/shared/procgen/Config")
local Features = require("../../src/shared/procgen/features/Features")
local Strategy = require("../../src/shared/procgen/Strategy")
local OpenAdditive = require("../../src/shared/procgen/strategies/OpenAdditive")

local function loadJson(path: string): any
	return serde.decode("json", fs.readFile(path))
end

local schema = loadJson("config/schema.json")
local level0 = loadJson("config/levels/level-0.json")

local function clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in pairs(value) do
		copy[key] = clone(item)
	end
	return copy
end

local function errorsFor(config: any): { string }
	local errors = Schema.validate(schema, config)
	for _, relationError in ipairs(Schema.checkRelations(config)) do
		table.insert(errors, relationError)
	end
	return errors
end

local function joined(errors: { string }): string
	return table.concat(errors, " | ")
end

H.test("level-0 validates against the schema", function()
	local errors = errorsFor(level0)
	H.eq(#errors, 0, "level-0 errors: " .. joined(errors))
end)

H.test("an unknown key fails with its JSON path", function()
	local broken = clone(level0)
	broken.bogus = true
	local errors = errorsFor(broken)
	H.ok(
		joined(errors):find("$.bogus: unknown key", 1, true) ~= nil,
		"path in error: " .. joined(errors)
	)
end)

H.test("a missing required key fails with its path", function()
	local broken = clone(level0)
	broken.tileset = nil
	local errors = errorsFor(broken)
	H.ok(joined(errors):find("$.tileset: required", 1, true) ~= nil, joined(errors))
end)

H.test("an enum violation is reported", function()
	local broken = clone(level0)
	broken.tileset = "nope"
	local errors = errorsFor(broken)
	H.ok(joined(errors):find("$.tileset", 1, true) ~= nil, joined(errors))
end)

H.test("a range violation is reported with its path", function()
	local broken = clone(level0)
	broken.generate.tiles = 1
	local errors = errorsFor(broken)
	H.ok(joined(errors):find("$.generate.tiles: below minimum", 1, true) ~= nil, joined(errors))
end)

H.test("anyOf rejects an invalid gate", function()
	local broken = clone(level0)
	broken.transitions[1].gate = "nonsense"
	local errors = errorsFor(broken)
	H.ok(joined(errors):find("$.transitions[0].gate", 1, true) ~= nil, joined(errors))
end)

H.test("a level without transitions is rejected unless dead_end", function()
	local broken = clone(level0)
	broken.transitions = {}
	local errors = errorsFor(broken)
	H.ok(joined(errors):find("at least one transition", 1, true) ~= nil, joined(errors))

	broken.dead_end = true
	H.eq(#errorsFor(broken), 0, "dead_end should be allowed")
end)

H.test("duplicate transition ids are rejected", function()
	local broken = clone(level0)
	broken.transitions[2].id = broken.transitions[1].id
	local errors = errorsFor(broken)
	H.ok(joined(errors):find("duplicate", 1, true) ~= nil, joined(errors))
end)

H.test("a level cannot transition to itself", function()
	local broken = clone(level0)
	broken.transitions[1].outcomes[1].level = broken.id
	local errors = errorsFor(broken)
	H.ok(joined(errors):find("cannot transition to itself", 1, true) ~= nil, joined(errors))
end)

H.test("codegen is deterministic and omits nulls", function()
	local first = ConfigGen.render(level0, "config/levels/level-0.json")
	local second = ConfigGen.render(level0, "config/levels/level-0.json")
	H.eq(first, second)
	H.eq(first:find("null", 1, true), nil, "no null literal")
	local bare = clone(level0)
	bare.style = nil
	local bareSource = ConfigGen.render(bare, "config/levels/level-0.json")
	H.eq(bareSource:find("style", 1, true), nil, "null style omitted")
	H.ok(first:find("style", 1, true) ~= nil, "authored style is emitted")
end)

H.test("generated module name is stable and safe", function()
	H.eq(ConfigGen.moduleName("level-0"), "Level_0")
	H.eq(ConfigGen.moduleName("level-0.1"), "Level_0_1")
end)

H.test("the committed module loads and satisfies runtime invariants", function()
	local generated = require("../../src/config/levels/Level_0")
	local config = Config.load(generated)
	H.eq(config.id, "level-0")
	H.eq(#config.transitions, 3)
	H.eq(#Config.verify(generated), 0)
end)

H.test("runtime rejects a level without transitions", function()
	local broken = clone(level0)
	broken.transitions = {}
	H.ok(#Config.verify(broken) > 0, "should reject")
end)

H.test("mastery requires every declared transition", function()
	local config = Config.load(level0)
	H.eq(Config.isMastered(config, {}), false)
	H.eq(Config.isMastered(config, { "l0.phase-wall" }), false)
	H.eq(Config.isMastered(config, { "l0.phase-wall", "l0.vent", "l0.glass-doors" }), true)
end)

-- Config lint (ADR 0032 D69) ------------------------------------------------

local function lintProblems(mutate: (any) -> ()): string
	local config = clone(level0)
	mutate(config)
	return joined(Features.validate(config))
end

local function expectProblem(mutate: (any) -> (), fragment: string)
	local problems = lintProblems(mutate)
	H.ok(problems:find(fragment, 1, true) ~= nil, "expected '" .. fragment .. "' in: " .. problems)
end

H.test("level-0 passes the config lint and the schema accepts ceiling bands", function()
	H.eq(#Features.validate(level0), 0, joined(Features.validate(level0)))
	H.eq(#Strategy.validate(level0), 0, joined(Strategy.validate(level0)))
	H.eq(#errorsFor(level0), 0)
	H.ok(level0.strategy.params.heights == nil, "level 0 uses ceiling bands, not heights")
end)

H.test("lint: ceiling.bands must be non-empty", function()
	expectProblem(function(c)
		c.strategy.params.ceiling.bands = {}
	end, "strategy.params.ceiling.bands: must be a non-empty list")
end)

H.test("lint: a band weight must be > 0", function()
	expectProblem(function(c)
		c.strategy.params.ceiling.bands[2].weight = 0
	end, "strategy.params.ceiling.bands[2].weight: must be a number > 0")
	expectProblem(function(c)
		c.strategy.params.ceiling.bands[1].weight = "heavy"
	end, "strategy.params.ceiling.bands[1].weight: must be a number > 0")
end)

H.test("lint: a band height must be >= terrain.minHeadroom", function()
	expectProblem(function(c)
		c.strategy.params.ceiling.bands[3].height = 8
	end, "strategy.params.ceiling.bands[3].height: must be >= terrain.minHeadroom (9)")
	expectProblem(function(c)
		c.strategy.params.terrain.minHeadroom = 13
	end, "strategy.params.ceiling.bands[1].height: must be >= terrain.minHeadroom (13)")
	expectProblem(function(c)
		c.strategy.params.ceiling.bands[1].height = "tall"
	end, "strategy.params.ceiling.bands[1].height: must be a number")
end)

H.test("lint: zoneBlocks must be a positive integer", function()
	for _, bad in ipairs({ 0, -2, 1.5 }) do
		expectProblem(function(c)
			c.strategy.params.ceiling.zoneBlocks = bad
		end, "strategy.params.ceiling.zoneBlocks: must be a positive integer")
	end
end)

H.test("lint: hanging wall keeps 6 studs of clearance under the lowest band", function()
	expectProblem(function(c)
		c.strategy.params.ceiling.bands[1].height = 9
	end, "lowest height 9 minus features.hangingWall.depth 4 leaves 5 studs")
	-- exactly 6 is allowed
	H.eq(
		lintProblems(function(c)
			c.strategy.params.ceiling.bands[1].height = 10
		end),
		"",
		"10 - 4 = 6 passes"
	)
	expectProblem(function(c)
		c.strategy.params.features.hangingWall.depth = 7
	end, "leaves 5 studs, need >= 6")
end)

H.test("lint: heights fallback gets the same height and clearance rules", function()
	local function legacy(c: any)
		c.strategy.params.ceiling = nil
		c.strategy.params.heights = { 12, 14, 16 }
	end
	H.eq(lintProblems(legacy), "", "legacy heights pass")
	expectProblem(function(c)
		legacy(c)
		c.strategy.params.heights[2] = 7
	end, "strategy.params.heights[2]: must be >= terrain.minHeadroom (9)")
	expectProblem(function(c)
		legacy(c)
		c.strategy.params.heights = { 9, 12 }
	end, "strategy.params.heights: lowest height 9 minus features.hangingWall.depth 4")
	expectProblem(function(c)
		legacy(c)
		c.strategy.params.heights = {}
	end, "strategy.params.heights: must be a non-empty list")
end)

H.test("lint: terrain.stepMax must be less than terrain.rise", function()
	expectProblem(function(c)
		c.strategy.params.terrain.stepMax = 4
	end, "strategy.params.terrain.stepMax: must be less than terrain.rise (stepMax 4, rise 4)")
	expectProblem(function(c)
		c.strategy.params.terrain.rise = 1
	end, "stepMax 1, rise 1")
	H.eq(
		lintProblems(function(c)
			c.strategy.params.terrain.stepMax = 3
		end),
		"",
		"stepMax 3 < rise 4 passes"
	)
end)

H.test("lint: secondRampChance is within [0,1]", function()
	for _, bad in ipairs({ -0.1, 1.5 }) do
		expectProblem(function(c)
			c.strategy.params.terrain.secondRampChance = bad
		end, "strategy.params.terrain.secondRampChance: must be a number within [0,1]")
	end
end)

H.test("lint: ceiling.zoneBlocks must divide the blocks per axis on a wrap world", function()
	-- Level 0: vast = 400 chunks x 18 cells / 6 = 1200 blocks per axis.
	H.eq(lintProblems(function(_) end), "", "Level 0 (zoneBlocks 1) passes")
	H.eq(
		lintProblems(function(c)
			c.strategy.params.ceiling.zoneBlocks = 4
		end),
		"",
		"4 divides 1200"
	)
	expectProblem(
		function(c)
			c.strategy.params.ceiling.zoneBlocks = 7
		end,
		"strategy.params.ceiling.zoneBlocks: must divide the blocks per axis of a wrapping world (1200 blocks"
	)
	expectProblem(
		function(c)
			c.world.worldSizeChunks = 4
			c.strategy.params.ceiling.zoneBlocks = 5
		end,
		"must divide the blocks per axis of a wrapping world (12 blocks = 4 chunks x 18 cells / 6), got 5"
	)
	H.eq(
		lintProblems(function(c)
			c.world.worldSizeChunks = 4
			c.world.boundaryMode = "infinite"
			c.strategy.params.ceiling.zoneBlocks = 5
		end),
		"",
		"an infinite world has no seam"
	)
end)

H.test("lint: ramp counts must be positive integers", function()
	for _, key in ipairs({ "rampSpacing", "extraRampCells", "secondRampFaces" }) do
		for _, bad in ipairs({ 0, 2.5 }) do
			expectProblem(function(c)
				c.strategy.params.terrain[key] = bad
			end, "strategy.params.terrain." .. key .. ": must be a positive integer")
		end
	end
end)

H.test("schema rejects bad ceiling and ramp params with their path", function()
	local broken = clone(level0)
	broken.strategy.params.ceiling.bands = {}
	broken.strategy.params.ceiling.zoneBlocks = 0
	broken.strategy.params.terrain.rampSpacing = 0
	broken.strategy.params.terrain.secondRampChance = 2
	local errors = joined(errorsFor(broken))
	H.ok(errors:find("$.strategy.params.ceiling.bands: fewer than 1 items", 1, true) ~= nil, errors)
	H.ok(errors:find("$.strategy.params.ceiling.zoneBlocks: below minimum", 1, true) ~= nil, errors)
	H.ok(
		errors:find("$.strategy.params.terrain.rampSpacing: below minimum", 1, true) ~= nil,
		errors
	)
	H.ok(
		errors:find("$.strategy.params.terrain.secondRampChance: above maximum", 1, true) ~= nil,
		errors
	)
end)

H.test("the committed Level_0 module is in sync with level-0.json (codegen drift)", function()
	local rendered = ConfigGen.render(level0, "config/levels/level-0.json")
	H.ok(
		rendered == fs.readFile("src/config/levels/Level_0.luau"),
		"run `lune run scripts/gen-config.luau`"
	)
end)

-- Ceiling band draw ----------------------------------------------------------

local function ceilingConfig(chunks: number, ceiling: any, heights: any): any
	local config = clone(level0)
	config.world.worldSizeChunks = chunks
	config.world.boundaryMode = "wrap"
	config.strategy.params.ceiling = ceiling
	config.strategy.params.heights = heights
	return config
end

local function blockHeights(config: any, seed: number): { number }
	local make = OpenAdditive.world(config, seed)
	local blocks = make.period // make.block
	local out = {}
	for bz = 0, blocks - 1 do
		for bx = 0, blocks - 1 do
			local _, height = OpenAdditive.cell(make, bx * make.block, bz * make.block)
			table.insert(out, height)
		end
	end
	return out
end

local function equalBands(heights: { number }): any
	local bands = {}
	for _, height in ipairs(heights) do
		table.insert(bands, { height = height, weight = 1 })
	end
	return { bands = bands, zoneBlocks = 1 }
end

H.test("pickHeight with equal weights matches the legacy mapping for every roll", function()
	local function legacy(heights: { number }, roll: number): number
		return heights[math.min(#heights, math.max(1, math.floor(roll * #heights) + 1))]
	end
	local sets = { { 12 }, { 12, 14 }, { 12, 14, 16 }, { 10, 12, 14, 16, 18, 20, 22 } }
	for _, heights in ipairs(sets) do
		for _, weight in ipairs({ 1, 0.1, 0.3, 7 }) do
			local bands = {}
			for _, height in ipairs(heights) do
				table.insert(bands, { height = height, weight = weight })
			end
			local ceiling = OpenAdditive.resolveCeiling({ ceiling = { bands = bands } })
			local count = #heights
			local rolls = { 0, 1 - 2 ^ -53, 0.5 }
			for step = 0, 999 do
				table.insert(rolls, step / 1000)
			end
			for k = 1, count do
				-- the float neighbourhood of every band edge
				local edge = k / count
				table.insert(rolls, edge)
				table.insert(rolls, edge - 2 ^ -52)
				table.insert(rolls, edge + 2 ^ -52)
			end
			for _, roll in ipairs(rolls) do
				if roll >= 0 and roll < 1 then
					H.eq(
						OpenAdditive.pickHeight(ceiling, roll),
						legacy(heights, roll),
						"n=" .. count .. " w=" .. weight .. " roll=" .. roll
					)
				end
			end
		end
	end
end)

H.test("equal-weight bands reproduce the legacy heights for every block (seeds 1..10)", function()
	local heights = { 12, 14, 16 }
	local distinct: { [number]: boolean } = {}
	for seed = 1, 10 do
		local legacy = blockHeights(ceilingConfig(4, nil, heights), seed)
		local banded = blockHeights(ceilingConfig(4, equalBands(heights), nil), seed)
		H.eq(#legacy, 144, "4x4 chunks of 3x3 blocks")
		for index = 1, #legacy do
			H.eq(banded[index], legacy[index], "seed " .. seed .. " block " .. index)
			distinct[legacy[index]] = true
		end
	end
	H.ok(distinct[12] and distinct[14] and distinct[16], "all three heights occur")
end)

H.test("skewed band weights shift the height histogram", function()
	local ceiling = {
		bands = {
			{ height = 12, weight = 1 },
			{ height = 14, weight = 0.01 },
			{ height = 16, weight = 0.01 },
		},
		zoneBlocks = 1,
	}
	local first, total = 0, 0
	for seed = 1, 10 do
		for _, height in ipairs(blockHeights(ceilingConfig(4, ceiling, nil), seed)) do
			total += 1
			if height == 12 then
				first += 1
			end
		end
	end
	H.ok(first / total > 0.9, "first band share " .. first / total)
end)

H.test("zoneBlocks groups blocks into equal-height zones", function()
	local ceiling = equalBands({ 12, 14, 16 })
	ceiling.zoneBlocks = 3
	local varied = false
	for seed = 1, 10 do
		local make = OpenAdditive.world(ceilingConfig(3, ceiling, nil), seed)
		local blocks = make.period // make.block
		H.eq(blocks, 9)
		local zoneHeights: { [string]: number } = {}
		local seen: { [number]: boolean } = {}
		for bz = 0, blocks - 1 do
			for bx = 0, blocks - 1 do
				local _, height = OpenAdditive.cell(make, bx * make.block, bz * make.block)
				local key = (bx // 3) .. ":" .. (bz // 3)
				if zoneHeights[key] == nil then
					zoneHeights[key] = height
				end
				H.eq(height, zoneHeights[key], "seed " .. seed .. " zone " .. key)
				seen[height] = true
			end
		end
		local kinds = 0
		for _ in pairs(seen) do
			kinds += 1
		end
		if kinds > 1 then
			varied = true
		end
	end
	H.ok(varied, "different zones differ for at least one seed")
end)
