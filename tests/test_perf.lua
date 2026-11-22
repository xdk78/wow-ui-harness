-- wowui.perf: instruction counts for deterministic budgets.
local T = ...

local function loop(n)
	local s = 0
	for i = 1, n do
		s = s + i
	end
	return s
end

T.case("perf.count: deterministic, linear, returns fn's results", function()
	local Perf = require("wowui.perf")
	T.eq(Perf.count(function() end), 0, "an empty function costs nothing")
	local a = Perf.count(loop, 100)
	T.eq(Perf.count(loop, 100), a, "the same count every run")
	local b = Perf.count(loop, 200)
	T.eq(Perf.count(loop, 300) - b, b - a, "linear in the work")
	T.ok(b > a, "more work, more instructions")
	local n, s, extra = Perf.count(function(x)
		return loop(x), nil
	end, 10)
	T.ok(n > 0)
	T.eq(s, 55, "fn's results follow the count")
	T.eq(extra, nil)
	T.eq(select("#", Perf.count(function()
		return 1, nil, 3
	end)), 4, "a nil among the results is kept")
end)

T.case("perf.count: errors go on; the previous hook is put back and keeps its events", function()
	local Perf = require("wowui.perf")
	local lines = 0
	local function lineHook()
		lines = lines + 1
	end
	debug.sethook(lineHook, "l")
	local ok, err = pcall(Perf.count, function()
		local x = 1
		x = x + 1
		error("boom " .. x)
	end)
	local hook, mask = debug.gethook()
	debug.sethook()
	T.eq(ok, false)
	T.ok(tostring(err):find("boom 2", 1, true), tostring(err))
	T.eq(hook, lineHook, "the previous hook is back")
	T.eq(mask, "l")
	T.ok(lines > 0, "the line hook saw lines while counting")
	T.eq(debug.gethook(), nil, "no hook left behind")
	T.eq(Perf.count(function() end), 0, "nothing left behind either")
end)

T.case("perf.count: coroutines created inside are counted; nested counts add up", function()
	local Perf = require("wowui.perf")
	local plain = Perf.count(loop, 50)
	local viaCoroutine = Perf.count(function()
		local co = coroutine.create(loop)
		coroutine.resume(co, 50)
		local w = coroutine.wrap(loop)
		w(50)
	end)
	T.ok(viaCoroutine > 2 * plain, "both coroutines' loops counted: " .. viaCoroutine .. " vs " .. plain)
	local kept
	Perf.count(function()
		kept = coroutine.create(function()
			coroutine.yield()
		end)
		coroutine.resume(kept)
	end)
	T.eq(debug.gethook(kept), nil, "a coroutine still alive gets its hook taken off")
	local inner
	local outer = Perf.count(function()
		inner = Perf.count(loop, 50)
	end)
	T.eq(inner, plain)
	T.ok(outer > inner, "the outer count includes the inner one")
	local ok = pcall(Perf.count, coroutine.wrap(function()
		error("in a wrapped coroutine")
	end))
	T.eq(ok, false, "errors from coroutines go on")
end)
