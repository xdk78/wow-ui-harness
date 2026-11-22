-- wowui.views: helpers that build the views list `wowui.runner` takes.
--
-- Views.Sequence(name, steps, opts) declares one interaction as several frames, for `wowui.py gif`. Step N is the state
-- after the N-th step, and steps run cumulatively on the same state: step 2 builds on what step 1 left, nothing is torn
-- down in between. The views are named `seq-<name>-NN` (01, 02, ...) and each records `sequence`, `step`, `steps` and
-- the optional `caption` in its dump's `meta`, which `wowui.py gif` reads for its captions.
--
--   local Views = require("wowui.views")
--   local views = {
--     { name = "main", setup = function() MyAddon:Open() end, window = function() return MyAddonFrame end },
--   }
--   for _, v in ipairs(Views.Sequence("pick-tab", {
--     function() MyAddon:Open() end,                                   -- a step is a function ...
--     { caption = "Click the Options tab", setup = function() MyAddon:ShowTab("options") end },   -- ... or a table
--     { caption = "Tick the box", setup = function() MyAddonCheck:Click() end },
--   }, { window = function() return MyAddonFrame end, finish = function() MyAddon:Close() end })) do
--     views[#views + 1] = v
--   end
--
-- A step table takes `setup(ctx)` (required), `caption`, `window` (this step's window; default: opts.window) and `meta`
-- (more fields for the dump). opts: `window` (a frame or a function returning one), `finish(ctx)` (runs once after the
-- last step, like a view's teardown) and `meta` (fields for every step).
--
-- With the runner's `--only seq-pick-tab-03`, the steps before it run first without being dumped (a view's `needs`), so
-- the state is the same as in a full run; `finish` runs at the end of the run when the last step was not part of it.

local Views = {}

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do
		out[k] = v
	end
	return out
end

function Views.Sequence(name, steps, opts)
	assert(type(name) == "string" and name:match("^[%w_.%-]+$"), "Views.Sequence: name must be letters, digits, _ . -")
	assert(type(steps) == "table" and #steps > 0, "Views.Sequence: needs at least one step")
	opts = opts or {}
	local count = #steps
	local digits = math.max(2, #tostring(count))
	local seq = { name = name, steps = count, finish = opts.finish, done = false }
	local views, previous = {}, nil
	for i, step in ipairs(steps) do
		if type(step) == "function" then
			step = { setup = step }
		end
		assert(type(step) == "table" and type(step.setup) == "function", "Views.Sequence: step " .. i .. " needs a setup function")
		local meta = copy(opts.meta)
		for k, v in pairs(step.meta or {}) do
			meta[k] = v
		end
		meta.sequence, meta.step, meta.steps, meta.caption = name, i, count, step.caption
		local view = {
			name = string.format("seq-%s-%0" .. digits .. "d", name, i),
			setup = step.setup,
			window = step.window or opts.window,
			meta = meta,
			needs = previous,
			sequence = seq,
		}
		if i == count then
			view.teardown = function(ctx)
				seq.done = true
				if seq.finish then
					seq.finish(ctx)
				end
			end
		end
		views[i] = view
		previous = view
	end
	return views
end

return Views
