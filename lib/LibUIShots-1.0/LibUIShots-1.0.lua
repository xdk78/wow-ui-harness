--[[
LibUIShots-1.0: walk an addon's UI through a list of steps and take a screenshot after each, out of combat, with a
plain backdrop behind the addon's windows, an Escape key that stops it, and a manifest of what each shot shows.

	local Shots = LibStub("LibUIShots-1.0")
	Shots:Register("MyAddon", {
		{ name = "main window", setup = function() MyAddon:Open() end, teardown = function() MyAddon:Close() end },
		{ name = "options", setup = OpenMyOptions, delay = 1.0 },
	}, {
		store = function() return MyAddonDB end,   -- the manifest goes to store().shots (optional)
		print = function(msg) MyAddon:Print(msg) end, -- chat output (optional; default: the default chat frame)
		delay = 0.8,                               -- seconds between a step's setup and its screenshot (default 0.8)
		backdrop = { 0.08, 0.08, 0.09, 1 },        -- a full-screen colour under the HIGH strata; false: none
		before = function() end, after = function(manifest) end, -- around the whole run
		text = { ... },                            -- the messages, for translation (see TEXT below)
	})
	Shots:Start("MyAddon")   -- returns false, reason when it cannot start (in combat, already running, no steps)
	Shots:Stop("MyAddon")    -- stops after restoring (Escape and entering combat do the same)

Callbacks (CallbackHandler-1.0, when it is loaded): "Started" (addon), "Shot" (addon, entry), "Finished" (addon,
manifest). Rules the library keeps: never runs in combat (Start refuses, PLAYER_REGEN_DISABLED stops it), touches no
secure frame and hooks nothing, hides nothing of the game's own UI (the backdrop covers what sits below HIGH strata),
and restores what it changed after the last step or an abort. The manifest lists every shot with its step name, index
and time, so the files in the game's Screenshots folder can be matched to steps by their time order.
]]

local MAJOR, MINOR = "LibUIShots-1.0", 1
local LibStub = _G.LibStub
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then
	return
end

lib.VERSION = "0.1.0"
lib.addons = lib.addons or {}
lib.run = nil

local CBH = LibStub("CallbackHandler-1.0", true)
if CBH and not lib.callbacks then
	lib.callbacks = CBH:New(lib)
end

-- Messages; an addon passes `text` with the same keys to translate them (%s / %d in the same order).
lib.TEXT = {
	started = "Screenshots: %d steps. Press Escape to stop.",
	step = "Screenshot %d/%d: %s",
	done = "Screenshots done: %d taken. They are in the game's Screenshots folder, in this order:",
	aborted = "Screenshots stopped (%s) after %d.",
	combat = "in combat",
	escape = "Escape",
	failed = "a step failed: %s",
	busy = "already running",
	noSteps = "no steps registered",
	inCombat = "cannot start in combat",
	line = "%d. %s  %s",
	lineFailed = "%d. %s  %s (failed)",
}

local function now()
	return GetTime and GetTime() or 0
end

local function fire(event, ...)
	if lib.callbacks then
		lib.callbacks:Fire(event, ...)
	end
end

local function say(run, key, ...)
	local fmt = (run.opts.text and run.opts.text[key]) or lib.TEXT[key] or key
	local ok, msg = pcall(string.format, fmt, ...)
	msg = ok and msg or fmt
	if run.opts.print then
		pcall(run.opts.print, msg)
	elseif DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99" .. MAJOR .. "|r " .. msg)
	end
end

-- Register (or replace) an addon's steps. steps: { { name, setup = fn(ctx), teardown = fn(ctx), delay = s } }.
function lib:Register(addon, steps, opts)
	assert(type(addon) == "string", "addon must be a string")
	assert(type(steps) == "table", "steps must be a table")
	lib.addons[addon] = { steps = steps, opts = opts or {} }
end

function lib:IsRunning(addon)
	return lib.run ~= nil and (addon == nil or lib.run.addon == addon)
