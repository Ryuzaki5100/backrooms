--!strict

local Harness = require("./harness")
local process = require("@lune/process")

require("./procgen/hash.spec")
require("./procgen/rng.spec")
require("./procgen/seed.spec")
require("./procgen/plan.spec")
require("./procgen/plan-codec.spec")
require("./procgen/macro.spec")
require("./procgen/config.spec")

process.exit(Harness.run())
