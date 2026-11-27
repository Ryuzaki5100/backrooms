--!strict

-- Shape check shared by the planned (declared, not yet consumed) systems.

local function isList(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	for key in pairs(value) do
		if type(key) ~= "number" then
			return false
		end
	end
	return true
end

local function shape(label: string, expected: string): (any, any) -> { string }
	return function(section: any, _level: any): { string }
		local kind = type(section)
		local ok = if expected == "list" then isList(section) else kind == expected
		if ok then
			return {}
		end
		return { `{label}: expected a {expected}, got {kind}` }
	end
end

return shape
