--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NoclipConfig = require(ReplicatedStorage:WaitForChild("NoclipConfig"))

print(string.format("[noclip] boot ok - %s v%s", NoclipConfig.name, NoclipConfig.version))
