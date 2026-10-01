--[[
Titulky.com Subtitles - VLC extension (premium.titulky.com only)

Search, pick a title and a release, download the subtitle and load it
into whatever is playing. Requires a premium.titulky.com account; the
free titulky.com site is not supported.

The "primary" (first) release of a title is read from the page text with
a heuristic rather than from structured markup, so its release tag is
occasionally slightly off; the alternates are parsed normally.

Logs in fresh on every request (no session caching).
]]

function descriptor()
return {
title = "Titulky.com Subtitles v1.1.0",
version = "1.1.0",
author = "Highflight Studio",
shortdesc = "Titulky.com subtitles (premium)",
description = "Search premium.titulky.com and download/apply subtitles.",
capabilities = {}
}
end

local dlg = nil
local user_input, pass_input, search_input = nil, nil, nil
local results_list = nil
local status_label = nil

-- sub_rows holds whatever's currently listed: either title matches
-- (kind="title", from a search with more than one hit) or releases for
-- one title (kind="release", ready to download)
local sub_rows = {}
local pending_row = nil

-- defined in the credentials section further down, after the helpers
-- they need
local save_credentials, load_credentials

--[[ ---------------- download handling ----------------
Everything here is prefixed hf_ so it can't clash with the rest of the
file. Only local function definitions: VLC's startup scan provides almost
no standard Lua functions, so nothing may be called at a file's top level.

What it does once a file has been downloaded (hf_finish):
  - rejects empty responses, HTML pages and anything over
    HF_MAX_DOWNLOAD_BYTES
  - for a zip: checks the total unpacked size (zip-bomb guard) and the
    entry names (no absolute paths or "..") BEFORE extracting, extracts
    into a temporary work folder (with the zip password if one is given),
    and picks the subtitle file inside
  - saves the subtitle to Documents/VLC Subtitles (shared by all the
    extensions) and attaches it to the playing video
  - removes the temporary files every time
hf_cleanup_old deletes this extension's own files in that folder once
they are older than HF_SUB_MAX_AGE_DAYS (the save time is in the name).
]]

local HF_MAX_DOWNLOAD_BYTES = 20 * 1024 * 1024
local HF_MAX_EXTRACTED_BYTES = 200 * 1024 * 1024
local HF_SUB_MAX_AGE_DAYS = 30
local HF_SUB_EXTS = { srt = true, ass = true, ssa = true, sub = true, vtt = true }

local hf_windows = nil
local function hf_is_windows()
	if hf_windows == nil then
		if package and package.config then
			hf_windows = package.config:sub(1, 1) == "\\"
		else
			hf_windows = os.getenv("WINDIR") ~= nil or os.getenv("OS") == "Windows_NT"
		end
	end
	return hf_windows
end

local function hf_join(...)
	return table.concat({...}, hf_is_windows() and "\\" or "/")
end

local function hf_log(tag, msg)
	vlc.msg.dbg(tag .. " " .. msg)
end

local function hf_run(tag, cmd, log_line)
	hf_log(tag, "running: " .. (log_line or cmd))
	local p = io.popen(cmd, "r")
	if not p then return nil end
	local out = p:read("*a")
	p:close()
	return out
end

