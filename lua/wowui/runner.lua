-- wowui.runner: a command line for "build these views, dump each, lint them, compare with a baseline".
--
--   -- my_dump.lua, run as: lua my_dump.lua --out <dir> [options]
--   local runner = require("wowui.runner")
--   os.exit(runner.Main(mock, {
--     install = function(ctx) ... end,          -- the client API: mock.Install() plus game-data stubs (default: Install)
--     prepare = function(ctx) ... end,          -- after layout is enabled: load the addon, log in, open the window
--     views = { { name = "home", setup = function(ctx) ... end, window = function() return MyFrame end }, ... },
--     baseline = "tests/ui_lint_baseline.txt",  -- default for --baseline
--     lintIgnore = { "^outside%-window | MyFrame%.Portrait" }, -- Lua patterns: findings by design
--   }, arg))
--
-- Options:
--   --out <dir>                where <view>.json, lint.json and lint.txt go (required; keep it out of the repository)
--   --font-root <prefix>=<dir> a game path prefix and the local folder that holds those files (repeatable), e.g.
--                              --font-root "Fonts\=<work>/fonts" (the folder `wowui.py fonts` writes)
--   --fallback-font <ttf>      the face used for any font not found, with --fallback-scale <n> (width factor)
--   --only <a,b>               only these views
--   --prefix <text>            prefixed to every view name (e.g. a locale: "plPL/")
--   --baseline <file>          accepted findings, one key per line; new findings make the exit code 1
--   --update-baseline          write the current findings to the baseline file instead
--   --width <n> --height <n>   UIParent's size (1920 x 1080)
--   --all-files                GetFileIDFromPath knows every path (M.SyntheticFileID): the renderer finds the files
--   --files <file>             the files the client has, one "fileID<TAB>path" per line (`wowui.py files`); only
--                              those exist for GetFileIDFromPath (wins over --all-files). Every run writes the paths
--                              the addon asked about to <out>/files-asked.txt, the input of `wowui.py files`.
--   --atlases <file>           the atlases the client has, one "name<TAB>width<TAB>height" per line (`wowui.py atlases`);
--                              C_Texture.GetAtlasInfo then answers like that client
--   --sizes <file>             recorded game facts (`wowui.py files --sizes`, JSON): the file IDs and pixel sizes of the
--                              files and the sizes of the atlases an earlier run asked for. Without --files / --atlases
--                              GetFileIDFromPath and C_Texture.GetAtlasInfo answer from it; texture sizes always apply.
--                              Default: the config's `sizes`. Every run writes the atlas names asked to
--                              <out>/atlases-asked.txt.
-- ctx (passed to prepare and setup): { mock, args, out }.
-- A view may also carry `meta` (fields copied into its dump's meta) and `needs` (another view that is set up first when
-- it has not run yet). `wowui.views` builds both for interaction sequences (`seq-<name>-NN`).

local JSON = require("wowui.json")
local Dump = require("wowui.dump")
local Lint = require("wowui.lint")
local Layout = require("wowui.layout")

local Runner = {}

-- The mock replaces print (it records what the addon prints); the runner writes to stdout itself.
local function say(s)
	io.stdout:write(s, "\n")
end

