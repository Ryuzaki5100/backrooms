--!strict

-- Level runtime bootstrap (ADR 0032 A1, ADR 0033 D78). The host does the work:
-- see ServerScriptService.Level.LevelHost. Kept under this name for the Rojo
-- mapping and the docs.

local LevelHost = require(script.Parent.Parent:WaitForChild("Level"):WaitForChild("LevelHost"))

LevelHost.start("level-0")