local function hf_read(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local data = f:read("*a")
	f:close()
	return data
end

local function hf_write(path, data)
	local f = io.open(path, "wb")
	if not f then return false end
	f:write(data)
	f:close()
	return true
end

local function hf_make_dir(tag, path)
	if hf_is_windows() then
		hf_run(tag, 'mkdir "' .. path .. '" 2>nul')
	else
		hf_run(tag, 'mkdir -p "' .. path .. '"')
	end
end

local function hf_remove_dir(tag, path)
	if hf_is_windows() then
		hf_run(tag, 'rmdir /s /q "' .. path .. '" 2>nul')
	else
		hf_run(tag, 'rm -rf "' .. path .. '"')
	end
end

local function hf_lines(text)
	local out = {}
	for line in string.gmatch(text or "", "[^\r\n]+") do table.insert(out, line) end
	return out
end

local function hf_subtitles_dir()
	local home = hf_is_windows() and os.getenv("USERPROFILE") or os.getenv("HOME")
	if not home or home == "" then return hf_join(vlc.config.userdatadir(), "VLC Subtitles") end
	return hf_join(home, "Documents", "VLC Subtitles")
end

local function hf_cleanup_old(tag, prefix)
	local dir = hf_subtitles_dir()
	local listing = hf_is_windows()
		and hf_run(tag, 'dir /b /a-d "' .. dir .. '" 2>nul')
		or hf_run(tag, 'ls -1 "' .. dir .. '" 2>/dev/null')
	local cutoff = os.time() - HF_SUB_MAX_AGE_DAYS * 24 * 60 * 60
	local removed = 0
	for _, name in ipairs(hf_lines(listing)) do
		if string.sub(name, 1, #prefix + 1) == prefix .. "_" then
			local saved_at = tonumber(string.match(name, "_(%d+)%.%w+$") or "")
			if saved_at and saved_at < cutoff and os.remove(hf_join(dir, name)) then
				removed = removed + 1
			end
		end
	end
	if removed > 0 then hf_log(tag, "cleanup: removed " .. removed .. " old subtitle file(s)") end
end

local function hf_u16(s, i)
	local a, b = string.byte(s, i, i + 1)
	return a + b * 256
end

local function hf_u32(s, i)
	local a, b, c, d = string.byte(s, i, i + 3)
	return a + b * 256 + c * 65536 + d * 16777216
end

-- Reads a zip's central directory without extracting anything. Returns
-- (total uncompressed bytes, entry count, encrypted?), or nil plus a
-- reason when the zip is malformed, uses zip64 or has an unsafe name.
local function hf_inspect_zip(data)
	local eocd = nil
	for i = #data - 21, math.max(1, #data - 65557), -1 do
		if string.sub(data, i, i + 3) == "PK\5\6" then
			eocd = i
			break
		end
	end
	if not eocd then return nil, "no end-of-central-directory record" end
	local entries = hf_u16(data, eocd + 10)
	local cd_offset = hf_u32(data, eocd + 16)
	if entries == 0xFFFF or cd_offset == 0xFFFFFFFF then return nil, "zip64 not supported" end
	local pos = cd_offset + 1
	local total, encrypted = 0, false
	for _ = 1, entries do
		if pos + 45 > #data or string.sub(data, pos, pos + 3) ~= "PK\1\2" then
			return nil, "bad central directory entry"
		end
		if hf_u16(data, pos + 8) % 2 == 1 then encrypted = true end
		local usize = hf_u32(data, pos + 24)
		if usize == 0xFFFFFFFF then return nil, "zip64 not supported" end
		local name_len = hf_u16(data, pos + 28)
		local name = string.sub(data, pos + 46, pos + 45 + name_len)
		if string.find(name, "..", 1, true) or string.find(name, "^[/\\]") or string.find(name, ":", 1, true) then
			return nil, "unsafe entry name: " .. name
		end
		total = total + usize
		pos = pos + 46 + name_len + hf_u16(data, pos + 30) + hf_u16(data, pos + 32)
	end
	return total, entries, encrypted
end

local function hf_check_download(data)
	if not data or #data == 0 then return false, "empty response" end
	if #data > HF_MAX_DOWNLOAD_BYTES then return false, "larger than a subtitle should be" end
	local head = string.gsub(string.sub(data, 1, 512), "^\239\187\191", "")
	if string.match(head, "^%s*<") then return false, "the site returned a web page instead of a subtitle" end
	return true
end

local function hf_find_subtitle(tag, dir)
	local listing = hf_is_windows()
		and hf_run(tag, 'dir /b /s /a-d "' .. dir .. '" 2>nul')
		or hf_run(tag, 'find "' .. dir .. '" -type f 2>/dev/null')
	local paths = hf_lines(listing)
	table.sort(paths)
	for _, path in ipairs(paths) do
		local ext = string.lower(string.match(path, "%.(%w+)$") or "")
		local f = io.open(path, "rb")
		local size = f and f:seek("end") or 0
		if f then f:close() end
		if HF_SUB_EXTS[ext] and size > 0 then return path end
	end
	if paths[1] then hf_log(tag, "zip had no subtitle-looking file, first file was " .. paths[1]) end
	return nil
end

-- extracts zip_path into dest_dir and returns the subtitle file inside, or
-- nil. A zip whose entries are flagged as encrypted goes straight to the
-- password step; otherwise it's tried without one first, then (if a
-- password is given and nothing usable came out) with it.
local function hf_extract(tag, zip_path, dest_dir, password, encrypted)
	hf_make_dir(tag, dest_dir)
	if encrypted and password and password ~= "" then
		hf_log(tag, "zip is password-protected, extracting with the zip password")
	elseif hf_is_windows() then
		hf_run(tag, string.format('tar -xf "%s" -C "%s" 2>nul', zip_path, dest_dir))
	else
		hf_run(tag, string.format('unzip -o "%s" -d "%s" >/dev/null 2>&1', zip_path, dest_dir))
	end
	if not (encrypted and password and password ~= "") then
		local found = hf_find_subtitle(tag, dest_dir)
		if found or not password or password == "" then return found end
		hf_log(tag, "nothing usable extracted without a password, retrying with the zip password")
	end
	if hf_is_windows() then
		if string.find(password, '"', 1, true) then
			hf_log(tag, "zip password contains a double quote, which can't be passed to tar on Windows")
			return nil
		end
		-- Windows' tar (bsdtar) takes the password via --passphrase
		hf_run(tag, string.format('tar -xf "%s" -C "%s" --passphrase "%s" 2>nul', zip_path, dest_dir, password),
			'tar -xf "' .. zip_path .. '" --passphrase *** (password not logged)')
	else
		local quoted = "'" .. string.gsub(password, "'", "'\\''") .. "'"
		hf_run(tag, string.format('unzip -o -P %s "%s" -d "%s" >/dev/null 2>&1', quoted, zip_path, dest_dir),
			'unzip -P *** "' .. zip_path .. '" (password not logged)')
	end
	return hf_find_subtitle(tag, dest_dir)
end

local function hf_attach(path)
	if not (vlc.input and vlc.input.item and vlc.input.add_subtitle) then return false end
	local has_item_ok, has_item = pcall(vlc.input.item)
	if not (has_item_ok and has_item) then return false end
	local ok, res = pcall(vlc.input.add_subtitle, path, true)
	if ok and res ~= false then return true end
	if vlc.strings and vlc.strings.make_uri then
		local ok2, res2 = pcall(vlc.input.add_subtitle, vlc.strings.make_uri(path), true)
		return ok2 and res2 ~= false
	end
	return false
end

--[[
Finishes a download. o = {
  tag = "[Name]", prefix = "name" (file-name prefix),
  body_path = the downloaded file,
  name_stem = final name without time/extension (should start with prefix),
  ext = extension for a non-zip file (".srt", "ass", ...),
  zip_password = optional,
}
Returns the text to show in the dialog's status line.
]]
local function hf_finish(o)
	local tag = o.tag
	local data = hf_read(o.body_path)
	local ok, reason = hf_check_download(data)
	if not ok then
		hf_log(tag, "download rejected: " .. reason)
		os.remove(o.body_path)
		return "Download failed: " .. reason .. ". Try again in a moment."
	end

	local work = hf_join(vlc.config.userdatadir(), o.prefix .. "_work")
	hf_remove_dir(tag, work)
	hf_make_dir(tag, work)

	local function done(msg)
		hf_remove_dir(tag, work)
		os.remove(o.body_path)
		return msg
	end

	local src, ext
	if string.sub(data, 1, 2) == "PK" then
		local total, info, encrypted = hf_inspect_zip(data)
		if not total then
			hf_log(tag, "zip refused: " .. tostring(info))
			return done("Downloaded a zip but it looks broken or unsafe (see debug log).")
		end
		if total > HF_MAX_EXTRACTED_BYTES then
			hf_log(tag, "zip refused: " .. total .. " bytes uncompressed")
			return done("Download refused: the archive is far too large when unpacked.")
		end
		if encrypted and (not o.zip_password or o.zip_password == "") then
			hf_log(tag, "zip is password-protected and no zip password is set")
			return done("This zip needs a password - fill in the zip password field, then download again.")
		end
		local zip_path = hf_join(work, "download.zip")
		hf_write(zip_path, data)
		src = hf_extract(tag, zip_path, hf_join(work, "extract"), o.zip_password, encrypted)
		if not src then
			return done(encrypted
				and "Couldn't unpack the zip - check the zip password (see debug log)."
				or "Downloaded a zip but found no subtitle inside (see debug log).")
		end
		ext = string.lower(string.match(src, "%.(%w+)$") or "srt")
	else
		src = o.body_path
		ext = string.lower(string.gsub(o.ext or "srt", "^%.", ""))
		if not HF_SUB_EXTS[ext] then ext = "srt" end
	end

	local dest_dir = hf_subtitles_dir()
	hf_make_dir(tag, dest_dir)
	local final_name = string.format("%s_%d.%s", string.gsub(o.name_stem, "[^%w%-_]+", "_"), os.time(), ext)
	local final_path = hf_join(dest_dir, final_name)
	local content = hf_read(src)
	if not content or not hf_write(final_path, content) then
		hf_log(tag, "could not write " .. final_path)
		return done("Downloaded, but couldn't save into " .. dest_dir .. " (see debug log).")
	end
	hf_log(tag, "saved subtitle to " .. final_path)

	if hf_attach(final_path) then
		return done("Downloaded and applied: " .. final_name)
	end
	return done("Saved to " .. final_path .. " (no video playing, open one and add it manually).")
end

function activate()
	pcall(hf_cleanup_old, "[Titulky]", "titulky")
show_dialog()
end

function deactivate()
if dlg then dlg:delete() end
end

function close()
vlc.deactivate()
end

-- best-effort guess at a title from the currently playing file, so the
-- search box starts pre-filled
local function guess_title_from_playing()
if not (vlc.input and vlc.input.item) then return nil end
local ok, item = pcall(vlc.input.item)
if not ok or not item then return nil end
local uri = item:uri()
if not uri then return nil end

local name = string.match(uri, "([^/\\]+)$") or uri
if vlc.strings and vlc.strings.decode_uri then
name = vlc.strings.decode_uri(name)
end
name = string.gsub(name, "%.%w+$", "") -- drop file extension
name = string.gsub(name, "%[[^%]]*%]", " ") -- drop [tags]
name = string.gsub(name, "%([^%)]*%)", " ") -- drop (tags)
name = string.gsub(name, "[%._]", " ") -- dots/underscores -> spaces

local lower = string.lower(name)
local cut_at = string.find(lower, "s%d%d?e%d%d?")

-- cut at the earliest standalone 4-digit year (e.g. "Avatar Fire and Ash
-- 2025 2160p..."), same as the quality/codec tags below.
-- %f[%d]/%f[%D] (frontier patterns) make sure this only matches a
-- whole 4-digit token, not part of a longer number.
local year_pos = string.find(lower, "%f[%d]%d%d%d%d%f[%D]")
if year_pos and (not cut_at or year_pos < cut_at) then cut_at = year_pos end

local keywords = {
"2160p", "1080p", "720p", "480p", "4k",
"blu%-ray", "bluray", "bdrip", "webrip", "web%-dl", "web dl",
"hdtv", "dvdrip", "hdrip",
"x264", "x265", "h264", "h265", "hevc", "avc",
"dual audio", "dual%-audio", "multi audio", "multi%-audio",
"aac", "flac", "dts", "opus",
}
for _, kw in ipairs(keywords) do
local ks = string.find(lower, kw)
if ks and (not cut_at or ks < cut_at) then cut_at = ks end
end
if cut_at then
name = string.sub(name, 1, cut_at - 1)
end

name = string.gsub(name, "%s%-%s*%d+.*$", "")
name = string.gsub(name, "[%-–—]+%s*$", "")
name = string.gsub(name, "%s+", " ")
name = string.match(name, "^%s*(.-)%s*$")

if name == "" then return nil end
return name
end

-- VERSION_TAG: shown in the dialog's title bar. Keep it in step with
-- descriptor().version; if the title bar shows an old version, VLC is
-- still running an old copy of this file.
local VERSION_TAG = "v1.1.0"

function show_dialog()
dlg = vlc.dialog("Titulky.com Subtitles (" .. VERSION_TAG .. ")")
local saved_username, saved_password = load_credentials()
local guessed_title = guess_title_from_playing()

-- Width/height on add_text_input/add_password/add_list are only hints
-- that VLC's GUI may ignore (in practice they make no visible difference),
-- and VLC always shrinks a dialog to its widgets' natural size. What
-- reliably widens a column is a button with real text in it, so the
-- button row has one button per column (3 in total).
local WIDE = 720

dlg:add_label("Username:", 1, 1, 1, 1)
user_input = dlg:add_text_input(saved_username, 2, 1, 2, 1, WIDE, 24)
dlg:add_label("Password:", 1, 2, 1, 1)
pass_input = dlg:add_password(saved_password, 2, 2, 2, 1, WIDE, 24)

dlg:add_label("Search:", 1, 3, 1, 1)
search_input = dlg:add_text_input(guessed_title or "", 2, 3, 2, 1, WIDE, 24)
dlg:add_button("Search", do_search, 1, 4, 1, 1)
dlg:add_button("Download Selected", do_download_start, 2, 4, 1, 1)
dlg:add_button("Clear", do_clear, 3, 4, 1, 1)

results_list = dlg:add_list(1, 5, 3, 1, WIDE, 160)
local initial_status = guessed_title
and ("Guessed '" .. guessed_title .. "' from the playing file - edit if wrong, then Search.")
or "Needs your premium titulky.com login. Type a title and hit Search."
status_label = dlg:add_label(initial_status, 1, 6, 3, 1)
vlc.msg.dbg("[Titulky] show_dialog: " .. VERSION_TAG .. ", WIDE=" .. WIDE
.. " - if the title bar doesn't say " .. VERSION_TAG .. ", VLC is loading a different titulky.lua than this one")
dlg:show()
end

--[[ ---------------- helpers ---------------- ]]

local function urlencode(str)
if str == nil then return "" end
str = string.gsub(str, "\n", "\r\n")
str = string.gsub(str, "([^%w%-%_%.%~])", function(c)
return string.format("%%%02X", string.byte(c))
end)
return str
end

local function decode_entities(str)
	if not str then return str end
	-- numbered (&#233; / &#x11B;) and named (&ecaron;, &amp;, ...) HTML
	-- entities -> UTF-8, in a single pass each so "&amp;lt;" stays "&lt;"
	local function utf8_char(cp)
		if not cp or cp < 0 or cp > 0x10FFFF then return "?" end
		if cp < 0x80 then return string.char(cp) end
		if cp < 0x800 then
			return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
		end
		if cp < 0x10000 then
			return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
		end
		return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
			0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	end
	local named = {
		amp = 38, quot = 34, apos = 39, lt = 60, gt = 62, nbsp = 32,
		ndash = 8211, mdash = 8212, hellip = 8230, laquo = 171, raquo = 187,
		bdquo = 8222, ldquo = 8220, rdquo = 8221, sbquo = 8218, lsquo = 8216, rsquo = 8217,
		aacute = 225, Aacute = 193, eacute = 233, Eacute = 201, iacute = 237, Iacute = 205,
		oacute = 243, Oacute = 211, uacute = 250, Uacute = 218, yacute = 253, Yacute = 221,
		uring = 367, Uring = 366, ccaron = 269, Ccaron = 268, dcaron = 271, Dcaron = 270,
		ecaron = 283, Ecaron = 282, ncaron = 328, Ncaron = 327, rcaron = 345, Rcaron = 344,
		scaron = 353, Scaron = 352, tcaron = 357, Tcaron = 356, zcaron = 382, Zcaron = 381,
		lcaron = 318, Lcaron = 317, lacute = 314, Lacute = 313, racute = 341, Racute = 340,
		ocirc = 244, Ocirc = 212, auml = 228, Auml = 196, ouml = 246, Ouml = 214, uuml = 252, Uuml = 220,
	}
	str = string.gsub(str, "&#[xX](%x+);", function(h) return utf8_char(tonumber(h, 16)) end)
	str = string.gsub(str, "&#(%d+);", function(d) return utf8_char(tonumber(d)) end)
	str = string.gsub(str, "&(%a+);", function(name)
		local cp = named[name]
		if cp then return utf8_char(cp) end
		return nil -- unknown entity: leave it as it was
	end)
	return str
end

-- log_line, if given, is logged INSTEAD OF cmd - keeps credentials out of
-- VLC's debug console
local function run(cmd, log_line)
vlc.msg.dbg("[Titulky] running: " .. (log_line or cmd))
local p = io.popen(cmd, "r")
if not p then return nil, "io.popen failed to start command" end
local out = p:read("*a")
p:close()
return out
end

local function cookie_jar()
return vlc.config.userdatadir() .. "/titulky_cookies.txt"
end

local function is_windows()
return package.config:sub(1, 1) == "\\"
end

local function downloads_dir()
if is_windows() then
return (os.getenv("USERPROFILE") or vlc.config.userdatadir()) .. "/Downloads"
else
return (os.getenv("HOME") or vlc.config.userdatadir()) .. "/Downloads"
end
end

-- --max-time on every curl call: io.popen blocks VLC's whole UI thread
-- while curl runs, so a server that never answers would otherwise freeze
-- the dialog with no error.
local function get(url, referer)
local ref = referer and string.format(' -e "%s"', referer) or ""
local cmd = string.format('curl -sS -L -b "%s" -c "%s" --max-time 20%s "%s"', cookie_jar(), cookie_jar(), ref, url)
return run(cmd)
end

local function post(url, data, referer, extra_headers, log_data)
local ref = referer and string.format(' -e "%s"', referer) or ""
local hdrs = extra_headers or ""
local cmd = string.format('curl -sS -L -b "%s" -c "%s" --max-time 20%s%s -d "%s" "%s"',
cookie_jar(), cookie_jar(), ref, hdrs, data, url)
local log_cmd = log_data and string.format('curl -sS -L -b "%s" -c "%s" --max-time 20%s%s -d "%s" "%s"',
cookie_jar(), cookie_jar(), ref, hdrs, log_data, url) or nil
return run(cmd, log_cmd)
end

--[[ ---------------- credentials ----------------
Username in a small plain-text file. The password is never written to
disk in plain text. VLC's Lua API has no credential store, so this
shells out, differently per OS:
- macOS: the system Keychain, via the `security` CLI. The password is
  only ever a (shell-escaped) `security` argument and Keychain's own
  storage, never a file on disk.
- Windows: DPAPI (what Credential Manager itself is built on), via
  PowerShell's ConvertTo-SecureString / ConvertFrom-SecureString: the
  result can only be decrypted by this Windows user account. The
  password goes into a temporary .ps1 script written with io.open (so it
  never appears on a command line or in the debug log), deleted right
  after it runs.

One-time migration: an old plain-text titulky_credentials.txt left by an
early version is read once, moved into secure storage, then deleted.
]]

local function username_file()
return vlc.config.userdatadir() .. "/titulky_username.txt"
end

local function old_creds_file()
return vlc.config.userdatadir() .. "/titulky_credentials.txt"
end

-- wraps a string as a double-quoted /bin/sh argument, escaping the 4
-- characters that matter inside double quotes there (\, ", $, `) - used
-- for every value handed to macOS's `security` command
local function sh_dquote(s)
s = string.gsub(s, "\\", "\\\\")
s = string.gsub(s, '"', '\\"')
s = string.gsub(s, "%$", "\\$")
s = string.gsub(s, "`", "\\`")
return '"' .. s .. '"'
end

-- wraps a string as a single-quoted PowerShell literal, doubling any
-- embedded single quote (PowerShell's own escape for '...' strings)
local function ps_squote(s)
return "'" .. string.gsub(s, "'", "''") .. "'"
end

local KEYCHAIN_SERVICE = "VLC Titulky Extension"

local function mac_save_password(username, password)
local cmd = string.format('security add-generic-password -a %s -s %s -w %s -U',
sh_dquote(username), sh_dquote(KEYCHAIN_SERVICE), sh_dquote(password))
local log_cmd = string.format('security add-generic-password -a %s -s %s -w *** -U',
sh_dquote(username), sh_dquote(KEYCHAIN_SERVICE))
run(cmd, log_cmd)
end

local function mac_load_password(username)
if username == "" then return "" end
local cmd = string.format('security find-generic-password -a %s -s %s -w 2>/dev/null',
sh_dquote(username), sh_dquote(KEYCHAIN_SERVICE))
local out = run(cmd)
if not out then return "" end
-- security prints the password followed by exactly one trailing newline
return (string.gsub(out, "\r?\n$", ""))
end

local function win_password_file()
return vlc.config.userdatadir() .. "/titulky_password.dat"
end

local function win_save_password(password)
local script_path = vlc.config.userdatadir() .. "/titulky_pwtmp.ps1"
local script = "$s = ConvertTo-SecureString -String " .. ps_squote(password) .. " -AsPlainText -Force\n"
.. "$enc = ConvertFrom-SecureString -SecureString $s\n"
.. "Set-Content -Path " .. ps_squote(win_password_file()) .. " -Value $enc -NoNewline\n"
local f = io.open(script_path, "w")
if not f then return end
f:write(script)
f:close()
run(string.format('powershell -NoProfile -ExecutionPolicy Bypass -File "%s"', script_path),
'powershell -NoProfile -ExecutionPolicy Bypass -File "(save-password script, contents not logged)"')
os.remove(script_path)
end

local function win_load_password()
local existing = io.open(win_password_file(), "r")
if not existing then return "" end
existing:close()

local script_path = vlc.config.userdatadir() .. "/titulky_pwtmp_read.ps1"
local script = "$enc = Get-Content -Path " .. ps_squote(win_password_file()) .. " -Raw\n"
.. "$s = ConvertTo-SecureString -String $enc\n"
.. "$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)\n"
.. "[System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)\n"
local sf = io.open(script_path, "w")
if not sf then return "" end
sf:write(script)
sf:close()

-- run() only ever logs the COMMAND, never the output - so the
-- decrypted password (this call's stdout) never reaches the debug log
local out = run(string.format('powershell -NoProfile -ExecutionPolicy Bypass -File "%s"', script_path))
os.remove(script_path)
if not out then return "" end
return (string.gsub(out, "\r?\n$", ""))
end

save_credentials = function(username, password)
local f = io.open(username_file(), "w")
if f then
f:write(username .. "\n")
f:close()
end
if is_windows() then
win_save_password(password)
else
mac_save_password(username, password)
end
end

load_credentials = function()
-- one-time migration off the old plain-text file, if it's still there
local old = io.open(old_creds_file(), "r")
if old then
local old_username = old:read("*l") or ""
local old_password = old:read("*l") or ""
old:close()
vlc.msg.dbg("[Titulky] found the old plain-text credentials file - migrating to secure storage and deleting it")
save_credentials(old_username, old_password)
os.remove(old_creds_file())
return old_username, old_password
end

local f = io.open(username_file(), "r")
if not f then return "", "" end
local username = f:read("*l") or ""
f:close()
if username == "" then return "", "" end

local password = is_windows() and win_load_password() or mac_load_password(username)
return username, password
end

-- fresh login, returns true/false. Always starts from an empty cookie
-- jar. premium.titulky.com has its own login, separate from
-- www.titulky.com - sessions don't carry over.
local function login(username, password)
os.remove(cookie_jar())

local post_data = "LoginName=" .. urlencode(username)
.. "&LoginPassword=" .. urlencode(password)
-- what actually gets logged - password redacted
local log_data = "LoginName=" .. urlencode(username) .. "&LoginPassword=***"

local result = post("https://premium.titulky.com/", post_data, nil, nil, log_data)
if result == nil then
vlc.msg.dbg("[Titulky] login POST returned nothing - curl didn't run or timed out")
return false
end

-- on success the page shows "Odhlásit" (log out); a snippet of the body
-- is logged too (no credentials in it) for troubleshooting
local ok = string.find(result, "Odhlásit", 1, true) ~= nil
local snippet = string.gsub(result, "%s+", " ")
snippet = string.sub(snippet, 1, 300)
vlc.msg.dbg("[Titulky] login response: " .. #result .. " bytes, 'Odhlásit' "
.. (ok and "found (login OK)" or "NOT found (login failed)")
.. " - body: " .. snippet)
return ok
end

--[[ ---------------- parsing ----------------
premium.titulky.com's tables are parsed by splitting rows into <td> cells
and reading them by position. Two tables in play:

Search results (title matches), 3 columns: checkbox, title (a <small>
badge + the title link), alternative names.

A title's "Alternativní titulky" table, 6 columns: checkbox, title
link, date, author link, release tag, checkbox.
]]

local function td_cells(row_html)
local cells = {}
for cell in string.gmatch(row_html, "<td.-</td>") do
table.insert(cells, cell)
end
return cells
end

local function cell_text(cell)
if not cell then return nil end
local inner = string.match(cell, "^<td.->(.*)</td>$") or cell
inner = string.gsub(inner, "<[^>]+>", "")
inner = decode_entities(inner)
inner = string.match(inner, "^%s*(.-)%s*$")
if inner == "" then return nil end
return inner
end

local function parse_premium_titles(html)
local out = {}
html = decode_entities(html)
for row_body in string.gmatch(html, '<tr class="pbl%d">(.-)</tr>') do
local cells = td_cells(row_body)
local title_cell, alt_cell = cells[2], cells[3]
local id = title_cell and string.match(title_cell, "action=detail&id=(%d+)")
local title = title_cell and string.match(title_cell, "<a[^>]->%s*([^<]+)%s*</a>")
if id and title then
table.insert(out, {
id = id,
title = string.match(title, "^%s*(.-)%s*$"),
alt = cell_text(alt_cell),
})
end
end
vlc.msg.dbg("[Titulky] premium title search -> " .. #out .. " match(es)")
return out
end

-- combines the title's "primary" release (reconstructed with a plain-
-- text heuristic - see file header) with its alternates table
local function parse_premium_detail(html, primary_id, primary_title)
html = decode_entities(html)
local dl_pos = string.find(html, "download%.php%?id=")
local top_html = dl_pos and string.sub(html, 1, dl_pos) or html
local rest_html = dl_pos and string.sub(html, dl_pos) or ""

local plain = string.gsub(top_html, "<[^>]+>", "\n")
local lines = {}
for line in string.gmatch(plain, "[^\n]+") do
line = string.match(line, "^%s*(.-)%s*$")
if line ~= "" then table.insert(lines, line) end
end

-- Every page opens with the site's logo as plain text "premium." +
-- "Titulky", and "premium." alone matches the release-tag pattern below.
-- So the scan starts after the line with the film's own title (known
-- from the search step), so the header can't match. Falls back to
-- scanning every line if the title isn't found verbatim (e.g. HTML
-- entities or whitespace differ from the search result's copy).
local scan_from = 1
if primary_title and primary_title ~= "" then
local needle = string.lower(primary_title)
for i, line in ipairs(lines) do
if string.find(string.lower(line), needle, 1, true) then
scan_from = i + 1
break
end
end
end

-- heuristic: the release tag reads like a scene-release token
-- (letters/digits/dots/hyphens, no spaces, at least one dot/hyphen) -
-- e.g. "UHD.BluRay", "WEBRip-NeoNoir" - excluding the site's own
-- branding text in case scan_from above didn't find the title line.
--
-- Also requires at least one letter: the upload date (e.g. "2.5.2027")
-- sits right after the title, before the real release tag, and would
-- otherwise match too. A real scene tag always has letters in it.
local release_tag = nil
for i = scan_from, #lines do
local line = lines[i]
local lower = string.lower(line)
if string.find(line, "^[%w%.%-]+$") and string.find(line, "[%.%-]") and string.find(line, "%a")
and lower ~= "premium." and not string.find(lower, "premium%.titulky", 1, true) then
release_tag = line
break
end
end

local out = {
{ id = primary_id, title = primary_title, date = nil, author = nil,
release = release_tag or "top result" },
}

for row_body in string.gmatch(rest_html, '<tr class="pbl%d">(.-)</tr>') do
local cells = td_cells(row_body)
local title_cell = cells[2]
local id = title_cell and string.match(title_cell, "id=(%d+)")
if id then
table.insert(out, {
id = id,
title = cell_text(title_cell) or primary_title,
date = cell_text(cells[3]),
author = cell_text(cells[4]),
release = cell_text(cells[5]),
})
end
end

vlc.msg.dbg("[Titulky] premium detail id=" .. tostring(primary_id) .. " -> " .. #out .. " release(s)")
return out
end

local function format_premium_label(row)
local label = row.title or "?"
if row.release and row.release ~= "" then label = label .. " [" .. row.release .. "]" end
if row.date then label = label .. " - " .. row.date end
if row.author then label = label .. " (" .. row.author .. ")" end
return label
end

--[[ ---------------- zip extraction ----------------
premium.titulky.com always wraps the actual subtitle in a zip. Extracted
with the system unzip (macOS/Linux) or tar (bundled with Windows 10
1803+, and able to extract zips).
]]

local SUBTITLE_EXTS = { srt = true, ass = true, ssa = true, sub = true, vtt = true }

local function extract_first_subtitle(zip_path)
local dest_dir = vlc.config.userdatadir() .. "/titulky_extract_" .. tostring(os.time())

if is_windows() then
run('mkdir "' .. dest_dir .. '" 2>nul')
run(string.format('tar -xf "%s" -C "%s"', zip_path, dest_dir))
else
run('mkdir -p "' .. dest_dir .. '"')
run(string.format('unzip -o -j "%s" -d "%s"', zip_path, dest_dir))
end

local listing
if is_windows() then
listing = run('dir /b "' .. dest_dir .. '"') or ""
else
listing = run('ls -1 "' .. dest_dir .. '"') or ""
end

local best = nil
for fname in string.gmatch(listing, "[^\r\n]+") do
local ext = string.match(fname, "%.([%a]+)$")
if ext and SUBTITLE_EXTS[string.lower(ext)] then
best = fname
break
end
if not best then best = fname end
end
if not best or best == "" then return nil end
return dest_dir .. "/" .. best
end

--[[ ---------------- actions ---------------- ]]

-- clears the search box and results - also the 3rd button in the row,
-- see the comment above show_dialog() for why that matters for width
function do_clear()
search_input:set_text("")
sub_rows = {}
pending_row = nil
results_list:clear()
status_label:set_text("Cleared. Type a title and hit Search.")
end

function do_search()
local username = user_input:get_text()
local password = pass_input:get_text()
local query = search_input:get_text()

if username == "" or password == "" then
status_label:set_text("Needs a premium titulky.com login - enter it above.")
return
end
if query == "" then
status_label:set_text("Type a title to search for.")
return
end

save_credentials(username, password)

status_label:set_text("Logging in...")
dlg:update()
if not login(username, password) then
status_label:set_text("Login failed (see debug log) - check username/password.")
return
end

status_label:set_text("Searching...")
dlg:update()
local html = get("https://premium.titulky.com/?Fulltext=" .. urlencode(query)
.. "&exact=&Autor=&Rok=&IMDB=&Serial=&Jazyk=&ASchvalene=&action=search")
if html == nil then
status_label:set_text("Search request failed to run (see debug log).")
return
end

local titles = parse_premium_titles(html)

if #titles == 0 then
sub_rows = {}
results_list:clear()
status_label:set_text("No results found.")
elseif #titles == 1 then
show_releases_for_title(titles[1].id, titles[1].title)
else
sub_rows = {}
results_list:clear()
for i, t in ipairs(titles) do
t.kind = "title"
table.insert(sub_rows, t)
results_list:add_value(t.title .. (t.alt and (" (" .. t.alt .. ")") or ""), i)
end
status_label:set_text(#titles .. " titles matched - select one, then Download to see releases.")
end
end

function show_releases_for_title(id, title)
-- kept short on purpose - the window only fits so much text on this
-- label (see the comment above show_dialog()), and the title is
-- already visible in the Search box / results list above, so it's
-- not repeated here
status_label:set_text("Loading releases...")
dlg:update()

local html = get("https://premium.titulky.com/?action=detail&id=" .. urlencode(id))
if html == nil then
status_label:set_text("Couldn't load releases (see debug log).")
return
end

sub_rows = parse_premium_detail(html, id, title)
for _, row in ipairs(sub_rows) do row.kind = "release" end

results_list:clear()
for i, row in ipairs(sub_rows) do
results_list:add_value(format_premium_label(row), i)
end

if #sub_rows == 0 then
status_label:set_text("No downloadable releases found (see debug log).")
else
status_label:set_text(#sub_rows .. " release(s) found - select one, then Download.")
end
end

function do_download_start()
local sel = results_list:get_selection()
local idx = nil
for id, _ in pairs(sel) do idx = id break end
if idx == nil or sub_rows[idx] == nil then
status_label:set_text("Select something from the list first.")
return
end
local row = sub_rows[idx]

if row.kind == "title" then
show_releases_for_title(row.id, row.title)
return
end

pending_row = row
status_label:set_text("Downloading...")
dlg:update()

local zip_path = vlc.config.userdatadir() .. "/titulky_last_sub.zip"
local cmd = string.format('curl -sS -L -b "%s" --max-time 60 -o "%s" "https://premium.titulky.com/download.php?id=%s"',
cookie_jar(), zip_path, urlencode(row.id))
local out, err = run(cmd)
if out == nil then
status_label:set_text("curl did not run: " .. tostring(err))
return
end

local zip_size = nil
local zf = io.open(zip_path, "rb")
if zf then
zip_size = zf:seek("end")
zf:close()
end
vlc.msg.dbg("[Titulky] download.php?id=" .. tostring(row.id) .. " -> " .. tostring(zip_size) .. " bytes at " .. zip_path)

status_label:set_text(hf_finish({
tag = "[Titulky]", prefix = "titulky", body_path = zip_path, ext = "srt",
name_stem = "titulky_" .. row.id,
}))

pending_row = nil
end
