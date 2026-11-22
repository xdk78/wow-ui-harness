-- The harness's own tests. Plain Lua 5.1, from the repository root:  lua tests/run.lua [filter]
-- Each case gets a fresh mock (the module is reloaded), so cases do not share frames.

package.path = "./lua/?.lua;./tests/?.lua;" .. package.path

local realPrint = print
local passed, failed = 0, 0
local filter = arg[1]

local T = {}

function T.eq(actual, expected, msg)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", msg or "values differ", tostring(expected), tostring(actual)), 2)
	end
end

function T.near(actual, expected, msg, tol)
	if type(actual) ~= "number" or math.abs(actual - expected) > (tol or 0.01) then
		error(string.format("%s: expected %s, got %s", msg or "values differ", tostring(expected), tostring(actual)), 2)
	end
end

function T.ok(v, msg)
	if not v then
		error(msg or "expected a true value", 2)
	end
end

-- A fresh mock with the client API installed; layout on when `layoutOpts` is given.
function T.fresh(layoutOpts)
	for name in pairs(package.loaded) do
		if name:match("^wowui") then
			package.loaded[name] = nil
		end
	end
	local mock = require("wowui.mock")
	mock.Install()
	if layoutOpts then
		require("wowui.layout").Enable(mock, layoutOpts)
	end
	return mock
end

function T.case(name, fn)
	if filter and not name:find(filter, 1, true) then
		return
	end
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		realPrint("FAIL " .. name .. "\n     " .. tostring(err))
	end
end

for _, file in ipairs({ "test_mock.lua", "test_layout.lua", "test_text.lua", "test_dump_lint.lua", "test_shots.lua",
	"test_client.lua" }) do
	assert(loadfile("tests/" .. file))(T)
end

_G.print = realPrint
realPrint(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
