-- wowui.text: the client's text markup and line layout, measured with real font metrics (wowui.ttf).
--
-- Markup handled: || (a bar), |cAARRGGBB ... |r (colour), |cn<name>: (named colour, drawn in the base colour),
-- |T<file>:<h>:<w>...|t and |A<atlas>:<h>:<w>...|a (inline pictures), |H<link>|h<text>|h (links: the text stays),
-- |K...|k (protected strings: dropped), |n and "\n" (new line). Anything else after a bar is kept as text.
--
-- Layout follows the client's FontString: words wrap at spaces when a width is given and word wrap is on (a word
-- wider than the line breaks between letters); a line that does not fit gets "..." (non-wrapping text, or the last
-- line allowed by MaxLines or the height); lines are `size + spacing` apart.

local Text = {}

local function utf8chars(s)
	local out = {}
	local i, n = 1, #s
	while i <= n do
		local c = s:byte(i)
		local len = c < 0x80 and 1 or c < 0xE0 and 2 or c < 0xF0 and 3 or 4
		local cp
		if len == 1 then
			cp = c
		elseif len == 2 then
			cp = (c % 0x20) * 64 + ((s:byte(i + 1) or 128) % 64)
		elseif len == 3 then
			cp = ((c % 0x10) * 64 + ((s:byte(i + 1) or 128) % 64)) * 64 + ((s:byte(i + 2) or 128) % 64)
		else
			cp = (((c % 0x08) * 64 + ((s:byte(i + 1) or 128) % 64)) * 64 + ((s:byte(i + 2) or 128) % 64)) * 64
				+ ((s:byte(i + 3) or 128) % 64)
		end
		out[#out + 1] = { cp = cp, s = s:sub(i, i + len - 1) }
		i = i + len
	end
	return out
end
Text.utf8chars = utf8chars

local function hexColor(h)
	local a, r, g, b = tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16),
		tonumber(h:sub(7, 8), 16)
	if not (a and r and g and b) then
		return nil
	end
	return { r / 255, g / 255, b / 255, a / 255 }
end

