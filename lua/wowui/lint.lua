-- wowui.lint: layout checks on a frame-tree dump (wowui.dump), no textures needed.
--
--   local findings = require("wowui.lint").Run(doc)   -- { { rule, key, message, rect, path } }
--
-- Rules:
--   text-truncated   a font string cut with "..." (too narrow, MaxLines or its height)
--   text-clipped     a font string partly cut off by a frame that clips its children (not a scroll frame)
--   text-overlap     two font strings of one window whose drawn lines cross each other
--   overlap          two clickable frames (buttons, edit boxes, frames with click scripts) covering each other, neither
--                    inside the other's tree, partly, or at about the same size (a small control on a big clickable
--                    surface is layering, not a finding)
-- With doc.window set, only that window's tree is checked.
--   outside-window   something drawn past the window's edges (doc.window, when the dump names one); frames that
--                    draw nothing themselves (containers, anchors) are not pieces, their contents are
--   missing-glyph    characters the font string's face has no glyph for (only when the real face was measured)
--   anchor-conflict  a region whose anchor points put the same edge or centre in two places (LEFT on one frame and
--                    RIGHT on another at a different height): clients need not settle that as this mock does
-- Every finding has a stable `key` (rule, paths, text), for baselines: Lint.Compare(findings, baselineKeys).

local TTF = require("wowui.ttf")
local Text = require("wowui.text")

local Lint = {}

local SLACK = 1 -- px of tolerance for "outside" and "overlap"

-- Templates drawn past their window's edge on purpose (the bottom tabs of the game's windows).
Lint.HANGING = { PanelTabButtonTemplate = true }

local function inter(a, b)
	local x1, y1 = math.max(a[1], b[1]), math.max(a[2], b[2])
	local x2, y2 = math.min(a[1] + a[3], b[1] + b[3]), math.min(a[2] + a[4], b[2] + b[4])
	if x2 <= x1 or y2 <= y1 then
		return nil
	end
	return { x1, y1, x2 - x1, y2 - y1 }
end

local function clipTo(rect, clip)
	if not clip then
		return rect
	end
	return inter(rect, clip)
end

local function short(s, n)
	s = (s or ""):gsub("\n", " ")
	if #s > n then
		return s:sub(1, n) .. "..."
	end
	return s
end

