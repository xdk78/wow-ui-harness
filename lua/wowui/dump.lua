-- wowui.dump: the visible frame tree as data (schema "wowui-dump/1", docs/DUMP-FORMAT.md), in draw order.
--
--   local dump = require("wowui.dump")
--   local doc = dump.Capture(mock, { view = "home", window = MyAddonFrame, meta = { locale = "enUS" } })
--   dump.Write(doc, "work/home.json")
--
-- Needs wowui.layout enabled. Every entry has a resolved rect (top-left origin, y down, UIParent units), its draw
-- position (strata, level, layer, sublevel), effective alpha and scale, clip rect, and what it draws.

local JSON = require("wowui.json")
local Text = require("wowui.text")

local Dump = {}

Dump.SCHEMA = "wowui-dump/1"

local SKIP = { Font = true, AnimationGroup = true, Animation = true }

local function clickable(f)
	local t = f._type
	if t == "Button" or t == "CheckButton" or t == "EditBox" or t == "Slider" then
		return f._mouse ~= false
	end
	if f._mouse and f._scripts then
		local s = f._scripts
		return s.OnClick ~= nil or s.OnMouseDown ~= nil or s.OnMouseUp ~= nil
	end
	return false
end

-- A readable, stable name for every object: its global name, else the field that holds it on an ancestor
-- ("Parent.list.rows[3]"), else its kind and index among its parent's children ("Parent/Texture#2").
local function namer(objects)
	local children = {}
	for _, o in ipairs(objects) do
		local p = o._parent
		if p then
			children[p] = children[p] or {}
			table.insert(children[p], o)
		end
	end
	local names = {}
	-- The first matching field in sorted order, so names do not depend on table iteration order.
	local function fieldOn(holder, o)
		local direct, listed = nil, nil
		for k, v in pairs(holder) do
			if type(k) == "string" and not k:match("^_") then
				if v == o then
					if not direct or k < direct then
						direct = k
					end
				elseif type(v) == "table" and getmetatable(v) == nil then
					for i, x in ipairs(v) do
						if x == o then
							local n = k .. "[" .. i .. "]"
							if not listed or n < listed then
								listed = n
							end
							break
						end
					end
				end
			end
		end
		if direct then
			return "." .. direct
		end
		return listed and ("." .. listed) or nil
	end
	local function name(o, depth)
		if names[o] then
			return names[o]
		end
		depth = depth or 0
		if o._name then
			names[o] = o._name
			return o._name
		end
		local p = o._parent
		if not p or depth > 60 then
			names[o] = o._type .. "@" .. tostring(o._order)
			return names[o]
		end
		local holder, hops = p, 0
		while holder and hops < 3 do
			local f = fieldOn(holder, o)
			if f then
				names[o] = name(holder, depth + 1) .. f
				return names[o]
			end
			holder = holder._parent
			hops = hops + 1
		end
		local n = 0
		for _, c in ipairs(children[p] or {}) do
			if c._type == o._type then
				n = n + 1
			end
			if c == o then
				break
			end
		end
		names[o] = name(p, depth + 1) .. "/" .. o._type .. "#" .. n
		return names[o]
	end
	return name
end

local function toScreen(L, l, b, w, h)
	return { l, L.state.height - (b + h), w, h }
end

local function intersect(a, b)
	if not a then
		return b
	end
	local x1, y1 = math.max(a[1], b[1]), math.max(a[2], b[2])
	local x2, y2 = math.min(a[1] + a[3], b[1] + b[3]), math.min(a[2] + a[4], b[2] + b[4])
	return { x1, y1, math.max(0, x2 - x1), math.max(0, y2 - y1) }
end

local function alphaOf(o)
	local a, p, guard = 1, o, 0
	while p and guard < 200 do
		a = a * (p._alpha or 1)
		p = p._parent
		guard = guard + 1
	end
	return a
end

local function color(c)
	if not c then
		return nil
	end
	return { c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1 }
end

-- SetTexture's wrap modes as the client names them: true is REPEAT, nil or false the default CLAMP.
local function wrapModes(w)
	if not w then
		return nil
	end
	local out = {}
	for i = 1, 2 do
		local v = w[i]
		out[i] = v == true and "REPEAT" or (type(v) == "string" and v:upper()) or "CLAMP"
	end
	return out
