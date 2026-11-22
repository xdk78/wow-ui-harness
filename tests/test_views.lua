local T = ...

-- Runs the runner on `views` into a scratch folder under the system's temp directory; returns the decoded dump of
-- every view it wrote (by view name) and the runner's exit code. The folder is removed again.
local function run(mock, views, extraArgs)
	local JSON = require("wowui.json")
	local base = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
	local dir = base:gsub("\\", "/") .. "/wowui-test-views-" .. tostring(os.time()) .. tostring(math.random(1000, 9999))
	local argv = { "--out", dir }
	for _, a in ipairs(extraArgs or {}) do
		argv[#argv + 1] = a
	end
	local realOut = io.stdout
	rawset(io, "stdout", { write = function() end }) -- the runner writes its summary to io.stdout
	local ok, code = pcall(require("wowui.runner").Main, mock, { install = function() end, views = views }, argv)
	rawset(io, "stdout", realOut)
	local docs = {}
	for _, v in ipairs(views) do
		local fh = io.open(dir .. "/" .. v.name .. ".json", "rb")
		if fh then
			docs[v.name] = JSON.Decode(fh:read("*a"))
			fh:close()
			os.remove(dir .. "/" .. v.name .. ".json")
		end
	end
	for _, f in ipairs({ "lint.json", "files-asked.txt" }) do
		os.remove(dir .. "/" .. f)
	end
	if package.config:sub(1, 1) == "\\" then
		os.execute('rmdir "' .. dir:gsub("/", "\\") .. '" >nul 2>nul')
	else
		os.execute("rmdir '" .. dir .. "' 2>/dev/null")
	end
	assert(ok, code)
	return docs, code
end

T.case("views: Sequence names the steps, chains them and records the caption", function()
	T.fresh()
	local Views = require("wowui.views")
	local window = function() return nil end
	local views = Views.Sequence("pick", {
		function() end,
		{ caption = "Second", setup = function() end, meta = { note = "x" } },
		{ setup = function() end, window = "own" },
	}, { window = window, meta = { locale = "enUS" } })
	T.eq(#views, 3)
	T.eq(views[1].name, "seq-pick-01")
	T.eq(views[3].name, "seq-pick-03")
	T.eq(views[1].window, window, "the sequence's window is the default")
	T.eq(views[3].window, "own", "a step may name its own window")
	T.eq(views[2].needs, views[1])
	T.eq(views[1].needs, nil)
	T.eq(views[2].meta.caption, "Second")
	T.eq(views[2].meta.step, 2)
	T.eq(views[2].meta.steps, 3)
	T.eq(views[2].meta.sequence, "pick")
	T.eq(views[2].meta.note, "x")
	T.eq(views[2].meta.locale, "enUS")
	T.eq(views[1].meta.caption, nil, "no caption, no field")
	T.eq(views[1].teardown, nil, "only the last step finishes")
	T.ok(views[3].teardown)
	local many = {}
	for i = 1, 100 do
		many[i] = function() end
	end
	local long = Views.Sequence("long", many)
	T.eq(long[1].name, "seq-long-001", "names keep sorting when there are more than 99 steps")
	T.eq(long[100].name, "seq-long-100")
	T.ok(not pcall(Views.Sequence, "bad name", { function() end }), "a name with a space is refused")
	T.ok(not pcall(Views.Sequence, "empty", {}), "a sequence needs a step")
	T.ok(not pcall(Views.Sequence, "x", { {} }), "a step needs a setup")
end)

T.case("views: steps run cumulatively and the dumps carry the captions", function()
	local mock = T.fresh()
	local Views = require("wowui.views")
	local f, order, finished = nil, {}, 0
	local views = Views.Sequence("grow", {
		{ caption = "Open it", setup = function()
			order[#order + 1] = 1
			f = CreateFrame("Frame", nil, UIParent)
			f:SetSize(100, 50)
			f:SetPoint("CENTER")
		end },
		{ caption = "Make it wider", setup = function()
			order[#order + 1] = 2
			f:SetWidth(200)
		end },
		{ setup = function()
			order[#order + 1] = 3
			f:SetHeight(80)
		end },
	}, { window = function() return f end, finish = function() finished = finished + 1 end })
	local docs, code = run(mock, views)
	T.eq(code, 0)
	T.eq(table.concat(order, ","), "1,2,3")
	T.eq(finished, 1, "finish runs once, after the last step")
	T.eq(docs["seq-grow-01"].window.rect[3], 100)
	T.eq(docs["seq-grow-02"].window.rect[3], 200, "step 2 builds on step 1")
	T.eq(docs["seq-grow-02"].window.rect[4], 50)
	T.eq(docs["seq-grow-03"].window.rect[3], 200, "step 3 keeps step 2's width")
	T.eq(docs["seq-grow-03"].window.rect[4], 80)
	T.eq(docs["seq-grow-01"].meta.caption, "Open it")
	T.eq(docs["seq-grow-02"].meta.caption, "Make it wider")
	T.eq(docs["seq-grow-03"].meta.caption, nil)
	T.eq(docs["seq-grow-03"].meta.sequence, "grow")
	T.eq(docs["seq-grow-03"].meta.steps, 3)
end)

T.case("views: --only a later step runs the steps before it first, and finish still runs", function()
	local mock = T.fresh()
	local Views = require("wowui.views")
	local f, order, finished = nil, {}, 0
	local views = Views.Sequence("grow", {
		function() order[#order + 1] = 1; f = CreateFrame("Frame", nil, UIParent); f:SetSize(100, 50); f:SetPoint("CENTER") end,
		function() order[#order + 1] = 2; f:SetWidth(200) end,
		function() order[#order + 1] = 3; f:SetHeight(80) end,
	}, { window = function() return f end, finish = function() finished = finished + 1 end })
	local docs = run(mock, views, { "--only", "seq-grow-02" })
	T.eq(table.concat(order, ","), "1,2", "step 1 was set up, step 3 was not asked for")
	T.eq(docs["seq-grow-01"], nil, "only the asked view is dumped")
	T.eq(docs["seq-grow-02"].window.rect[3], 200)
	T.eq(finished, 1, "the unfinished sequence is finished at the end of the run")
end)

T.case("views: plain views and sequences mix, and a failing step stops the run", function()
	local mock = T.fresh()
	local Views = require("wowui.views")
	local views = { { name = "plain", setup = function() end } }
	for _, v in ipairs(Views.Sequence("bad", { function() end, function() error("boom") end })) do
		views[#views + 1] = v
	end
	local realErr = io.stderr
	rawset(io, "stderr", { write = function() end })
	local docs, code = run(mock, views)
	rawset(io, "stderr", realErr)
	T.eq(code, 3, "setup failure is exit code 3")
	T.ok(docs.plain and docs["seq-bad-01"], "the views before the failure were dumped")
	T.eq(docs["seq-bad-02"], nil)
end)
