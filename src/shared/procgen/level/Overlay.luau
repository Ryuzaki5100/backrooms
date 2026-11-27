--!strict

-- Pure add-on merge (ADR 0033 D80/D81). A level config is a base plus ordered,
-- toggleable patches; this module folds the enabled patches into a copy of the
-- base. No Roblox APIs, no I/O, no dependency on the level catalog, so the
-- build pipeline and the runtime share it.
--
-- Merge rules, applied per key of the patch:
--   * { "$delete": true }          removes the key
--   * { "$append"/"$remove"/"$replace" }  array ops (see below)
--   * object over object           deep merge
--   * anything else                replaces (arrays and scalars)
-- Array ops may be combined in one op object and run in the order
-- $replace, $remove, $append. $remove drops elements whose `.id` or `.ref`
-- equals one of the listed strings. Any other `$`-prefixed key is an error.

export type Addon = {
	id: string,
	version: number,
	enabled: boolean?,
	order: number?,
	title: string,
	source: string?,
	patch: { [string]: any },
}

export type Applied = { id: string, version: number }

local Overlay = {}

local DEFAULT_ORDER = 100

local function clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in pairs(value) do
		copy[key] = clone(item)
	end
	return copy
end

local function isArray(value: any): boolean
	if type(value) ~= "table" or next(value) == nil then
		return false
	end
	return #value > 0
end

local function isOpObject(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	for key in pairs(value) do
		if type(key) == "string" and string.sub(key, 1, 1) == "$" then
			return true
		end
	end
	return false
end

local function fail(addonId: string, path: string, message: string)
	error(`Overlay: add-on '{addonId}' at {path}: {message}`, 0)
end

local ARRAY_OPS = { ["$append"] = true, ["$remove"] = true, ["$replace"] = true }

local function applyArrayOps(addonId: string, path: string, current: any, ops: any): any
	for key in pairs(ops) do
		if key == "$delete" then
			fail(addonId, path, "$delete cannot be combined with other ops")
		end
		if not ARRAY_OPS[key] then
			fail(addonId, path, `unknown op '{tostring(key)}'`)
		end
	end

	local result: { any }
	if ops["$replace"] ~= nil then
		if type(ops["$replace"]) ~= "table" then
			fail(addonId, path, "$replace expects an array")
		end
		result = clone(ops["$replace"])
	elseif current == nil then
		result = {}
	elseif type(current) == "table" and (next(current) == nil or isArray(current)) then
		result = clone(current)
	else
		fail(addonId, path, "array ops need an array target")
		result = {}
	end

	if ops["$remove"] ~= nil then
		if type(ops["$remove"]) ~= "table" then
			fail(addonId, path, "$remove expects an array of ids")
		end
		local drop: { [any]: boolean } = {}
		for _, id in ipairs(ops["$remove"]) do
			drop[id] = true
		end
		local kept = {}
		for _, element in ipairs(result) do
			local matches = type(element) == "table"
				and (drop[element.id] == true or drop[element.ref] == true)
			if not matches then
				table.insert(kept, element)
			end
		end
		result = kept
	end

	if ops["$append"] ~= nil then
		if type(ops["$append"]) ~= "table" then
			fail(addonId, path, "$append expects an array")
		end
		for _, element in ipairs(ops["$append"]) do
			table.insert(result, clone(element))
		end
	end

	return result
end

local materialize: (string, string, any) -> any

local function mergeInto(addonId: string, path: string, target: any, patch: any)
	for key, value in pairs(patch) do
		local keyPath = path .. "." .. tostring(key)
		if type(key) == "string" and string.sub(key, 1, 1) == "$" then
			fail(addonId, keyPath, `unknown op '{key}' (ops belong inside a key's value)`)
		end

		if isOpObject(value) then
			if value["$delete"] ~= nil then
				local count = 0
				for _ in pairs(value) do
					count += 1
				end
				if value["$delete"] ~= true or count ~= 1 then
					fail(addonId, keyPath, 'op $delete must be exactly { "$delete": true }')
				end
				target[key] = nil
			else
				target[key] = applyArrayOps(addonId, keyPath, target[key], value)
			end
		elseif type(value) == "table" then
			local existing = target[key]
			local existingIsObject = type(existing) == "table" and not isArray(existing)
			if next(value) == nil then
				-- `{}`/`[]` replaces an array, merges (a no-op) into an object.
				if not existingIsObject then
					target[key] = {}
				end
			elseif not isArray(value) and existingIsObject then
				mergeInto(addonId, keyPath, existing, value)
			else
				-- Array, or object over a non-object: replace. Ops nested inside a
				-- replaced value are still validated so a typo cannot hide there.
				target[key] = materialize(addonId, keyPath, value)
			end
		else
			target[key] = value
		end
	end
end

-- Copies a patch value that lands on a new key, resolving op objects nested in
-- it (so `{a = {b = {"$delete": true}}}` on a missing `a` still behaves).
materialize = function(addonId: string, path: string, value: any): any
	if type(value) ~= "table" then
		return value
	end
	if isArray(value) then
		return clone(value)
	end
	local fresh: { [string]: any } = {}
	mergeInto(addonId, path, fresh, value)
	return fresh
end

local function orderOf(addon: Addon): number
	return addon.order or DEFAULT_ORDER
end

local function isEnabled(addon: Addon, enabled: { [string]: boolean }?): boolean
	if enabled ~= nil and enabled[addon.id] ~= nil then
		return enabled[addon.id]
	end
	return addon.enabled ~= false
end

-- Folds the enabled add-ons into a deep copy of `base`. `applied` lists
-- { id, version } in apply order, i.e. sorted by (order, id).
function Overlay.apply(
	base: any,
	addons: { Addon },
	enabled: { [string]: boolean }?
): (any, { Applied })
	local sorted = table.clone(addons)
	table.sort(sorted, function(a: Addon, b: Addon)
		local orderA, orderB = orderOf(a), orderOf(b)
		if orderA ~= orderB then
			return orderA < orderB
		end
		return a.id < b.id
	end)

	local merged = clone(base)
	local applied: { Applied } = {}
	local seen: { [string]: boolean } = {}
	for _, addon in ipairs(sorted) do
		if seen[addon.id] then
			error(`Overlay: duplicate add-on id '{addon.id}'`, 0)
		end
		seen[addon.id] = true
		if isEnabled(addon, enabled) then
			mergeInto(addon.id, "$", merged, addon.patch)
			table.insert(applied, { id = addon.id, version = addon.version })
		end
	end
	return merged, applied
end

return Overlay
