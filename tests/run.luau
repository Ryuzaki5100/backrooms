--!strict

local Harness = require("./harness")
local process = require("@lune/process")

require("./procgen/hash.spec")
require("./procgen/rng.spec")
require("./procgen/seed.spec")
require("./procgen/plan.spec")

process.exit(Harness.run())