function Runner.ParseArgs(argv)
	local args = { fontRoots = {}, rest = {} }
	local i = 1
	while argv and i <= #argv do
		local a = argv[i]
		local function val()
			i = i + 1
			return argv[i]
		end
		if a == "--out" then
			args.out = val()
		elseif a == "--font-root" then
			local v = val() or ""
			local prefix, dir = v:match("^(.-)=(.*)$")
			if prefix then
				args.fontRoots[#args.fontRoots + 1] = { prefix, dir }
			end
		elseif a == "--fallback-font" then
			args.fallback = val()
		elseif a == "--fallback-scale" then
			args.fallbackScale = tonumber(val())
		elseif a == "--only" then
			args.only = {}
			for name in (val() or ""):gmatch("[^,]+") do
				args.only[name] = true
			end
		elseif a == "--prefix" then
			args.prefix = val()
		elseif a == "--baseline" then
			args.baseline = val()
		elseif a == "--all-files" then
			args.allFiles = true
		elseif a == "--files" then
			args.files = val()
		elseif a == "--atlases" then
			args.atlases = val()
		elseif a == "--sizes" then
			args.sizes = val()
		elseif a == "--update-baseline" then
			args.update = true
		elseif a == "--width" then
			args.width = tonumber(val())
		elseif a == "--height" then
			args.height = tonumber(val())
		else
			args.rest[#args.rest + 1] = a
		end
		i = i + 1
	end
	return args
end

-- Recorded game facts (`wowui.py files --sizes`): { schema = "wowui-sizes/1", files = { [path] = { id, size } },
-- atlases = { [name] = { width, height } } }. Texture sizes always go into M.textureSizes; with `use.files` the file
-- IDs answer GetFileIDFromPath, with `use.atlases` the atlases answer C_Texture.GetAtlasInfo (case-insensitively).
-- Returns true, or nil and an error.
function Runner.LoadSizes(M, path, use)
	use = use or { files = true, atlases = true }
	local fh = io.open(path, "rb")
	if not fh then
		return nil, "cannot open " .. path
	end
	local text = fh:read("*a")
	fh:close()
	local ok, doc = pcall(JSON.Decode, text)
	if not ok or type(doc) ~= "table" or doc.schema ~= "wowui-sizes/1" then
		return nil, path .. " is not a wowui-sizes/1 file"
	end
	local names = {}
	for file in pairs(doc.files or {}) do
		names[#names + 1] = file
	end
	table.sort(names) -- spellings that differ only in case: the same answer on every run
	for _, file in ipairs(names) do
		local info = doc.files[file]
		if type(info) == "table" then
			if type(info.size) == "table" then
				M.SetTextureSize(file, info.size[1], info.size[2])
				if info.id then
					M.SetTextureSize(info.id, info.size[1], info.size[2])
				end
			end
			if use.files and info.id then
				M.files[file:gsub("/", "\\"):lower()] = info.id
			end
		end
	end
	if use.atlases and doc.atlases then
		-- Atlases the addon's test setup registered stay (the recorded ones win on a clash).
		local known = {}
		for name, v in pairs(M.atlases or {}) do
			known[tostring(name):lower()] = v
		end
		for name, size in pairs(doc.atlases) do
			known[name:lower()] = { width = size[1], height = size[2] }
		end
		M.atlases = setmetatable({}, { __index = function(_, k)
			return type(k) == "string" and known[k:lower()] or nil
		end, __newindex = function(_, k, v)
			known[tostring(k):lower()] = v
		end })
	end
	return true
end

local function fileName(view)
	return (view:gsub("[^%w%-_.]", "_"))
end

-- Create the output folder (and its parents) when it is missing.
local function ensureDir(dir)
	local probe = io.open(dir .. "/.wowui-probe", "wb")
	if probe then
		probe:close()
		os.remove(dir .. "/.wowui-probe")
		return
	end
	if package.config:sub(1, 1) == "\\" then
		os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" >nul 2>nul')
	else
		os.execute("mkdir -p '" .. dir:gsub("'", "'\''") .. "'")
	end
end

function Runner.Main(M, cfg, argv)
	local args = Runner.ParseArgs(argv)
	if not args.out then
		io.stderr:write("--out <dir> is required\n")
		return 2
	end
	ensureDir(args.out)
	local roots = {}
	for _, r in ipairs(args.fontRoots) do
		roots[#roots + 1] = r
	end
	for _, r in ipairs(cfg.fontRoots or {}) do
		roots[#roots + 1] = r
	end
	local ctx = { mock = M, args = args, out = args.out }
	if cfg.install then
		cfg.install(ctx) -- the client's API (mock.Install and the addon's own stubs), before layout is enabled
	else
		M.Install()
	end
	Layout.Enable(M, {
		width = args.width,
		height = args.height,
		fonts = { roots = roots, fallback = args.fallback or cfg.fallbackFont,
			fallbackScale = args.fallbackScale or cfg.fallbackScale or 1 },
	})
	if args.allFiles then
		M.fileResolver = M.SyntheticFileID
	end
	M.fileQueries = {}
	M.atlasQueries = {}
	local sizes = args.sizes or cfg.sizes
	if sizes then
		local ok, err = Runner.LoadSizes(M, sizes, { files = not args.files, atlases = not args.atlases })
		if not ok then
			io.stderr:write("--sizes: " .. tostring(err) .. "\n")
			return 2
		end
	end
	if args.files then
		local fh = io.open(args.files, "rb")
		if fh then
			M.fileResolver = nil
			for line in fh:lines() do
				local id, path = line:match("^(%d+)\t(.+)$")
				if id then
					M.files[path:gsub("\r", ""):lower()] = tonumber(id)
				end
			end
			fh:close()
		end
	end
	if args.atlases then
		local fh = io.open(args.atlases, "rb")
		if fh then
			local known = {}
			for line in fh:lines() do
				local name, w, h = line:match("^([^	]+)	(%d+)	(%d+)")
				if name then
					known[name] = { width = tonumber(w), height = tonumber(h) }
				end
			end
			fh:close()
			-- Case-insensitive, as the client's atlas lookup is.
			M.atlases = setmetatable({}, { __index = function(_, k)
				return type(k) == "string" and known[k:lower()] or nil
			end, __newindex = function(_, k, v)
				known[tostring(k):lower()] = v
			end })
		end
	end
	if cfg.prepare then
		cfg.prepare(ctx)
	end
	local all, written = {}, {}
	local prefix = args.prefix or ""
	-- A view's setup runs once. A view with `needs` (a step of wowui.views' Sequence) has the view it builds on set up
	-- first when that one was not selected, so `--only` of a later step shows the same state as a full run. A step that
	-- fails (its own or one it needs) stops the run with exit code 3 at once: no further views are dumped and no pending
	-- teardown or sequence `finish` runs (the same as before sequences existed).
	local ran = {}
	local function setUp(view)
		if ran[view] then
			return true
		end
		if view.needs and not setUp(view.needs) then
			return false
		end
		ran[view] = true
		local ok, err = pcall(view.setup, ctx)
		if not ok then
			io.stderr:write(string.format("view %s: setup failed: %s\n", view.name, tostring(err)))
			return false
		end
		-- Sizes settle the way the client's do between frames: OnSizeChanged for every frame whose size changed.
		Layout.SettleSizes(M)
		return true
	end
	local selected = {}
	for _, view in ipairs(cfg.views or {}) do
		if not args.only or args.only[view.name] then
			selected[#selected + 1] = view
		end
	end
	for index, view in ipairs(selected) do
		if not setUp(view) then
			return 3
		end
		local window = view.window
		if type(window) == "function" then
			window = window(ctx)
		end
		local name = prefix .. view.name
		local meta = cfg.meta and cfg.meta(ctx, view) or nil
		if view.meta then
			meta = meta or {}
			for k, v in pairs(view.meta) do
				meta[k] = v
			end
		end
		local doc = Dump.Capture(M, { view = name, window = window, meta = meta })
		local path = args.out .. "/" .. fileName(name) .. ".json"
		Dump.Write(doc, path)
		written[#written + 1] = path
		for _, f in ipairs(Lint.Run(doc)) do
			local ignored = false
			for _, pattern in ipairs(cfg.lintIgnore or {}) do
				if f.key:find(pattern) then
					ignored = true
					break
				end
			end
			if not ignored then
				all[#all + 1] = f
			end
		end
		if view.teardown then
			view.teardown(ctx)
		end
		-- A sequence whose last step was not selected finishes after its last selected step, before the next selected
		-- view, so that view sees the same state as in a full run.
		local seq = view.sequence
		if seq and not seq.done and seq.finish then
			local later = false
			for j = index + 1, #selected do
				if selected[j].sequence == seq then
					later = true
					break
				end
			end
			if not later then
				seq.done = true
				seq.finish(ctx)
			end
		end
	end
	local asked = {}
	for path in pairs(M.fileQueries or {}) do
		asked[#asked + 1] = path
	end
	table.sort(asked)
	local fq = io.open(args.out .. "/" .. fileName(prefix .. "files-asked") .. ".txt", "wb")
	if fq then
		fq:write(table.concat(asked, "\n"), "\n")
		fq:close()
	end
	local atlasesAsked = {}
	for name in pairs(M.atlasQueries or {}) do
		atlasesAsked[#atlasesAsked + 1] = name
	end
	table.sort(atlasesAsked)
	local aq = io.open(args.out .. "/" .. fileName(prefix .. "atlases-asked") .. ".txt", "wb")
	if aq then
		aq:write(table.concat(atlasesAsked, "\n"), "\n")
		aq:close()
	end
	-- lint.json: every finding.
	local fh = assert(io.open(args.out .. "/" .. fileName(prefix .. "lint") .. ".json", "wb"))
	fh:write(JSON.Encode({ findings = all }, " "))
	fh:close()
	local lines = {}
	for _, f in ipairs(all) do
		lines[#lines + 1] = f.view .. " | " .. f.key
	end
	table.sort(lines)
	say(string.format("wowui: %d views dumped to %s, %d lint findings", #written, args.out, #all))
	local baseline = args.baseline or cfg.baseline
	if args.update and baseline then
		-- Comment lines ("# ...") right above a key say why it is accepted: they stay with a key that stays. The
		-- comment block at the top of the file (before the first blank line) stays as the file's header.
		local notes, header = {}, nil
		local fh0 = io.open(baseline, "rb")
		if fh0 then
			local pending, seenKey = {}, false
			for line in fh0:lines() do
				line = line:gsub("\r", "")
				if line:match("^#") then
					pending[#pending + 1] = line
				elseif line == "" then
					if not seenKey and not header and #pending > 0 then
						header = pending
					end
					pending = {}
				else
					seenKey = true
					if #pending > 0 then
						notes[line] = pending
					end
					pending = {}
				end
			end
			fh0:close()
		end
		local keep = {}
		-- Keep other prefixes' lines (another locale's run) when updating one.
		for _, k in ipairs(Lint.ReadBaseline(baseline)) do
			if prefix ~= "" and k:sub(1, #prefix) ~= prefix then
				keep[#keep + 1] = k
			elseif prefix == "" and k:match("^[^ |]+/") then
				keep[#keep + 1] = k
			end
		end
		for _, l in ipairs(lines) do
			keep[#keep + 1] = l
		end
		table.sort(keep)
		local out = assert(io.open(baseline, "wb"))
		local top = header
			or { "# Accepted UI lint findings (wowui.lint). One key per line; regenerate with --update-baseline." }
		for _, line in ipairs(top) do
			out:write(line, "\n")
		end
		out:write("\n")
		for _, k in ipairs(keep) do
			for _, note in ipairs(notes[k] or {}) do
				out:write(note, "\n")
			end
			out:write(k, "\n")
		end
		out:close()
		say("wowui: baseline written: " .. baseline)
		return 0
	end
	if baseline then
		local keys = {}
		for _, k in ipairs(Lint.ReadBaseline(baseline)) do
			if k:sub(1, #prefix) == prefix and (prefix ~= "" or not k:match("^[^ |]+/")) then
				keys[#keys + 1] = k
			end
		end
		local fresh, gone = Lint.Compare(all, keys)
		for _, k in ipairs(gone) do
			say("  fixed (remove from the baseline): " .. k)
		end
		for _, f in ipairs(fresh) do
			say("  NEW " .. f.view .. " | " .. f.key)
			say("      " .. f.message)
		end
		if #fresh > 0 then
			say(string.format("wowui: %d new lint findings (not in %s)", #fresh, baseline))
			return 1
		end
		say("wowui: no new lint findings")
		return 0
	end
	for _, f in ipairs(all) do
		say("  " .. f.view .. " | " .. f.message)
	end
	return 0
end

return Runner
