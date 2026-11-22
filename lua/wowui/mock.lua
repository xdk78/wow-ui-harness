-- wowui.mock: a permissive stand-in for the World of Warcraft client API, enough to load a whole addon (with its
-- Ace3-style libraries) in plain Lua 5.1 and build its UI. Frames and regions are tables that remember what was set on
-- them; unknown CamelCase methods do nothing and return nil. Game-specific data (instances, maps, journal...) is not
-- here: an addon's own test setup adds it after `M.Install()` (see README.md, "Stubs").
--
-- With `require("wowui.layout").Enable(M, opts)` the mock also resolves anchors, sizes, scales and text like the
-- client does, so GetRect / GetWidth / GetStringWidth return real values and `wowui.dump` can write the frame tree.
-- Without it (the default) geometry getters return fixed placeholder values and nothing is resolved, which keeps
-- plain test runs fast.

local M = {}

M.VERSION = "0.2.0"

local frames = {}
M.frames = frames
M.sent = {} -- addon messages sent: { prefix, text, channel, target }
M.chat = {} -- chat messages sent
M.timers = {}
M.now = 1000
M.printed = {}
M.gen = 0 -- bumped on every change that can move or resize something (layout caches key on it)

-- Settings an addon's test setup may change before Install (or at any time; read at call time).
M.buildInfo = { "1.0.0", "1", "Jan 1 2000", 110000 } -- GetBuildInfo
M.locale = "enUS"
M.realm = "Realm"
M.loadableAddons = {} -- [name] = true: C_AddOns.IsAddOnLoadable says yes
M.atlases = {} -- [name] = true or { width, height }: C_Texture.GetAtlasInfo knows it
M.files = {} -- [lower-case path] = file ID: GetFileIDFromPath knows it

