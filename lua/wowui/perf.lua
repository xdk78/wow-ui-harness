-- wowui.perf: the cost of Lua code as a number of Lua VM instructions, for budgets in tests that give the same
-- answer on every run and machine (unlike time).
--
--   local Perf = require("wowui.perf")
--   local n = Perf.count(function() MyAddon:Refresh() end)
--   assert(n < 50000, "Refresh costs " .. n .. " instructions")
--
-- Perf.count(fn, ...) runs fn(...) with a count hook (debug.sethook, one call per instruction) and returns the number
-- of instructions, then fn's results. Coroutines created by fn (coroutine.create / coroutine.wrap) are counted too.
-- A hook that was set before (a coverage tool's line hook, an outer Perf.count) keeps getting its events while fn
-- runs and is put back afterwards, also when fn raises (the error goes on unchanged).
--
-- What the number is and is not:
--   - Lua instructions only: a call into a C function (string.format, table.sort, the mock's API is Lua) is one
--     instruction however much work it does, so budgets compare Lua code paths, not wall time.
--   - It depends on the Lua build: Lua 5.1 and 5.2+ compile to different instruction sets, and LuaJIT does not run
--     count hooks for compiled code. Record budgets with the Lua the tests run on in CI (5.1.5, as the game's).
--   - Coroutines that already existed before fn and are resumed by it are not counted (a hook is per coroutine).
--     One created by a coroutine.create the code saved in a local before counting is counted (Lua 5.1 copies the
--     hook into it) but keeps that hook afterwards.
--   - Counting is slow (a hook call per instruction): keep the measured work small.

local Perf = {}

local function pack(...)
	return { n = select("#", ...), ... }
end

-- A hook that counts every instruction into `box.n` and passes the events the previous hook asked for on to it.
local function makeHook(box, prev, prevMask, prevCount)
	local wantLine = prevMask and prevMask:find("l", 1, true)
	local wantCall = prevMask and prevMask:find("c", 1, true)
	local wantReturn = prevMask and prevMask:find("r", 1, true)
	local wantCount = prev and prevCount and prevCount > 0
	local sinceCount = 0
	return function(event, line)
		if event == "count" then
			box.n = box.n + 1
			if wantCount then
				sinceCount = sinceCount + 1
				if sinceCount >= prevCount then
					sinceCount = 0
					prev("count")
				end
			end
		elseif prev and ((event == "line" and wantLine) or ((event == "call" or event == "tail call") and wantCall)
			or (event == "return" and wantReturn)) then
			prev(event, line)
		end
	end
end

local function maskOf(prevMask)
	local mask = ""
	for _, c in ipairs({ "c", "r", "l" }) do
		if prevMask and prevMask:find(c, 1, true) then
			mask = mask .. c
		end
	end
	return mask
end

local overhead -- instructions Perf.count spends around fn itself (measured once), taken off every result

local function raw(fn, ...)
	local prev, prevMask, prevCount = debug.gethook()
	local box = { n = 0 }
	local hook = makeHook(box, prev, prevMask, prevCount)
	local mask = maskOf(prevMask)
	local create, wrap = coroutine.create, coroutine.wrap
	-- New coroutines get the same counting hook (debug.sethook applies to one coroutine only; Lua 5.1 also copies the
	-- creator's hook into a new coroutine). Afterwards they get the previous hook back.
	local made = setmetatable({}, { __mode = "k" })
	local function counted(f)
		local co = create(f)
		debug.sethook(co, hook, mask, 1)
		made[co] = true
		return co
	end
	rawset(coroutine, "create", counted)
	rawset(coroutine, "wrap", function(f)
		local co = counted(f)
		return function(...)
			local r = pack(coroutine.resume(co, ...))
			if not r[1] then
				error(r[2], 0)
			end
			return unpack(r, 2, r.n)
		end
	end)
	debug.sethook(hook, mask, 1)
	local r = pack(pcall(fn, ...))
	debug.sethook()
	rawset(coroutine, "create", create)
	rawset(coroutine, "wrap", wrap)
	for co in pairs(made) do
		if coroutine.status(co) ~= "dead" then
			if prev then
				debug.sethook(co, prev, prevMask, prevCount)
			else
				debug.sethook(co)
			end
		end
	end
	if prev then
		debug.sethook(prev, prevMask, prevCount)
	end
	if not r[1] then
		error(r[2], 0)
	end
	return box.n, unpack(r, 2, r.n)
end

local function empty() end

function Perf.count(fn, ...)
	if not overhead then
		overhead = raw(empty)
	end
	local r = pack(raw(fn, ...))
	r[1] = r[1] - overhead
	return unpack(r, 1, r.n)
end

return Perf
