--!strict

-- Lighting and atmosphere (ADR 0033 D78). `lighting.resolve` is the pure half: it
-- fills defaults and returns a profile of plain values (hex strings, numbers) that
-- is JSON-safe. `hooks.runtime` is the Roblox half: the server applies the profile
-- to game.Lighting and publishes it for clients as Workspace.NoclipLightingProfile.
--
-- The Sky is never created, changed or removed here: sky colour stays as authored.

export type Atmosphere = {
	density: number,
	offset: number,
	color: string,
	decay: string,
	glare: number,
	haze: number,
}

export type ColorCorrection = {
	brightness: number,
	contrast: number,
	saturation: number,
	tintColor: string,
}

export type Profile = {
	clockTime: number,
	brightness: number,
	ambient: string,
	outdoorAmbient: string,
	fogStart: number,
	fogEnd: number,
	fogColor: string,
	exposure: number,
	globalShadows: boolean,
	environmentDiffuseScale: number,
	environmentSpecularScale: number,
	bloom: number,
	atmosphere: Atmosphere?,
	colorCorrection: ColorCorrection?,
}

local lighting: any = {}

lighting.ATTRIBUTE = "NoclipLightingProfile"

local function pick(value: any, default: any): any
	if value == nil then
		return default
	end
	return value
end

-- Missing keys take defaults. outdoorAmbient and fogColor follow ambient unless set.
function lighting.resolve(section: any): Profile
	local s: any = if type(section) == "table" then section else {}
	local ambient = pick(s.ambient, "#000000")
	local profile: any = {
		clockTime = pick(s.clockTime, 14),
		brightness = pick(s.brightness, 2),
		ambient = ambient,
		outdoorAmbient = pick(s.outdoorAmbient, ambient),
		fogStart = pick(s.fogStart, 0),
		fogEnd = pick(s.fogEnd, 100000),
		fogColor = pick(s.fogColor, ambient),
		exposure = pick(s.exposure, 0),
		globalShadows = pick(s.globalShadows, true),
		environmentDiffuseScale = pick(s.environmentDiffuseScale, 0),
		environmentSpecularScale = pick(s.environmentSpecularScale, 0),
		bloom = pick(s.bloom, 0),
	}
	if type(s.atmosphere) == "table" then
		local a = s.atmosphere
		profile.atmosphere = {
			density = pick(a.density, 0.3),
			offset = pick(a.offset, 0),
			color = pick(a.color, "#c7c7c7"),
			decay = pick(a.decay, "#6a6a6a"),
			glare = pick(a.glare, 0),
			haze = pick(a.haze, 0),
		}
	end
	if type(s.colorCorrection) == "table" then
		local c = s.colorCorrection
		profile.colorCorrection = {
			brightness = pick(c.brightness, 0),
			contrast = pick(c.contrast, 0),
			saturation = pick(c.saturation, 0),
			tintColor = pick(c.tintColor, "#ffffff"),
		}
	end
	return profile
end

local function checkNumber(
	problems: { string },
	path: string,
	value: any,
	low: number,
	high: number
)
	if value == nil then
		return
	end
	if type(value) ~= "number" or value ~= value then
		table.insert(problems, `{path}: expected a number, got {type(value)}`)
	elseif value < low or value > high then
		table.insert(problems, `{path}: {value} is outside {low}..{high}`)
	end
end

local function checkHex(problems: { string }, path: string, value: any)
	if value == nil then
		return
	end
	if type(value) ~= "string" or string.match(value, "^#%x%x%x%x%x%x$") == nil then
		table.insert(problems, `{path}: expected a #rrggbb colour, got {tostring(value)}`)
	end
end

local function checkGroup(
	problems: { string },
	section: any,
	name: string,
	numbers: { { any } },
	colors: { string }
)
	local group = section[name]
	if group == nil then
		return
	end
	if type(group) ~= "table" then
		table.insert(problems, `lighting.{name}: expected a table, got {type(group)}`)
		return
	end
	for _, entry in ipairs(numbers) do
		checkNumber(problems, `lighting.{name}.{entry[1]}`, group[entry[1]], entry[2], entry[3])
	end
	for _, key in ipairs(colors) do
		checkHex(problems, `lighting.{name}.{key}`, group[key])
	end
end