end

-- Frames ---------------------------------------------------------------------------------------------------------------

local function backdropFrame()
	local f = lib.backdrop
	if not f then
		f = CreateFrame("Frame", nil, UIParent)
		f:SetAllPoints(UIParent)
		f.tex = f:CreateTexture(nil, "BACKGROUND")
		f.tex:SetAllPoints()
		f:Hide()
		lib.backdrop = f
	end
	-- Under the HIGH strata the addon windows usually use, over the world and the game's bars and chat.
	f:SetFrameStrata("MEDIUM")
	f:SetFrameLevel(9000)
	return f
end

-- An invisible frame that sees key presses first, takes Escape and lets every other key through.
local function keyFrame()
	local f = lib.keys
	if not f then
		f = CreateFrame("Frame", nil, UIParent)
		f:SetFrameStrata("FULLSCREEN_DIALOG")
		f:SetSize(1, 1)
		f:SetPoint("TOPLEFT")
		f:SetScript("OnKeyDown", function(self, key)
			local escape = key == "ESCAPE"
			if self.SetPropagateKeyboardInput and not (InCombatLockdown and InCombatLockdown()) then
				pcall(self.SetPropagateKeyboardInput, self, not escape)
			end
			if escape and lib.run then
				lib:Stop(lib.run.addon, "escape")
			end
		end)
		f:Hide()
		lib.keys = f
	end
	return f
end

local function eventFrame()
	local f = lib.events
	if not f then
		f = CreateFrame("Frame")
		f:SetScript("OnEvent", function(_, event)
			local run = lib.run
			if not run then
				return
			end
			if event == "PLAYER_REGEN_DISABLED" then
				lib:Stop(run.addon, "combat")
			elseif event == "SCREENSHOT_SUCCEEDED" or event == "SCREENSHOT_FAILED" then
				lib.Step(run, event)
			end
		end)
		lib.events = f
	end
	return f
end

-- The run: a small state machine. Phases: "setup" (wait `delay`), "shot" (Screenshot() called, wait for its event or
-- a timeout), then the next step's setup. Timers carry the run's token, so a stale timer after a stop does nothing.
-- ---------------------------------------------------------------------------------------------------------------------

local function after(run, seconds, event)
	local token = run.token
	C_Timer.After(seconds, function()
		if lib.run == run and run.token == token then
			lib.Step(run, event)
		end
	end)
end

local function teardown(run)
	local step = run.steps[run.index]
	if step and step.teardown and run.setUp then
		pcall(step.teardown, run.ctx)
	end
	run.setUp = false
end

