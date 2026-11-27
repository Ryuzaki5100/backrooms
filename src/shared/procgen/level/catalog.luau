--!strict

-- The default level systems, one module per system under systems/. Each module
-- returns a System spec; this file only fixes the registration order, which is
-- also the order Level.resolve reports problems and warnings in.
--
-- `active` systems are consumed by the pipeline (the generate ones run from
-- OpenAdditive.layout). `planned` sections are declared in level files but
-- nothing reads them yet; Level.resolve reports them as warnings and checks
-- only their shape.

local System = if script ~= nil then require(script.Parent.System) else require("./System")

local spec_core = if script ~= nil
	then require(script.Parent.systems.core)
	else require("./systems/core")
local spec_strategy = if script ~= nil
	then require(script.Parent.systems.strategy)
	else require("./systems/strategy")
local spec_terrain = if script ~= nil
	then require(script.Parent.systems.terrain)
	else require("./systems/terrain")
local spec_structures = if script ~= nil
	then require(script.Parent.systems.structures)
	else require("./systems/structures")
local spec_templates = if script ~= nil
	then require(script.Parent.systems.templates)
	else require("./systems/templates")
local spec_connectivity = if script ~= nil
	then require(script.Parent.systems.connectivity)
	else require("./systems/connectivity")
local spec_details = if script ~= nil
	then require(script.Parent.systems.details)
	else require("./systems/details")
local spec_world = if script ~= nil
	then require(script.Parent.systems.world)
	else require("./systems/world")
local spec_visibility = if script ~= nil
	then require(script.Parent.systems.visibility)
	else require("./systems/visibility")
local spec_render = if script ~= nil
	then require(script.Parent.systems.render)
	else require("./systems/render")
local spec_style = if script ~= nil
	then require(script.Parent.systems.style)
	else require("./systems/style")
local spec_lighting = if script ~= nil
	then require(script.Parent.systems.lighting)
	else require("./systems/lighting")
local spec_props = if script ~= nil
	then require(script.Parent.systems.props)
	else require("./systems/props")
local spec_tileset = if script ~= nil
	then require(script.Parent.systems.tileset)
	else require("./systems/tileset")
local spec_hazards = if script ~= nil
	then require(script.Parent.systems.hazards)
	else require("./systems/hazards")
local spec_entities = if script ~= nil
	then require(script.Parent.systems.entities)
	else require("./systems/entities")
local spec_transitions = if script ~= nil
	then require(script.Parent.systems.transitions)
	else require("./systems/transitions")
local spec_generate = if script ~= nil
	then require(script.Parent.systems.generate)
	else require("./systems/generate")

local catalog = {}

local specs: { any } = {
	spec_core,
	spec_strategy,
	spec_terrain,
	spec_structures,
	spec_templates,
	spec_connectivity,
	spec_details,
	spec_world,
	spec_visibility,
	spec_render,
	spec_style,
	spec_lighting,
	spec_props,
	spec_tileset,
	spec_hazards,
	spec_entities,
	spec_transitions,
	spec_generate,
}

-- Fresh System values on every call, so callers may mutate their registry freely.
function catalog.systems(): { System.System }
	local out = {}
	for _, spec in ipairs(specs) do
		table.insert(out, System.define(spec))
	end
	return out
end

return catalog