-- The boxes a text entry draws (one per line), clipped.
local function textBoxes(e)
	local out = {}
	local t = e.text
	for _, line in ipairs(t.lines or {}) do
		if line.w > 0 then
			local box = clipTo({ line.x, line.y, line.w, t.lineHeight }, e.clip)
			if box then
				out[#out + 1] = box
			end
		end
	end
	return out
end

local function round(v)
	return math.floor(v + 0.5)
end

function Lint.Run(doc)
	local findings = {}
	local seen = {}
	local function add(rule, key, message, rect, path)
		key = rule .. " | " .. key
		if seen[key] then
			return
		end
		seen[key] = true
		findings[#findings + 1] = { rule = rule, key = key, message = message, rect = rect, path = path,
			view = doc.view }
	end
	local byPath = {}
	for _, e in ipairs(doc.regions or {}) do
		if e.kind ~= "Texture" and e.kind ~= "FontString" and e.kind ~= "Line" then
			byPath[e.path] = e
		end
	end
	local function ancestorOf(a, b) -- is entry a an ancestor of entry b
		local p, guard = b.parentPath, 0
		while p and guard < 200 do
			if p == a.path then
				return true
			end
			local pe = byPath[p]
			p = pe and pe.parentPath
			guard = guard + 1
		end
		return false
	end
	local function within(e, pathRoot)
		if e.path == pathRoot then
			return true
		end
		local p, guard = e.parentPath, 0
		while p and guard < 200 do
			if p == pathRoot then
				return true
			end
			local pe = byPath[p]
			p = pe and pe.parentPath
			guard = guard + 1
		end
		return false
	end
	local texts, clicks = {}, {}
	local scope = doc.window and doc.window.path
	for _, e in ipairs(doc.regions or {}) do
		local inScope = not scope or within(e, scope) -- with a window, only the view's window is linted
		if inScope and e.text and (e.alpha or 1) > 0.05 then
			texts[#texts + 1] = e
		end
		if inScope and e.clickable and (e.alpha or 1) > 0.05 then
			local r = clipTo(e.rect, e.clip)
			if r and r[3] > 0 and r[4] > 0 then
				clicks[#clicks + 1] = { e = e, r = r }
			end
		end
	end
	-- text-truncated, missing-glyph
	for _, e in ipairs(texts) do
		local t = e.text
		if t.truncated and #textBoxes(e) > 0 then
			add("text-truncated", e.path .. " | " .. short(t.plain, 60),
				string.format('"%s" is cut to fit %dx%d', short(t.plain, 80), round(e.rect[3]), round(e.rect[4])), e.rect,
				e.path)
		end
		-- Text cut by a clipping frame (not by a scroll frame, whose edges cut rows by design).
		if e.clip and not e.scrolled then
			for _, line in ipairs(t.lines or {}) do
				local box = { line.x, line.y, line.w, t.lineHeight }
				local vis = inter(box, e.clip)
				if vis and vis[3] < box[3] - SLACK then -- sideways only: lists cut rows at their top and bottom
					add("text-clipped", e.path .. " | " .. short(t.plain, 60),
						string.format('"%s" is cut by a clipping frame (%d of %d px shown)', short(t.plain, 80),
							round(vis[3]), round(box[3])), box, e.path)
					break
				end
			end
		end
		if t.fontHow == "exact" and t.fontLocal then
			local font = TTF.Load(t.fontLocal)
			if font then
				local missing, list = {}, {}
				for _, ch in ipairs(Text.utf8chars(t.plain or "")) do
					if ch.cp > 32 and not font:Has(ch.cp) and not missing[ch.s] then
						missing[ch.s] = true
						list[#list + 1] = ch.s
					end
				end
				if #list > 0 then
					table.sort(list)
					local chars = table.concat(list)
					add("missing-glyph", tostring(t.font) .. " | " .. chars,
						string.format("%s has no glyph for %s (in %s)", tostring(t.font), chars, e.path), e.rect, e.path)
				end
			end
		end
	end
	-- anchor-conflict
	for _, e in ipairs(doc.regions or {}) do
		local c = e.anchorConflict
		if c and (not scope or within(e, scope)) and (e.alpha or 1) > 0.05 and (c.delta or 0) >= 2 then
			add("anchor-conflict", e.path,
				string.format("%s has two %s positions %d px apart (conflicting anchor points)", e.path,
					c.axis == "x" and "horizontal" or "vertical", c.delta), e.rect, e.path)
		end
	end
	-- text-overlap
	local boxes = {}
	for i, e in ipairs(texts) do
		boxes[i] = textBoxes(e)
	end
	for i = 1, #texts do
		for j = i + 1, #texts do
			local a, b = texts[i], texts[j]
			local hit
			-- Only within one top-level frame: across two, the upper one covers the lower.
			for _, ba in ipairs(a.top == b.top and boxes[i] or {}) do
				for _, bb in ipairs(boxes[j]) do
					local x = inter(ba, bb)
					if x and x[3] >= 2 and x[4] >= 2 then
						hit = x
						break
					end
				end
				if hit then
					break
				end
			end
			if hit then
				local pa, pb = a.path, b.path
				if pb < pa then
					pa, pb = pb, pa
				end
				add("text-overlap", pa .. " + " .. pb,
					string.format('"%s" overlaps "%s"', short(a.text.plain, 40), short(b.text.plain, 40)), hit, pa)
			end
		end
	end
	-- overlap (clickable frames)
	for i = 1, #clicks do
		for j = i + 1, #clicks do
			local a, b = clicks[i], clicks[j]
			if a.e.strata == b.e.strata and not ancestorOf(a.e, b.e) and not ancestorOf(b.e, a.e) then
				local x = inter(a.r, b.r)
				-- A small control laid on a bigger clickable surface (a button on a map) is by design; a partial overlap
				-- or two controls of about the same size on top of each other is not.
				local areaA, areaB = a.r[3] * a.r[4], b.r[3] * b.r[4]
				local small, big = math.min(areaA, areaB), math.max(areaA, areaB)
				local layered = x and (x[3] * x[4] >= small - 1) and small < 0.5 * big
				if x and x[3] > SLACK and x[4] > SLACK and not layered then
					local pa, pb = a.e.path, b.e.path
					if pb < pa then
						pa, pb = pb, pa
					end
					add("overlap", pa .. " + " .. pb,
						string.format("clickable %s and %s overlap by %dx%d", pa, pb, round(x[3]), round(x[4])), x, pa)
				end
			end
		end
	end
	-- outside-window: only the outermost piece (a frame, not also each of its regions), and not the game's tabs, which
	-- hang under a window's edge by design (Lint.HANGING lists their templates). A frame that draws nothing of its own
	-- (no backdrop, nine-slice, template or text, and takes no mouse) is a container or an anchor: it is not a piece;
	-- what it holds is checked one by one.
	local win = doc.window
	local outside = {}
	local function drawsNothing(e)
		return e.kind ~= "Texture" and e.kind ~= "FontString" and e.kind ~= "Line" and not e.backdrop
			and not e.nineSlice and not e.template and not e.text and not e.clickable and not e.mouse
	end
	local function excused(e)
		local p, guard = e, 0
		while p and guard < 200 do
			if outside[p.path] or (p.template and Lint.HANGING[p.template]) then
				return true
			end
			p = p.parentPath and byPath[p.parentPath]
			guard = guard + 1
		end
		return false
	end
	if win and win.rect then
		local w = win.rect
		for _, e in ipairs(doc.regions or {}) do
			if e.path ~= win.path and within(e, win.path) and (e.alpha or 1) > 0.05 and not drawsNothing(e)
				and not excused(e) then
				local rects = e.text and textBoxes(e) or { clipTo(e.rect, e.clip) }
				for _, r in ipairs(rects) do
					if r and r[3] > 0 and r[4] > 0 then
						local dl, dt = w[1] - r[1], w[2] - r[2]
						local dr, db = (r[1] + r[3]) - (w[1] + w[3]), (r[2] + r[4]) - (w[2] + w[4])
						local worst = math.max(dl, dt, dr, db)
						if worst > SLACK then
							add("outside-window", e.path .. (e.text and (" | " .. short(e.text.plain, 40)) or ""),
								string.format("%s reaches %d px past the window", e.path, round(worst)), r, e.path)
							outside[e.path] = true
							break
						end
					end
				end
			end
		end
	end
	table.sort(findings, function(a, b)
		return a.key < b.key
	end)
	return findings
end

-- Split findings against a baseline (a set or list of keys): new ones, and baseline keys no longer found.
function Lint.Compare(findings, baseline)
	local set = {}
	for k, v in pairs(baseline or {}) do
		if type(k) == "number" then
			set[v] = true
		else
			set[k] = true
		end
	end
	local fresh, found = {}, {}
	for _, f in ipairs(findings) do
		local k = (f.view and (f.view .. " | ") or "") .. f.key
		found[k] = true
		if not set[k] then
			fresh[#fresh + 1] = f
		end
	end
	local gone = {}
	for k in pairs(set) do
		if not found[k] then
			gone[#gone + 1] = k
		end
	end
	table.sort(gone)
	return fresh, gone
end

-- Read a baseline file: one key per line ("<view> | <rule> | ..."), # comments.
function Lint.ReadBaseline(path)
	local keys = {}
	local fh = io.open(path, "rb")
	if not fh then
		return keys
	end
	for line in fh:lines() do
		line = line:gsub("\r", "")
		if line ~= "" and not line:match("^#") then
			keys[#keys + 1] = line
		end
	end
	fh:close()
	return keys
end

return Lint
