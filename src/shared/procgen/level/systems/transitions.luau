--!strict

-- Declared in level files; nothing reads it yet. Level.resolve warns and checks
-- only the shape.

local shape = if script ~= nil then require(script.Parent.shape) else require("./shape")

return {
	id = "transitions",
	owns = { "transitions" },
	phase = "runtime",
	stage = "player",
	status = "planned",
	validate = shape("transitions", "list"),
}