-- Markup -> tokens: { t = "text", s, color } | { t = "icon", file?, atlas?, h, w } | { t = "br" }.
function Text.Parse(raw)
	local tokens = {}
	local color = nil
	local buf = {}
	local function flush()
		if #buf > 0 then
			tokens[#tokens + 1] = { t = "text", s = table.concat(buf), color = color }
			buf = {}
		end
	end
	local i, n = 1, #raw
	while i <= n do
		local c = raw:sub(i, i)
		if c == "\n" then
			flush()
			tokens[#tokens + 1] = { t = "br" }
			i = i + 1
		elseif c == "|" and i < n then
			local k = raw:sub(i + 1, i + 1)
			if k == "|" then
				buf[#buf + 1] = "|"
				i = i + 2
			elseif k == "c" and raw:sub(i + 2, i + 2) == "n" then
				local e = raw:find(":", i + 3, true)
				flush()
				i = e and e + 1 or n + 1
			elseif k == "c" then
				flush()
				color = hexColor(raw:sub(i + 2, i + 9)) or color
				i = i + 10
			elseif k == "r" then
				flush()
				color = nil
				i = i + 2
			elseif k == "n" then
				flush()
				tokens[#tokens + 1] = { t = "br" }
				i = i + 2
			elseif k == "T" or k == "A" then
				local close = k == "T" and "|t" or "|a"
				local e = raw:find(close, i + 2, true)
				local body = raw:sub(i + 2, (e or n + 1) - 1)
				local parts = {}
				for part in (body .. ":"):gmatch("([^:]*):") do
					parts[#parts + 1] = part
				end
				flush()
				local h = tonumber(parts[2]) or 0
				local w = tonumber(parts[3])
				local tok = { t = "icon", h = h, w = w }
				if k == "T" then
					tok.file = parts[1]
				else
					tok.atlas = parts[1]
				end
				tokens[#tokens + 1] = tok
				i = e and e + 2 or n + 1
			elseif k == "H" then
				local e = raw:find("|h", i + 2, true)
				i = e and e + 2 or n + 1
			elseif k == "h" then
				i = i + 2
			elseif k == "K" then
				local e = raw:find("|k", i + 2, true)
				i = e and e + 2 or n + 1
			else
				buf[#buf + 1] = c
				i = i + 1
			end
		else
			buf[#buf + 1] = c
			i = i + 1
		end
	end
	flush()
	return tokens
end

-- The visible characters of a markup string (for tests, keys and glyph checks).
function Text.Plain(raw)
	local out = {}
	for _, tok in ipairs(Text.Parse(raw or "")) do
		if tok.t == "text" then
			out[#out + 1] = tok.s
		elseif tok.t == "br" then
			out[#out + 1] = "\n"
		end
	end
	return table.concat(out)
end

-- A measurer: font (wowui.ttf object or nil), size, scale (a fallback face's width correction).
local function measurer(font, size, scale)
	scale = scale or 1
	local per = font and (size / font.upem * scale) or nil
	return function(s)
		local w = 0
		for _, ch in ipairs(utf8chars(s)) do
			if per then
				w = w + font:Advance(ch.cp) * per
			else
				w = w + size * 0.55 * scale
			end
		end
		return w
	end
end
Text.Measurer = measurer

local function iconWidth(tok, size)
	local h = (tok.h and tok.h > 0) and tok.h or size
	local w = tok.w and tok.w > 0 and tok.w or h
	return w, h
end

-- Atoms for wrapping: words (with their colour runs), spaces, icons, breaks.
local function atoms(tokens, measure, size)
	local list = {}
	for _, tok in ipairs(tokens) do
		if tok.t == "br" then
			list[#list + 1] = { kind = "br" }
		elseif tok.t == "icon" then
			local w, h = iconWidth(tok, size)
			list[#list + 1] = { kind = "word", parts = { { icon = tok, w = w, h = h } }, w = w }
		else
			local s = tok.s
			local pos = 1
			while pos <= #s do
				local sp, spe = s:find(" +", pos)
				local word = s:sub(pos, (sp or #s + 1) - 1)
				if word ~= "" then
					local last = list[#list]
					local part = { s = word, color = tok.color, w = measure(word) }
					if last and last.kind == "word" and last.glue then
						last.parts[#last.parts + 1] = part
						last.w = last.w + part.w
						last.glue = nil
					else
						list[#list + 1] = { kind = "word", parts = { part }, w = part.w }
					end
					list[#list].glue = sp == nil -- a word running into the next token (a colour change mid-word)
				end
				if sp then
					local spaces = s:sub(sp, spe)
					list[#list + 1] = { kind = "space", s = spaces, color = tok.color, w = measure(spaces) }
					pos = spe + 1
				else
					pos = #s + 1
				end
			end
		end
	end
	return list
end

local function newLine()
	return { parts = {}, w = 0 }
end

local function push(line, part)
	local last = line.parts[#line.parts]
	if last and part.s and last.s and last.color == part.color and not last.icon then
		last.s = last.s .. part.s
		last.w = last.w + part.w
	else
		line.parts[#line.parts + 1] = { s = part.s, color = part.color, w = part.w, icon = part.icon, h = part.h }
	end
	line.w = line.w + part.w
end

-- Cut a line so that it ends with "..." within `width`.
local function ellipsize(line, width, measure)
	local dots = measure("...")
	local out = newLine()
	local room = width - dots
	for _, part in ipairs(line.parts) do
		if part.w <= room then
			push(out, part)
			room = room - part.w
		else
			if part.s then
				local acc, kept = 0, {}
				for _, ch in ipairs(utf8chars(part.s)) do
					local cw = measure(ch.s)
					if acc + cw > room then
						break
					end
					acc = acc + cw
					kept[#kept + 1] = ch.s
				end
				if #kept > 0 then
					push(out, { s = table.concat(kept), color = part.color, w = acc })
				end
			end
			break
		end
	end
	-- Trailing spaces go before the dots, as the client does.
	local last = out.parts[#out.parts]
	if last and last.s then
		local trimmed = last.s:gsub(" +$", "")
		if trimmed ~= last.s then
			local cut = measure(last.s) - measure(trimmed)
			last.s, last.w, out.w = trimmed, last.w - cut, out.w - cut
		end
	end
	push(out, { s = "...", color = (out.parts[#out.parts] or {}).color, w = dots })
	return out
end

-- Lay out markup. opts: font, size, scale, width (nil = unbounded), wrap (default true), nonSpaceWrap, maxLines,
-- maxHeight, spacing. Returns { lines = { { parts, w } }, width (widest line), height, truncated, full (unbounded
-- single-line width), lineHeight }.
function Text.Layout(raw, opts)
	local size = opts.size or 12
	local measure = measurer(opts.font, size, opts.scale)
	local tokens = Text.Parse(raw or "")
	local list = atoms(tokens, measure, size)
	local width = opts.width
	if width and width <= 0 then
		width = nil -- an unsized font string lays out on one line
	end
	local wrap = opts.wrap ~= false and width ~= nil
	local spacing = opts.spacing or 0
	local lines = { newLine() }
	local full, fullLine = 0, 0
	local function cur()
		return lines[#lines]
	end
	for _, a in ipairs(list) do
		if a.kind == "br" then
			full = math.max(full, fullLine)
			fullLine = 0
			lines[#lines + 1] = newLine()
		elseif a.kind == "space" then
			fullLine = fullLine + a.w
			if not (wrap and #cur().parts == 0 and #lines > 1 and cur().soft) then
				push(cur(), { s = a.s, color = a.color, w = a.w })
			end
		else
			fullLine = fullLine + a.w
			if wrap and cur().w + a.w > width + 0.01 and #cur().parts > 0 then
				-- Drop the trailing space of the full line, start a soft-wrapped one.
				local line = cur()
				local last = line.parts[#line.parts]
				if last and last.s then
					local trimmed = last.s:gsub(" +$", "")
					local cut = measure(last.s) - measure(trimmed)
					last.s, last.w, line.w = trimmed, last.w - cut, line.w - cut
					if last.s == "" then
						table.remove(line.parts)
					end
				end
				lines[#lines + 1] = newLine()
				cur().soft = true
			end
			if wrap and a.w > width + 0.01 then
				-- A word wider than the line: break between letters.
				for _, part in ipairs(a.parts) do
					if part.icon then
						push(cur(), part)
					else
						for _, ch in ipairs(utf8chars(part.s)) do
							local cw = measure(ch.s)
							if cur().w + cw > width + 0.01 and #cur().parts > 0 then
								lines[#lines + 1] = newLine()
								cur().soft = true
							end
							push(cur(), { s = ch.s, color = part.color, w = cw })
						end
					end
				end
			else
				for _, part in ipairs(a.parts) do
					push(cur(), part)
				end
			end
		end
	end
	full = math.max(full, fullLine)
	local truncated = false
	-- Non-wrapping lines that are too wide.
	if width and not wrap then
		for i, line in ipairs(lines) do
			if line.w > width + 0.5 then
				lines[i] = ellipsize(line, width, measure)
				truncated = true
			end
		end
	end
	-- Line limits: MaxLines, then the height.
	local limit = (opts.maxLines and opts.maxLines > 0) and opts.maxLines or nil
	if opts.maxHeight and opts.maxHeight > 0 then
		local fit = math.max(1, math.floor((opts.maxHeight + spacing + 0.5) / (size + spacing)))
		limit = limit and math.min(limit, fit) or fit
	end
	if limit and #lines > limit then
		local keep = {}
		for i = 1, limit do
			keep[i] = lines[i]
		end
		-- The rest of the text would follow: the last kept line ends with "...".
		keep[limit] = ellipsize(keep[limit], width or math.huge, measure)
		lines = keep
		truncated = true
	end
	local widest = 0
	for _, line in ipairs(lines) do
		widest = math.max(widest, line.w)
	end
	local height = #lines * size + math.max(0, #lines - 1) * spacing
	if (raw or "") == "" then
		height = 0
	end
	return { lines = lines, width = widest, height = height, truncated = truncated, full = full, lineHeight = size,
		spacing = spacing }
end

return Text
