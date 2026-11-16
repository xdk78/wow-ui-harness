-- wowui.ttf: just enough of a TrueType / OpenType reader for text layout in plain Lua 5.1: units per em, ascender
-- and descender, advance widths (hmtx) and the character map (cmap formats 4 and 12). No kerning, no shaping.
--
--   local font = TTF.Load("FRIZQT__.TTF")      -- nil, err when the file is missing or unreadable
--   font:Has(0x0105)                            -- the face has a glyph for U+0105
--   font:Advance(0x41)                          -- advance of "A" in font units (font.upem per em)

local TTF = {}


local function u16(s, p)
	local a, b = s:byte(p + 1, p + 2)
	return a * 256 + b
end

local function s16(s, p)
	local v = u16(s, p)
	return v >= 32768 and v - 65536 or v
end

local function u32(s, p)
	local a, b, c, d = s:byte(p + 1, p + 4)
	return ((a * 256 + b) * 256 + c) * 256 + d
end

local Font = {}
Font.__index = Font

function Font:Glyph(cp)
	return self.cmap[cp]
end

function Font:Has(cp)
	return self.cmap[cp] ~= nil and self.cmap[cp] ~= 0
end

-- Advance width in font units of a code point (the .notdef glyph's for a missing one).
function Font:Advance(cp)
	local g = self.cmap[cp] or 0
	local adv = self.advances
	return adv[g + 1] or adv[#adv] or self.upem / 2
end

local function parseCmap4(s, p, map)
	local segX2 = u16(s, p + 6)
	local n = segX2 / 2
	local ends, starts, deltas, offsets = p + 14, p + 16 + segX2, p + 16 + 2 * segX2, p + 16 + 3 * segX2
	for i = 0, n - 1 do
		local e = u16(s, ends + 2 * i)
		local st = u16(s, starts + 2 * i)
		local delta = s16(s, deltas + 2 * i)
		local ro = u16(s, offsets + 2 * i)
		if st ~= 0xFFFF then
			for c = st, e do
				local g
				if ro == 0 then
					g = (c + delta) % 65536
				else
					local at = offsets + 2 * i + ro + 2 * (c - st)
					g = u16(s, at)
					if g ~= 0 then
						g = (g + delta) % 65536
					end
				end
				if g ~= 0 and map[c] == nil then
					map[c] = g
				end
			end
		end
	end
end

local function parseCmap12(s, p, map)
	local groups = u32(s, p + 12)
	for i = 0, groups - 1 do
		local q = p + 16 + 12 * i
		local st, e, g = u32(s, q), u32(s, q + 4), u32(s, q + 8)
		for c = st, math.min(e, st + 0x2FFFF) do
			if map[c] == nil then
				map[c] = g + (c - st)
			end
		end
	end
end

-- Parse a font file's bytes. Returns a font object, or nil and an error.
function TTF.Parse(s)
	if #s < 12 then
		return nil, "too short"
	end
	local tag = s:sub(1, 4)
	if tag == "ttcf" then
		return nil, "font collections are not supported"
	end
	local numTables = u16(s, 4)
	local tables = {}
	for i = 0, numTables - 1 do
		local q = 12 + 16 * i
		tables[s:sub(q + 1, q + 4)] = { off = u32(s, q + 8), len = u32(s, q + 12) }
	end
	local head, hhea, hmtx, maxp, cmap = tables.head, tables.hhea, tables.hmtx, tables.maxp, tables.cmap
	if not (head and hhea and hmtx and maxp and cmap) then
		return nil, "missing a required table"
	end
	local f = setmetatable({}, Font)
	f.upem = u16(s, head.off + 18)
	f.ascender = s16(s, hhea.off + 4)
	f.descender = s16(s, hhea.off + 6)
	f.lineGap = s16(s, hhea.off + 8)
	local nh = u16(s, hhea.off + 34)
	f.numGlyphs = u16(s, maxp.off + 4)
	f.advances = {}
	for i = 0, nh - 1 do
		f.advances[i + 1] = u16(s, hmtx.off + 4 * i)
	end
	local os2 = tables["OS/2"]
	if os2 and os2.len >= 74 then
		f.typoAscender = s16(s, os2.off + 68)
		f.typoDescender = s16(s, os2.off + 70)
	end
	f.cmap = {}
	local n = u16(s, cmap.off + 2)
	local subs = {}
	for i = 0, n - 1 do
		local q = cmap.off + 4 + 8 * i
		local platform, encoding, off = u16(s, q), u16(s, q + 2), u32(s, q + 4)
		local p = cmap.off + off
		local format = u16(s, p)
		-- Unicode subtables first (3,10 full range; 3,1 / 0,x BMP); a symbol font (3,0) as a last resort.
		local rank = (platform == 3 and encoding == 10) and 1 or (platform == 0 and format == 12) and 2
			or (platform == 3 and encoding == 1) and 3 or (platform == 0) and 4 or (platform == 3 and encoding == 0) and 5
			or nil
		if rank and (format == 4 or format == 12) then
			subs[#subs + 1] = { rank = rank, p = p, format = format }
		end
	end
	table.sort(subs, function(a, b)
		return a.rank < b.rank
	end)
	for _, sub in ipairs(subs) do
		if sub.format == 12 then
			parseCmap12(s, sub.p, f.cmap)
		else
			parseCmap4(s, sub.p, f.cmap)
		end
	end
	-- A symbol-encoded face maps its glyphs at U+F0xx; the client also finds them at the ASCII code.
	if subs[1] and subs[1].rank == 5 then
		for c = 0x20, 0xFF do
			if f.cmap[c] == nil and f.cmap[0xF000 + c] then
				f.cmap[c] = f.cmap[0xF000 + c]
			end
		end
	end
	return f
end

local cache = {}

-- Load and cache a font file. Returns the font, or nil and an error.
function TTF.Load(path)
	if cache[path] ~= nil then
		return cache[path] or nil, "unreadable"
	end
	local fh = io.open(path, "rb")
	if not fh then
		cache[path] = false
		return nil, "not found"
	end
	local data = fh:read("*a")
	fh:close()
	local ok, font, err = pcall(TTF.Parse, data)
	if not ok or not font then
		cache[path] = false
		return nil, err or font
	end
	font.path = path
	cache[path] = font
	return font
end

return TTF
