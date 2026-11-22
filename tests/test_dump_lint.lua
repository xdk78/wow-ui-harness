local T = ...

local function buildExample()
	local mock = T.fresh({ width = 1000, height = 800 })
	local ns = {}
	mock.LoadAddon("examples/HarnessExample", "HarnessExample.toc", "HarnessExample", ns)
	return mock, ns.Build()
end

T.case("dump: entries in draw order with rects, text lines, backdrops", function()
	local mock, frame = buildExample()
	local dump = require("wowui.dump")
	local doc = dump.Capture(mock, { view = "example", window = frame })
	T.eq(doc.schema, "wowui-dump/1")
	T.eq(doc.window.path, "HarnessExampleFrame")
	local byPath = {}
	for _, e in ipairs(doc.regions) do
		byPath[e.path] = e
	end
	local win = byPath.HarnessExampleFrame
	T.ok(win.backdrop, "backdrop recorded")
	T.eq(win.rect[1], 350)
	T.eq(win.rect[2], 300, "top-left origin")
	local label = byPath["HarnessExampleFrame.label"]
	T.ok(label.text.truncated, "the narrow label is truncated")
	local body = byPath["HarnessExampleFrame.body"]
	T.ok(#body.text.lines >= 2, "the body wraps")
	local swatch = byPath["HarnessExampleFrame.swatch.tex"]
	T.eq(swatch.rect[3], 20, "scale 0.5: 40 units are 20 on screen")
	T.ok(win.id < label.id, "the window draws before its text")
	local badge = byPath["HarnessExampleFrame.badge"]
	T.near(badge.texture.rotation, math.pi / 6, "rotation", 0.001)
	T.eq(badge.texture.rotationPoint, nil, "the default rotation point is not recorded")
	T.eq(byPath["HarnessExampleFrame.stroke"].line.thickness, 3)
	-- JSON round trip.
	local JSON = require("wowui.json")
	local back = JSON.Decode(JSON.Encode(doc))
	T.eq(back.view, "example")
	T.eq(#back.regions, #doc.regions)
end)

T.case("dump: rotation point, wrap modes and the client's default line thickness", function()
	local mock, frame = buildExample()
	local tex = frame:CreateTexture(nil, "ARTWORK")
	tex:SetTexture("Interface\\Buttons\\WHITE8X8", "REPEAT", "MIRROR")
	tex:SetAllPoints()
	tex:SetRotation(1, { x = 0, y = 0.25 })
	local plain = frame:CreateTexture(nil, "ARTWORK")
	plain:SetTexture("Interface\\Buttons\\WHITE8X8", true)
	plain:SetAllPoints()
	local line = frame:CreateLine(nil, "ARTWORK")
	line:SetColorTexture(1, 1, 1, 1)
	line:SetStartPoint("TOPLEFT", frame)
	line:SetEndPoint("BOTTOMRIGHT", frame)
	T.eq(line:GetThickness(), 4, "GetThickness answers the client's default with layout on")
	local doc = require("wowui.dump").Capture(mock, { view = "example", window = frame })
	local t, p, l
	for _, e in ipairs(doc.regions) do
		if e.texture and e.texture.rotationPoint then
			t = e.texture
		elseif e.texture and e.texture.wrap then
			p = e.texture
		elseif e.line and e.line.thickness == 4 then
			l = e.line
		end
	end
	T.ok(t, "the turned texture")
	T.eq(t.rotationPoint[1], 0)
	T.eq(t.rotationPoint[2], 0.25)
	T.eq(t.wrap[1], "REPEAT")
	T.eq(t.wrap[2], "MIRROR")
	T.eq(p.wrap[1], "REPEAT", "true is REPEAT")
	T.eq(p.wrap[2], "CLAMP", "an omitted mode is CLAMP")
	T.ok(l, "a line without SetThickness is 4 thick")
end)

T.case("lint: truncation and overlapping buttons are found, with stable keys", function()
	local mock, frame = buildExample()
	local doc = require("wowui.dump").Capture(mock, { view = "example", window = frame })
	local findings = require("wowui.lint").Run(doc)
	local rules = {}
	for _, f in ipairs(findings) do
		rules[f.rule] = (rules[f.rule] or 0) + 1
	end
	T.eq(rules["text-truncated"], 1)
	T.eq(rules.overlap, 1, "OK and Cancel overlap")
	T.eq(rules["text-overlap"], nil)
	local Lint = require("wowui.lint")
	local fresh, gone = Lint.Compare(findings, { "example | " .. findings[1].key, "example | gone | x" })
	T.eq(#fresh, #findings - 1)
	T.eq(gone[1], "example | gone | x")
end)

T.case("lint: outside-window and missing glyphs need their inputs only", function()
	local mock, frame = buildExample()
	local stray = frame:CreateTexture(nil, "ARTWORK")
	stray:SetColorTexture(1, 1, 1, 1)
	stray:SetSize(20, 20)
	stray:SetPoint("LEFT", frame, "RIGHT", 5, 0)
	local doc = require("wowui.dump").Capture(mock, { view = "example", window = frame })
	local found = false
	for _, f in ipairs(require("wowui.lint").Run(doc)) do
		found = found or f.rule == "outside-window"
	end
	T.ok(found, "a texture past the window's edge")
end)

T.case("lint: a container that draws nothing is not a piece outside the window; what it holds is", function()
	local mock, frame = buildExample()
	local holder = CreateFrame("Frame", nil, frame)
	holder:SetSize(300, 40)
	holder:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, 10) -- reaches 30 px past the bottom edge
	local inside = holder:CreateTexture(nil, "ARTWORK")
	inside:SetColorTexture(1, 1, 1, 1)
	inside:SetSize(20, 8)
	inside:SetPoint("TOPLEFT") -- within the window
	local doc = require("wowui.dump").Capture(mock, { view = "example", window = frame })
	local function outside()
		local n = 0
		for _, f in ipairs(require("wowui.lint").Run(doc)) do
			n = n + (f.rule == "outside-window" and 1 or 0)
		end
		return n
	end
	T.eq(outside(), 0, "an empty holder hanging past the edge draws nothing there")
	local below = holder:CreateTexture(nil, "ARTWORK")
	below:SetColorTexture(1, 1, 1, 1)
	below:SetSize(20, 8)
	below:SetPoint("BOTTOMLEFT")
	doc = require("wowui.dump").Capture(mock, { view = "example", window = frame })
	T.eq(outside(), 1, "its texture below the edge is")
end)

T.case("lint: anchor points that pin one centre in two places are reported", function()
	local mock, frame = buildExample()
	local head = frame:CreateFontString(nil, "OVERLAY")
	head:SetFontObject(rawget(_G, "GameFontNormal"))
	head:SetText("Heading")
	head:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -10)
	local band = frame:CreateTexture(nil, "ARTWORK")
	band:SetColorTexture(1, 1, 1, 1)
	band:SetHeight(20)
	band:SetPoint("LEFT", head, "LEFT") -- the heading's height...
	band:SetPoint("RIGHT", frame, "RIGHT") -- ...and the frame's middle: two vertical centres
	local tops = frame:CreateTexture(nil, "ARTWORK")
	tops:SetColorTexture(1, 1, 1, 1)
	tops:SetHeight(20)
	tops:SetPoint("TOPLEFT", head, "BOTTOMLEFT")
	tops:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -40)
	local doc = require("wowui.dump").Capture(mock, { view = "example", window = frame })
	local found = {}
	for _, f in ipairs(require("wowui.lint").Run(doc)) do
		if f.rule == "anchor-conflict" then
			found[#found + 1] = f.path
		end
	end
	T.eq(#found, 2, "the band, and the second texture whose two tops differ")
end)