function lighting.validate(section: any, _level: any?): { string }
	if type(section) ~= "table" then
		return { `lighting: expected a table, got {type(section)}` }
	end
	local problems: { string } = {}
	checkNumber(problems, "lighting.clockTime", section.clockTime, 0, 24)
	checkNumber(problems, "lighting.brightness", section.brightness, 0, 10)
	checkHex(problems, "lighting.ambient", section.ambient)
	checkHex(problems, "lighting.outdoorAmbient", section.outdoorAmbient)
	checkNumber(problems, "lighting.fogStart", section.fogStart, 0, 5000)
	checkNumber(problems, "lighting.fogEnd", section.fogEnd, 0, 100000)
	checkHex(problems, "lighting.fogColor", section.fogColor)
	checkNumber(problems, "lighting.exposure", section.exposure, -3, 3)
	if section.globalShadows ~= nil and type(section.globalShadows) ~= "boolean" then
		table.insert(problems, "lighting.globalShadows: expected a boolean")
	end
	checkNumber(problems, "lighting.environmentDiffuseScale", section.environmentDiffuseScale, 0, 1)
	checkNumber(
		problems,
		"lighting.environmentSpecularScale",
		section.environmentSpecularScale,
		0,
		1
	)
	checkNumber(problems, "lighting.bloom", section.bloom, 0, 2)
	checkGroup(problems, section, "atmosphere", {
		{ "density", 0, 1 },
		{ "offset", 0, 1 },
		{ "glare", 0, 10 },
		{ "haze", 0, 10 },
	}, { "color", "decay" })
	checkGroup(problems, section, "colorCorrection", {
		{ "brightness", -1, 1 },
		{ "contrast", -1, 1 },
		{ "saturation", -1, 1 },
	}, { "tintColor" })

	if #problems == 0 then
		local resolved = lighting.resolve(section)
		if resolved.fogStart >= resolved.fogEnd then
			table.insert(
				problems,
				`lighting: fogStart {resolved.fogStart} must be below fogEnd {resolved.fogEnd}`
			)
		end
	end
	return problems
end

-- Roblox half ------------------------------------------------------------------

local function color(hex: string): any
	return (Color3 :: any).fromHex(hex)
end

-- Finds or creates a named child of Lighting. Matches by name only, so an
-- authored Sky (or any other effect) is never touched.
local function child(parent: any, className: string, name: string): any
	local existing = parent:FindFirstChild(name)
	if existing ~= nil and existing.ClassName == className then
		return existing
	end
	if existing ~= nil then
		existing:Destroy()
	end
	local created = Instance.new(className)
	created.Name = name
	created.Parent = parent
	return created
end

local function drop(parent: any, name: string)
	local old = parent:FindFirstChild(name)
	if old ~= nil then
		old:Destroy()
	end
end

function lighting.apply(profile: Profile)
	local service: any = game:GetService("Lighting")
	service.ClockTime = profile.clockTime
	service.Brightness = profile.brightness
	service.Ambient = color(profile.ambient)
	service.OutdoorAmbient = color(profile.outdoorAmbient)
	service.FogStart = profile.fogStart
	service.FogEnd = profile.fogEnd
	service.FogColor = color(profile.fogColor)
	service.ExposureCompensation = profile.exposure
	service.GlobalShadows = profile.globalShadows
	service.EnvironmentDiffuseScale = profile.environmentDiffuseScale
	service.EnvironmentSpecularScale = profile.environmentSpecularScale

	if profile.bloom > 0 then
		local effect = child(service, "BloomEffect", "NoclipBloom")
		effect.Intensity = profile.bloom
		effect.Enabled = true
	else
		drop(service, "NoclipBloom")
	end

	local atmosphere = profile.atmosphere
	if atmosphere ~= nil then
		local effect = child(service, "Atmosphere", "NoclipAtmosphere")
		effect.Density = atmosphere.density
		effect.Offset = atmosphere.offset
		effect.Color = color(atmosphere.color)
		effect.Decay = color(atmosphere.decay)
		effect.Glare = atmosphere.glare
		effect.Haze = atmosphere.haze
	else
		drop(service, "NoclipAtmosphere")
	end

	local correction = profile.colorCorrection
	if correction ~= nil then
		local effect = child(service, "ColorCorrectionEffect", "NoclipColorCorrection")
		effect.Brightness = correction.brightness
		effect.Contrast = correction.contrast
		effect.Saturation = correction.saturation
		effect.TintColor = color(correction.tintColor)
		effect.Enabled = true
	else
		drop(service, "NoclipColorCorrection")
	end
end

-- System.define accepts functions only, so one runtime hook takes the side first:
-- hooks.runtime("server", host) stands for hooks.runtime.server(host).
local function runtime(side: string, host: any)
	if side ~= "server" then
		return
	end
	local profile = lighting.resolve(host.config.lighting)
	lighting.apply(profile)
	local json = (game:GetService("HttpService") :: any):JSONEncode(profile)
	host.setAttribute(lighting.ATTRIBUTE, json)
end

lighting.id = "lighting"
lighting.owns = { "lighting" }
lighting.phase = "runtime"
lighting.stage = "world"
lighting.status = "active"
lighting.hooks = { runtime = runtime }

return lighting
