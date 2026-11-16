local T = ...

local function loadLib(mock)
	_G.LibStub = nil
	assert(loadfile("tests/vendor/LibStub.lua"))()
	assert(loadfile("lib/LibUIShots-1.0/LibUIShots-1.0.lua"))()
	mock.screenshots = 0
	_G.DEFAULT_CHAT_FRAME.AddMessage = function(_, msg)
		mock.chat[#mock.chat + 1] = { msg }
	end
	return LibStub("LibUIShots-1.0")
end

local function runAll(mock, seconds)
	for _ = 1, math.ceil(seconds / 0.1) do
		mock.Advance(0.1)
		if mock.screenshotPending then
			mock.screenshotPending = false
			mock.FireEvent("SCREENSHOT_SUCCEEDED")
		end
	end
end

T.case("shots: every step is set up, shot and torn down; the manifest is saved", function()
	local mock = T.fresh()
	local Shots = loadLib(mock)
	_G.Screenshot = function()
		mock.screenshots = mock.screenshots + 1
		mock.screenshotPending = true
	end
	local log, store = {}, {}
	Shots:Register("Test", {
		{ name = "one", setup = function()
			log[#log + 1] = "setup one"
		end, teardown = function()
			log[#log + 1] = "teardown one"
		end },
		{ name = "two", setup = function()
			log[#log + 1] = "setup two"
		end },
	}, { store = function()
		return store
	end, delay = 0.2 })
	T.ok(Shots:Start("Test"))
	T.ok(not Shots:Start("Test"), "only one run at a time")
	runAll(mock, 10)
	T.eq(mock.screenshots, 2)
	T.eq(table.concat(log, ","), "setup one,teardown one,setup two")
	T.eq(#store.shots.shots, 2)
	T.eq(store.shots.shots[2].name, "two")
	T.ok(store.shots.shots[1].ok)
	T.ok(not Shots:IsRunning())
	T.ok(not Shots.backdrop:IsShown(), "backdrop hidden again")
end)

T.case("shots: refuses to start in combat, stops when combat starts or on Escape", function()
	local mock = T.fresh()
	local Shots = loadLib(mock)
	_G.Screenshot = function() end
	local tornDown = false
	Shots:Register("Test", { { name = "one", setup = function() end, teardown = function()
		tornDown = true
	end } }, { delay = 5 })
	mock.inCombat = true
	local ok, why = Shots:Start("Test")
	T.ok(not ok)
	T.eq(why, "inCombat")
	mock.inCombat = false
	T.ok(Shots:Start("Test"))
	runAll(mock, 1)
	mock.FireEvent("PLAYER_REGEN_DISABLED")
	T.ok(not Shots:IsRunning(), "stopped by combat")
	T.ok(tornDown, "the step was torn down")
	T.ok(Shots:Start("Test"))
	runAll(mock, 1)
	Shots.keys:GetScript("OnKeyDown")(Shots.keys, "ESCAPE")
	T.ok(not Shots:IsRunning(), "stopped by Escape")
end)
