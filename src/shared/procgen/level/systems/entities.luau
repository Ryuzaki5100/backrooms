--!strict

-- Declared in level files; nothing reads it yet. Level.resolve warns and checks
-- only the shape.

local shape = if script ~= nil then require(script.Parent.shape) else require("./shape")

return {
	id = "entities",
	owns = { "entities" },
	phase = "runtime",
	stage = "zone",
	status = "planned",
	validate = shape("entities", "list"),
}
