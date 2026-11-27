--!strict

-- Declared in level files; nothing reads it yet. Level.resolve warns and checks
-- only the shape.

local shape = if script ~= nil then require(script.Parent.shape) else require("./shape")

return {
	id = "lighting",
	owns = { "lighting" },
	phase = "render",
	stage = "fixtures",
	status = "planned",
	validate = shape("lighting", "table"),
}
