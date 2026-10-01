--[[ ---------------- download checks ---------------- ]]

local function u16(s, i)
	local a, b = string.byte(s, i, i + 1)
	return a + b * 256
end

local function u32(s, i)
	local a, b, c, d = string.byte(s, i, i + 3)
	return a + b * 256 + c * 65536 + d * 16777216
end

-- Reads a zip's central directory without extracting anything. Returns
-- (total uncompressed bytes, entry count), or (nil, reason) when the zip
-- is malformed, uses zip64, or has an unsafe entry name.
local function inspect_zip(data)
	local eocd = nil
	local stop = math.max(1, #data - 65557)
	for i = #data - 21, stop, -1 do
		if string.sub(data, i, i + 3) == "PK\5\6" then
			eocd = i
			break
		end
	end
	if not eocd then return nil, "no end-of-central-directory record" end

	local entries = u16(data, eocd + 10)
	local cd_offset = u32(data, eocd + 16)
	if entries == 0xFFFF or cd_offset == 0xFFFFFFFF then return nil, "zip64 not supported" end

	local pos = cd_offset + 1
	local total = 0
	for _ = 1, entries do
		if pos + 45 > #data or string.sub(data, pos, pos + 3) ~= "PK\1\2" then
			return nil, "bad central directory entry"
		end
		local usize = u32(data, pos + 24)
		if usize == 0xFFFFFFFF then return nil, "zip64 not supported" end
		local name_len = u16(data, pos + 28)
		local extra_len = u16(data, pos + 30)
		local comment_len = u16(data, pos + 32)
		local name = string.sub(data, pos + 46, pos + 45 + name_len)
		if string.find(name, "..", 1, true) or string.find(name, "^[/\\]") or string.find(name, ":", 1, true) then
			return nil, "unsafe entry name: " .. name
		end
		total = total + usize
		pos = pos + 46 + name_len + extra_len + comment_len
	end
	return total, entries
end

-- Returns (ok, reason). Rejects empty, oversized and HTML responses.
local function check_download(data)
	if not data or #data == 0 then return false, L("empty response", "prázdná odpověď") end
	if #data > MAX_DOWNLOAD_BYTES then return false, L("larger than expected (%s bytes)", "soubor je větší, než by měl být (%s bajtů)", #data) end
	local head = string.gsub(string.sub(data, 1, 512), "^\239\187\191", "") -- drop UTF-8 BOM
	if string.match(head, "^%s*<") then return false, L("the site returned a web page instead of a subtitle", "stránka místo titulků vrátila webovou stránku") end
	return true
end

local SUBTITLE_EXTS = { srt = true, ass = true, ssa = true, sub = true, vtt = true }

local function attach_subtitle(path)
	if not (vlc.input and vlc.input.item and vlc.input.add_subtitle) then return false end
	local has_item_ok, has_item = pcall(vlc.input.item)
	if not (has_item_ok and has_item) then return false end
	local ok, res = pcall(vlc.input.add_subtitle, path, true)
	if ok and res ~= false then return true end
	-- some VLC builds want a URI rather than a plain path
	if vlc.strings and vlc.strings.make_uri then
		local ok2, res2 = pcall(vlc.input.add_subtitle, vlc.strings.make_uri(path), true)
		return ok2 and res2 ~= false
	end
	return false
end
