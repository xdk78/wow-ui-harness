-- The example addon's views, dumped and linted through wowui.runner. From the repository root:
--   lua examples/dump_example.lua --out <dir> [--baseline examples/lint_baseline.txt]
-- An addon's own dump script looks like this, with its own views and stubs.

package.path = "./lua/?.lua;" .. package.path

local mock = require("wowui.mock")
local runner = require("wowui.runner")

local ns = {}

os.exit(runner.Main(mock, {
	-- install = function(ctx) ... end: mock.Install() plus the game-data stubs the addon reads (the default installs the
	-- generic API only).
	prepare = function()
		mock.LoadAddon("examples/HarnessExample", "HarnessExample.toc", "HarnessExample", ns)
	end,
	views = {
		{
			name = "main",
			setup = function()
				ns.Build()
			end,
			window = function()
				return ns.frame
			end,
		},
		{
			name = "small",
			setup = function()
				ns.frame:SetSize(220, 160)
			end,
			window = function()
				return ns.frame
			end,
		},
	},
}, arg))
