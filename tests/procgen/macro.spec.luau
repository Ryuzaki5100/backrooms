--!strict

local H = require("../harness")
local Macro = require("../../src/shared/procgen/Macro")
local Plan = require("../../src/shared/procgen/Plan")
local Level0 = require("../../src/config/levels/Level_0")

local function cycleRank(plan: any): number
	return #plan.edges - #plan.nodes + 1
end

H.test("builds a valid plan for a fixed seed", function()
	local plan = Macro.build(Level0, 42)
	H.eq(plan.seed, 42)
	H.eq(#Macro.validate(plan), 0, "validators")
	H.ok(#plan.nodes > 0, "has nodes")
	H.ok(plan.spawn.nodeId ~= 0, "has spawn")
end)

H.test("is deterministic: same seed, same bytes", function()
	local a = Macro.build(Level0, 42)
	local b = Macro.build(Level0, 42)
	H.eq(Plan.bytes(a), Plan.bytes(b))
end)

H.test("different seeds produce different plans", function()
	local a = Macro.build(Level0, 42)
	local b = Macro.build(Level0, 43)
	H.neq(Plan.hash(a), Plan.hash(b))
end)

H.test("every declared transition has exactly one exit", function()
	local plan = Macro.build(Level0, 42)
	H.eq(#plan.exits, #Level0.transitions, "exit count")
	local seen: { [string]: boolean } = {}
	for _, exit in ipairs(plan.exits) do
		H.ok(not seen[exit.id], "unique exit id " .. exit.id)
		seen[exit.id] = true
		H.ok(#exit.outcomes >= 1, "exit has an outcome")
	end
	for _, transition in ipairs(Level0.transitions) do
		H.ok(seen[transition.id], "transition placed: " .. transition.id)
	end
end)

H.test("seed mode stores exactly one resolved outcome", function()
	local plan = Macro.build(Level0, 42)
	for _, exit in ipairs(plan.exits) do
		if exit.resolve == "seed" then
			H.eq(#exit.outcomes, 1, "resolved outcome for " .. exit.id)
		end
	end
end)

H.test("loop count is exact", function()
	local plan = Macro.build(Level0, 42)
	H.eq(cycleRank(plan), Level0.generate.loops, "independent cycles")
end)

H.test("1000 seeds are fully connected, valid, and keep the loop count", function()
	local failures = 0
	local firstFailure = nil
	for seed = 1, 1000 do
		local ok, plan = pcall(Macro.build, Level0, seed)
		if not ok then
			failures += 1
			firstFailure = firstFailure or ("seed " .. seed .. ": " .. tostring(plan))
		else
			local problems = Macro.validate(plan)
			local rank = cycleRank(plan)
			if #problems > 0 or rank ~= Level0.generate.loops then
				failures += 1
				firstFailure = firstFailure
					or (
						"seed "
						.. seed
						.. ": rank "
						.. rank
						.. " / "
						.. table.concat(problems, "; ")
					)
			end
		end
	end
	H.eq(failures, 0, "failing seeds (" .. tostring(firstFailure) .. ")")
end)

H.test("dead-end levels are rejected without transitions", function()
	local broken = table.clone(Level0)
	broken.transitions = {}
	local ok = pcall(Macro.build, broken, 42)
	H.ok(not ok, "should refuse a level with no transitions")
end)
