--!strict

-- The level-system contract. A System is a descriptor: who it is, which config
-- paths it owns, where it sits in the pipeline, and (optionally) the hooks that
-- do the work. The registry orders systems and enforces ownership; it never
-- calls a hook itself, so this module stays pure and Lune-testable.

export type Phase = "generate" | "render" | "runtime"

export type Hooks = {
	bind: ((...any) -> any)?,
	generate: ((...any) -> any)?,
	render: ((...any) -> any)?,
	runtime: ((...any) -> any)?,
}

export type System = {
	id: string,
	owns: { string },
	phase: Phase,
	stage: string?,
	after: { string }?,
	before: { string }?,
	status: "active" | "planned",
	defaults: any?,
	validate: ((section: any, level: any) -> { string })?,
	hooks: Hooks,
}

local System = {}

-- Stage order per phase. A stage is a coarse slot; after/before refine within it.
System.STAGES = {
	generate = { "field", "base", "gated", "repair", "decorate" },
	render = { "surfaces", "structure", "fixtures", "props", "debug" },
	runtime = { "world", "zone", "player" },
} :: { [string]: { string } }

local PHASES: { [string]: boolean } = { generate = true, render = true, runtime = true }

-- 0 for "no stage" (sorts first), -1 for an unknown stage name.
function System.stageIndex(phase: string, stage: string?): number
	if stage == nil then
		return 0
	end
	local stages = System.STAGES[phase]
	for index, name in ipairs(stages) do
		if name == stage then
			return index
		end
	end
	return -1
end

local function checkStringList(id: string, field: string, value: any)
	if value == nil then
		return
	end
	assert(type(value) == "table", `System {id}: {field} must be a list of strings`)
	for _, entry in ipairs(value) do
		assert(type(entry) == "string", `System {id}: {field} must be a list of strings`)
	end
end

-- Checks the shape and fills defaults. Returns a new table; the spec is untouched.
function System.define(spec: any): System
	assert(type(spec) == "table", "System.define: spec must be a table")
	local id = spec.id
	assert(type(id) == "string" and id ~= "", "System.define: id must be a non-empty string")
	assert(
		type(spec.owns) == "table" and #spec.owns > 0,
		`System {id}: owns must list at least one config path`
	)
	for _, path in ipairs(spec.owns) do
		assert(
			type(path) == "string" and path ~= "" and not string.find(path, "..", 1, true),
			`System {id}: invalid owned path {tostring(path)}`
		)
	end
	assert(PHASES[spec.phase], `System {id}: phase must be generate, render or runtime`)
	if spec.stage ~= nil then
		assert(
			System.stageIndex(spec.phase, spec.stage) > 0,
			`System {id}: unknown stage '{tostring(spec.stage)}' for phase {spec.phase}`
		)
	end
	checkStringList(id, "after", spec.after)
	checkStringList(id, "before", spec.before)
	local status = spec.status or "active"
	assert(
		status == "active" or status == "planned",
		`System {id}: status must be active or planned`
	)
	assert(
		spec.validate == nil or type(spec.validate) == "function",
		`System {id}: validate must be a function`
	)
	local hooks = spec.hooks or {}
	assert(type(hooks) == "table", `System {id}: hooks must be a table`)
	for name, fn in pairs(hooks) do
		assert(
			(name == "bind" or name == "generate" or name == "render" or name == "runtime")
				and type(fn) == "function",
			`System {id}: unknown or non-function hook {tostring(name)}`
		)
	end

	return {
		id = id,
		owns = table.clone(spec.owns),
		phase = spec.phase,
		stage = spec.stage,
		after = if spec.after then table.clone(spec.after) else {},
		before = if spec.before then table.clone(spec.before) else {},
		status = status,
		defaults = spec.defaults,
		validate = spec.validate,
		hooks = hooks,
	}
end

return System
