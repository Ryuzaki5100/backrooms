--!strict

-- Thin Roblox layer: turn a geometry description into Parts.
--
-- All geometry decisions live in `ReplicatedStorage.Procgen.Geometry`; this
-- module only applies them. Keeping it dumb is what lets the pure layer be
-- tested under Lune and hashed across Lune and Studio.
--
-- QA rule (ADR 0011): a non-debug apply refuses to create any part tagged `qa`.
-- That guard exists so debug markers cannot ship by accident.
--
-- A template spec (`spec.template`) is a clone order, not a box: the model is
-- authored once in `ServerStorage.Assets.Templates` and cloned at the footprint
-- (task 0038). M19 owns when that happens (streaming, unloading, yaw and the
-- doorway cut); this hook only applies one order.

local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")

local Build = {}

local FOLDER_NAME = "NoclipBuild"

local function toVector(value: { number }): Vector3
	return Vector3.new(value[1], value[2], value[3])
end

local function materialOf(name: string): Enum.Material
	local ok, material = pcall(function()
		return Enum.Material[name]
	end)
	if ok and material ~= nil then
		return material
	end
	return Enum.Material.SmoothPlastic
end

-- A template is resolved by `noclipTemplateId`, not by `Name`: the name carries
-- the variant (`setpiece_manila_room_a`), the attribute carries the id a level
-- names (`20-assets/templates/contract.md`). An exact-name child still wins, so
-- an asset renamed to its id keeps working.
local function findTemplate(id: string): Instance?
	local assets = ServerStorage:FindFirstChild("Assets")
	if assets == nil then
		return nil
	end
	local templates = assets:FindFirstChild("Templates")
	if templates == nil then
		return nil
	end
	local direct = templates:FindFirstChild(id)
	if direct ~= nil and direct:IsA("Model") then
		return direct
	end
	for _, child in ipairs(templates:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("noclipTemplateId") == id then
			return child
		end
	end
	return nil
end

-- Clone one authored set piece and pivot its footprint corner onto the spec
-- position. Attributes and tags come with the clone; `PrimaryPart` is left
-- unset because the model's `WorldPivot` is the contract's pivot.
local function applyTemplate(spec: any, parent: Folder): ()
	if type(spec.template) ~= "string" or spec.template == "" then
		error("Build.apply: template spec has no asset id", 3)
	end
	local source = findTemplate(spec.template)
	if source == nil then
		error(
			string.format(
				"Build.apply: no template model for id %q in ServerStorage.Assets.Templates",
				spec.template
			),
			3
		)
	end
	local model = source:Clone() :: Model
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
	local cframe = CFrame.new(toVector(spec.position))
	if spec.yaw ~= nil and spec.yaw ~= 0 then
		cframe = cframe * CFrame.Angles(0, math.rad(spec.yaw), 0)
	end
	model:PivotTo(cframe)
	model.Parent = parent
end

function Build.clear(): ()
	local existing = workspace:FindFirstChild(FOLDER_NAME)
	if existing ~= nil then
		existing:Destroy()
	end
end

function Build.apply(parts: { any }, options: any?): Folder
	local debug = options ~= nil and options.debug == true

	if not debug then
		for _, spec in ipairs(parts) do
			if spec.tag == "qa" then
				error(
					string.format(
						"Build.apply: refusing to build QA part %q in a non-debug build",
						tostring(spec.owner)
					),
					2
				)
			end
		end
	end

	Build.clear()

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME

	for _, spec in ipairs(parts) do
		if spec.template ~= nil then
			applyTemplate(spec, folder)
			continue
		end

		-- Ramps are true wedges (ADR 0029), not tilted boxes. Part yaw is in degrees
		-- (ChunkRenderer documents the wedge mapping), hence math.rad(spec.yaw).
		local part = Instance.new(if spec.wedge == true then "WedgePart" else "Part")
		part.Name = tostring(spec.owner) .. "_" .. tostring(spec.kind)
		part.Size = toVector(spec.size)
		local cframe = CFrame.new(toVector(spec.position))
		if spec.yaw ~= nil and spec.yaw ~= 0 then
			cframe = cframe * CFrame.Angles(0, math.rad(spec.yaw), 0)
		end
		if spec.pitch ~= nil and spec.pitch ~= 0 then
			cframe = cframe * CFrame.Angles(0, 0, math.rad(spec.pitch))
		end
		part.CFrame = cframe
		part.Anchored = true
		part.CanCollide = spec.canCollide ~= false
		part.Material = materialOf(spec.material)
		part.Color = Color3.new(spec.color[1], spec.color[2], spec.color[3])
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part:SetAttribute("noclipKind", spec.kind)
		part:SetAttribute("noclipOwner", spec.owner)
		if spec.tag ~= nil then
			part:SetAttribute("noclipTag", spec.tag)
			CollectionService:AddTag(part, "noclip." .. tostring(spec.tag))
		end
		part.Parent = folder
	end

	folder.Parent = workspace
	return folder
end

return Build
