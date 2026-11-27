--!strict

local Harness = require("./harness")
local process = require("@lune/process")

require("./procgen/hash.spec")
require("./procgen/rng.spec")
require("./procgen/seed.spec")
require("./procgen/config.spec")
require("./procgen/grid.spec")
require("./procgen/world.spec")
require("./procgen/strategy.spec")
require("./procgen/open-additive.spec")
require("./procgen/walkgraph.spec")
require("./procgen/closure.spec")
require("./procgen/template.spec")
require("./procgen/streaming.spec")

process.exit(Harness.run())
