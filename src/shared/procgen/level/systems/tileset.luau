--!strict

-- Declared in level files; nothing reads it yet. Level.resolve warns and checks
-- only the shape.

local shape = if script ~= nil then require(script.Parent.shape) else require("./shape")

return {
	id = "tileset",
	owns = { "tileset" },
	phase = "render",
	stage = "surfaces",
	status = "planned",
	validate = shape("tileset", "string"),
}
