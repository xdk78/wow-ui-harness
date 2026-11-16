-- A small window with two deliberate mistakes for the lint to find: a label too long for its width, and two buttons
-- that overlap. The harness's tests build it, dump it and lint it.
local _, ns = ...

function ns.Build()
	local f = CreateFrame("Frame", "HarnessExampleFrame", UIParent, "BackdropTemplate")
	f:SetSize(300, 200)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	f:SetBackdropColor(0.1, 0.1, 0.12, 1)
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.title:SetPoint("TOPLEFT", 10, -10)
	f.title:SetText("Harness Example")
	-- Too narrow: "..." at the end.
	f.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.label:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -8)
	f.label:SetWidth(80)
	f.label:SetWordWrap(false)
	f.label:SetText("A label that is far too long for eighty units")
	-- Wraps onto three lines inside its width.
	f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.body:SetPoint("TOPLEFT", f.label, "BOTTOMLEFT", 0, -8)
	f.body:SetPoint("RIGHT", -10, 0)
	f.body:SetJustifyH("LEFT")
	f.body:SetText("This text wraps at the window's right edge, the way a font string with two side anchors does.")
	-- Two buttons on top of each other.
	f.ok = CreateFrame("Button", nil, f)
	f.ok:SetSize(80, 24)
	f.ok:SetPoint("BOTTOMLEFT", 10, 10)
	f.ok:SetNormalFontObject("GameFontNormal")
	f.ok:SetText("OK")
	f.cancel = CreateFrame("Button", nil, f)
	f.cancel:SetSize(80, 24)
	f.cancel:SetPoint("LEFT", f.ok, "RIGHT", -20, 0)
	f.cancel:SetNormalFontObject("GameFontNormal")
	f.cancel:SetText("Cancel")
	-- A colour swatch scaled down.
	f.swatch = CreateFrame("Frame", nil, f)
	f.swatch:SetScale(0.5)
	f.swatch:SetSize(40, 40)
	f.swatch:SetPoint("TOPRIGHT", -10, -10)
	f.swatch.tex = f.swatch:CreateTexture(nil, "ARTWORK")
	f.swatch.tex:SetAllPoints()
	f.swatch.tex:SetColorTexture(0.8, 0.2, 0.2, 1)
	ns.frame = f
	return f
end
