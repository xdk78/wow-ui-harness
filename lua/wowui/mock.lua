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
		self._w = w
		touch()
	end,
	SetHeight = function(self, h)
		self._h = h
		touch()
	end,
	SetSize = function(self, w, h)
		self._w, self._h = w, h
		touch()
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
	Show = function(self)
		self._shown = true
		touch()
		local fn = self._scripts and self._scripts.OnShow
		if fn then
			fn(self)
		end
	end,
	Hide = function(self)
		local was = self._shown
		self._shown = false
		touch()
		local fn = self._scripts and self._scripts.OnHide
		if fn and was then
			fn(self)
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
	SetScript = function(self, name, fn)
		self._scripts = self._scripts or {}
		self._scripts[name] = fn
	end,
	GetScript = function(self, name)
		return self._scripts and self._scripts[name]
	end,
	HookScript = function(self, name, fn)
		self._scripts = self._scripts or {}
		local old = self._scripts[name]
		self._scripts[name] = function(...)
			if old then
				old(...)
			end
			return fn(...)
		end
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
	SetParent = function(self, p)
		self._parent = lookup(p)
		touch()
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
	IsMouseOver = function()
		return false
	end,
	EnableMouse = function(self, v)
		self._mouse = v and true or false
	end,
	SetMouseClickEnabled = function(self, v)
		self._mouseClick = v and true or false
	end,
	SetMouseMotionEnabled = function(self, v)
		self._mouseMotion = v and true or false
	end,
	IsMouseEnabled = function()
		return true
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
		if f._events and f._events[event] and f._scripts and f._scripts.OnEvent then
			f._scripts.OnEvent(f, event, ...)
		end
	end
end

-- Run due timers (C_Timer) and OnUpdate scripts once.
function M.Advance(seconds)
	M.now = M.now + seconds
	-- One frame of OnUpdate for every shown frame (ChatThrottleLib sends its queue from OnUpdate).
	for _, f in ipairs(frames) do
		local fn = f._scripts and f._scripts.OnUpdate
		if fn and f._shown ~= false then
			fn(f, seconds)
		end
	end
	local due = M.timers
	M.timers = {}
	for _, t in ipairs(due) do
		if t.at <= M.now then
			if not t.cancelled then
				t.fn(t.handle)
				if t.every and not t.cancelled then
					t.at = M.now + t.every
					M.timers[#M.timers + 1] = t
				end
			end
		else
			M.timers[#M.timers + 1] = t
		end
	end
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
	_G.GetCursorPosition = function()
		return 0, 0
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
	_G.C_Timer = {
		After = function(sec, fn)
			M.timers[#M.timers + 1] = { at = M.now + sec, fn = fn }
		end,
		NewTimer = function(sec, fn)
			local t = { at = M.now + sec }
			local handle = {
				Cancel = function()
					t.cancelled = true
				end,
				IsCancelled = function()
					return t.cancelled
				end,
			}
			t.handle, t.fn = handle, fn
			M.timers[#M.timers + 1] = t
			return handle
		end,
		NewTicker = function(sec, fn)
			local t = { at = M.now + sec, every = sec }
			local handle = {
				Cancel = function()
					t.cancelled = true
				end,
				IsCancelled = function()
					return t.cancelled
				end,
			}
			t.handle, t.fn = handle, fn
			M.timers[#M.timers + 1] = t
			return handle
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
	_G.IsShiftKeyDown = function()
		return M.shiftDown or false
	end
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
	_G.MenuUtil = {
		CreateContextMenu = function(region, generator)
			local root
			root = {
				items = {},
				CreateButton = function(self, text, fn)
					local item = { text = text, fn = fn, items = {} }
					setmetatable(item, { __index = root })
					table.insert(self.items, item)
					return item
				end,
				CreateRadio = function(self, text, isSelected, setSelected, data)
					table.insert(self.items, { text = text, isSelected = isSelected, setSelected = setSelected, data = data })
				end,
				CreateDivider = noop,
				CreateTitle = noop,
			}
			generator(region, root)
			M.lastMenu = root
			return root
		end,
	}
	_G.C_UIFileAsset = {
		IsKnownFile = function()
			return true
		end,
	}
	_G.C_Item = {
		GetItemNameByID = function(id)
			return "Item " .. id
		end,
		GetItemIconByID = function()
			return 134400
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
