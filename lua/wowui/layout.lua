-- wowui.layout: anchor, size, scale and text resolution for wowui.mock, applied as the client does.
--
--   local layout = require("wowui.layout")
--   layout.Enable(mock, {
--     width = 1920, height = 1080,               -- UIParent's size in UI units (default 1920 x 1080)
--     fonts = {
--       roots = { { "Fonts\\", "<dir with the game's fonts>" },            -- game path prefix -> local folder
--                 { "Interface\\AddOns\\MyAddon\\", "<addon folder>" } },
--       fallback = "<a .ttf>", fallbackScale = 1.0,                      -- for any face not found
--     },
--   })
--
-- After Enable, region getters answer from the resolved layout: GetLeft/Right/Top/Bottom/Center/Rect, GetWidth/Height/
-- Size, GetEffectiveScale, IsVisible, GetStringWidth/Height, GetUnboundedStringWidth, IsTruncated, GetFrameStrata
-- (inherited), GetFrameLevel (parent + 1 unless set), IsMouseEnabled (as set). Rectangles are in UIParent units with the
-- origin at the bottom left, like the client's; a region without anchors (or anchored to one without) has no rect.
--
-- How it resolves, as the client does: every anchor fixes one horizontal value (LEFT, RIGHT or centre) and one vertical
-- (TOP, BOTTOM or centre) from its target's rect plus the offset times the region's effective scale; a side pair gives
-- the size, otherwise the set size (a font string's measured text) does. A scroll frame's child sits at the frame's top
-- left, moved by the scroll offsets. Scales multiply down the parent chain.

local Text = require("wowui.text")
local TTF = require("wowui.ttf")

local Layout = {}

local LAYERS = { BACKGROUND = 1, BORDER = 2, ARTWORK = 3, OVERLAY = 4, HIGHLIGHT = 5 }
local STRATA = { WORLD = 0, BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6,
	FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
Layout.LAYERS, Layout.STRATA = LAYERS, STRATA

local REGION = { Texture = true, FontString = true, Line = true, MaskTexture = true }
Layout.REGION = REGION

local state -- set by Enable

local function root()
	return rawget(_G, "UIParent")
end

-- Effective scale: own scale times every parent's.
local function effScale(r)
	local s, p, guard = 1, r, 0
	while p and guard < 200 do
		s = s * (p._scale or 1)
		p = p._parent
		guard = guard + 1
	end
	return s
end
Layout.EffectiveScale = effScale

function Layout.Visible(r)
	local p, guard = r, 0
	while p and guard < 200 do
		if p._shown == false then
			return false
		end
		p = p._parent
		guard = guard + 1
	end
	return true
end

-- Font resolution --------------------------------------------------------------------------------------------------

local function norm(path)
	return (tostring(path or ""):gsub("/", "\\")):lower()
end

-- Local file for a game font path: (font object or nil, local path, how) with how = "exact" | "fallback" | "none".
function Layout.ResolveFont(gamePath)
	local cfg = state.fonts or {}
	local key = norm(gamePath)
	local hit = state.fontCache[key]
	if hit then
		return hit[1], hit[2], hit[3]
	end
	local found
	-- The longest matching prefix wins (an addon's own folder before a general AddOns folder).
	local roots = {}
	for _, r in ipairs(cfg.roots or {}) do
		roots[#roots + 1] = r
	end
	table.sort(roots, function(a, b)
		return #a[1] > #b[1]
	end)
	for _, r in ipairs(roots) do
		local prefix = norm(r[1])
		if key:sub(1, #prefix) == prefix then
			local rest = tostring(gamePath):sub(#prefix + 1):gsub("\\", "/")
			local candidate = r[2] .. "/" .. rest
			local font = TTF.Load(candidate)
			if not font then
				-- Case differences between the game's path and the file on disk.
				local lower = r[2] .. "/" .. rest:lower()
				font = TTF.Load(lower)
				candidate = lower
			end
			if font then
				found = { font, candidate, "exact" }
				break
			end
		end
	end
	if not found and cfg.fallback then
		local font = TTF.Load(cfg.fallback)
		if font then
			found = { font, cfg.fallback, "fallback" }
		end
	end
	found = found or { nil, nil, "none" }
	state.fontCache[key] = found
	return found[1], found[2], found[3]
end

-- A font string's face, size, flags, colours and justification, following its font object chain.
function Layout.FontInfo(fs)
	local file, size, flags = fs._font, fs._fontSize, fs._fontFlags
	local color, shadowColor, shadowOffset = fs._textColor, fs._shadowColor, fs._shadowOffset
	local jh, jv, spacing = fs._justifyH, fs._justifyV, fs._spacing
	local fo, guard = fs._fontObject, 0
	while type(fo) == "table" and guard < 20 do
		file = file or fo._font
		size = size or fo._fontSize
		flags = flags or fo._fontFlags
		color = color or fo._textColor
		shadowColor = shadowColor or fo._shadowColor
		shadowOffset = shadowOffset or fo._shadowOffset
		jh, jv, spacing = jh or fo._justifyH, jv or fo._justifyV, spacing or fo._spacing
		fo = fo._fontObject
		guard = guard + 1
	end
	return {
		file = file or "Fonts\\FRIZQT__.TTF",
		size = size or 12,
		flags = flags or "",
		color = color or { 1, 1, 1, 1 },
		shadowColor = shadowColor,
		shadowOffset = shadowOffset,
		justifyH = jh or "CENTER",
		justifyV = jv or "MIDDLE",
		spacing = spacing or 0,
	}
end

-- Text layout of a font string for a width / height limit in its own units (nil = unbounded).
function Layout.TextLayout(fs, width, height)
	local info = Layout.FontInfo(fs)
	local font, localPath, how = Layout.ResolveFont(info.file)
	local scale = how == "fallback" and (state.fonts and state.fonts.fallbackScale) or 1
	local text = fs._text or ""
	local key = table.concat({ text, info.file, info.size, tostring(width), tostring(height), tostring(fs._wordWrap),
		tostring(fs._maxLines), info.spacing }, "\1")
	local hit = state.textCache[key]
	if hit then
		return hit, info
	end
	local lay = Text.Layout(text, {
		font = font,
		size = info.size,
		scale = scale,
		width = width,
		wrap = fs._wordWrap ~= false,
		maxLines = fs._maxLines,
		maxHeight = height,
		spacing = info.spacing,
	})
	lay.fontLocal, lay.fontHow, lay.fontScale = localPath, how, scale
	state.textCache[key] = lay
	return lay, info
end

-- Rectangles ----------------------------------------------------------------------------------------------------------

local function axisX(point)
	if point:find("LEFT", 1, true) then
		return "L"
	elseif point:find("RIGHT", 1, true) then
		return "R"
	end
	return "C"
end

local function axisY(point)
	if point:find("TOP", 1, true) then
		return "T"
	elseif point:find("BOTTOM", 1, true) then
		return "B"
	end
	return "C"
end

local resolve

-- A point of a rect (l, b, w, h).
local function pointOf(l, b, w, h, point)
	local ax, ay = axisX(point), axisY(point)
	local x = ax == "L" and l or ax == "R" and (l + w) or (l + w / 2)
	local y = ay == "B" and b or ay == "T" and (b + h) or (b + h / 2)
	return x, y
end
Layout.PointOf = pointOf

local function compute(r)
	if r == root() then
		return 0, 0, state.width, state.height
	end
	local s = effScale(r)
	local sp = r._scrollParent
	if sp then
		local l, b, _, h = resolve(sp)
		if not l then
			return nil
		end
		local ss = effScale(sp)
		local cw, ch = (r._w or 0) * s, (r._h or 0) * s
		local top = b + h + (sp._scroll or 0) * ss
		local left = l - (sp._hscroll or 0) * ss
		return left, top - ch, cw, ch
	end
	local pts = r._points
	if (not pts or #pts == 0) and r._type == "FontString" and r._parent and r._parent._template then
		-- A template's text the mock built without anchors: templates centre their label.
		pts = { { "CENTER", r._parent, "CENTER", 0, 0 } }
	end
	if not pts or #pts == 0 then
		return nil
	end
	local L, R, CX, T, B, CY
	-- Two points that pin the same edge (or centre) to different places: the client's answer is not something to
	-- rely on (this mock takes the last one set). Recorded for the lint (rule anchor-conflict).
	local conflict
	local function put(old, new, axis, centre)
		if old and math.abs(old - new) > 0.5 then
			conflict = conflict or { axis = axis, delta = math.abs(old - new), centre = centre }
		end
		return new
	end
	for _, p in ipairs(pts) do
		local point, rel, relPoint, x, y = p[1], p[2], p[3] or p[1], p[4] or 0, p[5] or 0
		local target = rel or r._parent or root()
		local tl, tb, tw, th = resolve(target)
		if not tl then
			return nil
		end
		local px, py = pointOf(tl, tb, tw, th, relPoint)
		px, py = px + x * s, py + y * s
		local ax, ay = axisX(point), axisY(point)
		if ax == "L" then
			L = put(L, px, "x")
		elseif ax == "R" then
			R = put(R, px, "x")
		else
			CX = put(CX, px, "x", true)
		end
		if ay == "T" then
			T = put(T, py, "y")
		elseif ay == "B" then
			B = put(B, py, "y")
		else
			CY = put(CY, py, "y", true)
		end
	end
	-- An edge set by one point wins over a centre set by another (TOPLEFT and RIGHT: the top is TOPLEFT's), as in the
	-- client; only the same edge or the same centre set twice is ambiguous.
	if conflict and conflict.centre and ((conflict.axis == "y" and (T or B)) or (conflict.axis == "x" and (L or R))) then
		conflict = nil
	end
	r._anchorConflict = conflict
	local w, h
	if L and R then
		w = R - L
	elseif r._w then
		w = r._w * s
	end
	if T and B then
		h = T - B
	elseif r._h then
		h = r._h * s
	end
	-- A texture given no size (or 0) whose file's size is known (mock.textureSizes, the runner's --sizes) takes the
	-- file's pixel size, as the client does.
	if r._type == "Texture" and r._texture ~= nil and not (L and R and T and B) then
		local M = state.mock
		local key = M.TextureKey and M.TextureKey(M.SyntheticPath and M.SyntheticPath(r._texture) or r._texture)
		local size = key ~= nil and M.textureSizes and M.textureSizes[key]
		if size then
			if not (L and R) and (r._w or 0) == 0 then
				w = size[1] * s
			end
			if not (T and B) and (r._h or 0) == 0 then
				h = size[2] * s
			end
		end
	end
	if r._type == "FontString" and (w == nil or h == nil) then
		local lay = Layout.TextLayout(r, w and (w / s) or nil, h and (h / s) or nil)
		w = w or lay.width * s
		h = h or lay.height * s
	end
	w, h = w or 0, h or 0
	local left = L or (R and R - w) or (CX and CX - w / 2) or 0
	local bottom = B or (T and T - h) or (CY and CY - h / 2) or 0
	return left, bottom, w, h
end

-- The resolved rect of a region in UIParent units: left, bottom, width, height (nil when it has none).
function resolve(r)
	if type(r) ~= "table" then
		return nil
	end
	local c = state.rects[r]
	if c and c.gen == state.mock.gen then
		return c[1], c[2], c[3], c[4]
	end
	if state.busy[r] then
		return nil -- an anchor cycle the client would have refused
	end
	state.busy[r] = true
	local l, b, w, h = compute(r)
	state.busy[r] = nil
	state.rects[r] = { l, b, w, h, gen = state.mock.gen }
	return l, b, w, h
end
Layout.Rect = resolve

-- Strata and level, as the client assigns them: inherited strata; level = parent's + 1 unless set.
function Layout.Strata(f)
	local p, guard = f, 0
	while p and guard < 200 do
		if p._strata then
			return p._strata
		end
		p = p._parent
		guard = guard + 1
	end
	return "MEDIUM"
end

function Layout.Level(f)
	if f._level then
		return f._level
	end
	local p = f._parent
	if not p then
		return 0
	end
	return Layout.Level(p) + 1
end

-- The wrap width / height limit a font string lays out in (own units), as resolved.
function Layout.TextBox(fs)
	local s = effScale(fs)
	local pts = fs._points or {}
	local hasL, hasR, hasT, hasB = false, false, false, false
	for _, p in ipairs(pts) do
		local ax, ay = axisX(p[1]), axisY(p[1])
		hasL, hasR = hasL or ax == "L", hasR or ax == "R"
		hasT, hasB = hasT or ay == "T", hasB or ay == "B"
	end
	local l, _, w, h = resolve(fs)
	if not l then
		return fs._w, fs._h
	end
	local width = (hasL and hasR) and w / s or fs._w
	local height = (hasT and hasB) and h / s or fs._h
	return width, height
end

-- Enable --------------------------------------------------------------------------------------------------------------

-- The client fires OnSizeChanged when a frame's resolved size changes (also when anchors, not SetSize, change it, and
-- the first time it gets a size). The mock fires it at once for SetSize / SetWidth / SetHeight; sizes that change
-- through anchors are resolved lazily, so this does the rest on demand: every shown frame with an OnSizeChanged script
-- whose size differs from the last one it was told gets the call (handler and hooks), repeated until nothing changes
-- (handlers that resize their children cascade), at most `passes` times. Returns the number of calls made.
function Layout.SettleSizes(M, passes)
	local calls = 0
	for _ = 1, passes or 8 do
		local changed = false
		for _, f in ipairs(M.frames or {}) do
			local has = (f._scripts and f._scripts.OnSizeChanged) or (f._hooks and f._hooks.OnSizeChanged)
			if has and Layout.Visible(f) then
				local w, h = f:GetWidth() or 0, f:GetHeight() or 0
				local last = f._settledSize
				if not last or math.abs(last[1] - w) > 0.01 or math.abs(last[2] - h) > 0.01 then
					f._settledSize = { w, h }
					if w > 0 or h > 0 or last then
						f._inSizeChanged = true
						local ok, err = pcall(M.FireScript, f, "OnSizeChanged", w, h)
						f._inSizeChanged = nil
						if not ok then
							error(err, 0)
						end
						calls = calls + 1
						changed = true
						M.gen = (M.gen or 0) + 1
					end
				end
			end
		end
		if not changed then
			break
		end
	end
	return calls
end

function Layout.Enable(M, opts)
	opts = opts or {}
	state = {
		mock = M,
		width = opts.width or 1920,
		height = opts.height or 1080,
		fonts = opts.fonts,
		rects = setmetatable({}, { __mode = "k" }),
		busy = {},
		fontCache = {},
		textCache = {},
	}
	M.layout = Layout
	Layout.state = state
	local UIParent = root()
	if UIParent then
		UIParent._w, UIParent._h = state.width, state.height
	end
	-- Frames the client keeps hidden until used.
	for _, name in ipairs({ "GameTooltip" }) do
		local f = rawget(_G, name)
		if f then
			f._shown = false
		end
	end
	local D = M.DEFAULTS
	local function own(r)
		local l, b, w, h = resolve(r)
		if not l then
			return nil
		end
		local s = effScale(r)
		return l / s, b / s, w / s, h / s
	end
	D.GetRect = function(r)
		return own(r)
	end
	D.GetLeft = function(r)
		local l = own(r)
		return l
	end
	D.GetBottom = function(r)
		local _, b = own(r)
		return b
	end
	D.GetRight = function(r)
		local l, _, w = own(r)
		return l and l + w
	end
	D.GetTop = function(r)
		local _, b, _, h = own(r)
		return b and b + h
	end
	D.GetCenter = function(r)
		local l, b, w, h = own(r)
		if not l then
			return nil
		end
		return l + w / 2, b + h / 2
	end
	D.GetWidth = function(r)
		local l, _, w = own(r)
		if l then
			return w
		end
		return r._w or 0
	end
	D.GetHeight = function(r)
		local l, _, _, h = own(r)
		if l then
			return h
		end
		return r._h or 0
	end
	D.GetSize = function(r)
		return D.GetWidth(r), D.GetHeight(r)
	end
	D.GetEffectiveScale = function(r)
		return effScale(r)
	end
	D.IsVisible = function(r)
		return Layout.Visible(r)
	end
	D.GetFrameStrata = function(r)
		return Layout.Strata(r)
	end
	D.GetFrameLevel = function(r)
		return Layout.Level(r)
	end
	D.IsMouseEnabled = function(r)
		return r._mouse or false
	end
	D.GetJustifyH = function(r)
		return Layout.FontInfo(r).justifyH
	end
	D.GetJustifyV = function(r)
		return Layout.FontInfo(r).justifyV
	end
	D.GetLineHeight = function(r)
		return Layout.FontInfo(r).size
	end
	D.GetUnboundedStringWidth = function(r)
		local lay = Layout.TextLayout(r, nil, nil)
		return lay.full
	end
	D.GetStringWidth = function(r)
		local width, height = Layout.TextBox(r)
		local lay = Layout.TextLayout(r, width, height)
		return lay.width
	end
	D.GetStringHeight = function(r)
		local width, height = Layout.TextBox(r)
		local lay = Layout.TextLayout(r, width, height)
		return lay.height
	end
	D.IsTruncated = function(r)
		local width, height = Layout.TextBox(r)
		local lay = Layout.TextLayout(r, width, height)
		return lay.truncated
	end
	D.GetNumLines = function(r)
		local width, height = Layout.TextBox(r)
		return #Layout.TextLayout(r, width, height).lines
	end
	return Layout
end

return Layout
