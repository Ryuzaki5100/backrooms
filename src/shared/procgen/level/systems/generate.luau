--!strict

-- Declared in level files; nothing reads it yet. Level.resolve warns and checks
-- only the shape.
-- Legacy node pipeline, superseded by `strategy`; kept so old files still resolve.

local shape = if script ~= nil then require(script.Parent.shape) else require("./shape")

return {
	id = "generate",
	owns = { "generate" },
	phase = "generate",
	stage = "field",
	status = "planned",
	validate = shape("generate", "table"),
}
