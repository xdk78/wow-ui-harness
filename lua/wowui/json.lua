-- wowui.json: a small deterministic JSON encoder (sorted object keys, compact numbers) and a decoder for the files
-- this package writes (baselines, dumps). Plain Lua 5.1.

local JSON = {}

local function num(v)
	if v ~= v or v == math.huge or v == -math.huge then
		return "null"
	end
	if v == math.floor(v) and math.abs(v) < 1e15 then
		return string.format("%d", v)
	end
	local s = string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", "")
	if s == "-0" then
		s = "0"
	end
	return s
end

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function str(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		return ESC[c] or string.format("\\u%04x", c:byte())
	end) .. '"'
end

local function isArray(t)
	local n = #t
	if n == 0 then
		return next(t) == nil and "empty" or false
	end
	for k in pairs(t) do
		if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then
			return false
		end
	end
	return true
end

local function enc(v, indent, depth, out)
	local t = type(v)
	if t == "string" then
		out[#out + 1] = str(v)
	elseif t == "number" then
		out[#out + 1] = num(v)
	elseif t == "boolean" then
		out[#out + 1] = tostring(v)
	elseif t == "table" then
		local arr = isArray(v)
		local nl = indent and ("\n" .. string.rep(indent, depth + 1)) or ""
		local close = indent and ("\n" .. string.rep(indent, depth)) or ""
		if arr == "empty" then
			out[#out + 1] = "[]"
		elseif arr then
			-- Arrays of plain values stay on one line.
			local flat = true
			for _, x in ipairs(v) do
				if type(x) == "table" then
					flat = false
					break
				end
			end
			out[#out + 1] = "["
			for i, x in ipairs(v) do
				if i > 1 then
					out[#out + 1] = ","
				end
				if not flat then
					out[#out + 1] = nl
				end
				enc(x, indent, depth + 1, out)
			end
			out[#out + 1] = flat and "]" or (close .. "]")
		else
			local keys = {}
			for k, x in pairs(v) do
				if type(x) ~= "function" then
					keys[#keys + 1] = tostring(k)
				end
			end
			table.sort(keys)
			out[#out + 1] = "{"
			for i, k in ipairs(keys) do
				if i > 1 then
					out[#out + 1] = ","
				end
				out[#out + 1] = nl
				out[#out + 1] = str(k)
				out[#out + 1] = indent and ": " or ":"
				local x = v[k]
				if x == nil then
					x = v[tonumber(k)]
				end
				enc(x, indent, depth + 1, out)
			end
			out[#out + 1] = close .. "}"
		end
	else
		out[#out + 1] = "null"
	end
end

-- Encode a value. `indent` (e.g. "  ") pretty-prints objects.
function JSON.Encode(v, indent)
	local out = {}
	enc(v, indent, 0, out)
	return table.concat(out)
end

-- Decode JSON text (objects, arrays, strings with \uXXXX in the BMP, numbers, true, false, null -> nil).
function JSON.Decode(s)
	local pos = 1
	local function ws()
		pos = s:find("[^ \t\r\n]", pos) or #s + 1
	end
	local value
	local function err(what)
		error(string.format("json: %s at %d", what, pos), 0)
	end
	local function utf8(cp)
		if cp < 0x80 then
			return string.char(cp)
		elseif cp < 0x800 then
			return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
		end
		return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
	end
	function value()
		ws()
		local c = s:sub(pos, pos)
		if c == "{" then
			pos = pos + 1
			local obj = {}
			ws()
			if s:sub(pos, pos) == "}" then
				pos = pos + 1
				return obj
			end
			while true do
				ws()
				local k = value()
				ws()
				if s:sub(pos, pos) ~= ":" then
					err("expected ':'")
				end
				pos = pos + 1
				obj[k] = value()
				ws()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == "}" then
					return obj
				elseif d ~= "," then
					err("expected ',' or '}'")
				end
			end
		elseif c == "[" then
			pos = pos + 1
			local arr = {}
			ws()
			if s:sub(pos, pos) == "]" then
				pos = pos + 1
				return arr
			end
			while true do
				arr[#arr + 1] = value()
				ws()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == "]" then
					return arr
				elseif d ~= "," then
					err("expected ',' or ']'")
				end
			end
		elseif c == '"' then
			local out = {}
			pos = pos + 1
			while true do
				local ch = s:sub(pos, pos)
				if ch == "" then
					err("unterminated string")
				elseif ch == '"' then
					pos = pos + 1
					return table.concat(out)
				elseif ch == "\\" then
					local e = s:sub(pos + 1, pos + 1)
					local map = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ["/"] = "/", ["\\"] = "\\", ['"'] = '"' }
					if e == "u" then
						out[#out + 1] = utf8(tonumber(s:sub(pos + 2, pos + 5), 16) or 63)
						pos = pos + 6
					else
						out[#out + 1] = map[e] or e
						pos = pos + 2
					end
				else
					out[#out + 1] = ch
					pos = pos + 1
				end
			end
		elseif s:sub(pos, pos + 3) == "true" then
			pos = pos + 4
			return true
		elseif s:sub(pos, pos + 4) == "false" then
			pos = pos + 5
			return false
		elseif s:sub(pos, pos + 3) == "null" then
			pos = pos + 4
			return nil
		end
		local numText = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
		if not numText or numText == "" then
			err("unexpected character")
		end
		pos = pos + #numText
		return tonumber(numText)
	end
	return value()
end

return JSON
