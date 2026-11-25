--!strict

-- Thin Roblox layer: turn a geometry description into Parts.
--
-- All geometry decisions live in `ReplicatedStorage.Procgen.Geometry`; this
-- module only applies them. Keeping it dumb is what lets the pure layer be
-- tested under Lune and hashed across Lune and Studio.
--
-- QA rule (ADR 0011): a non-debug apply refuses to create any part tagged `qa`.
-- That guard exists so debug markers cannot ship by accident.

local CollectionService = game:GetService("CollectionService")

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
		local part = Instance.new("Part")
		part.Name = tostring(spec.owner) .. "_" .. tostring(spec.kind)
		part.Size = toVector(spec.size)
		local cframe = CFrame.new(toVector(spec.position))
		if spec.yaw ~= nil and spec.yaw ~= 0 then
			cframe = cframe * CFrame.Angles(0, math.rad(spec.yaw * 90), 0)
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
