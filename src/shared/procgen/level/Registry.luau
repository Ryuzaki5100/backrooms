--!strict

-- Holds registered systems, enforces config ownership and produces the run
-- order. Pure bookkeeping: no hook is ever called here.

local System = if script ~= nil then require(script.Parent.System) else require("./System")

export type Registry = {
	register: (self: Registry, system: System.System) -> (),
	get: (self: Registry, id: string) -> System.System?,
	systems: (self: Registry) -> { System.System },
	order: (self: Registry, phase: string) -> { System.System },
	owner: (self: Registry, path: string) -> System.System?,
	covers: (self: Registry, path: string) -> boolean,
}

local Registry = {}

local function isPrefix(owned: string, path: string): boolean
	return path == owned or string.sub(path, 1, #owned + 1) == owned .. "."
end

function Registry.new(): Registry
	local byId: { [string]: System.System } = {}
	local list: { System.System } = {}
	local pathOwner: { [string]: string } = {}

	local self = {} :: Registry

	function self.register(_self: Registry, system: System.System)
		if byId[system.id] ~= nil then
			error(`Registry: duplicate system id '{system.id}'`, 2)
		end
		for _, path in ipairs(system.owns) do
			local existing = pathOwner[path]
			if existing ~= nil then
				error(
					`Registry: config path '{path}' is owned by both '{existing}' and '{system.id}'`,
					2
				)
			end
		end
		for _, path in ipairs(system.owns) do
			pathOwner[path] = system.id
		end
		byId[system.id] = system
		table.insert(list, system)
	end

	function self.get(_self: Registry, id: string): System.System?
		return byId[id]
	end

	function self.systems(_self: Registry): { System.System }
		return table.clone(list)
	end

	-- Stage decides first (ADR 0033 D75); after/before only order systems within
	-- one stage. A dependency that contradicts stage order is an error rather than
	-- a silent override.
	function self.order(_self: Registry, phase: string): { System.System }
		assert(System.STAGES[phase] ~= nil, `Registry.order: unknown phase '{phase}'`)

		-- Validate dependencies against every registered system, so a typo is
		-- an error even when the target lives in another phase.
		for _, system in ipairs(list) do
			for _, dep in ipairs(system.after or {}) do
				if byId[dep] == nil then
					error(
						`Registry: system '{system.id}' lists unknown dependency '{dep}' in after`,
						2
					)
				end
			end
			for _, dep in ipairs(system.before or {}) do
				if byId[dep] == nil then
					error(
						`Registry: system '{system.id}' lists unknown dependency '{dep}' in before`,
						2
					)
				end
			end
		end

		local nodes: { System.System } = {}
		local inPhase: { [string]: boolean } = {}
		for _, system in ipairs(list) do
			if system.phase == phase then
				table.insert(nodes, system)
				inPhase[system.id] = true
			end
		end

		-- edges[a] = set of ids that must come after a
		local edges: { [string]: { [string]: boolean } } = {}
		local indegree: { [string]: number } = {}
		for _, system in ipairs(nodes) do
			edges[system.id] = {}
			indegree[system.id] = 0
		end
		local function stageOf(id: string): number
			return System.stageIndex(phase, (byId[id] :: System.System).stage)
		end
		local function addEdge(first: string, second: string)
			if not (inPhase[first] and inPhase[second]) then
				return
			end
			if stageOf(first) > stageOf(second) then
				local a, b = byId[first] :: System.System, byId[second] :: System.System
				error(
					`Registry: '{b.id}' (stage '{tostring(b.stage)}') is ordered after '{a.id}' (stage '{tostring(
						a.stage
					)}') in phase '{phase}', but stage order runs '{b.id}' first; after/before only order systems within one stage`,
					2
				)
			end
			if edges[first][second] then
				return
			end
			edges[first][second] = true
			indegree[second] += 1
		end
		for _, system in ipairs(nodes) do
			for _, dep in ipairs(system.after or {}) do
				addEdge(dep, system.id)
			end
			for _, dep in ipairs(system.before or {}) do
				addEdge(system.id, dep)
			end
		end

		local function earlier(a: System.System, b: System.System): boolean
			local ra, rb = System.stageIndex(phase, a.stage), System.stageIndex(phase, b.stage)
			if ra ~= rb then
				return ra < rb
			end
			return a.id < b.id
		end

		local result: { System.System } = {}
		local remaining = #nodes
		while remaining > 0 do
			local pick: System.System? = nil
			for _, system in ipairs(nodes) do
				if indegree[system.id] == 0 and (pick == nil or earlier(system, pick)) then
					pick = system
				end
			end
			if pick == nil then
				local stuck = {}
				for _, system in ipairs(nodes) do
					if indegree[system.id] > 0 then
						table.insert(stuck, system.id)
					end
				end
				table.sort(stuck)
				error(
					`Registry: dependency cycle in phase '{phase}' among: {table.concat(stuck, ", ")}`,
					2
				)
			end
			indegree[pick.id] = -1
			remaining -= 1
			table.insert(result, pick)
			for following in pairs(edges[pick.id]) do
				indegree[following] -= 1
			end
		end
		return result
	end

	-- Longest owned path that is a prefix of `path` (dot-segment aware).
	function self.owner(_self: Registry, path: string): System.System?
		local bestPath: string? = nil
		for owned in pairs(pathOwner) do
			if isPrefix(owned, path) and (bestPath == nil or #owned > #bestPath) then
				bestPath = owned
			end
		end
		if bestPath == nil then
			return nil
		end
		return byId[pathOwner[bestPath]]
	end

	-- True when `path` is owned, or is an ancestor of something owned (a parent
	-- section whose children are claimed one by one, like `strategy`).
	function self.covers(_self: Registry, path: string): boolean
		if self.owner(self, path) ~= nil then
			return true
		end
		for owned in pairs(pathOwner) do
			if string.sub(owned, 1, #path + 1) == path .. "." then
				return true
			end
		end
		return false
	end

	return self
end

return Registry