-- "Every file exists": a stable made-up file ID per path, mapped back to the path in dumps (M.syntheticPaths), so a
-- renderer can look the file up by name. Set M.fileResolver = M.SyntheticFileID to use it.
M.syntheticPaths = {}
local syntheticIDs = {}
function M.SyntheticFileID(path)
	local key = tostring(path):gsub("/", "\\"):lower()
	local id = syntheticIDs[key]
	if not id then
		id = 2000000000 + #M.syntheticPaths + 1
		M.syntheticPaths[#M.syntheticPaths + 1] = path
		syntheticIDs[key] = id
	end
	return id
end
function M.SyntheticPath(id)
	if type(id) == "number" and id > 2000000000 then
		return M.syntheticPaths[id - 2000000000]
	end
	return nil
end

local function noop() end

local function touch()
	M.gen = M.gen + 1
end
M.Touch = touch

local function lookup(o)
	if type(o) == "string" then
		return rawget(_G, o)
	end
	return o
end

-- Script handlers, as the client keeps them: one handler per script (SetScript, or the first HookScript on a script
-- that has none) and the hooks added after it, run in the order they were added. SetScript drops the hooks.
local function hasScript(f, name)
	return (f._scripts and f._scripts[name]) or (f._hooks and f._hooks[name]) or nil
end

-- Run a frame's script the way the client does: the handler, then every hook with the same arguments. Returns the
-- handler's results. `M.FireScript(button, "OnClick", "LeftButton", false)`.
function M.FireScript(f, name, ...)
	local fn = f._scripts and f._scripts[name]
	local hooks = f._hooks and f._hooks[name]
	if not hooks then
		if fn then
			return fn(f, ...)
		end
		return
	end
	local r = fn and { fn(f, ...) } or {}
	for _, hook in ipairs(hooks) do
		hook(f, ...)
	end
	return unpack(r)
end
local fireScript = M.FireScript

-- The frame tree, for OnShow / OnHide: every object's children in the order they were parented.
local function addChild(p, f)
	if type(p) == "table" then
		local kids = rawget(p, "_children")
		if not kids then
			kids = {}
			rawset(p, "_children", kids)
		end
		kids[#kids + 1] = f
	end
end

local function removeChild(p, f)
	local kids = type(p) == "table" and rawget(p, "_children")
	for i, k in ipairs(kids or {}) do
		if k == f then
			table.remove(kids, i)
			return
		end
	end
end

-- Shown with every ancestor shown: what the client calls visible (IsVisible), whether or not layout is enabled.
local function visible(f)
	local guard = 0
	while f and guard < 200 do
		if f._shown == false then
			return false
		end
		f = f._parent
		guard = guard + 1
	end
	return true
end

-- OnShow / OnHide for a frame that became visible / hidden and for each of its descendants that is shown itself
-- (so it changed visibility with it), parent first.
local function fireTree(f, name)
	if hasScript(f, name) then
		fireScript(f, name)
	end
	local kids = rawget(f, "_children")
	if kids then
		local copy = { unpack(kids) } -- a handler may reparent or create frames
		for _, k in ipairs(copy) do
			if k._shown ~= false and k._parent == f then
				fireTree(k, name)
			end
		end
	end
end

-- The size OnSizeChanged compares: the resolved one with wowui.layout, else the size set (0 when none).
local function sizeNow(f)
	if M.layout then
		return f:GetWidth() or 0, f:GetHeight() or 0
	end
	return f._w or 0, f._h or 0
end

-- After SetSize / SetWidth / SetHeight: OnSizeChanged(self, width, height) when the size really changed, as the client
-- does (it fires when it next resolves the frame; the mock fires at once). Not re-entered for the same frame from its
-- own handler; wowui.layout.SettleSizes picks up sizes that changed through anchors.
local function sizeChanged(f, ow, oh)
	if f._inSizeChanged or not hasScript(f, "OnSizeChanged") then
		return
	end
	local w, h = sizeNow(f)
	if math.abs(w - ow) <= 0.01 and math.abs(h - oh) <= 0.01 then
		return
	end
	f._settledSize = { w, h }
	f._inSizeChanged = true
	local ok, err = pcall(fireScript, f, "OnSizeChanged", w, h)
	f._inSizeChanged = nil
	if not ok then
		error(err, 0)
	end
end

-- Methods with meaningful return values or recorded state. Everything else returns nil.
local DEFAULTS
DEFAULTS = {
	GetWidth = function(self)
		return self._w or 400
	end,
	GetHeight = function(self)
		return self._h or 300
	end,
	GetSize = function(self)
		return self._w or 400, self._h or 300
	end,
	SetWidth = function(self, w)
		DEFAULTS._resize(self, w, self._h)
	end,
	SetHeight = function(self, h)
		DEFAULTS._resize(self, self._w, h)
	end,
	SetSize = function(self, w, h)
		DEFAULTS._resize(self, w, h)
	end,
	_resize = function(self, w, h)
		local watch = not self._inSizeChanged and hasScript(self, "OnSizeChanged")
		local ow, oh
		if watch then
			ow, oh = sizeNow(self)
		end
		self._w, self._h = w, h
		touch()
		if watch then
			sizeChanged(self, ow, oh)
		end
	end,
	GetLeft = function()
		return 0
	end,
	GetRight = function(self)
		return self._w or 400
	end,
	GetTop = function(self)
		return self._h or 300
	end,
	GetBottom = function()
		return 0
	end,
	GetCenter = function()
		return 200, 150
	end,
	GetRect = function(self)
		return 0, 0, self._w or 400, self._h or 300
	end,
	GetEffectiveScale = function()
		return 1
	end,
	GetScale = function(self)
		return self._scale or 1
	end,
	SetScale = function(self, s)
		self._scale = s
		touch()
	end,
	GetStringWidth = function(self)
		return #(self._text or "") * 6
	end,
	GetUnboundedStringWidth = function(self)
		return #(self._text or "") * 6
	end,
	GetStringHeight = function()
		return 14
	end,
	-- Whether the text is cut with "...": only for a font string given a width (SetWidth / SetSize; without
	-- wowui.layout anchors are not resolved), measured at the mock's 6 units a character and 14 a line. The lines
	-- allowed are MaxLines and what the set height holds; without either, wrapped text grows and is not cut.
	-- wowui.layout replaces this with the real measurement.
	IsTruncated = function(self)
		local w = self._w
		if not w or w <= 0 then
			return false
		end
		local need = DEFAULTS.GetUnboundedStringWidth(self)
		if need <= w + 0.5 then
			return false
		end
		if self._wordWrap == false then
			return true
		end
		local lines = (self._maxLines or 0) > 0 and self._maxLines or nil
		if self._h and self._h > 0 then
			local fit = math.max(1, math.floor(self._h / 14))
			lines = lines and math.min(lines, fit) or fit
		end
		return lines ~= nil and need > w * lines + 0.5
	end,
	GetLineHeight = function()
		return 14
	end,
	SetText = function(self, t)
		self._text = t ~= nil and tostring(t) or ""
		if self._type == "Button" or self._type == "CheckButton" then
			local fs = DEFAULTS.GetFontString(self)
			fs._text = self._text
		end
		touch()
	end,
	SetFormattedText = function(self, fmt, ...)
		DEFAULTS.SetText(self, string.format(fmt, ...))
	end,
	GetText = function(self)
		return self._text or ""
	end,
	GetNumber = function(self)
		return tonumber(self._text) or 0
	end,
	GetVerticalScroll = function(self)
		return self._scroll or 0
	end,
	SetVerticalScroll = function(self, v)
		self._scroll = v
		touch()
	end,
	GetHorizontalScroll = function(self)
		return self._hscroll or 0
	end,
	SetHorizontalScroll = function(self, v)
		self._hscroll = v
		touch()
	end,
	GetVerticalScrollRange = function()
		return 0
	end,
	-- As in the client: OnShow when the frame becomes visible (its parents are shown), then for each descendant that
	-- became visible with it; Show on a shown frame does nothing. Hide mirrors it with OnHide.
	Show = function(self)
		if self._shown ~= false then
			return
		end
		self._shown = true
		touch()
		if visible(self) then
			fireTree(self, "OnShow")
		end
	end,
	Hide = function(self)
		if self._shown == false then
			return
		end
		local was = visible(self)
		self._shown = false
		touch()
		if was then
			fireTree(self, "OnHide")
		end
	end,
	SetShown = function(self, v)
		if v then
			self:Show()
		else
			self:Hide()
		end
	end,
	IsShown = function(self)
		return self._shown ~= false
	end,
	IsVisible = function(self)
		return self._shown ~= false
	end,
	-- SetScript replaces the handler and drops the script's hooks; HookScript on a script without a handler sets it (as
	-- the client has done since 3.0.8), otherwise adds a hook that runs after the handler and earlier hooks. GetScript
	-- returns the handler only. mock.FireScript runs handler and hooks.
	SetScript = function(self, name, fn)
		self._scripts = self._scripts or {}
		self._scripts[name] = fn
		if self._hooks then
			self._hooks[name] = nil
		end
	end,
	GetScript = function(self, name)
		return self._scripts and self._scripts[name]
	end,
	HookScript = function(self, name, fn)
		self._scripts = self._scripts or {}
		if not self._scripts[name] then
			self._scripts[name] = fn
			return
		end
		self._hooks = self._hooks or {}
		local list = self._hooks[name] or {}
		self._hooks[name] = list
		list[#list + 1] = fn
	end,
	HasScript = function()
		return true
	end,
	RegisterEvent = function(self, event)
		self._events = self._events or {}
		self._events[event] = true
	end,
	UnregisterEvent = function(self, event)
		if self._events then
			self._events[event] = nil
		end
	end,
	UnregisterAllEvents = function(self)
		self._events = {}
	end,
	IsEventRegistered = function(self, event)
		return self._events and self._events[event] or false
	end,
	GetName = function(self)
		return self._name
	end,
	GetParent = function(self)
		return self._parent
	end,
	-- Reparenting can change visibility: OnShow / OnHide fire as for Show and Hide.
	SetParent = function(self, p)
		p = lookup(p)
		if p == self._parent then
			return
		end
		local was = visible(self)
		removeChild(self._parent, self)
		self._parent = p
		addChild(p, self)
		touch()
		local now = visible(self)
		if was ~= now then
			fireTree(self, now and "OnShow" or "OnHide")
		end
	end,
	GetObjectType = function(self)
		return self._type
	end,
	IsObjectType = function(self, t)
		return self._type == t
	end,
	GetFrameLevel = function(self)
		return self._level or 1
	end,
	SetFrameLevel = function(self, l)
		self._level = l
	end,
	GetFrameStrata = function(self)
		return self._strata or "MEDIUM"
	end,
	SetFrameStrata = function(self, s)
		self._strata = s
	end,
	SetToplevel = function(self, v)
		self._toplevel = v and true or false
	end,
	-- Anchors are remembered (one per point name, as on the client), so tests can check a layout's anchoring.
	SetPoint = function(self, point, rel, relPoint, x, y)
		if type(rel) == "number" then
			rel, relPoint, x, y = nil, point, rel, relPoint
		end
		rel = lookup(rel)
		-- The client refuses an anchor whose target already depends on this region (directly or through a chain), with
		-- "Cannot anchor to a region dependent on it"; the error aborts the caller, as it does in game.
		if type(rel) == "table" then
			local seen = {}
			local function dependsOnSelf(r)
				if r == self then
					return true
				end
				if type(r) ~= "table" or seen[r] then
					return false
				end
				seen[r] = true
				for _, p in ipairs(r._points or {}) do
					if dependsOnSelf(p[2]) then
						return true
					end
				end
				return false
			end
			if dependsOnSelf(rel) then
				error("Action[SetPoint] failed because[Cannot anchor to a region dependent on it]", 2)
			end
		end
		self._points = self._points or {}
		for i, p in ipairs(self._points) do
			if p[1] == point then
				table.remove(self._points, i)
				break
			end
		end
		table.insert(self._points, { point, rel, relPoint or point, x or 0, y or 0 })
		touch()
	end,
	-- SetAllPoints(relativeTo): TOPLEFT and BOTTOMRIGHT on the same points of `relativeTo` (default: the parent).
	SetAllPoints = function(self, rel)
		rel = lookup(rel)
		if type(rel) ~= "table" then
			rel = nil
		end
		DEFAULTS.SetPoint(self, "TOPLEFT", rel, "TOPLEFT", 0, 0)
		DEFAULTS.SetPoint(self, "BOTTOMRIGHT", rel, "BOTTOMRIGHT", 0, 0)
	end,
	ClearAllPoints = function(self)
		self._points = nil
		touch()
	end,
	ClearPoint = function(self, point)
		for i, p in ipairs(self._points or {}) do
			if p[1] == point then
				table.remove(self._points, i)
				touch()
				return
			end
		end
	end,
	GetPoint = function(self, i)
		local p = self._points and self._points[i or 1]
		if p then
			return p[1], p[2], p[3], p[4], p[5]
		end
		return "CENTER", nil, "CENTER", 0, 0
	end,
	GetNumPoints = function(self)
		return self._points and #self._points or 0
	end,
	-- The anchor of `point` as { point, relativeTo, relativePoint, x, y }, or nil (tests only).
	FindPoint = function(self, point)
		for _, p in ipairs(self._points or {}) do
			if p[1] == point then
				return p
			end
		end
		return nil
	end,
	IsEnabled = function(self)
		return self._enabled ~= false
	end,
	SetEnabled = function(self, v)
		self._enabled = v and true or false
	end,
	Enable = function(self)
		self._enabled = true
	end,
	Disable = function(self)
		self._enabled = false
	end,
	HasFocus = function()
		return false
	end,
	GetChecked = function(self)
		return self._checked
	end,
	SetChecked = function(self, v)
		self._checked = v
	end,
	GetFont = function(self)
		local fo = self._fontObject and lookup(self._fontObject)
		if not self._font and fo and fo ~= self and fo._font then
			return fo._font, fo._fontSize or 12, fo._fontFlags or ""
		end
		return self._font or "Fonts\\FRIZQT__.TTF", self._fontSize or 12, self._fontFlags or ""
	end,
	-- As on the client: a Font object's SetFont returns nothing (SimpleFontAPI); a FontString's returns success
	-- (SimpleFontStringAPI), false for a file listed in M.missingFonts.
	SetFont = function(self, file, size, flags)
		if self._type == "FontString" and M.missingFonts and M.missingFonts[file] then
			return false
		end
		self._font = file
		self._fontSize = tonumber(size) or self._fontSize
		self._fontFlags = flags
		touch()
		if self._type == "FontString" then
			return true
		end
	end,
	SetNormalFontObject = function(self, o)
		self._normalFont = lookup(o)
		if self._fs then
			self._fs._fontObject = self._normalFont
		end
	end,
	SetHighlightFontObject = function(self, o)
		self._highlightFont = lookup(o)
	end,
	SetDisabledFontObject = function(self, o)
		self._disabledFont = lookup(o)
	end,
	GetNormalFontObject = function(self)
		return self._normalFont
	end,
	GetFontObject = function(self)
		return self._fontObject
	end,
	SetFontObject = function(self, o)
		self._fontObject = lookup(o)
		touch()
	end,
	CopyFontObject = function(self, o)
		o = lookup(o)
		if type(o) == "table" then
			self._font, self._fontSize, self._fontFlags = o._font, o._fontSize, o._fontFlags
			self._textColor, self._justifyH, self._justifyV = o._textColor, o._justifyH, o._justifyV
		end
	end,
	CreateTexture = function(self, name, layer, template, sublevel)
		local t = M.CreateFrame("Texture", name, self, template)
		t._layer, t._sublevel = layer, sublevel
		return t
	end,
	CreateMaskTexture = function(self, name, layer)
		local t = M.CreateFrame("Texture", name, self)
		t._isMask, t._layer = true, layer
		return t
	end,
	CreateFontString = function(self, name, layer, inherits)
		local fs = M.CreateFrame("FontString", name, self)
		fs._layer = layer
		if inherits then
			fs._fontObject = lookup(inherits)
		end
		return fs
	end,
	CreateLine = function(self, name, layer, template, sublevel)
		local l = M.CreateFrame("Line", name, self, template)
		l._layer, l._sublevel = layer, sublevel
		return l
	end,
	CreateAnimationGroup = function(self)
		return M.CreateFrame("AnimationGroup", nil, self)
	end,
	CreateAnimation = function(self)
		return M.CreateFrame("Animation", nil, self)
	end,
	SetDrawLayer = function(self, layer, sublevel)
		self._layer, self._sublevel = layer, sublevel
	end,
	GetDrawLayer = function(self)
		return self._layer or "ARTWORK", self._sublevel or 0
	end,
	GetChildren = function()
		return nil
	end,
	GetRegions = function()
		return nil
	end,
	-- True while the frame is hovered with mock.Hover (until mock.Leave).
	IsMouseOver = function(self)
		return self._hovered or false
	end,
	EnableMouse = function(self, v)
		self._mouse = v and true or false
	end,
	-- Which clicks a button takes ("LeftButtonUp", "AnyUp", ...; the client's default is "LeftButtonUp") and which
	-- buttons start a drag: recorded, and honoured by mock.Click and mock.Drag.
	RegisterForClicks = function(self, ...)
		self._clicks = { ... }
	end,
	RegisterForDrag = function(self, ...)
		self._drag = { ... }
	end,
	SetMouseClickEnabled = function(self, v)
		self._mouseClick = v and true or false
	end,
	SetMouseMotionEnabled = function(self, v)
		self._mouseMotion = v and true or false
	end,
	-- As last set with EnableMouse (true until then; wowui.layout answers false until then, as the client does for
	-- frames).
	IsMouseEnabled = function(self)
		return self._mouse ~= false
	end,
	SetClipsChildren = function(self, v)
		self._clips = v and true or false
	end,
	DoesClipChildren = function(self)
		return self._clips or false
	end,
	SetAlpha = function(self, a)
		self._alpha = a
	end,
	GetAlpha = function(self)
		return self._alpha or 1
	end,
	GetTexture = function(self)
		return self._texture
	end,
	-- Like the client: success, or false for a file it cannot open (M.missingTextures, e.g. a file added after start).
	SetTexture = function(self, t, wrapH, wrapV)
		self._atlas, self._color = nil, nil
		if M.missingTextures and M.missingTextures[t] then
			self._texture = nil
			return false
		end
		self._texture = t
		self._wrap = (wrapH or wrapV) and { wrapH, wrapV } or nil
		return true
	end,
	SetColorTexture = function(self, r, g, b, a)
		self._texture, self._atlas = nil, nil
		self._color = { r or 1, g or 1, b or 1, a or 1 }
	end,
	SetAtlas = function(self, name, useAtlasSize)
		self._texture, self._color = nil, nil
		self._atlas = name
		self._coords = nil
		if useAtlasSize and C_Texture and C_Texture.GetAtlasInfo then
			local info = C_Texture.GetAtlasInfo(name)
			if info and info.width then
				self._w, self._h = info.width, info.height
				touch()
			end
		end
	end,
	GetAtlas = function(self)
		return self._atlas
	end,
	SetTexCoord = function(self, ...)
		local n = select("#", ...)
		if n == 4 or n == 8 then
			self._coords = { ... }
		end
	end,
	GetTexCoord = function(self)
		local c = self._coords
		if c and #c == 4 then
			return c[1], c[3], c[1], c[4], c[2], c[3], c[2], c[4]
		elseif c then
			return unpack(c)
		end
		return 0, 0, 0, 1, 1, 0, 1, 1
	end,
	SetVertexColor = function(self, r, g, b, a)
		self._vertex = { r, g, b, a or 1 }
	end,
	GetVertexColor = function(self)
		local c = self._vertex
		if c then
			return c[1], c[2], c[3], c[4]
		end
		return 1, 1, 1, 1
	end,
	SetDesaturated = function(self, v)
		self._desaturated = v and true or false
	end,
	IsDesaturated = function(self)
		return self._desaturated or false
	end,
	SetBlendMode = function(self, mode)
		self._blend = mode
	end,
	SetRotation = function(self, r)
		self._rotation = r
	end,
	SetGradient = function(self, orientation, c1, c2)
		self._gradient = { orientation, c1, c2 }
	end,
	SetHorizTile = function(self, v)
		self._tileH = v and true or false
	end,
	SetVertTile = function(self, v)
		self._tileV = v and true or false
	end,
	AddMaskTexture = function(self, mask)
		self._masks = self._masks or {}
		self._masks[#self._masks + 1] = mask
	end,
	RemoveMaskTexture = function(self, mask)
		for i, m in ipairs(self._masks or {}) do
			if m == mask then
				table.remove(self._masks, i)
				return
			end
		end
	end,
	SetTextColor = function(self, r, g, b, a)
		self._textColor = { r or 1, g or 1, b or 1, a or 1 }
	end,
	GetTextColor = function(self)
		local c = self._textColor
		if c then
			return c[1], c[2], c[3], c[4]
		end
		return 1, 1, 1, 1
	end,
	SetShadowColor = function(self, r, g, b, a)
		self._shadowColor = { r or 0, g or 0, b or 0, a or 1 }
	end,
	GetShadowColor = function(self)
		local c = self._shadowColor
		if c then
			return c[1], c[2], c[3], c[4]
		end
		return 0, 0, 0, 1
	end,
	SetShadowOffset = function(self, x, y)
		self._shadowOffset = { x or 0, y or 0 }
	end,
	GetShadowOffset = function(self)
		local o = self._shadowOffset
		if o then
			return o[1], o[2]
		end
		return 0, 0
	end,
	SetJustifyH = function(self, j)
		self._justifyH = j
		touch()
	end,
	SetJustifyV = function(self, j)
		self._justifyV = j
		touch()
	end,
	GetJustifyH = function(self)
		return self._justifyH or "LEFT"
	end,
	GetJustifyV = function(self)
		return self._justifyV or "MIDDLE"
	end,
	SetWordWrap = function(self, v)
		self._wordWrap = v and true or false
		touch()
	end,
	CanWordWrap = function(self)
		return self._wordWrap ~= false
	end,
	SetNonSpaceWrap = function(self, v)
		self._nonSpaceWrap = v and true or false
		touch()
	end,
	SetMaxLines = function(self, n)
		self._maxLines = n
		touch()
	end,
	GetMaxLines = function(self)
		return self._maxLines or 0
	end,
	SetSpacing = function(self, s)
		self._spacing = s
		touch()
	end,
	GetSpacing = function(self)
		return self._spacing or 0
	end,
	GetMaxLetters = function()
		return 0
	end,
	GetNumLetters = function(self)
		return #(self._text or "")
	end,
	GetCursorPosition = function()
		return 0
	end,
	IsMultiLine = function()
		return false
	end,
	SetTextInsets = function(self, l, r, t, b)
		self._insets = { l or 0, r or 0, t or 0, b or 0 }
	end,
	GetTextInsets = function(self)
		local i = self._insets
		if i then
			return i[1], i[2], i[3], i[4]
		end
		return 0, 0, 0, 0
	end,
	SetMinMaxValues = function(self, lo, hi)
		self._min, self._max = lo, hi
	end,
	GetMinMaxValues = function(self)
		return self._min or 0, self._max or 1
	end,
	SetValue = function(self, v)
		self._value = v
	end,
	GetValue = function(self)
		return self._value or 0
	end,
	GetValueStep = function()
		return 1
	end,
	SetHitRectInsets = function(self, l, r, t, b)
		self._hitInsets = { l or 0, r or 0, t or 0, b or 0 }
	end,
	GetHitRectInsets = function(self)
		local i = self._hitInsets
		if i then
			return i[1], i[2], i[3], i[4]
		end
		return 0, 0, 0, 0
	end,
	GetID = function()
		return 0
	end,
	IsDragging = function()
		return false
	end,
	IsToplevel = function(self)
		return self._toplevel or false
	end,
	-- BackdropTemplate's API: recorded so a dump can draw the backdrop.
	SetBackdrop = function(self, info)
		self._backdrop = info
	end,
	SetBackdropColor = function(self, r, g, b, a)
		self._backdropColor = { r or 1, g or 1, b or 1, a or 1 }
	end,
	SetBackdropBorderColor = function(self, r, g, b, a)
		self._backdropBorderColor = { r or 1, g or 1, b or 1, a or 1 }
	end,
	GetStatusBarTexture = function(self)
		return DEFAULTS._stateTexture(self, "_barTex", "ARTWORK", "bar")
	end,
	SetStatusBarTexture = function(self, t)
		local tex = DEFAULTS._stateTexture(self, "_barTex", "ARTWORK", "bar")
		if type(t) == "table" then
			self._barTex = t
		else
			tex:SetTexture(t)
		end
	end,
	-- A button's state textures: one region each, anchored to the button (as the client does), drawn by state.
	_stateTexture = function(self, field, layer, state)
		local t = rawget(self, field)
		if not t then
			t = M.CreateFrame("Texture", nil, self)
			t._layer, t._buttonState = layer, state
			DEFAULTS.SetAllPoints(t, self)
			rawset(self, field, t)
		end
		return t
	end,
	GetNormalTexture = function(self)
		return DEFAULTS._stateTexture(self, "_normalTex", "ARTWORK", "normal")
	end,
	GetHighlightTexture = function(self)
		return DEFAULTS._stateTexture(self, "_highlightTex", "HIGHLIGHT", "highlight")
	end,
	GetPushedTexture = function(self)
		return DEFAULTS._stateTexture(self, "_pushedTex", "ARTWORK", "pushed")
	end,
	GetDisabledTexture = function(self)
		return DEFAULTS._stateTexture(self, "_disabledTex", "ARTWORK", "disabled")
	end,
	GetCheckedTexture = function(self)
		return DEFAULTS._stateTexture(self, "_checkedTex", "OVERLAY", "checked")
	end,
	SetNormalTexture = function(self, t)
		DEFAULTS._setState(self, "_normalTex", "ARTWORK", "normal", t)
	end,
	SetHighlightTexture = function(self, t, blend)
		DEFAULTS._setState(self, "_highlightTex", "HIGHLIGHT", "highlight", t)
		if blend then
			self._highlightTex._blend = blend
		end
	end,
	SetPushedTexture = function(self, t)
		DEFAULTS._setState(self, "_pushedTex", "ARTWORK", "pushed", t)
	end,
	SetDisabledTexture = function(self, t)
		DEFAULTS._setState(self, "_disabledTex", "ARTWORK", "disabled", t)
	end,
	SetCheckedTexture = function(self, t)
		DEFAULTS._setState(self, "_checkedTex", "OVERLAY", "checked", t)
	end,
	SetNormalAtlas = function(self, a)
		DEFAULTS._stateTexture(self, "_normalTex", "ARTWORK", "normal"):SetAtlas(a)
	end,
	SetHighlightAtlas = function(self, a)
		DEFAULTS._stateTexture(self, "_highlightTex", "HIGHLIGHT", "highlight"):SetAtlas(a)
	end,
	SetPushedAtlas = function(self, a)
		DEFAULTS._stateTexture(self, "_pushedTex", "ARTWORK", "pushed"):SetAtlas(a)
	end,
	_setState = function(self, field, layer, state, t)
		if type(t) == "table" then
			t._buttonState = state
			t._layer = t._layer or layer
			rawset(self, field, t)
			if not t._points then
				DEFAULTS.SetAllPoints(t, self)
			end
		else
			DEFAULTS._stateTexture(self, field, layer, state):SetTexture(t)
		end
	end,
	GetFontString = function(self)
		local fs = rawget(self, "_fs")
		if not fs then
			fs = M.CreateFrame("FontString", nil, self)
			fs._layer = "OVERLAY"
			fs._fontObject = self._normalFont
			fs._buttonText = true
			fs._points = { { "CENTER", self, "CENTER", 0, 0 } }
			rawset(self, "_fs", fs)
		end
		return fs
	end,
	SetFontString = function(self, fs)
		rawset(self, "_fs", fs)
	end,
	IsOwned = function()
		return false
	end,
	NumLines = function()
		return 0
	end,
	GetScrollChild = function(self)
		return self._child
	end,
	SetScrollChild = function(self, c)
		if self._child and self._child._scrollParent == self then
			self._child._scrollParent = nil
		end
		self._child = c
		if type(c) == "table" then
			c._scrollParent = self
		end
		touch()
	end,
	GetAttribute = function()
		return nil
	end,
	SetTextureSliceMargins = function() end,
	-- Lines (CreateLine): endpoints relative to regions, thickness.
	SetStartPoint = function(self, relPoint, rel, x, y)
		self._startPoint = { relPoint, lookup(rel), x or 0, y or 0 }
	end,
	SetEndPoint = function(self, relPoint, rel, x, y)
		self._endPoint = { relPoint, lookup(rel), x or 0, y or 0 }
	end,
	SetThickness = function(self, t)
		self._thickness = t
	end,
	GetThickness = function(self)
		return self._thickness or 1
	end,
}
M.DEFAULTS = DEFAULTS

local mt = {
	__index = function(_, k)
		local fn = DEFAULTS[k]
		if fn then
			return fn
		end
		-- Widget methods are CamelCase; anything else is a field the code set (or nil).
		if type(k) == "string" and k:match("^%u") then
			return noop
		end
		return nil
	end,
}
M.mt = mt

-- Frame templates the mock knows: M.templates[name] = function(frame) that adds the template's parts (the regions and
-- methods an addon's code touches). An addon's test setup fills it; any other template name is only recorded.
M.templates = {}

-- CreateFrame(kind, name, parent, template): the template is recorded (`_template`) and built from M.templates.
function M.CreateFrame(kind, name, parent, template)
	local f = setmetatable({ _type = kind, _name = name, _parent = lookup(parent), _shown = true, _template = template,
		_order = #frames + 1 }, mt)
	frames[#frames + 1] = f
	addChild(f._parent, f)
	if name then
		_G[name] = f
	end
	touch()
	local build = type(template) == "string" and M.templates[template]
	if build then
		build(f)
	end
	return f
end

-- Fire a game event at every frame registered for it (AceEvent, AceAddon, the addon's own).
function M.FireEvent(event, ...)
	for _, f in ipairs(frames) do
		if f._events and f._events[event] and hasScript(f, "OnEvent") then
			fireScript(f, "OnEvent", event, ...)
		end
	end
end

-- One frame of `seconds`: OnUpdate(self, elapsed) for every visible frame (the client runs OnUpdate only for visible
-- frames), then the C_Timer callbacks due by then, earliest first. A timer created by a callback runs on a later frame,
-- and a ticker fires at most once a frame, as in the client.
local timerSeq = 0
local function frameStep(seconds)
	M.now = M.now + seconds
	for _, f in ipairs(frames) do
		if hasScript(f, "OnUpdate") and visible(f) then
			fireScript(f, "OnUpdate", seconds)
		end
	end
	local due, keep = {}, {}
	for _, t in ipairs(M.timers) do
		if not t.cancelled then
			if t.at <= M.now + 1e-9 then
				due[#due + 1] = t
			else
				keep[#keep + 1] = t
			end
		end
	end
	M.timers = keep
	table.sort(due, function(a, b)
		if a.at ~= b.at then
			return a.at < b.at
		end
		return (a.seq or 0) < (b.seq or 0)
	end)
	for _, t in ipairs(due) do
		if not t.cancelled then
			t.fn(t.handle)
			if t.left then -- a ticker with a number of iterations
				t.left = t.left - 1
				if t.left <= 0 then
					t.cancelled = true
				end
			end
			if t.every and not t.cancelled then
				t.at = M.now + t.every
				M.timers[#M.timers + 1] = t
			end
		end
	end
end

-- Advance time by `seconds` as one frame, or as frames of `step` seconds each: `mock.Advance(2, 0.1)` runs 20 frames.
function M.Advance(seconds, step)
	if not step or step <= 0 or step >= seconds then
		frameStep(seconds)
		return
	end
	local left = seconds
	while left > 1e-9 do
		local dt = math.min(step, left)
		frameStep(dt)
		left = left - dt
	end
end

-- Input the tests drive: the cursor (GetCursorPosition), held mouse buttons (IsMouseButtonDown) and held keys
-- (IsShiftKeyDown, IsControlKeyDown, IsAltKeyDown, IsModifierKeyDown, IsKeyDown...). Keys are the client's names:
-- "LSHIFT", "RSHIFT", "LCTRL", "RCTRL", "LALT", "RALT", "LMETA", "RMETA", letters; "SHIFT", "CTRL", "ALT" and "META"
-- mean the left one.
M.input = { x = 0, y = 0, buttons = {}, keys = {} }

local KEY_ALIAS = { SHIFT = "LSHIFT", CTRL = "LCTRL", ALT = "LALT", META = "LMETA" }
local BUTTON_ALIAS = { [1] = "LeftButton", [2] = "RightButton", [3] = "MiddleButton", [4] = "Button4", [5] = "Button5" }

function M.SetCursor(x, y)
	M.input.x, M.input.y = x, y
end

function M.SetMouseButtonDown(button, down)
	M.input.buttons[BUTTON_ALIAS[button] or button or "LeftButton"] = down ~= false or nil
end

function M.SetKeyDown(key, down)
	key = tostring(key):upper()
	M.input.keys[KEY_ALIAS[key] or key] = down ~= false or nil
end

function M.ResetInput()
	M.input = { x = 0, y = 0, buttons = {}, keys = {} }
end

-- Run fn with this input, then put the previous input back (also when fn fails). `state`: { cursor = { x, y },
-- keys = { "SHIFT", ... }, buttons = { "LeftButton", ... } }. Returns fn's results.
function M.WithInput(state, fn, ...)
	local saved = M.input
	M.input = { x = saved.x, y = saved.y, buttons = {}, keys = {} }
	for k, v in pairs(saved.buttons) do
		M.input.buttons[k] = v
	end
	for k, v in pairs(saved.keys) do
		M.input.keys[k] = v
	end
	if state.cursor then
		M.SetCursor(state.cursor[1], state.cursor[2])
	end
	for _, k in ipairs(state.keys or {}) do
		M.SetKeyDown(k, true)
	end
	for _, b in ipairs(state.buttons or {}) do
		M.SetMouseButtonDown(b, true)
	end
	local r = { pcall(fn, ...) }
	M.input = saved
	if not r[1] then
		error(r[2], 0)
	end
	return unpack(r, 2)
end

local function keyDown(...)
	for i = 1, select("#", ...) do
		if M.input.keys[(select(i, ...))] then
			return true
		end
	end
	return false
end

local function clickRegistered(f, button, dir)
	local list = rawget(f, "_clicks") or { "LeftButtonUp" }
	for _, c in ipairs(list) do
		if c == button .. dir or c == "Any" .. dir then
			return true
		end
	end
	return false
end

local function runIf(f, name, ...)
	if hasScript(f, name) then
		return fireScript(f, name, ...)
	end
end

local function click(f, button, down)
	if f._type ~= "Button" and f._type ~= "CheckButton" then
		return false
	end
	if f._enabled == false or not clickRegistered(f, button, down and "Down" or "Up") then
		return false
	end
	if f._type == "CheckButton" then
		f._checked = not f._checked
	end
	runIf(f, "PreClick", button, down)
	runIf(f, "OnClick", button, down)
	runIf(f, "PostClick", button, down)
	return true
end

-- A click as the client delivers it: OnMouseDown, (OnClick if registered for the down stroke), OnMouseUp, then
-- PreClick / OnClick / PostClick for a button registered for that click (RegisterForClicks; default "LeftButtonUp")
-- and enabled. A check button toggles before OnClick. Returns whether OnClick ran.
function M.Click(f, button)
	button = button or "LeftButton"
	M.SetMouseButtonDown(button, true)
	runIf(f, "OnMouseDown", button)
	local clicked = click(f, button, true)
	M.SetMouseButtonDown(button, false)
	runIf(f, "OnMouseUp", button, true)
	return click(f, button, false) or clicked
end

-- A drag: the cursor at `from`, the button down (OnMouseDown), the cursor moves to `to` in `steps` frames; after the
-- first move OnDragStart (only for a frame registered for that button with RegisterForDrag, as in the client), and
-- each frame is a mock.Advance(elapsed) (OnUpdate, timers); at the end OnDragStop and OnMouseUp, the button released.
-- opts: { from = { x, y }, to = { x, y }, steps = 1, button = "LeftButton", elapsed = 1 / 60 }.
function M.Drag(f, opts)
	opts = opts or {}
	local button = opts.button or "LeftButton"
	local from = opts.from or { M.input.x, M.input.y }
	local to = opts.to or from
	local steps = math.max(1, opts.steps or 1)
	local dt = opts.elapsed or (1 / 60)
	local drags = false
	for _, b in ipairs(rawget(f, "_drag") or {}) do
		if b == button or b == "AnyButton" then
			drags = true
		end
	end
	M.SetCursor(from[1], from[2])
	M.SetMouseButtonDown(button, true)
	runIf(f, "OnMouseDown", button)
	for i = 1, steps do
		M.SetCursor(from[1] + (to[1] - from[1]) * i / steps, from[2] + (to[2] - from[2]) * i / steps)
		if i == 1 and drags then
			runIf(f, "OnDragStart", button)
		end
		M.Advance(dt)
	end
	if drags then
		runIf(f, "OnDragStop")
	end
	M.SetMouseButtonDown(button, false)
	runIf(f, "OnMouseUp", button, true)
end

-- The pointer enters / leaves a frame: OnEnter(self, true) / OnLeave(self, true); IsMouseOver answers in between.
function M.Hover(f)
	f._hovered = true
	runIf(f, "OnEnter", true)
end

function M.Leave(f)
	f._hovered = nil
	runIf(f, "OnLeave", true)
end

-- The mouse wheel over a frame: OnMouseWheel(self, delta) (1 up, -1 down).
function M.Wheel(f, delta)
	runIf(f, "OnMouseWheel", delta or 1)
end

-- WoW ships Lua BitOp as `bit`; plain Lua 5.1 does not. A small arithmetic version for the libraries that use it.
local function bitop(a, b, fn)
	local r, p = 0, 1
	a, b = a % 2 ^ 32, b % 2 ^ 32
	for _ = 1, 32 do
		local x, y = a % 2, b % 2
		if fn(x, y) then
			r = r + p
		end
		a, b, p = (a - x) / 2, (b - y) / 2, p * 2
	end
	return r
end
local bitlib
bitlib = {
	band = function(a, b, ...)
		local r = bitop(a, b, function(x, y)
			return x == 1 and y == 1
		end)
		if ... then
			return bitlib.band(r, ...)
		end
		return r
	end,
	bor = function(a, b, ...)
		local r = bitop(a, b or 0, function(x, y)
			return x == 1 or y == 1
		end)
		if ... then
			return bitlib.bor(r, ...)
		end
		return r
	end,
	bxor = function(a, b)
		return bitop(a, b, function(x, y)
			return x ~= y
		end)
	end,
	bnot = function(a)
		return (2 ^ 32 - 1) - (a % 2 ^ 32)
	end,
	lshift = function(a, n)
		return (a * 2 ^ n) % 2 ^ 32
	end,
	rshift = function(a, n)
		return math.floor((a % 2 ^ 32) / 2 ^ n)
	end,
}
M.bit = bitlib

-- Menus, as Blizzard_Menu (11.0 and later) builds them: MenuUtil.CreateContextMenu(owner, generator, ...) calls
-- generator(owner, rootDescription, ...); descriptions have the client's element API (CreateButton, CreateCheckbox,
-- CreateRadio, CreateTitle, CreateDivider, CreateSpacer, CreateTemplate, CreateColorSwatch; SetEnabled with a boolean
-- or a predicate that gets the description, SetCanSelect, SetResponse, SetTooltip, Queue*...) and Pick works as the
-- client's: nothing for a disabled or unselectable element; the responder gets (data, menuInputData, menu); its
-- response (else the element's default: Refresh for checkboxes) decides whether the menu closes (nil and CloseAll
-- close it, Close closes the level it is on). The returned menu (also mock.lastMenu) has test helpers: Find, Click,
-- Lines, IsOpen. Nothing is drawn.
local MENU_RESPONSE = { Open = 1, Refresh = 2, Close = 3, CloseAll = 4 }
local MENU_INPUT = { None = 1, MouseButton = 2, MouseWheel = 3 }
M.MenuResponse, M.MenuInputContext = MENU_RESPONSE, MENU_INPUT

local Desc = {}
local descMT = {
	__index = function(_, k)
		local fn = Desc[k]
		if fn then
			return fn
		end
		if type(k) == "string" and k:match("^%u") then
			return noop
		end
		return nil
	end,
}

local function newDesc(kind, text, data)
	local d = setmetatable({ kind = kind, text = text, data = data, elements = {} }, descMT)
	d.items = d.elements -- the name earlier versions of the mock used
	return d
end

function Desc:Insert(d, index)
	for _, q in ipairs(self._queued or {}) do
		q._parentDesc = self
		self.elements[#self.elements + 1] = q
	end
	self._queued = nil
	d._parentDesc = self
	if index then
		table.insert(self.elements, index, d)
	else
		self.elements[#self.elements + 1] = d
	end
	return d
end

local function button(text, callback, data)
	local d = newDesc("button", text, data)
	d.responder, d.fn = callback, callback
	return d
end

local function selection(kind, text, isSelected, setSelected, data)
	local d = newDesc(kind, text, data)
	d.isSelected, d.responder, d.setSelected = isSelected, setSelected, setSelected
	if kind == "checkbox" then
		d.defaultResponse = MENU_RESPONSE.Refresh
	end
	return d
end

-- Standalone creators (MenuUtil.CreateButton...), and the same as methods that insert into a description.
local CREATE = {
	CreateButton = button,
	CreateHighlightButton = function(text, data, onEnter)
		local d = button(text, nil, data)
		d.onEnter = onEnter
		return d
	end,
	CreateCheckbox = function(text, isSelected, setSelected, data)
		return selection("checkbox", text, isSelected, setSelected, data)
	end,
	CreateRadio = function(text, isSelected, setSelected, data)
		return selection("radio", text, isSelected, setSelected, data)
	end,
	CreateHighlightRadio = function(text, isSelected, setSelected, data, onEnter)
		local d = selection("radio", text, isSelected, setSelected, data)
		d.onEnter = onEnter
		return d
	end,
	CreateTitle = function(text, color)
		local d = newDesc("title", text)
		d.color = color
		return d
	end,
	CreateDivider = function()
		return newDesc("divider")
	end,
	CreateSpacer = function(extent)
		local d = newDesc("spacer")
		d.extent = extent
		return d
	end,
	CreateFrame = function()
		return newDesc("frame")
	end,
	CreateTemplate = function(template)
		local d = newDesc("template")
		d.template = template
		return d
	end,
	CreateColorSwatch = function(text, callback, colorInfo)
		local d = button(text, callback, colorInfo)
		d.kind = "colorswatch"
		return d
	end,
}
for name, create in pairs(CREATE) do
	Desc[name] = function(self, ...)
		return self:Insert(create(...))
	end
end

function Desc:QueueTitle(text, color)
	self._queued = self._queued or {}
	self._queued[#self._queued + 1] = CREATE.CreateTitle(text, color)
end
function Desc:QueueDivider()
	self._queued = self._queued or {}
	self._queued[#self._queued + 1] = CREATE.CreateDivider()
end
function Desc:QueueSpacer(extent)
	self._queued = self._queued or {}
	self._queued[#self._queued + 1] = CREATE.CreateSpacer(extent)
end
function Desc:ClearQueuedDescriptions()
	self._queued = nil
end

function Desc:SetEnabled(isEnabled)
	self.isEnabled = isEnabled
end
function Desc:IsEnabled()
	if self.isEnabled == nil then
		return true
	elseif type(self.isEnabled) == "boolean" then
		return self.isEnabled
	end
	return self.isEnabled(self)
end
function Desc:ShouldPollEnabled()
	return type(self.isEnabled) == "function"
end
function Desc:SetCanSelect(canSelect)
	self.canSelect = canSelect
end
function Desc:CanSelect()
	if not self:IsEnabled() then
		return false
	elseif self.canSelect == nil then
		return true
	elseif type(self.canSelect) == "boolean" then
		return self.canSelect
	end
	return self.canSelect(self.data)
end
function Desc:SetIsSelected(isSelected)
	self.isSelected = isSelected
end
function Desc:IsSelected()
	if self.isSelected == nil then
		return false
	end
	return self.isSelected(self.data)
end
function Desc:SetRadio(v)
	self.kind = v and "radio" or self.kind
end
function Desc:IsRadio()
	return self.kind == "radio"
end
function Desc:SetCheckbox(v)
	self.kind = v and "checkbox" or self.kind
end
function Desc:IsCheckbox()
	return self.kind == "checkbox"
end
function Desc:SetData(data)
	self.data = data
end
function Desc:GetData()
	return self.data
end
function Desc:SetResponder(callback)
	self.responder, self.fn = callback, callback
end
function Desc:HasResponder()
	return self.responder ~= nil
end
function Desc:HookResponder(callback)
	local old = self.responder
	if not old then
		self:SetResponder(callback)
		return
	end
	self:SetResponder(function(...)
		local r = old(...)
		callback(...)
		return r
	end)
end
function Desc:SetResponse(response)
	self.defaultResponse = response
end
function Desc:GetDefaultResponse(context, buttonName)
	if type(self.defaultResponse) == "function" then
		return self.defaultResponse(context, buttonName)
	end
	return self.defaultResponse
end
function Desc:SetOnEnter(fn)
	self.onEnter = fn
end
function Desc:GetOnEnter()
	return self.onEnter
end
function Desc:SetOnLeave(fn)
	self.onLeave = fn
end
function Desc:GetOnLeave()
	return self.onLeave
end
function Desc:SetTooltip(initializer)
	self.tooltip = initializer or true
end
function Desc:SetTitleAndTextTooltip(title, text)
	self.tooltip = { title, text }
end
function Desc:HasElements()
	return #self.elements > 0
end
function Desc:EnumerateElementDescriptions()
	return ipairs(self.elements)
end
function Desc:AddInitializer(fn)
	self.initializers = self.initializers or {}
	self.initializers[#self.initializers + 1] = fn
end

local function menuOf(d)
	local guard = 0
	while d and guard < 100 do
		if d.menu then
			return d.menu
		end
		d = d._parentDesc
		guard = guard + 1
	end
	return nil
end

-- The client's MenuElementDescriptionProxyMixin:Pick.
function Desc:Pick(context, buttonName)
	if not self:CanSelect() then
		return false
	end
	if not self:HasResponder() then
		return false
	end
	local menu = menuOf(self)
	local response = self:GetDefaultResponse(context, buttonName)
	local override = self.responder(self.data, { context = context, buttonName = buttonName }, menu)
	if override then
		response = override
	end
	if menu then
		menu:_respond(self, response)
	end
	return true, response
end

local Menu = {}
local menuMT = { __index = function(_, k)
	local fn = Menu[k]
	if fn then
		return fn
	end
	if type(k) == "string" and k:match("^%u") then
		return noop
	end
	return nil
end }

function Menu:_respond(d, response)
	self.lastResponse = response
	if response == nil or response == MENU_RESPONSE.CloseAll then
		if not d:HasElements() then
			self:Close()
		end
	elseif response == MENU_RESPONSE.Close then
		if d._parentDesc == self.root then
			self:Close()
		end
	elseif response == MENU_RESPONSE.Refresh then
		self.refreshes = self.refreshes + 1
	end
end

function Menu:IsOpen()
	return self.open
end

function Menu:Close()
	if self.open then
		self.open = false
		if self.onClosed then
			self.onClosed()
		end
	end
end

function Menu:SetClosedCallback(fn)
	self.onClosed = fn
end

-- The element at a path of texts ("Sort", "By name": a submenu's entry) or the first, depth first, whose text is the
-- given one (markup is compared as is).
function Menu:Find(...)
	local n = select("#", ...)
	if n > 1 then
		local d = self.root
		for i = 1, n do
			local want = select(i, ...)
			local found
			for _, e in ipairs(d.elements) do
				if e.text == want then
					found = e
					break
				end
			end
			if not found then
				return nil
			end
			d = found
		end
		return d
	end
	local want = ...
	local function walk(d)
		for _, e in ipairs(d.elements) do
			if e.text == want then
				return e
			end
			local hit = walk(e)
			if hit then
				return hit
			end
		end
		return nil
	end
	return walk(self.root)
end

-- Click an element (a description or the texts Find takes): Pick with the mouse button. Errors when there is no such
-- element or the menu was closed; returns Pick's results (false when the element is disabled).
function Menu:Click(...)
	local d = ...
	if type(d) ~= "table" then
		d = self:Find(...)
	end
	if not d then
		error("menu has no element " .. table.concat({ ... }, " > "), 2)
	end
	if not self.open then
		error("the menu is closed", 2)
	end
	return d:Pick(MENU_INPUT.MouseButton, "LeftButton")
end

-- The menu as text lines, one per element, indented by level: "button Delete", "radio [x] Small",
-- "checkbox [ ] Show", "title Options", "divider", with " (disabled)" for disabled ones. For assertions and logs.
function Menu:Lines()
	local out = {}
	local function walk(d, depth)
		for _, e in ipairs(d.elements) do
			local s = string.rep("  ", depth) .. e.kind
			if e.kind == "checkbox" or e.kind == "radio" then
				s = s .. (e:IsSelected() and " [x]" or " [ ]")
			end
			if e.text then
				s = s .. " " .. tostring(e.text)
			end
			if not e:IsEnabled() then
				s = s .. " (disabled)"
			end
			out[#out + 1] = s
			walk(e, depth + 1)
		end
	end
	walk(self.root, 0)
	return out
end

local function openMenu(owner, root)
	local menu = setmetatable({ owner = owner, root = root, open = true, refreshes = 0 }, menuMT)
	menu.items = root.elements -- earlier versions of the mock returned the root with its items
	root.menu = menu
	M.lastMenu = menu
	return menu
end

-- Install the generic client API into _G. Game data stubs (maps, journal, instances, ...) are the addon's to add.
function M.Install()
	_G.bit = bitlib
	_G.CreateFrame = M.CreateFrame
	_G.UIParent = M.CreateFrame("Frame", "UIParent")
	_G.UIParent._level = 0
	_G.WorldFrame = M.CreateFrame("Frame", "WorldFrame")
	_G.Minimap = M.CreateFrame("Frame", "Minimap")
	_G.GameTooltip = M.CreateFrame("GameTooltip", "GameTooltip")
	_G.CreateFont = function(name)
		return M.CreateFrame("Font", name)
	end
	-- The game's common font objects (the client defines many more; add what an addon uses).
	for _, spec in ipairs({
		{ "GameFontNormal", 12, { 1, 0.82, 0, 1 } },
		{ "GameFontHighlight", 12, { 1, 1, 1, 1 } },
		{ "GameFontNormalSmall", 10, { 1, 0.82, 0, 1 } },
		{ "GameFontHighlightSmall", 10, { 1, 1, 1, 1 } },
		{ "GameFontNormalLarge", 16, { 1, 0.82, 0, 1 } },
		{ "GameFontDisable", 12, { 0.5, 0.5, 0.5, 1 } },
		{ "ChatFontNormal", 14, { 1, 1, 1, 1 } },
	}) do
		local f = M.CreateFrame("Font", spec[1])
		f._font, f._fontSize, f._textColor = "Fonts\\FRIZQT__.TTF", spec[2], spec[3]
		f._shadowColor, f._shadowOffset = { 0, 0, 0, 1 }, { 1, -1 }
	end
	_G.ChatFontNormal._font = "Fonts\\ARIALN.TTF"
	_G.UISpecialFrames = {}
	_G.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
	_G.NUM_CHAT_WINDOWS = 10
	_G.DEFAULT_CHAT_FRAME = M.CreateFrame("ScrollingMessageFrame", "ChatFrame1")
	_G.SlashCmdList = {}
	_G.hash_SlashCmdList = {}
	_G.GetTime = function()
		return M.now
	end
	_G.GetLocale = function()
		return M.locale or "enUS"
	end
	_G.GetBuildInfo = function()
		local b = M.buildInfo
		return b[1], b[2], b[3], b[4]
	end
	_G.GetCurrentRegion = function()
		return 3
	end
	_G.GetFramerate = function()
		return 60
	end
	_G.GetCurrentRegionName = function()
		return "EU"
	end
	_G.GetRealmName = function()
		return M.realm
	end
	_G.GetNormalizedRealmName = function()
		return M.realm
	end
	-- Units the tests place (nameplates, party members): M.units[token] = { level, class, name, hostile, combat, dead }.
	-- A field set to M.SECRET is a secret value (issecretvalue says so; comparing it would raise in the client).
	M.units = {}
	_G.UnitName = function(unit)
		if unit == "player" then
			return "Tester"
		end
		local u = M.units and M.units[unit]
		return u and u.name or nil
	end
	-- Secret values (recent clients): an opaque marker the code must never compare or store.
	M.SECRET = setmetatable({}, { __tostring = function()
		return "<secret>"
	end })
	_G.issecretvalue = function(v)
		return v == M.SECRET
	end
	_G.UnitNameUnmodified = _G.UnitName
	_G.UnitClass = function()
		return "Warrior", "WARRIOR", 1
	end
	_G.UnitRace = function()
		return "Human", "Human", 1
	end
	_G.UnitFactionGroup = function()
		return "Alliance", "Alliance"
	end
	_G.UnitExists = function(unit)
		return (M.units and M.units[unit] ~= nil) or false
	end
	_G.UnitInParty = function()
		return false
	end
	_G.UnitInRaid = function()
		return nil
	end
	_G.UnitGUID = function()
		return "Player-1-00000001"
	end
	_G.IsInGroup = function()
		return M.inGroup or false
	end
	_G.IsInRaid = function()
		return false
	end
	_G.IsInGuild = function()
		return false
	end
	_G.GetNumGroupMembers = function()
		return M.inGroup and 2 or 0
	end
	_G.InCombatLockdown = function()
		return M.inCombat or false
	end
	_G.IsLoggedIn = function()
		return M.loggedIn or false
	end
	-- Input (mock.SetCursor, mock.SetKeyDown, mock.SetMouseButtonDown, mock.WithInput). The client's GetCursorPosition
	-- is in screen pixels (addons divide by UIParent:GetEffectiveScale()); the mock returns what was set.
	_G.GetCursorPosition = function()
		return M.input.x, M.input.y
	end
	_G.IsMouseButtonDown = function(button)
		if button == nil then
			return next(M.input.buttons) ~= nil
		end
		return M.input.buttons[BUTTON_ALIAS[button] or button] or false
	end
	_G.IsShiftKeyDown = function()
		return keyDown("LSHIFT", "RSHIFT") or M.shiftDown or false
	end
	_G.IsLeftShiftKeyDown = function()
		return keyDown("LSHIFT")
	end
	_G.IsRightShiftKeyDown = function()
		return keyDown("RSHIFT")
	end
	_G.IsControlKeyDown = function()
		return keyDown("LCTRL", "RCTRL")
	end
	_G.IsLeftControlKeyDown = function()
		return keyDown("LCTRL")
	end
	_G.IsRightControlKeyDown = function()
		return keyDown("RCTRL")
	end
	_G.IsAltKeyDown = function()
		return keyDown("LALT", "RALT")
	end
	_G.IsLeftAltKeyDown = function()
		return keyDown("LALT")
	end
	_G.IsRightAltKeyDown = function()
		return keyDown("RALT")
	end
	_G.IsMetaKeyDown = function()
		return keyDown("LMETA", "RMETA")
	end
	_G.IsModifierKeyDown = function()
		return _G.IsShiftKeyDown() or _G.IsControlKeyDown() or _G.IsAltKeyDown() or _G.IsMetaKeyDown()
	end
	_G.IsKeyDown = function(key)
		key = tostring(key):upper()
		if KEY_ALIAS[key] then
			return keyDown("L" .. key, "R" .. key)
		end
		return keyDown(key)
	end
	_G.GetCursorInfo = function()
		return nil
	end
	_G.ClearCursor = noop
	_G.PlaySound = noop
	_G.Screenshot = function()
		M.screenshots = (M.screenshots or 0) + 1
	end
	_G.GetNumClasses = function()
		return 2
	end
	_G.GetClassInfo = function(i)
		if i == 1 then
			return "Warrior", "WARRIOR", 1
		end
		return "Mage", "MAGE", 8
	end
	_G.SendChatMessage = function(text, channel)
		M.chat[#M.chat + 1] = { text, channel }
	end
	_G.geterrorhandler = function()
		return function(err)
			error(err, 0)
		end
	end
	_G.seterrorhandler = noop
	_G.securecall = function(fn, ...)
		if type(fn) == "string" then
			fn = _G[fn]
		end
		return fn(...)
	end
	_G.securecallfunction = _G.securecall
	_G.hooksecurefunc = function(a, b, c)
		local tbl, name, fn = _G, a, b
		if type(a) == "table" then
			tbl, name, fn = a, b, c
		end
		local old = tbl[name]
		tbl[name] = function(...)
			local r = { old(...) }
			fn(...)
			return unpack(r)
		end
	end
	_G.issecurevariable = function()
		return false
	end
	_G.strsplit = function(sep, s, limit)
		local out, start = {}, 1
		while true do
			if limit and #out == limit - 1 then
				out[#out + 1] = s:sub(start)
				break
			end
			local i = s:find(sep, start, true)
			if not i then
				out[#out + 1] = s:sub(start)
				break
			end
			out[#out + 1] = s:sub(start, i - 1)
			start = i + #sep
		end
		return unpack(out)
	end
	_G.strtrim = function(s)
		return (s:gsub("^%s*(.-)%s*$", "%1"))
	end
	_G.strlower, _G.strupper, _G.strsub, _G.strfind, _G.strlen = string.lower, string.upper, string.sub, string.find,
		string.len
	_G.strmatch, _G.gsub, _G.format, _G.strrep, _G.strbyte, _G.strchar = string.match, string.gsub, string.format,
		string.rep, string.byte, string.char
	_G.tinsert, _G.tremove, _G.tconcat, _G.sort = table.insert, table.remove, table.concat, table.sort
	_G.wipe = function(t)
		for k in pairs(t) do
			t[k] = nil
		end
		return t
	end
	_G.table.wipe = _G.wipe
	_G.floor, _G.ceil, _G.max, _G.min, _G.abs = math.floor, math.ceil, math.max, math.min, math.abs
	_G.Ambiguate = function(name)
		return (name:gsub("%-.*$", ""))
	end
	_G.date = os.date
	_G.time = function()
		return 1794700000
	end
	_G.debugstack = function()
		return ""
	end
	-- C_Timer, driven by mock.Advance: a callback runs on the first frame at or after its time. NewTimer / NewTicker
	-- return a handle (Cancel, IsCancelled) that is also passed to the callback; NewTicker's third argument limits the
	-- number of calls.
	local function newTimer(sec, fn, every, iterations)
		timerSeq = timerSeq + 1
		local t = { at = M.now + (sec or 0), fn = fn, every = every, left = iterations, seq = timerSeq }
		t.handle = {
			Cancel = function()
				t.cancelled = true
			end,
			IsCancelled = function()
				return t.cancelled or false
			end,
		}
		M.timers[#M.timers + 1] = t
		return t
	end
	_G.C_Timer = {
		After = function(sec, fn)
			local t = newTimer(sec, fn)
			t.handle = nil
		end,
		NewTimer = function(sec, fn)
			return newTimer(sec, fn).handle
		end,
		NewTicker = function(sec, fn, iterations)
			return newTimer(sec, fn, sec, iterations).handle
		end,
	}
	_G.C_AddOns = {
		GetAddOnMetadata = function(_, field)
			if field == "Version" then
				return "@project-version@"
			end
			return nil
		end,
		IsAddOnLoaded = function(name)
			return M.loadedAddons and M.loadedAddons[name] or false
		end,
		GetAddOnEnableState = function(name)
			return (M.loadedAddons and M.loadedAddons[name]) and 2 or 0
		end,
		GetNumAddOns = function()
			return 0
		end,
		GetAddOnInfo = function()
			return nil
		end,
		IsAddOnLoadable = function(name)
			return M.loadableAddons[name] == true, ""
		end,
		LoadAddOn = function(name)
			M.loadedAddons = M.loadedAddons or {}
			M.loadedAddons[name] = true
			return true, nil
		end,
	}
	_G.Enum = {
		SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, GeneralError = 9 },
		UITextureSliceMode = { Stretched = 0, Tiled = 1 },
	}
	_G.C_ChatInfo = {
		RegisterAddonMessagePrefix = function()
			return true
		end,
		IsAddonMessagePrefixRegistered = function()
			return true
		end,
		SendAddonMessage = function(prefix, text, channel, target)
			M.sent[#M.sent + 1] = { prefix, text, channel, target }
			return 0
		end,
		SendAddonMessageLogged = function(prefix, text, channel, target)
			M.sent[#M.sent + 1] = { prefix, text, channel, target }
			return 0
		end,
		InChatMessagingLockdown = function()
			return M.lockdown or false
		end,
	}
	-- Game files the mock client "has" (GetFileIDFromPath, case-insensitive); tests add paths. M.fileResolver, when
	-- set, answers for paths not listed (a dump can make every file "exist" and let the renderer find it).
	_G.GetFileIDFromPath = function(path)
		if type(path) ~= "string" then
			return nil
		end
		if M.fileQueries then
			M.fileQueries[path] = true
		end
		local id = M.files[path:lower()]
		if id == nil and M.fileResolver then
			id = M.fileResolver(path)
		end
		return id or nil
	end
	_G.C_Texture = {
		GetAtlasInfo = function(name)
			local a = M.atlases[name]
			if a then
				local w, h = 16, 16
				if type(a) == "table" then
					w, h = a.width or a[1] or w, a.height or a[2] or h
				end
				return { file = 1, width = w, height = h, leftTexCoord = 0, rightTexCoord = 1, topTexCoord = 0,
					bottomTexCoord = 1 }
			end
			return nil
		end,
	}
	local function unitField(unit, field, default)
		local u = M.units[unit]
		if u == nil then
			return default
		end
		return u[field]
	end
	_G.UnitLevel = function(unit)
		return unitField(unit, "level", 15)
	end
	_G.UnitClassification = function(unit)
		return unitField(unit, "class", "normal")
	end
	_G.UnitCanAttack = function(_, unit)
		return unitField(unit, "hostile", false)
	end
	_G.UnitAffectingCombat = function(unit)
		return unitField(unit, "combat", false)
	end
	_G.UnitIsDead = function(unit)
		return unitField(unit, "dead", false)
	end
	_G.UnitIsDeadOrGhost = function(unit)
		return unitField(unit, "dead", false)
	end
	_G.GetSubZoneText = function()
		return M.subzone or ""
	end
	_G.GetMinimapZoneText = function()
		return M.subzone or ""
	end
	-- Nameplates: M.plates = { unit token, ... } (C_NamePlate.GetNamePlates returns plate frames).
	M.plates = {}
	_G.C_NamePlate = {
		GetNamePlates = function()
			local out = {}
			for i, unit in ipairs(M.plates) do
				out[i] = { namePlateUnitToken = unit, GetCenter = function()
					return 100 + i, 200
				end }
			end
			return out
		end,
	}
	_G.Settings = {
		RegisterCanvasLayoutCategory = function(_, name)
			return { ID = name, GetID = function()
				return name
			end }
		end,
		RegisterCanvasLayoutSubcategory = function(_, _, name)
			return { ID = name }
		end,
		RegisterAddOnCategory = noop,
		GetCategory = function(id)
			return { ID = id }
		end,
		OpenToCategory = noop,
	}
	-- Nine-slice layouts and the window template's helpers: recorded (`_nineSlice`, `_noPortrait`) so a dump can name
	-- them and the renderer can draw the game's frame pieces. M.nineSliceLayouts lists the layouts GetLayout knows.
	M.nineSliceLayouts = M.nineSliceLayouts or { PortraitFrameTemplate = {}, ButtonFrameTemplateNoPortrait = {},
		InsetFrameTemplate = {}, Dialog = {} }
	_G.NineSliceUtil = {
		GetLayout = function(name)
			return M.nineSliceLayouts[name]
		end,
		ApplyLayoutByName = function(frame, name)
			frame._nineSlice = name
		end,
	}
	_G.ButtonFrameTemplate_HidePortrait = function(f)
		f._noPortrait = true
	end
	_G.MenuResponse, _G.MenuInputContext = MENU_RESPONSE, MENU_INPUT
	local MenuUtil = setmetatable({}, { __index = function(_, k)
		if type(k) == "string" and k:match("^%u") then
			return noop
		end
		return nil
	end })
	for name, create in pairs(CREATE) do
		MenuUtil[name] = create
	end
	MenuUtil.CreateRootMenuDescription = function()
		return newDesc("root")
	end
	MenuUtil.CreateContextMenu = function(owner, generator, ...)
		local root = newDesc("root")
		local menu = openMenu(owner, root)
		generator(owner, root, ...)
		return menu
	end
	-- CreateButtonContextMenu(owner, { text, callback, data }, ...); the checkbox and radio forms take isSelected and
	-- setSelected first, then { text, data } entries.
	MenuUtil.CreateButtonContextMenu = function(owner, ...)
		local entries = { ... }
		return MenuUtil.CreateContextMenu(owner, function(_, root)
			for _, e in ipairs(entries) do
				root:CreateButton(e[1], e[2], e[3])
			end
		end)
	end
	for _, kind in ipairs({ "Checkbox", "Radio" }) do
		MenuUtil["Create" .. kind .. "ContextMenu"] = function(owner, isSelected, setSelected, ...)
			local entries = { ... }
			return MenuUtil.CreateContextMenu(owner, function(_, root)
				for _, e in ipairs(entries) do
					root["Create" .. kind](root, e[1], isSelected, setSelected, e[2])
				end
			end)
		end
	end
	MenuUtil.SetElementText = function(d, text)
		d.text = text
	end
	MenuUtil.GetElementText = function(d)
		return d.text
	end
	local function traverse(d, op, condition)
		if condition == nil or condition(d) then
			if op(d) then
				return true
			end
		end
		for _, e in ipairs(d.elements or {}) do
			if traverse(e, op, condition) then
				return true
			end
		end
		return false
	end
	MenuUtil.TraverseMenu = traverse
	MenuUtil.GetSelections = function(d, condition)
		local out = {}
		traverse(d, function(e)
			if e:IsSelected() then
				out[#out + 1] = e
			end
		end, condition)
		return out
	end
	_G.MenuUtil = MenuUtil
	_G.C_UIFileAsset = {
		IsKnownFile = function()
			return true
		end,
	}
	-- Items the tests describe: M.items[itemID] = { name, itemType, itemSubType, itemEquipLoc, icon, classID,
	-- subClassID } (fields by those names). GetItemInfoInstant (global and C_Item) takes an item ID, an item link or
	-- string ("item:123:..."), or the name of an item listed there, and returns the client's seven values (itemID,
	-- itemType, itemSubType, itemEquipLoc, icon, classID, subClassID), or nothing for an item not listed.
	M.items = {}
	local function itemID(item)
		if type(item) == "number" then
			return item
		elseif type(item) ~= "string" then
			return nil
		end
		local id = tonumber(item) or tonumber(item:match("item:(%d+)"))
		if id then
			return id
		end
		local found
		for k, info in pairs(M.items) do
			if info.name == item and (not found or k < found) then
				found = k
			end
		end
		return found
	end
	local function getItemInfoInstant(item)
		local id = itemID(item)
		local info = id and M.items[id]
		if not info then
			return nil
		end
		return id, info.itemType, info.itemSubType, info.itemEquipLoc or "", info.icon, info.classID, info.subClassID
	end
	_G.GetItemInfoInstant = getItemInfoInstant
	_G.C_Item = {
		GetItemInfoInstant = getItemInfoInstant,
		GetItemNameByID = function(id)
			local info = M.items[itemID(id) or id]
			return info and info.name or ("Item " .. id)
		end,
		GetItemIconByID = function(id)
			local info = M.items[itemID(id) or id]
			return info and info.icon or 134400
		end,
	}
	_G.print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[#parts + 1] = tostring((select(i, ...)))
		end
		M.printed[#M.printed + 1] = table.concat(parts, " ")
	end
end

-- Load a .toc's files in order (following embeds.xml / lib.xml <Script>/<Include>), like the client does.
-- `root` is the addon folder; every file chunk gets (addonName, ns) as the client passes them.
function M.LoadAddon(root, tocName, addonName, ns)
	local function loadLua(path)
		local chunk, err = loadfile(root .. "/" .. path)
		if not chunk then
			error("load " .. path .. ": " .. tostring(err))
		end
		chunk(addonName, ns)
	end
	local loadXml
	function loadXml(path)
		local f = assert(io.open(root .. "/" .. path, "rb"))
		local xml = f:read("*a")
		f:close()
		xml = xml:gsub("<!%-%-.-%-%->", "")
		local dir = path:match("^(.*)[/\\][^/\\]+$") or ""
		for tag, file in xml:gmatch("<(%a+)%s+file=\"([^\"]+)\"") do
			local full = (dir ~= "" and (dir .. "/") or "") .. file:gsub("\\", "/")
			if tag == "Script" then
				loadLua(full)
			elseif tag == "Include" then
				loadXml(full)
			end
		end
	end
	for line in io.lines(root .. "/" .. tocName) do
		line = line:gsub("\r", "")
		if line ~= "" and not line:match("^#") then
			local file = line:gsub("\\", "/")
			if file:match("%.xml$") then
				loadXml(file)
			else
				loadLua(file)
			end
		end
	end
end

return M
