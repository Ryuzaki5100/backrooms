--!strict

-- Declared in level files; nothing reads it yet. Level.resolve warns and checks
-- only the shape.

local shape = if script ~= nil then require(script.Parent.shape) else require("./shape")

return {
	id = "props",
	owns = { "props" },
	phase = "render",
	stage = "props",
	status = "planned",
	validate = shape("props", "list"),
}