local function finish(run, reason)
	teardown(run)
	lib.run = nil
	run.token = run.token + 1
	if lib.backdrop then
		lib.backdrop:Hide()
	end
	if lib.keys then
		lib.keys:EnableKeyboard(false)
		lib.keys:Hide()
	end
	if lib.events then
		lib.events:UnregisterAllEvents()
	end
	local m = run.manifest
	m.finished = time and time() or nil
	m.aborted = reason
	if run.opts.after then
		pcall(run.opts.after, m)
	end
	if reason then
		local why = (run.opts.text and run.opts.text[reason]) or lib.TEXT[reason] or reason
		say(run, "aborted", why, #m.shots)
	else
		say(run, "done", #m.shots)
	end
	for _, e in ipairs(m.shots) do
		say(run, e.ok == false and "lineFailed" or "line", e.index, e.date or "", e.name or "?")
	end
	fire("Finished", run.addon, m)
end

-- Advance the run on an event: "next" (start a step), "settled" (take the shot), a screenshot event, "timeout".
function lib.Step(run, event)
	if lib.run ~= run then
		return
	end
	if event == "next" then
		teardown(run)
		run.index = run.index + 1
		local step = run.steps[run.index]
		if not step then
			finish(run, nil)
			return
		end
		say(run, "step", run.index, #run.steps, step.name or "?")
		if step.setup then
			local ok, err = pcall(step.setup, run.ctx)
			if not ok then
				say(run, "failed", tostring(err))
				run.manifest.shots[#run.manifest.shots + 1] = { index = run.index, name = step.name, ok = false,
					error = tostring(err) }
				after(run, 0.1, "next")
				return
			end
		end
		run.setUp = true
		if GameTooltip and GameTooltip.Hide then
			GameTooltip:Hide()
		end
		-- At least 1.1 s between shots: the game names screenshot files by the second.
		local wait = math.max(step.delay or run.opts.delay or 0.8, 1.1 - (now() - (run.lastShot or -10)))
		run.phase = "setup"
		after(run, wait, "settled")
	elseif event == "settled" and run.phase == "setup" then
		run.phase = "shot"
		run.shotAt = now()
		Screenshot()
		after(run, 3, "timeout")
	elseif run.phase == "shot" and (event == "SCREENSHOT_SUCCEEDED" or event == "SCREENSHOT_FAILED" or event == "timeout") then
		run.phase = "taken"
		run.lastShot = now()
		local step = run.steps[run.index]
		local entry = {
			index = #run.manifest.shots + 1,
			step = run.index,
			name = step.name,
			at = time and time() or nil,
			date = date and date("%Y-%m-%d %H:%M:%S") or nil,
			ok = event == "SCREENSHOT_SUCCEEDED" or nil,
			timeout = event == "timeout" or nil,
		}
		run.manifest.shots[#run.manifest.shots + 1] = entry
		fire("Shot", run.addon, entry)
		after(run, 0.2, "next")
	end
end

-- Start an addon's steps. Returns true, or false and a reason ("combat", "busy", "noSteps").
function lib:Start(addon)
	local reg = lib.addons[addon]
	if lib.run then
		return false, "busy"
	end
	if InCombatLockdown and InCombatLockdown() then
		return false, "inCombat"
	end
	if not reg or #reg.steps == 0 then
		return false, "noSteps"
	end
	local opts = reg.opts
	local run = {
		addon = addon,
		steps = reg.steps,
		opts = opts,
		index = 0,
		token = (lib.lastToken or 0) + 1,
		ctx = { addon = addon },
		manifest = {
			addon = addon,
			library = MAJOR .. " " .. lib.VERSION,
			started = time and time() or nil,
			date = date and date("%Y-%m-%d %H:%M:%S") or nil,
			locale = GetLocale and GetLocale() or nil,
			shots = {},
		},
	}
	lib.lastToken = run.token
	lib.run = run
	if opts.before then
		local ok, err = pcall(opts.before, run.ctx)
		if not ok then
			lib.run = nil
			return false, tostring(err)
		end
	end
	-- The manifest is saved as it grows, so an interrupted run still leaves what it took.
	if opts.store then
		local ok, store = pcall(opts.store)
		if ok and type(store) == "table" then
			store.shots = run.manifest
		end
	end
	if opts.backdrop ~= false then
		local f = backdropFrame()
		local c = opts.backdrop or { 0.08, 0.08, 0.09, 1 }
		f.tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
		f:Show()
	end
	local k = keyFrame()
	k:Show()
	if k.SetPropagateKeyboardInput then
		pcall(k.SetPropagateKeyboardInput, k, true)
	end
	k:EnableKeyboard(true)
	local ev = eventFrame()
	ev:RegisterEvent("PLAYER_REGEN_DISABLED")
	ev:RegisterEvent("SCREENSHOT_SUCCEEDED")
	ev:RegisterEvent("SCREENSHOT_FAILED")
	say(run, "started", #run.steps)
	fire("Started", addon)
	after(run, 0.3, "next")
	return true
end

-- Stop the running walk (restores everything). reason: "escape", "combat" or any text.
function lib:Stop(addon, reason)
	local run = lib.run
	if not run or (addon and run.addon ~= addon) then
		return false
	end
	finish(run, reason or "stopped")
	return true
end
