--!strict

-- Decorate: small props scattered over the finished layout.

return {
	id = "details",
	owns = { "details" },
	phase = "generate",
	stage = "decorate",
	status = "active",
	validate = function(section: any, _level: any): { string }
		local problems: { string } = {}
		local detailIds: { [string]: boolean } = {}
		if type(section) ~= "table" then
			return problems
		end
		for index, detail in ipairs(section) do
			local prefix = "details[" .. index .. "]"
			if detail.id == nil or detail.id == "" then
				table.insert(problems, prefix .. ".id: required")
			elseif detailIds[detail.id] then
				table.insert(problems, prefix .. ".id: duplicate " .. detail.id)
			else
				detailIds[detail.id] = true
			end
			if detail.chance ~= nil and (detail.chance < 0 or detail.chance > 1) then
				table.insert(problems, prefix .. ".chance: must be within [0,1]")
			end
			if detail.minSpacing ~= nil and detail.minSpacing < 0 then
				table.insert(problems, prefix .. ".minSpacing: must be >= 0")
			end
		end
		return problems
	end,
	hooks = {
		generate = function(make: any, layout: any, ctx: any): ()
			ctx.passes.placeDetails(make, layout)
		end,
	},
}
