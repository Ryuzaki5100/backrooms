--!strict

-- A deliberate subset of JSON Schema, enough to validate level configs with
-- useful error paths. Supported keywords: type (string | array), enum, pattern
-- (Lua patterns), minimum, maximum, minLength, maxLength, required, properties,
-- additionalProperties(false), items, minItems, maxItems, anyOf.
--
-- Not supported on purpose: $ref, allOf/oneOf, dependencies. If a config needs
-- one of those, it is a sign the schema is doing too much.

local Schema = {}

local function kindOf(value: any): string
	local kind = type(value)
	if kind == "number" then
		return if value % 1 == 0 then "integer" else "number"
	end
	return kind
end

local function accepts(expected: string, actual: string): boolean
	if expected == actual then
		return true
	end
	-- An integer value satisfies "number"; an array or object satisfies "table".
	if expected == "number" and actual == "integer" then
		return true
	end
	if (expected == "object" or expected == "array") and actual == "table" then
		return true
	end
	return false
end

local validate: (any, any, string, { string }) -> ()

validate = function(schema: any, value: any, path: string, errors: { string })
	if type(schema) ~= "table" then
		return
	end

	if schema.anyOf then
		for _, alternative in ipairs(schema.anyOf) do
			local alternativeErrors = {}
			validate(alternative, value, path, alternativeErrors)
			if #alternativeErrors == 0 then
				return
			end
		end
		table.insert(errors, path .. ": does not match any allowed form")
		return
	end

	if value == nil then
		if schema.type then
			local allowed = if type(schema.type) == "table" then schema.type else { schema.type }
			for _, expected in ipairs(allowed) do
				if expected == "null" then
					return
				end
			end
		end
		table.insert(errors, path .. ": expected a value")
		return
	end

	if schema.type then
		local allowed = if type(schema.type) == "table" then schema.type else { schema.type }
		local actual = kindOf(value)
		local matched = false
		for _, expected in ipairs(allowed) do
			if accepts(expected, actual) then
				matched = true
				break
			end
		end
		if not matched then
			table.insert(
				errors,
				path .. ": expected " .. table.concat(allowed, "|") .. ", got " .. actual
			)
			return
		end
	end

	if schema.enum then
		local found = false
		for _, candidate in ipairs(schema.enum) do
			if candidate == value then
				found = true
				break
			end
		end
		if not found then
			table.insert(
				errors,
				path .. ": '" .. tostring(value) .. "' is not one of the allowed values"
			)
		end
	end

	if type(value) == "string" then
		if schema.minLength and #value < schema.minLength then
			table.insert(errors, path .. ": shorter than " .. tostring(schema.minLength))
		end
		if schema.maxLength and #value > schema.maxLength then
			table.insert(errors, path .. ": longer than " .. tostring(schema.maxLength))
		end
		if schema.pattern and not string.match(value, schema.pattern) then
			table.insert(errors, path .. ": does not match " .. tostring(schema.pattern))
		end
	end

	if type(value) == "number" then
		if schema.minimum and value < schema.minimum then
			table.insert(errors, path .. ": below minimum " .. tostring(schema.minimum))
		end
		if schema.maximum and value > schema.maximum then
			table.insert(errors, path .. ": above maximum " .. tostring(schema.maximum))
		end
	end

	if type(value) == "table" then
		if schema.required then
			for _, key in ipairs(schema.required) do
				if value[key] == nil then
					table.insert(errors, path .. "." .. key .. ": required")
				end
			end
		end
		if schema.properties then
			for key, subSchema in pairs(schema.properties) do
				if value[key] ~= nil then
					validate(subSchema, value[key], path .. "." .. key, errors)
				end
			end
			if schema.additionalProperties == false then
				for key in pairs(value) do
					if schema.properties[key] == nil then
						table.insert(errors, path .. "." .. tostring(key) .. ": unknown key")
					end
				end
			end
		end
		if schema.items then
			for index, item in ipairs(value) do
				validate(schema.items, item, path .. "[" .. (index - 1) .. "]", errors)
			end
		end
		if schema.minItems and #value < schema.minItems then
			table.insert(errors, path .. ": fewer than " .. tostring(schema.minItems) .. " items")
		end
		if schema.maxItems and #value > schema.maxItems then
			table.insert(errors, path .. ": more than " .. tostring(schema.maxItems) .. " items")
		end
	end
end

-- Returns the list of error strings; empty means valid.
function Schema.validate(schema: any, value: any): { string }
	local errors: { string } = {}
	validate(schema, value, "$", errors)
	return errors
end

-- Cross-field rules that JSON Schema expresses badly.
function Schema.checkRelations(config: any): { string }
	local errors = {}
	if type(config) ~= "table" then
		return { "$: expected an object" }
	end

	local transitions = config.transitions
	if type(transitions) == "table" then
		local seen = {}
		for index, transition in ipairs(transitions) do
			local id = transition.id
			if id ~= nil then
				if seen[id] then
					table.insert(
						errors,
						"$.transitions[" .. (index - 1) .. "].id: duplicate '" .. id .. "'"
					)
				end
				seen[id] = true
			end
			if transition.to == config.id then
				table.insert(
					errors,
					"$.transitions[" .. (index - 1) .. "].to: a level cannot transition to itself"
				)
			end
		end
		if #transitions == 0 and config.dead_end ~= true then
			table.insert(
				errors,
				"$.transitions: a level needs at least one transition unless dead_end is true"
			)
		end
	end

	local generate = config.generate
	if type(generate) == "table" and type(generate.regions) == "table" then
		local low, high = generate.regions[1], generate.regions[2]
		if low and high and low > high then
			table.insert(errors, "$.generate.regions: minimum is greater than maximum")
		end
	end

	return errors
end

return Schema
