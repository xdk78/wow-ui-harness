-- The example addon's views, dumped and linted through wowui.runner. From the repository root:
--   lua examples/dump_example.lua --out <dir> [--baseline examples/lint_baseline.txt]
-- An addon's own dump script looks like this, with its own views and stubs.

package.path = "./lua/?.lua;" .. package.path

local mock = require("wowui.mock")
local runner = require("wowui.runner")
local Views = require("wowui.views")

local ns = {}

local function window()
	return ns.frame
end

-- An interaction as a sequence of views, seq-example-01 .. 03: each step builds on the previous one, and the captions
-- end up in the dumps' meta for `wowui.py gif`.
local steps = Views.Sequence("example", {
	{
		caption = "The window at its normal size",
		setup = function()
			ns.frame:SetSize(300, 200)
		end,
	},
	{
		caption = "Step 2 changes the text",
		setup = function()
			ns.frame.body:SetText("The body text changed in the second step.")
		end,
	},
	{
		caption = "Step 3 recolours the swatch",
		setup = function()
			ns.frame.swatch.tex:SetColorTexture(0.2, 0.7, 0.3, 1)
		end,
	},
}, { window = window })

local views = {
	{ name = "main", setup = function() ns.Build() end, window = window },
	{ name = "small", setup = function() ns.frame:SetSize(220, 160) end, window = window },
}
for _, view in ipairs(steps) do
	views[#views + 1] = view
end

os.exit(runner.Main(mock, {
	-- install = function(ctx) ... end: mock.Install() plus the game-data stubs the addon reads (the default installs the
	-- generic API only).
	prepare = function()
		mock.LoadAddon("examples/HarnessExample", "HarnessExample.toc", "HarnessExample", ns)
	end,
	views = views,
}, arg))
