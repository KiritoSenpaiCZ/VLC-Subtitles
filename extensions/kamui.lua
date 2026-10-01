--[[
Kamui-Subs.cz Subtitles - VLC extension

Search a show, pick its season page, then an episode; the subtitle zip is
downloaded, unpacked and loaded into whatever is playing.

Site notes:
  - WordPress + Elementor + Ultimate Member (login) + WP Download Manager.
  - Each show/season is its OWN page - season 1 / a movie has no "S<n>"
    suffix at all.
  - Episode buttons are Elementor buttons: the href sits on the <a> tag,
    the visible label ("N. Dil") is two <span> levels deeper
    (elementor-button-text). The "Cela serie" (whole-season zip) link is
    deliberately skipped.
  - Login is Ultimate Member's default form at /log-in/: dynamically
    named fields username-<form_id>/user_password-<form_id> plus a
    freshly-scraped _wpnonce, POSTed back to /log-in/ itself. Success is
    a "wordpress_logged_in_*" cookie landing in the jar.
  - WordPress's own site search (?s=<query>) returns real show pages
    (article.type-page) alongside per-episode "download item" posts
    (article.type-lana_download), which are filtered out.
  - Every /download/<id>/ response is a .zip, protected with a fixed,
    site-wide password. It is deliberately NOT hardcoded here (published
    source shouldn't carry a real password, even a non-secret one): the
    user types it into the "Zip password" field once, and it's saved
    locally in plain text, like the username.

Zips are extracted with the system `unzip -P` (macOS/Linux) or the
`tar --passphrase` bundled with Windows 10 1803+.

Logs in fresh on every request (no session caching).
]]

function descriptor()
	return {
		title = "Kamui Subtitles v1.1.2",
		version = "1.1.2",
		author = "Highflight Studio",
		shortdesc = "Kamui-Subs subtitles",
		description = "Search kamui-subs.cz and download/apply subtitles.",
		capabilities = {}
	}
end

local dlg = nil
local user_input, pass_input, zippw_input, search_input = nil, nil, nil, nil
local results_list = nil
local status_label = nil

-- current_stage: "search" (results_list holds show/season page matches,
-- id = index into show_pages) or "episodes" (results_list holds episode
-- rows, id = index into ep_rows)
local current_stage = "search"
local show_pages = {} -- [n] = {title=, url=}
local ep_rows = {} -- [n] = {ep=, href=, label=}
local current_show_title = ""

-- defined in the credentials section further down
local save_credentials, load_credentials

-- >>> shared block "hf_download" - edit dev/shared/hf_download.lua in VLC-Subtitles, then run dev/sync.py
--[[ ---------------- download handling and curl helpers ----------------
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

HF_CURL_PAGE / HF_CURL_DOWNLOAD are time limits for every curl call, so a
site that stops answering can't freeze VLC for good. hf_post_file hands
POST data to curl through a temporary file, so passwords never appear on
a command line (where other programs could read them).
]]

local HF_MAX_DOWNLOAD_BYTES = 20 * 1024 * 1024
local HF_MAX_EXTRACTED_BYTES = 200 * 1024 * 1024
local HF_SUB_MAX_AGE_DAYS = 30
local HF_SUB_EXTS = { srt = true, ass = true, ssa = true, sub = true, vtt = true }
local HF_CURL_PAGE = "--connect-timeout 10 --max-time 20"
local HF_CURL_DOWNLOAD = "--connect-timeout 10 --max-time 60"

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

-- Writes POST data to a temporary file. Returns the curl option that sends
-- it, and the file to delete once curl has run.
local function hf_post_file(prefix, data)
	local path = hf_join(vlc.config.userdatadir(), prefix .. "_post.tmp")
	hf_write(path, data)
	return '--data-binary "@' .. path .. '"', path
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
-- <<< shared block "hf_download"

function activate()
	pcall(hf_cleanup_old, "[Kamui]", "kamui")
	show_dialog()
end

function deactivate()
	if dlg then dlg:delete() end
end

function close()
	vlc.deactivate()
end

-- best-effort guess at a show title from the currently playing file, so
-- the search box starts pre-filled
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
	name = string.gsub(name, "%.%w+$", "")
	name = string.gsub(name, "%[[^%]]*%]", " ")
	name = string.gsub(name, "%([^%)]*%)", " ")
	name = string.gsub(name, "[%._]", " ")

	local lower = string.lower(name)
	local cut_at = string.find(lower, "s%d%d?e%d%d?")
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
	name = string.gsub(name, "[%-\226\128\147\226\128\148]+%s*$", "")
	name = string.gsub(name, "%s+", " ")
	name = string.match(name, "^%s*(.-)%s*$")

	if name == "" then return nil end
	return name
end

function show_dialog()
	dlg = vlc.dialog("Kamui Subtitles v1.1.2")
	local saved_username, saved_password = load_credentials()
	local saved_zippw = load_zip_password()
	local guessed_title = guess_title_from_playing()

	dlg:add_label("Username:", 1, 1, 1, 1)
	user_input = dlg:add_text_input(saved_username, 2, 1, 2, 1)
	dlg:add_label("Password:", 1, 2, 1, 1)
	pass_input = dlg:add_password(saved_password, 2, 2, 2, 1)
	dlg:add_label("Zip password:", 1, 3, 1, 1)
	zippw_input = dlg:add_password(saved_zippw, 2, 3, 2, 1)

	dlg:add_label("Search:", 1, 4, 1, 1)
	search_input = dlg:add_text_input(guessed_title or "", 2, 4, 2, 1)
	dlg:add_button("Search", do_search, 1, 5, 1, 1)
	dlg:add_button("View Episodes", do_view_episodes, 2, 5, 1, 1)
	dlg:add_button("Download Selected", do_download, 3, 5, 1, 1)

	results_list = dlg:add_list(1, 6, 3, 1)
	local initial_status = guessed_title
		and ("Guessed '" .. guessed_title .. "' from the playing file - edit if wrong, then Search.")
		or "Enter your login, the zip password and a show title, then Search."
	status_label = dlg:add_label(initial_status, 1, 7, 3, 1)
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
	vlc.msg.dbg("[Kamui] running: " .. (log_line or cmd))
	local p = io.popen(cmd, "r")
	if not p then return nil, "io.popen failed to start" end
	local out = p:read("*a")
	p:close()
	return out
end

local function cookie_jar()
	return vlc.config.userdatadir() .. "/kamui_cookies.txt"
end

local function is_windows()
	return package.config:sub(1, 1) == "\\"
end

local function get(url, referer)
	local ref = referer and string.format(' -e "%s"', referer) or ""
	local cmd = string.format('curl -sS -L %s -b "%s" -c "%s"%s "%s"', HF_CURL_PAGE, cookie_jar(), cookie_jar(), ref, url)
	return run(cmd)
end

local function post(url, data, referer, log_data)
	local ref = referer and string.format(' -e "%s"', referer) or ""
	local data_opt, data_file = hf_post_file("kamui", data)
	local cmd = string.format('curl -sS -L %s -b "%s" -c "%s"%s %s "%s"', HF_CURL_PAGE, cookie_jar(), cookie_jar(), ref, data_opt, url)
	local log_cmd = log_data and (cmd .. " (data: " .. log_data .. ")") or nil
	local out, err = run(cmd, log_cmd)
	os.remove(data_file)
	return out, err
end

--[[ ---------------- credentials ----------------
Username in a small plain-text file. The account password is never
written to disk in plain text: macOS Keychain via the `security` CLI, or
on Windows, DPAPI via a short-lived PowerShell temp script. The zip
password is the same for every user (not a personal secret), so it's
stored as plain text, like the username.
]]

local function username_file()
	return vlc.config.userdatadir() .. "/kamui_username.txt"
end

local function zippw_file()
	return vlc.config.userdatadir() .. "/kamui_zippassword.txt"
end

local function sh_dquote(s)
	s = string.gsub(s, "\\", "\\\\")
	s = string.gsub(s, '"', '\\"')
	s = string.gsub(s, "%$", "\\$")
	s = string.gsub(s, "`", "\\`")
	return '"' .. s .. '"'
end

local function ps_squote(s)
	return "'" .. string.gsub(s, "'", "''") .. "'"
end

local KEYCHAIN_SERVICE = "VLC Kamui Extension"

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
	return (string.gsub(out, "\r?\n$", ""))
end

local function win_password_file()
	return vlc.config.userdatadir() .. "/kamui_password.dat"
end

local function win_save_password(password)
	local script_path = vlc.config.userdatadir() .. "/kamui_pwtmp.ps1"
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

	local script_path = vlc.config.userdatadir() .. "/kamui_pwtmp_read.ps1"
	local script = "$enc = Get-Content -Path " .. ps_squote(win_password_file()) .. " -Raw\n"
		.. "$s = ConvertTo-SecureString -String $enc\n"
		.. "$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)\n"
		.. "[System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)\n"
	local sf = io.open(script_path, "w")
	if not sf then return "" end
	sf:write(script)
	sf:close()

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
	local f = io.open(username_file(), "r")
	if not f then return "", "" end
	local username = f:read("*l") or ""
	f:close()
	if username == "" then return "", "" end

	local password = is_windows() and win_load_password() or mac_load_password(username)
	return username, password
end

function save_zip_password(pw)
	local f = io.open(zippw_file(), "w")
	if f then
		f:write(pw .. "\n")
		f:close()
	end
end

function load_zip_password()
	local f = io.open(zippw_file(), "r")
	if not f then return "" end
	local pw = f:read("*l") or ""
	f:close()
	return pw
end

-- fresh login every time. Ultimate Member names its username/password fields dynamically as
-- username-<form_id>/user_password-<form_id> and requires a fresh
-- _wpnonce scraped from the just-loaded form.
local function login(username, password)
	os.remove(cookie_jar())

	local login_page = get("https://kamui-subs.cz/log-in/")
	if login_page == nil then return false end

	local form_id = string.match(login_page, 'name="form_id"%s+[^>]-value="(%d+)"')
	if not form_id then
		form_id = string.match(login_page, 'id="form_id_(%d+)"')
	end
	if not form_id then
		vlc.msg.dbg("[Kamui] login: form_id not found on login page")
		return false
	end

	local nonce = string.match(login_page, 'name="_wpnonce"%s+[^>]-value="([0-9a-f]+)"')
	if not nonce then
		vlc.msg.dbg("[Kamui] login: _wpnonce not found on login page")
		return false
	end

	local referer = string.match(login_page, 'name="_wp_http_referer"%s+[^>]-value="([^"]*)"')
	referer = referer and decode_entities(referer) or "/log-in/"

	local post_data = "username-" .. form_id .. "=" .. urlencode(username)
		.. "&user_password-" .. form_id .. "=" .. urlencode(password)
		.. "&form_id=" .. form_id
		.. "&um_request="
		.. "&redirect_to=" .. urlencode("https://kamui-subs.cz/")
		.. "&_wpnonce=" .. urlencode(nonce)
		.. "&_wp_http_referer=" .. urlencode(referer)
	local log_data = "username-" .. form_id .. "=" .. urlencode(username)
		.. "&user_password-" .. form_id .. "=***"
		.. "&form_id=" .. form_id
		.. "&um_request="
		.. "&redirect_to=" .. urlencode("https://kamui-subs.cz/")
		.. "&_wpnonce=" .. urlencode(nonce)
		.. "&_wp_http_referer=" .. urlencode(referer)

	local result = post("https://kamui-subs.cz/log-in/", post_data, "https://kamui-subs.cz/log-in/", log_data)
	if result == nil then return false end

	-- success is a wordpress_logged_in_* cookie landing in the jar
	local jar = io.open(cookie_jar(), "r")
	if not jar then return false end
	local jar_contents = jar:read("*a") or ""
	jar:close()
	return string.find(jar_contents, "wordpress_logged_in_", 1, true) ~= nil
end

--[[ ---------------- parsing ---------------- ]]

-- returns [{title=, url=}] for real show/season pages only - WordPress's
-- own search also matches individual per-episode "download item" posts
-- (type-lana_download), which are filtered out here.
local function parse_search_results(html)
	local out = {}
	for attrs, block in string.gmatch(html, '<article(.-)>(.-)</article>') do
		if string.find(attrs, "type%-page") then
			local href, title = string.match(block, '<a%s+href="([^"]+)"[^>]->%s*([^<]-)%s*</a>')
			if href then
				table.insert(out, {url = href, title = decode_entities(title)})
			end
		end
	end
	return out
end

-- returns [{ep=, href=, label=}] - one per numbered episode button on the
-- show/season page ("Cela serie" whole-season zip is skipped). Each button is an Elementor
-- widget: href on the <a>, visible label two <span> levels deeper.
local function parse_episode_links(html)
	local rows = {}
	for href, inner in string.gmatch(html, '<a[^>]-href="(https://kamui%-subs%.cz/download/%d+/)"[^>]->(.-)</a>') do
		local label = string.match(inner, 'elementor%-button%-text">%s*([^<]-)%s*</span>')
		if label then
			label = decode_entities(label)
			local ep = string.match(label, "^(%d+)%s*%.%s*D")
			if ep then
				table.insert(rows, {ep = tonumber(ep), href = href, label = label})
			end
		end
	end
	return rows
end

--[[ ---------------- actions ---------------- ]]

function do_search()
	local username = user_input:get_text()
	local password = pass_input:get_text()
	local zip_password = zippw_input:get_text()
	local query = search_input:get_text()

	if username == "" or password == "" then
		status_label:set_text("Enter your kamui-subs.cz username and password first.")
		return
	end
	if query == "" then
		status_label:set_text("Type a show title to search for.")
		return
	end

	save_credentials(username, password)
	save_zip_password(zip_password)

	status_label:set_text("Logging in...")
	dlg:update()
	if not login(username, password) then
		status_label:set_text("Login failed (see debug log) - check username/password.")
		return
	end

	status_label:set_text("Searching...")
	dlg:update()
	local html = get("https://kamui-subs.cz/?s=" .. urlencode(query))
	if html == nil then
		status_label:set_text("Search request failed to run (see debug log).")
		return
	end

	show_pages = parse_search_results(html)
	vlc.msg.dbg("[Kamui] search '" .. query .. "' -> " .. #show_pages .. " page match(es)")

	results_list:clear()
	for i, s in ipairs(show_pages) do
		results_list:add_value(s.title, i)
	end
	current_stage = "search"

	if #show_pages == 0 then
		status_label:set_text("No results for '" .. query .. "'.")
	else
		status_label:set_text(#show_pages .. " page(s) matched (one per season). Select one, then 'View Episodes'.")
	end
end

function do_view_episodes()
	if current_stage ~= "search" then
		status_label:set_text("Do a search first, then select a show/season from the list.")
		return
	end
	local sel = results_list:get_selection()
	local idx = nil
	for id, _ in pairs(sel) do idx = id break end
	if idx == nil or show_pages[idx] == nil then
		status_label:set_text("Select a show/season from the list first.")
		return
	end
	local show = show_pages[idx]
	current_show_title = show.title

	status_label:set_text("Loading episode list...")
	dlg:update()

	local username = user_input:get_text()
	local password = pass_input:get_text()
	login(username, password)

	local html = get(show.url)
	if html == nil then
		status_label:set_text("Request failed to run (see debug log).")
		return
	end

	ep_rows = parse_episode_links(html)

	results_list:clear()
	for i, row in ipairs(ep_rows) do
		results_list:add_value(row.label, i)
	end
	current_stage = "episodes"

	if #ep_rows == 0 then
		status_label:set_text("No numbered episodes found on '" .. current_show_title .. "' (see debug log).")
	else
		status_label:set_text(#ep_rows .. " episode(s) for '" .. current_show_title .. "'. Select one, then Download.")
	end
end

function do_download()
	if current_stage ~= "episodes" then
		status_label:set_text("View a show's episodes first, then select one to download.")
		return
	end
	local sel = results_list:get_selection()
	local idx = nil
	for id, _ in pairs(sel) do idx = id break end
	if idx == nil or ep_rows[idx] == nil then
		status_label:set_text("Select an episode from the list first.")
		return
	end
	local row = ep_rows[idx]

	status_label:set_text("Downloading...")
	dlg:update()

	local username = user_input:get_text()
	local password = pass_input:get_text()
	local zip_password = zippw_input:get_text()
	save_zip_password(zip_password)
	if not login(username, password) then
		status_label:set_text("Login failed - can't download (see debug log).")
		return
	end

	local zip_path = vlc.config.userdatadir() .. "/kamui_last_sub.zip"
	local cmd = string.format('curl -sS -L %s -b "%s" -o "%s" "%s"', HF_CURL_DOWNLOAD, cookie_jar(), zip_path, row.href)
	local out, err = run(cmd)
	if out == nil then
		status_label:set_text("curl did not run: " .. tostring(err))
		return
	end

	local zf = io.open(zip_path, "rb")
	local zip_size = zf and zf:seek("end") or 0
	if zf then zf:close() end
	vlc.msg.dbg("[Kamui] " .. row.href .. " -> " .. tostring(zip_size) .. " bytes at " .. zip_path)

	if zip_size == 0 then
		status_label:set_text("Download failed - empty response (see debug log). Try again in a moment.")
		return
	end

	status_label:set_text(hf_finish({
				tag = "[Kamui]", prefix = "kamui", body_path = zip_path, ext = "srt",
				name_stem = "kamui_ep" .. row.ep, zip_password = zip_password,
			}))
end
