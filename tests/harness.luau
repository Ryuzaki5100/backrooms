--!strict

-- Minimal test harness. Lune-only: this file is never required from a Roblox
-- place, so it can use plain string requires.

local Harness = {}

type Case = { name: string, fn: () -> () }

local tests: { Case } = {}

function Harness.test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

function Harness.ok(condition: boolean, label: string)
	if not condition then
		error(label .. ": condition was false", 2)
	end
end

function Harness.eq(actual: any, expected: any, label: string?)
	if actual ~= expected then
		error(
			string.format(
				"%s: expected %s, got %s",
				label or "eq",
				tostring(expected),
				tostring(actual)
			),
			2
		)
	end
end

function Harness.neq(actual: any, unexpected: any, label: string?)
	if actual == unexpected then
		error(string.format("%s: value should not be %s", label or "neq", tostring(unexpected)), 2)
	end
end

-- Asserts that fn raises.
function Harness.throws(fn: () -> (), label: string)
	local ok = pcall(fn)
	if ok then
		error(label .. ": expected an error, none raised", 2)
	end
end

function Harness.run(): number
	local passed, failed = 0, 0
	for _, case in ipairs(tests) do
		local ok, err = pcall(case.fn)
		if ok then
			passed += 1
		else
			failed += 1
			print(string.format("  FAIL  %s\n        %s", case.name, tostring(err)))
		end
	end
	print(string.format("\n%d passed, %d failed", passed, failed))
	return if failed == 0 then 0 else 1
end

return Harness
