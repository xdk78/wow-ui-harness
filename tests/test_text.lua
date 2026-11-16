local T = ...

local Text = require("wowui.text")

T.case("text: markup is parsed into colour runs, pictures and line breaks", function()
	local toks = Text.Parse("a |cffff0000red|r b||c|n|TInterface\\Icons\\X:16|t")
	T.eq(toks[1].s, "a ")
	T.eq(toks[2].s, "red")
	T.near(toks[2].color[1], 1)
	T.eq(toks[3].s, " b|c")
	T.eq(toks[4].t, "br")
	T.eq(toks[5].t, "icon")
	T.eq(toks[5].h, 16)
	T.eq(Text.Plain("|cff00ff00ok|r |Hitem:1|h[Item]|h"), "ok [Item]")
end)

T.case("text: wraps at spaces inside a width, cuts with ... without wrap", function()
	-- Without a font every character is 0.55 * size wide: 6.6 units at 12.
	local lay = Text.Layout("aaaa bbbb cccc", { size = 12, width = 70 })
	T.eq(#lay.lines, 2, "two lines")
	T.eq(lay.lines[1].parts[1].s, "aaaa bbbb")
	T.ok(not lay.truncated)
	local cut = Text.Layout("aaaa bbbb cccc", { size = 12, width = 70, wrap = false })
	T.eq(#cut.lines, 1)
	T.ok(cut.truncated, "truncated")
	local last = cut.lines[1].parts[#cut.lines[1].parts]
	T.eq(last.s:sub(-3), "...")
	local limited = Text.Layout("aaaa bbbb cccc dddd eeee", { size = 12, width = 70, maxLines = 2 })
	T.eq(#limited.lines, 2)
	T.ok(limited.truncated)
	local tall = Text.Layout("aaaa bbbb cccc dddd eeee", { size = 12, width = 70, maxHeight = 12 })
	T.eq(#tall.lines, 1, "the height allows one line")
end)

T.case("text: a font string sizes itself and reports truncation", function()
	T.fresh({ width = 1000, height = 800 })
	local f = CreateFrame("Frame", nil, UIParent)
	f:SetSize(100, 100)
	f:SetPoint("CENTER")
	local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("TOPLEFT")
	fs:SetText("Hello")
	T.near(fs:GetStringWidth(), 5 * 12 * 0.55)
	T.eq(fs:GetHeight(), 12)
	fs:SetWidth(20)
	fs:SetWordWrap(false)
	T.ok(fs:IsTruncated())
end)

-- A minimal TrueType file built here: glyph 0 (.notdef, 500 wide), glyph 1 = "A" (600), glyph 2 = U+0105 (550).
local function u16(v)
	return string.char(math.floor(v / 256) % 256, v % 256)
end
local function u32(v)
	return u16(math.floor(v / 65536) % 65536) .. u16(v % 65536)
end
local function tinyFont()
	local head = string.rep("\0", 18) .. u16(1000) .. string.rep("\0", 54 - 20)
	local hhea = string.rep("\0", 4) .. u16(800) .. u16(65536 - 200) .. string.rep("\0", 34 - 8) .. u16(3)
	local maxp = u32(0x00005000) .. u16(3)
	local hmtx = u16(500) .. u16(0) .. u16(600) .. u16(0) .. u16(550) .. u16(0)
	-- cmap format 4: segments [0x41, 0x41] -> 1, [0x105, 0x105] -> 2, [0xFFFF].
	local seg = { { 0x41, 0x41, 1 - 0x41 }, { 0x105, 0x105, 2 - 0x105 }, { 0xFFFF, 0xFFFF, 1 } }
	local ends, starts, deltas, offs = "", "", "", ""
	for _, s in ipairs(seg) do
		ends, starts = ends .. u16(s[2]), starts .. u16(s[1])
		deltas, offs = deltas .. u16((s[3] + 65536) % 65536), offs .. u16(0)
	end
	local sub = u16(4) .. u16(16 + 8 * #seg) .. u16(0) .. u16(2 * #seg) .. u16(0) .. u16(0) .. u16(0) .. ends .. u16(0)
		.. starts .. deltas .. offs
	local cmap = u16(0) .. u16(1) .. u16(3) .. u16(1) .. u32(12) .. sub
	local tables = { { "cmap", cmap }, { "head", head }, { "hhea", hhea }, { "hmtx", hmtx }, { "maxp", maxp } }
	local out = u32(0x00010000) .. u16(#tables) .. u16(0) .. u16(0) .. u16(0)
	local offset = 12 + 16 * #tables
	local body = ""
	for _, t in ipairs(tables) do
		out = out .. t[1] .. u32(0) .. u32(offset + #body) .. u32(#t[2])
		body = body .. t[2] .. string.rep("\0", (4 - #t[2] % 4) % 4)
	end
	return out .. body
end

T.case("ttf: reads units per em, advances and the character map", function()
	local TTF = require("wowui.ttf")
	local font = assert(TTF.Parse(tinyFont()))
	T.eq(font.upem, 1000)
	T.eq(font.ascender, 800)
	T.ok(font:Has(0x41), "A")
	T.ok(font:Has(0x105), "a with ogonek")
	T.ok(not font:Has(0x42), "no B")
	T.eq(font:Advance(0x41), 600)
	T.eq(font:Advance(0x42), 500, ".notdef for a missing glyph")
	T.near(Text.Measurer(font, 10)("AA"), 12)
end)