end

local function textRecord(_, o, rect, s, info, lay)
	local lines = {}
	local block = lay.height * s
	local jv = info.justifyV
	local top = rect[2] + (jv == "TOP" and 0 or jv == "BOTTOM" and (rect[4] - block) or (rect[4] - block) / 2)
	local step = (info.size + info.spacing) * s
	for i, line in ipairs(lay.lines) do
		local w = line.w * s
		local jh = info.justifyH
		local x = rect[1] + (jh == "LEFT" and 0 or jh == "RIGHT" and (rect[3] - w) or (rect[3] - w) / 2)
		local parts = {}
		for _, part in ipairs(line.parts) do
			if part.icon then
				parts[#parts + 1] = { icon = part.icon.file, atlas = part.icon.atlas, w = part.w * s, h = (part.h or 0) * s }
			else
				parts[#parts + 1] = { s = part.s, color = part.color, w = part.w * s }
			end
		end
		lines[#lines + 1] = { x = x, y = top + (i - 1) * step, w = w, parts = parts }
	end
	return {
		raw = o._text or "",
		plain = Text.Plain(o._text or ""),
		font = info.file,
		fontLocal = lay.fontLocal,
		fontHow = lay.fontHow,
		fontScale = lay.fontScale,
		size = info.size * s,
		flags = info.flags,
		color = color(info.color),
		shadow = info.shadowColor and { color = color(info.shadowColor), offset = info.shadowOffset } or nil,
		justifyH = info.justifyH,
		justifyV = info.justifyV,
		wrap = o._wordWrap ~= false,
		maxLines = o._maxLines,
		lineHeight = info.size * s,
		lines = lines,
		width = lay.width * s,
		full = lay.full * s,
		truncated = lay.truncated or false,
	}
end

-- Capture the visible tree. opts: view (name), window (frame: lint's "outside the window" reference), root (only
-- this frame's descendants), meta (copied into the document).
function Dump.Capture(M, opts)
	opts = opts or {}
	local L = M.layout
	assert(L, "wowui.dump needs wowui.layout enabled")
	local objects = {}
	for _, o in ipairs(M.frames) do
		if not SKIP[o._type] then
			objects[#objects + 1] = o
		end
	end
	local name = namer(objects)
	local function under(o, rootFrame)
		local p, guard = o, 0
		while p and guard < 200 do
			if p == rootFrame then
				return true
			end
			p = p._parent
			guard = guard + 1
		end
		return false
	end
	-- Group regions by frame; order frames by strata, level, creation.
	local regionsOf, framesList = {}, {}
	for _, o in ipairs(objects) do
		if L.REGION[o._type] then
			local p = o._parent
			if p then
				regionsOf[p] = regionsOf[p] or {}
				table.insert(regionsOf[p], o)
			end
		elseif o ~= rawget(_G, "UIParent") then
			framesList[#framesList + 1] = o
		end
	end
	local key = {}
	for _, f in ipairs(framesList) do
		key[f] = { L.STRATA[L.Strata(f)] or 3, L.Level(f), f._order }
	end
	table.sort(framesList, function(a, b)
		local ka, kb = key[a], key[b]
		for i = 1, 3 do
			if ka[i] ~= kb[i] then
				return ka[i] < kb[i]
			end
		end
		return false
	end)
	local ids = {}
	local entries = {}
	local function clipOf(o)
		local clip, scrolled
		local p, guard = o._parent, 0
		local function add(q)
			if q and (q._clips or q._type == "ScrollFrame") then
				local l, b, w, h = L.Rect(q)
				if l then
					clip = intersect(clip, toScreen(L, l, b, w, h))
				end
				scrolled = scrolled or q._type == "ScrollFrame" or nil
			end
		end
		if o._scrollParent then
			add(o._scrollParent)
		end
		while p and guard < 200 do
			add(p)
			if p._scrollParent then
				add(p._scrollParent)
			end
			p = p._parent
			guard = guard + 1
		end
		return clip, scrolled
	end
	-- The top-level frame an object belongs to (the child of UIParent, or the root of its tree).
	local UIP = rawget(_G, "UIParent")
	local function topOf(o)
		local p, guard = o, 0
		while p._parent and p._parent ~= UIP and guard < 200 do
			p = p._parent
			guard = guard + 1
		end
		return name(p)
	end
	local function base(o, rect)
		local s = L.EffectiveScale(o)
		local e = {
			id = #entries + 1,
			kind = o._type,
			path = name(o),
			rect = rect,
			scale = s,
			alpha = alphaOf(o),
			template = o._template,
			top = topOf(o),
		}
		e.clip, e.scrolled = clipOf(o)
		if o._anchorConflict then
			local c = o._anchorConflict
			e.anchorConflict = { axis = c.axis, delta = math.floor(c.delta * s + 0.5) }
		end
		return e, s
	end
	local function visibleRect(o)
		if not L.Visible(o) then
			return nil
		end
		if opts.root and not under(o, opts.root) then
			return nil
		end
		local l, b, w, h = L.Rect(o)
		if not l then
			return nil
		end
		return toScreen(L, l, b, w, h)
	end
	local function push(e, o)
		if e.clip and (e.clip[3] <= 0 or e.clip[4] <= 0) then
			return -- clipped away entirely
		end
		entries[#entries + 1] = e
		e.id = #entries
		ids[o] = e.id
	end
	local function buttonStateShown(t)
		local st = t._buttonState
		if not st then
			return true
		end
		local b = t._parent
		if st == "highlight" or st == "pushed" then
			return false
		elseif st == "disabled" then
			return b._enabled == false
		elseif st == "normal" then
			return b._enabled ~= false or not rawget(b, "_disabledTex")
		elseif st == "checked" then
			return b._checked and true or false
		end
		return true
	end
	for _, f in ipairs(framesList) do
		local rect = visibleRect(f)
		if rect then
			local e, s = base(f, rect)
			local k = key[f]
			e.strata, e.level, e.layer, e.sublevel = L.Strata(f), k[2], "FRAME", 0
			e.parent = f._parent and ids[f._parent]
			e.parentPath = f._parent and name(f._parent)
			e.clickable = clickable(f) or nil
			e.mouse = f._mouse or nil
			e.enabled = f._enabled ~= false
			e.nineSlice = f._nineSlice
			e.noPortrait = f._noPortrait or nil
			if f._backdrop then
				local bd = f._backdrop
				local ins = bd.insets or {}
				e.backdrop = {
					bgFile = bd.bgFile,
					edgeFile = bd.edgeFile,
					tile = bd.tile or false,
					tileSize = (bd.tileSize or 0) * s,
					edgeSize = (bd.edgeSize or 0) * s,
					insets = { (ins.left or 0) * s, (ins.right or 0) * s, (ins.top or 0) * s, (ins.bottom or 0) * s },
					color = color(f._backdropColor) or { 1, 1, 1, 1 },
					borderColor = color(f._backdropBorderColor) or { 1, 1, 1, 1 },
				}
			end
			if f._type == "EditBox" and (f._text or "") ~= "" then
				local info = L.FontInfo(f)
				info.justifyH = f._justifyH or "LEFT"
				local ins = f._insets or { 0, 0, 0, 0 }
				local inner = { rect[1] + ins[1] * s, rect[2] + ins[3] * s, rect[3] - (ins[1] + ins[2]) * s,
					rect[4] - (ins[3] + ins[4]) * s }
				local lay = L.TextLayout(f, nil, nil)
				e.text = textRecord(L, f, inner, s, info, lay)
			end
			if f._type == "StatusBar" then
				e.bar = { min = f._min or 0, max = f._max or 1, value = f._value or 0 }
			end
			push(e, f)
			-- The frame's own regions, by layer, sublevel and creation.
			local regs = {}
			for _, r in ipairs(regionsOf[f] or {}) do
				if not r._isMask and r._layer ~= "HIGHLIGHT" and buttonStateShown(r) then
					regs[#regs + 1] = r
				end
			end
			table.sort(regs, function(a, b)
				local la, lb = L.LAYERS[a._layer or "ARTWORK"] or 3, L.LAYERS[b._layer or "ARTWORK"] or 3
				if la ~= lb then
					return la < lb
				end
				local sa, sb = a._sublevel or 0, b._sublevel or 0
				if sa ~= sb then
					return sa < sb
				end
				return a._order < b._order
			end)
			for _, r in ipairs(regs) do
				local rr = r._type ~= "Line" and visibleRect(r) or (L.Visible(r) and { 0, 0, 0, 0 } or nil)
				if rr then
					local re, rs = base(r, rr)
					re.strata, re.level = e.strata, e.level
					re.layer, re.sublevel = r._layer or "ARTWORK", r._sublevel or 0
					re.parent, re.parentPath = e.id, e.path
					local keep = false
					if r._type == "Texture" or r._type == "MaskTexture" then
						local synthetic = M.SyntheticPath and M.SyntheticPath(r._texture)
						local tex = {
							file = synthetic or (type(r._texture) == "string" and r._texture or nil),
							fileID = not synthetic and type(r._texture) == "number" and r._texture or nil,
							atlas = r._atlas,
							color = color(r._color),
							coords = r._coords,
							vertex = color(r._vertex),
							blend = r._blend,
							desaturated = r._desaturated or nil,
							rotation = r._rotation,
							rotationPoint = r._rotation and r._rotationPoint or nil,
							wrap = wrapModes(r._wrap),
							tile = (r._tileH or r._tileV) and { r._tileH or false, r._tileV or false } or nil,
							gradient = r._gradient,
						}
						if r._masks then
							tex.masks = {}
							for _, m in ipairs(r._masks) do
								local ml, mb, mw, mh = L.Rect(m)
								if ml then
									tex.masks[#tex.masks + 1] = { file = M.SyntheticPath(m._texture) or m._texture, atlas = m._atlas,
										rect = toScreen(L, ml, mb, mw, mh) }
								end
							end
						end
						if r._buttonState == "bar" and f._type == "StatusBar" then
							local lo, hi, v = f._min or 0, f._max or 1, f._value or 0
							local frac = hi > lo and math.max(0, math.min(1, (v - lo) / (hi - lo))) or 0
							re.rect = { rr[1], rr[2], rr[3] * frac, rr[4] }
						end
						keep = tex.file ~= nil or tex.fileID ~= nil or tex.atlas ~= nil or tex.color ~= nil
						re.texture = tex
					elseif r._type == "FontString" then
						local skip = r._buttonText and not r._fontObject and not r._font
						if (r._text or "") ~= "" and not skip then
							local width, height = L.TextBox(r)
							local lay, info = L.TextLayout(r, width, height)
							re.text = textRecord(L, r, rr, rs, info, lay)
							keep = true
						end
					elseif r._type == "Line" and r._startPoint and r._endPoint then
						local function ep(p)
							local rel = p[2] or f
							local l, b, w, h = L.Rect(rel)
							if not l then
								return nil
							end
							local x, y = L.PointOf(l, b, w, h, p[1] or "CENTER")
							return { x + (p[3] or 0) * rs, L.state.height - (y + (p[4] or 0) * rs) }
						end
						local a, z = ep(r._startPoint), ep(r._endPoint)
						if a and z then
							re.line = { from = a, to = z, thickness = (r._thickness or M.LINE_THICKNESS) * rs,
								color = color(r._color), vertex = color(r._vertex), file = r._texture, atlas = r._atlas,
								coords = r._coords }
							re.rect = { math.min(a[1], z[1]), math.min(a[2], z[2]), math.abs(a[1] - z[1]),
								math.abs(a[2] - z[2]) }
							keep = true
						end
					end
					if keep and re.alpha > 0 then
						push(re, r)
					end
				end
			end
		end
	end
	local doc = {
		schema = Dump.SCHEMA,
		harness = M.VERSION,
		view = opts.view,
		meta = opts.meta or {},
		screen = { L.state.width, L.state.height },
		regions = entries,
	}
	if opts.window then
		local l, b, w, h = L.Rect(opts.window)
		if l then
			doc.window = { path = name(opts.window), rect = toScreen(L, l, b, w, h), id = ids[opts.window] }
		end
	end
	return doc
end

function Dump.Write(doc, path)
	local fh = assert(io.open(path, "wb"))
	fh:write(JSON.Encode(doc, " "))
	fh:write("\n")
	fh:close()
end

return Dump
