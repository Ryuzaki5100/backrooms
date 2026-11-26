--!strict

local Harness = require("./harness")
local process = require("@lune/process")

require("./procgen/hash.spec")
require("./procgen/rng.spec")
require("./procgen/seed.spec")
require("./procgen/plan.spec")
require("./procgen/plan-codec.spec")
require("./procgen/macro.spec")
require("./procgen/embedding.spec")
require("./procgen/geometry.spec")
require("./procgen/qa.spec")
require("./procgen/config.spec")
require("./procgen/grid.spec")
require("./procgen/world.spec")
require("./procgen/strategy.spec")
require("./procgen/open-additive.spec")
require("./procgen/walkgraph.spec")
require("./procgen/template.spec")

process.exit(Harness.run())
