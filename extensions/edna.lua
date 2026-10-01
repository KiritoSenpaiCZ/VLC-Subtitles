--[[
Edna.cz Subtitles - VLC extension

Search a show, pick a season and an episode, download the subtitle and
load it into whatever is playing.

Site notes:
- edna.cz has a show -> season -> episode hierarchy, and the whole
  season/episode listing requires being logged in.
- Login is a Nette form: a hidden "form_created" anti-spam token must come
  from a fresh GET of the login page, the "spam" honeypot field must be
  sent empty, and the form must not be submitted too soon (see login()).
- Each episode can have 0, 1 or 2 flags (Czech/Slovak), each pointing either
  to an edna.cz page (internal) or straight to titulky.com (external).
  The language comes from the flag's icon class ("flag-cz"/"flag-sk").
- An internal page's real file is its "?direct=1" link. It can be a raw
  .srt/.ass or a .zip, so the download step handles both.
- External subtitles are marked EXTERNAL and their link is copied to the
  clipboard; they are never downloaded.
- Whole-season bulk download is deliberately not supported.
]]

function descriptor()
	return {
		title = "Edna Subtitles v1.1.3",
		version = "1.1.3",
		author = "Highflight Studio",
		shortdesc = "Edna subtitles",
		description = "Search edna.cz and download/apply subtitles.",
		capabilities = {}
	}
end

local dlg = nil
local user_input, pass_input, search_input = nil, nil, nil
local results_list = nil
local status_label = nil
local initial_status_text = ""
-- credentials as last loaded/saved, so they're only re-saved (a PowerShell
-- run on Windows, ~1 s) when they actually changed
local creds_saved_user, creds_saved_pass = nil, nil

-- current_stage: "search" (shows), "seasons", or "episodes"
local current_stage = "search"
local shows = {}     -- [n] = {title=, path=}          path e.g. "/hra-o-truny/"
local seasons = {}   -- [n] = {season=N}
local episodes = {}  -- [n] = {ep_label=, lang=, href=, internal=(bool)}
local current_show = nil
local current_season = nil

-- defined in the credentials section further down, after the helpers
-- they need
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

Login reuse (hf_login / hf_login_refresh): a successful login (the cookie
jar) is reused until it has gone unused for HF_LOGIN_REUSE_SECONDS,
instead of logging in on every click. Fewer requests per click also keeps
each step well away from the ~10 s that makes VLC 3 hang on Windows. If a
page then looks logged out, the caller asks hf_login_refresh for one
fresh login and tries again. hf_remember_credentials saves the login only
when it changed (on Windows every save runs PowerShell, about 1 s).
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

-- On Windows every command-line tool started from VLC (curl, tar,
-- PowerShell) opens its own black window for a moment, because VLC has no
-- console. Giving VLC one console of its own and hiding it right away
-- makes later tools run inside it instead: at most one short flash when
-- the extension opens, none after that. Calling this again (or from
-- another extension) is harmless: the console already exists.
local function hf_quiet_console(tag)
	if not hf_is_windows() or not (vlc.win and vlc.win.console_init) then return end
	local ok, err = pcall(vlc.win.console_init)
	if not ok then
		hf_log(tag, "couldn't create the hidden console: " .. tostring(err))
		return
	end
	hf_run(tag, "powershell -NoProfile -WindowStyle Hidden -Command exit")
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

local HF_LOGIN_REUSE_SECONDS = 15 * 60
local hf_login_user, hf_login_used_at, hf_login_reused = nil, 0, false
local hf_saved_user, hf_saved_pass = nil, nil

-- Logs in with login_fn(username, password) unless an earlier login of
-- the same user can be reused. Returns true when logged in.
local function hf_login(username, password, login_fn)
	if hf_login_user == username and os.time() - hf_login_used_at < HF_LOGIN_REUSE_SECONDS then
		hf_login_used_at = os.time()
		hf_login_reused = true
		return true
	end
	hf_login_reused = false
	if login_fn(username, password) then
		hf_login_user, hf_login_used_at = username, os.time()
		return true
	end
	hf_login_user = nil
	return false
end

-- Call when a result looks logged out. If the last hf_login only reused an
-- earlier login, logs in fresh and returns true: try the request again.
local function hf_login_refresh(tag, username, password, login_fn)
	if not hf_login_reused then return false end
	hf_log(tag, "reused login looks expired, logging in again")
	hf_login_user = nil
	return hf_login(username, password, login_fn)
end

-- Saves the login with save_fn only when it differs from the last saved or
-- loaded one. Call with save_fn = nil to just record what was loaded.
local function hf_remember_credentials(save_fn, username, password)
	if username == hf_saved_user and password == hf_saved_pass then return end
	if save_fn then save_fn(username, password) end
	hf_saved_user, hf_saved_pass = username, password
end

-- true when a downloaded file is a web page (e.g. a login page) rather
-- than a subtitle or zip
local function hf_looks_like_page(path)
	local f = io.open(path, "rb")
	if not f then return false end
	local head = f:read(512) or ""
	f:close()
	return string.match(head, "^%s*<") ~= nil or string.find(string.lower(head), "<html", 1, true) ~= nil
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

local warm_up -- assigned further down, after the login helpers it uses

function activate()
	pcall(hf_quiet_console, "[Edna]")
	pcall(hf_cleanup_old, "[Edna]", "edna")
	show_dialog()
	local ok, err = pcall(warm_up)
	if not ok then vlc.msg.dbg("[Edna] warm-up failed: " .. tostring(err)) end
end

function deactivate()
	if dlg then dlg:delete() end
end

function close()
	vlc.deactivate()
end

-- best-effort guess at a show title from the currently playing file,
-- so the search box starts pre-filled
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
	name = string.gsub(name, "%.%w+$", "")      -- drop file extension
	name = string.gsub(name, "%[[^%]]*%]", " ") -- drop [tags]
	name = string.gsub(name, "%([^%)]*%)", " ") -- drop (tags)
	name = string.gsub(name, "[%._]", " ")      -- dots/underscores -> spaces

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

	name = string.gsub(name, "%s%-%s*%d+.*$", "") -- drop trailing "- 05..." episode marker
	name = string.gsub(name, "[%-–—]+%s*$", "")   -- drop a leftover trailing dash
	name = string.gsub(name, "%s+", " ")
	name = string.match(name, "^%s*(.-)%s*$")     -- trim

	if name == "" then return nil end
	return name
end

function show_dialog()
	dlg = vlc.dialog("Edna Subtitles v1.1.3")
	local saved_username, saved_password = load_credentials()
	local guessed_title = guess_title_from_playing()

	dlg:add_label("Username:", 1, 1, 1, 1)
	user_input = dlg:add_text_input(saved_username, 2, 1, 3, 1)
	dlg:add_label("Password:", 1, 2, 1, 1)
	pass_input = dlg:add_password(saved_password, 2, 2, 3, 1)

	dlg:add_label("Search:", 1, 3, 1, 1)
	search_input = dlg:add_text_input(guessed_title or "", 2, 3, 3, 1)

	dlg:add_button("Search", do_search, 1, 4, 1, 1)
	dlg:add_button("View Seasons", do_view_seasons, 2, 4, 1, 1)
	dlg:add_button("View Episodes", do_view_episodes, 3, 4, 1, 1)
	dlg:add_button("Download Selected", do_download, 4, 4, 1, 1)

	results_list = dlg:add_list(1, 5, 4, 1)
	local initial_status = guessed_title
		and ("Guessed '" .. guessed_title .. "' from the playing file - edit if wrong, then Search.")
		or "Enter credentials + a show title, then Search."
	initial_status_text = initial_status
	creds_saved_user, creds_saved_pass = saved_username, saved_password
	status_label = dlg:add_label(initial_status, 1, 6, 4, 1)
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

local function cookie_jar()
	return vlc.config.userdatadir() .. "/edna_cookies.txt"
end

-- log_line, if given, is logged INSTEAD OF cmd - keeps credentials out of
-- VLC's debug console. Also captures curl's stderr (io.popen only captures
-- stdout by default) and logs it whenever it's non-empty, for diagnostics
-- if a request silently fails to do what it should.
local function run(cmd, log_line)
	vlc.msg.dbg("[Edna] running: " .. (log_line or cmd))
	local stderr_file = vlc.config.userdatadir() .. "/edna_stderr.tmp"
	local full_cmd = cmd .. ' 2>"' .. stderr_file .. '"'
	local p = io.popen(full_cmd, "r")
	if not p then return nil, "io.popen failed to start curl" end
	local out = p:read("*a")
	p:close()
	local sf = io.open(stderr_file, "r")
	if sf then
		local err_text = sf:read("*a") or ""
		sf:close()
		os.remove(stderr_file)
		if err_text ~= "" then
			vlc.msg.dbg("[Edna] curl stderr: " .. err_text)
		end
	end
	return out
end

-- Reports whether the cookie jar file exists at all, and if so its size
-- and line count - distinguishes "curl never wrote the file" (a real
-- write/permission failure) from "curl wrote the file but there were
-- genuinely no cookies to save" (only the 1-2 boilerplate comment lines
-- curl always includes). Byte size and line count aren't sensitive -
-- actual cookie values are never touched here, same as jar_cookie_names().
local function jar_status()
	local f = io.open(cookie_jar(), "rb")
	if not f then return "jar file does not exist" end
	local content = f:read("*a") or ""
	f:close()
	local lines = 0
	for _ in string.gmatch(content, "[^\n]+") do lines = lines + 1 end
	return string.format("jar file exists: %d bytes, %d line(s)", #content, lines)
end

local function is_windows()
	return package.config:sub(1, 1) == "\\"
end

local function copy_to_clipboard(text)
	local cmd = is_windows() and "clip" or "pbcopy"
	local p = io.popen(cmd, "w")
	if not p then return false end
	p:write(text)
	p:close()
	return true
end

-- edna.cz needs a realistic browser User-Agent to behave normally.
local USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

-- The login POST also needs Origin plus a few Sec-Fetch-* headers that
-- curl doesn't send by default, or the site's anti-spam check rejects it
-- even with correct credentials. Left off the GET helper below since a
-- real browser only sends Origin on POST/form-submit navigations.
local POST_EXTRA_HEADERS = ' -H "Origin: https://www.edna.cz"'
	.. ' -H "Accept-Language: cs-CZ,cs;q=0.9,en;q=0.8"'
	.. ' -H "Sec-Fetch-Site: same-origin"'
	.. ' -H "Sec-Fetch-Mode: navigate"'
	.. ' -H "Sec-Fetch-User: ?1"'
	.. ' -H "Sec-Fetch-Dest: document"'

local function get(url, referer)
	local ref = referer and string.format(' -e "%s"', referer) or ""
	local cmd = string.format('curl -sS -L %s -A "%s" -b "%s" -c "%s"%s "%s"', HF_CURL_PAGE, USER_AGENT, cookie_jar(), cookie_jar(), ref, url)
	return run(cmd)
end

local function post(url, data, referer, log_data)
	local ref = referer and string.format(' -e "%s"', referer) or ""
	local data_opt, data_file = hf_post_file("edna", data)
	local cmd = string.format('curl -sS -L %s -A "%s"%s -b "%s" -c "%s"%s %s "%s"',
		HF_CURL_PAGE, USER_AGENT, POST_EXTRA_HEADERS, cookie_jar(), cookie_jar(), ref, data_opt, url)
	local log_cmd = log_data and (cmd .. " (data: " .. log_data .. ")") or nil
	local out, err = run(cmd, log_cmd)
	os.remove(data_file)
	return out, err
end

local function extract_attr(attr_str, name)
	return string.match(attr_str, name .. '="([^"]*)"')
end

--[[ ---------------- credentials ----------------
Username in a small plain-text file. The password is never written to
disk in plain text: macOS Keychain via the `security` CLI, or on Windows,
DPAPI via a short-lived PowerShell temp script.
]]

local function username_file()
	return vlc.config.userdatadir() .. "/edna_username.txt"
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

local KEYCHAIN_SERVICE = "VLC Edna Extension"

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
	return vlc.config.userdatadir() .. "/edna_password.dat"
end

local function win_save_password(password)
	local script_path = vlc.config.userdatadir() .. "/edna_pwtmp.ps1"
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

	local script_path = vlc.config.userdatadir() .. "/edna_pwtmp_read.ps1"
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

-- reads the cookie jar file (Netscape format) and returns a count plus
-- the cookie names found (not values - values can be session secrets).
-- Used purely for diagnostics: if this comes back empty after the login
-- page GET, curl isn't even getting a session cookie from the server,
-- which would point at something other than username/password/token
-- being wrong (e.g. a bot-detection layer curl doesn't satisfy).
-- Note: curl writes HttpOnly cookies (both of edna.cz's are) with a
-- "#HttpOnly_" prefix. Those lines are real cookies, not comments.
local function jar_cookie_names()
	local f = io.open(cookie_jar(), "r")
	if not f then return {} end
	local names = {}
	for line in f:lines() do
		local is_comment = string.sub(line, 1, 1) == "#" and string.sub(line, 1, 10) ~= "#HttpOnly_"
		if line ~= "" and not is_comment then
			local parts = {}
			for p in string.gmatch(line, "[^\t]+") do table.insert(parts, p) end
			if parts[6] then table.insert(names, parts[6]) end
		end
	end
	f:close()
	return names
end

-- lists every <input>'s name/type (and value, except passwords) found in
-- a chunk of form HTML - lets us confirm the real login form doesn't
-- require some field we're not sending (an extra token, a checkbox, etc).
local function extract_form_fields(form_html)
	local fields = {}
	for attrs in string.gmatch(form_html, "<input%s+([^>]-)/?>") do
		local name = extract_attr(attrs, "name")
		if name then
			local ftype = extract_attr(attrs, "type") or "text"
			local value = (ftype == "password") and "***" or (extract_attr(attrs, "value") or "")
			table.insert(fields, name .. "=" .. value .. " [" .. ftype .. "]")
		end
	end
	return fields
end

-- Login reuse: a login costs a 6 s anti-spam pause, and a step that blocks
-- VLC for ~10 s makes VLC 3 hang on Windows. So: log in once,
-- keep the cookie jar, and only log in again if a page comes back without
-- the logout link that every logged-in edna.cz page has.
local session_user = nil
local saved_session_checked = false -- set by warm_up() when the dialog opens

-- The cookie jar survives VLC restarts, and the login ticks "keep me logged
-- in", so a new VLC session can usually skip the slow login entirely. This
-- file records which account the saved jar belongs to.
local function session_user_file()
	return vlc.config.userdatadir() .. "/edna_session_user.txt"
end

local function read_saved_session_user()
	local f = io.open(session_user_file(), "r")
	if not f then return nil end
	local u = f:read("*l")
	f:close()
	return (u and u ~= "") and u or nil
end

local function is_logged_in_page(html)
	return html ~= nil and (string.find(html, "do=logout", 1, true) ~= nil
		or string.find(html, "Odhlásit", 1, true) ~= nil)
end

-- Edna's login form has an anti-spam timer (see login() below): it must not
-- be submitted until several seconds after it was loaded. A step that takes
-- ~10 s makes VLC 3 hang on Windows, so the form is loaded ahead of time,
-- when the dialog opens, and the timer runs while the user reads/types.
-- login() then only waits for whatever is left of the delay, usually
-- nothing.
local LOGIN_FORM_DELAY = 6        -- seconds the form must "age" before submit
local PREPARED_MAX_AGE = 15 * 60  -- reload a prepared form older than this
local prepared = nil              -- { form_created =, at = os.time() }

local function prepare_login()
	prepared = nil
	session_user = nil
	os.remove(session_user_file())
	os.remove(cookie_jar())
	vlc.msg.dbg("[Edna] login: " .. jar_status() .. " (right after removing it - should not exist yet)")

	-- Visit the homepage first, like a real visitor would, before going
	-- straight to the login page - the site hands out session cookies
	-- during general browsing, not just on the login page itself.
	get("https://www.edna.cz/")
	vlc.msg.dbg("[Edna] login: cookies after homepage visit: " .. table.concat(jar_cookie_names(), ", ") .. " -- " .. jar_status())

	local login_page = get("https://www.edna.cz/uzivatel/prihlaseni/")
	if login_page == nil then return false end
	vlc.msg.dbg("[Edna] login: fetched login page, " .. #login_page .. " bytes")
	vlc.msg.dbg("[Edna] login: cookies after GET: " .. table.concat(jar_cookie_names(), ", ") .. " -- " .. jar_status())

	-- Scrape the login form's anti-spam "form_created" token from a fresh
	-- GET of the login page.
	local form_created = nil
	local action_idx = string.find(login_page, "loginForm%-submit")
	if action_idx then
		local form_start = nil
		local search_from = 1
		while true do
			local f = string.find(login_page, "<form", search_from)
			if not f or f > action_idx then break end
			form_start = f
			search_from = f + 1
		end
		local form_end = string.find(login_page, "</form>", action_idx) or #login_page
		if form_start then
			local form_html = string.sub(login_page, form_start, form_end)
			for attrs in string.gmatch(form_html, "<input%s+([^>]-)/?>") do
				if extract_attr(attrs, "name") == "form_created" then
					form_created = extract_attr(attrs, "value")
				end
			end
			vlc.msg.dbg("[Edna] login: real form fields: " .. table.concat(extract_form_fields(form_html), " | "))
		end
	end
	if not form_created then
		vlc.msg.dbg("[Edna] login: form_created token not found inside the login form (see debug log for a page snippet)")
		vlc.msg.dbg("[Edna] login page snippet: " .. string.sub(login_page, 1, 300))
	else
		vlc.msg.dbg("[Edna] login: scraped form_created=" .. form_created)
	end

	if not form_created then return false end
	local at_us = nil -- VLC's precise clock (microseconds), when available
	pcall(function() at_us = vlc.misc.mdate() end)
	prepared = { form_created = form_created, at = os.time(), at_us = at_us, page = login_page }
	return true
end

local function login(username, password)
	if not prepared or os.time() - prepared.at > PREPARED_MAX_AGE then
		if not prepare_login() then return false end
	end
	local form_created = prepared.form_created
	local login_page = prepared.page or "" -- kept for the failure diagnostics below

	-- The "spam" honeypot field must be sent back empty.
	local post_data = "spam="
		.. "&nick=" .. urlencode(username)
		.. "&password=" .. urlencode(password)
		.. "&keep=on"
		.. "&send=" .. urlencode("Přihlásit se")
		.. "&form_created=" .. urlencode(form_created or "")
	local log_data = "spam="
		.. "&nick=" .. urlencode(username)
		.. "&password=***"
		.. "&keep=on"
		.. "&send=" .. urlencode("Přihlásit se")
		.. "&form_created=" .. urlencode(form_created or "")

	-- Edna's login form uses the Nette AntiSpam add-on: form_created encodes
	-- when the form was rendered (9999999999 minus the unix time, digits
	-- written as letters a-j), and a form submitted only moments later is
	-- rejected as a bot ("Byl detekovan pokus o spam"). So wait like a
	-- person filling it in would.
	-- A fixed wait rather than one computed from the token, so a PC clock
	-- that's off can't break it.
	-- precise when VLC's clock is available; otherwise whole seconds (+1
	-- because os.time() can't see fractions)
	local remaining = LOGIN_FORM_DELAY + 1 - (os.time() - prepared.at)
	if prepared.at_us then
		pcall(function() remaining = LOGIN_FORM_DELAY - (vlc.misc.mdate() - prepared.at_us) / 1000000 end)
	end
	if remaining > 0 then
		pcall(function()
			status_label:set_text("Logging in to Edna (its anti-spam check needs a " .. math.ceil(remaining) .. " s pause)...")
			dlg:update()
		end)
		vlc.msg.dbg("[Edna] login: waiting " .. string.format("%.1f", remaining) .. " s before submitting (anti-spam form timer)")
		local waited = false
		if vlc.misc and vlc.misc.mwait and vlc.misc.mdate then
			waited = pcall(function() vlc.misc.mwait(vlc.misc.mdate() + math.floor(remaining * 1000000)) end)
		end
		if not waited then
			local stop = os.time() + math.ceil(remaining)
			while os.time() < stop do end
		end
	else
		vlc.msg.dbg("[Edna] login: form was loaded " .. (os.time() - prepared.at) .. " s ago, no wait needed")
	end
	prepared = nil -- a form token is used once

	local result = post("https://www.edna.cz/uzivatel/prihlaseni/?do=loginForm-submit", post_data,
		"https://www.edna.cz/uzivatel/prihlaseni/", log_data)
	if result == nil then return false end
	vlc.msg.dbg("[Edna] login: cookies after POST: " .. table.concat(jar_cookie_names(), ", ") .. " -- " .. jar_status())

	local ok = string.find(result, "do=logout", 1, true) ~= nil
		or string.find(result, "Odhlásit", 1, true) ~= nil
	if ok then
		session_user = username
		local f = io.open(session_user_file(), "w")
		if f then
			f:write(username .. "\n")
			f:close()
		end
	end
	vlc.msg.dbg("[Edna] login " .. (ok and "succeeded" or "failed") .. " (response " .. #result .. " bytes, login page was " .. #login_page .. " bytes)")
	if not ok then
		-- diagnostics: is the login form still present (meaning we bounced back to the login page,
		-- likely a rejected token or wrong credentials), and does the
		-- page contain any obvious Czech error text?
		local still_login_form = string.find(result, "loginForm%-submit") ~= nil
		vlc.msg.dbg("[Edna] login failure diagnostics: still_on_login_form=" .. tostring(still_login_form))
		for _, needle in ipairs({
			"neplatn", "špatn", "chyba", "Chyba", "expirovala", "vypršel",
			"nesprávn", "účet", "zablokov", "pokus", "limit", "robot", "captcha", "Captcha"
		}) do
			local pos = string.find(result, needle)
			if pos then
				vlc.msg.dbg("[Edna] login failure text near '" .. needle .. "': " .. string.sub(result, math.max(1, pos - 60), pos + 60))
			end
		end
		-- find the first byte where the POST response actually diverges from
		-- the plain GET of the same page - whatever got inserted/changed
		-- (almost certainly the real error message) shows up right there,
		-- regardless of what language or wording it uses.
		local min_len = math.min(#login_page, #result)
		local diff_at = min_len + 1
		for i = 1, min_len do
			if string.byte(login_page, i) ~= string.byte(result, i) then
				diff_at = i
				break
			end
		end
		vlc.msg.dbg("[Edna] login: GET vs POST first differ at byte " .. diff_at
			.. ": " .. string.sub(result, math.max(1, diff_at - 80), diff_at + 200))
	end
	return ok
end

--[[ ---------------- parsing ---------------- ]]

-- returns ordered list of {title=, path=} - only the "Seriály" (TV
-- series) section of the search results, since movies don't have the
-- season/episode structure this extension needs
local function parse_search_results(html)
	local out = {}
	local start_idx = string.find(html, '<h2 class="pushed">Seriály</h2>', 1, true)
	if not start_idx then return out end
	local end_idx = string.find(html, "<h2", start_idx + 1) or #html
	local section = string.sub(html, start_idx, end_idx)
	for path, title in string.gmatch(section, '<h3 class="h4"><a href="([^"]+)">([^<]+)</a></h3>') do
		table.insert(out, {title = decode_entities(title), path = path})
	end
	return out
end

-- returns ordered list of {season=N}. We always fetch season=1 to
-- discover the list (guaranteed to exist for any show with subtitles),
-- so season 1 itself is added explicitly - the page's own season nav
-- only links to the OTHER seasons (its own current season is plain text,
-- not a link).
local function parse_seasons(html)
	local seen = {[1] = true}
	for href, num in string.gmatch(html, 'href="([^"]+/titulky/%?season=(%d+))"') do
		num = tonumber(num)
		if num then seen[num] = true end
	end
	local nums = {}
	for n in pairs(seen) do table.insert(nums, n) end
	table.sort(nums)
	local rows = {}
	for _, n in ipairs(nums) do table.insert(rows, {season = n}) end
	return rows
end

-- returns list of {ep_label=, lang=, href=, internal=(bool)} - one entry
-- per (episode, language) flag found. An episode can have 0, 1 or 2
-- flags; each is independently internal (edna.cz-hosted) or external
-- (titulky.com), identified purely by the href, with language read from
-- the flag icon's own class ("flag-cz"/"flag-sk").
local function parse_episodes(html)
	local rows = {}
	local row_count = 0
	local flag_count = 0

	for row_html in string.gmatch(html, "<tr.-</tr>") do
		row_count = row_count + 1
		local ep_label = string.match(row_html, "(S%d%d?E%d%d?:%s*[^<]-)</a>")
		if ep_label then
			ep_label = decode_entities(ep_label)
			for attrs, lang in string.gmatch(row_html, '<a%s+([^>]-)>%s*<i class="flag%-(%a%a)"') do
				local href = extract_attr(attrs, "href")
				if href then
					flag_count = flag_count + 1
					local internal = string.sub(href, 1, 1) == "/"
					local full_href = internal and ("https://www.edna.cz" .. href) or href
					table.insert(rows, {
						ep_label = ep_label,
						lang = lang,
						href = full_href,
						internal = internal
					})
				end
			end
		end
	end

	vlc.msg.dbg("[Edna] parsed " .. row_count .. " <tr> rows, " .. flag_count .. " subtitle flag(s) found")
	return rows
end

--[[ ---------------- actions ---------------- ]]

-- logs in only if this username isn't logged in already
local function ensure_login(username, password)
	if session_user ~= nil and session_user == username then
		vlc.msg.dbg("[Edna] reusing the existing login session")
		return true
	end
	-- new VLC session: the saved cookie jar may still be logged in (one
	-- quick page load instead of the ~10 s login with its 6 s pause)
	if read_saved_session_user() == username and not saved_session_checked then
		local home = get("https://www.edna.cz/")
		if is_logged_in_page(home) then
			session_user = username
			vlc.msg.dbg("[Edna] still logged in from a previous VLC session, skipping the login")
			return true
		end
		vlc.msg.dbg("[Edna] saved session has expired, logging in again")
	end
	return login(username, password)
end

-- GET a page that needs a logged-in session; if the site logged us out in
-- the meantime, log in again once and retry
local function get_logged_in(url, username, password)
	local html = get(url)
	if html == nil or is_logged_in_page(html) then return html end
	vlc.msg.dbg("[Edna] page came back logged out, logging in again")
	if not login(username, password) then return nil end
	return get(url)
end

-- Runs right after the dialog opens: checks a saved login from an earlier
-- VLC session, or loads the login form ahead of time so its anti-spam timer
-- is already running when the user clicks Search (see prepare_login()).
warm_up = function()
	status_label:set_text("Connecting to Edna...")
	dlg:update()
	local username = user_input:get_text()
	if username ~= "" and read_saved_session_user() == username then
		saved_session_checked = true
		if is_logged_in_page(get("https://www.edna.cz/")) then
			session_user = username
			vlc.msg.dbg("[Edna] still logged in from a previous VLC session")
			status_label:set_text(initial_status_text)
			return
		end
		vlc.msg.dbg("[Edna] saved session has expired, loading the login form in advance")
	end
	if prepare_login() then
		vlc.msg.dbg("[Edna] login form loaded in advance (anti-spam timer started)")
	end
	status_label:set_text(initial_status_text)
end

function do_search()
	local username = user_input:get_text()
	local password = pass_input:get_text()
	local query = search_input:get_text()

	if username == "" or password == "" then
		status_label:set_text("Enter your edna.cz username and password first.")
		return
	end
	if query == "" then
		status_label:set_text("Type a show title to search for.")
		return
	end

	if username ~= creds_saved_user or password ~= creds_saved_pass then
		save_credentials(username, password)
		creds_saved_user, creds_saved_pass = username, password
	end

	status_label:set_text("Logging in...")
	dlg:update()
	if not ensure_login(username, password) then
		status_label:set_text("Login failed (see debug log) - check username/password.")
		return
	end

	status_label:set_text("Searching...")
	dlg:update()
	local html = get("https://www.edna.cz/vyhledavani/?q=" .. urlencode(query))
	if html == nil then
		status_label:set_text("Search request failed to run (see debug log).")
		return
	end

	shows = parse_search_results(html)
	vlc.msg.dbg("[Edna] search '" .. query .. "' -> " .. #shows .. " show(s)")

	results_list:clear()
	for i, s in ipairs(shows) do
		results_list:add_value(s.title, i)
	end
	current_stage = "search"

	if #shows == 0 then
		status_label:set_text("No series found for '" .. query .. "' (only TV series are supported, not movies).")
	else
		status_label:set_text(#shows .. " show(s). Select one, then click 'View Seasons'.")
	end
end

function do_view_seasons()
	if current_stage ~= "search" then
		status_label:set_text("Search first, then select a show from the list.")
		return
	end
	local sel = results_list:get_selection()
	local idx = nil
	for id, _ in pairs(sel) do idx = id break end
	if idx == nil or shows[idx] == nil then
		status_label:set_text("Select a show from the list first.")
		return
	end
	current_show = shows[idx]

	status_label:set_text("Loading season list...")
	dlg:update()

	local username = user_input:get_text()
	local password = pass_input:get_text()
	if not ensure_login(username, password) then
		status_label:set_text("Login failed - can't load the Titulky tab (see debug log).")
		return
	end

	local html = get_logged_in("https://www.edna.cz" .. current_show.path .. "titulky/?season=1", username, password)
	if html == nil then
		status_label:set_text("Request failed to run (see debug log).")
		return
	end

	seasons = parse_seasons(html)

	results_list:clear()
	for i, se in ipairs(seasons) do
		results_list:add_value("Sezóna " .. se.season, i)
	end
	current_stage = "seasons"

	if #seasons == 0 then
		status_label:set_text("No seasons found for '" .. current_show.title .. "' (see debug log).")
	else
		status_label:set_text(#seasons .. " season(s) for '" .. current_show.title .. "'. Select one, then View Episodes.")
	end
end

function do_view_episodes()
	if current_stage ~= "seasons" then
		status_label:set_text("View seasons first, then select one from the list.")
		return
	end
	local sel = results_list:get_selection()
	local idx = nil
	for id, _ in pairs(sel) do idx = id break end
	if idx == nil or seasons[idx] == nil then
		status_label:set_text("Select a season from the list first.")
		return
	end
	current_season = seasons[idx].season

	status_label:set_text("Loading episode list...")
	dlg:update()

	local username = user_input:get_text()
	local password = pass_input:get_text()
	if not ensure_login(username, password) then
		status_label:set_text("Login failed - can't load the episode list (see debug log).")
		return
	end

	local html = get_logged_in("https://www.edna.cz" .. current_show.path .. "titulky/?season=" .. tostring(current_season), username, password)
	if html == nil then
		status_label:set_text("Request failed to run (see debug log).")
		return
	end

	episodes = parse_episodes(html)

	results_list:clear()
	for i, e in ipairs(episodes) do
		local prefix = e.internal and "" or "EXTERNAL - "
		results_list:add_value(prefix .. e.ep_label .. " [" .. string.upper(e.lang) .. "]", i)
	end
	current_stage = "episodes"

	if #episodes == 0 then
		status_label:set_text("No subtitle flags found for season " .. current_season .. " (see debug log).")
	else
		status_label:set_text(#episodes .. " subtitle(s) for season " .. current_season .. ". Select one, then Download.")
	end
end

function do_download()
	if current_stage ~= "episodes" then
		status_label:set_text("View episodes first, then select a subtitle to download.")
		return
	end
	local sel = results_list:get_selection()
	local idx = nil
	for id, _ in pairs(sel) do idx = id break end
	if idx == nil or episodes[idx] == nil then
		status_label:set_text("Select a subtitle from the list first.")
		return
	end
	local row = episodes[idx]

	if not row.internal then
		if copy_to_clipboard(row.href) then
			status_label:set_text("External subtitle (titulky.com) - link copied to the clipboard.")
		else
			search_input:set_text(row.href)
			status_label:set_text("External subtitle - clipboard copy failed, link put in the search box instead.")
		end
		return
	end

	status_label:set_text("Downloading...")
	dlg:update()

	local username = user_input:get_text()
	local password = pass_input:get_text()
	if not ensure_login(username, password) then
		status_label:set_text("Login failed - can't download (see debug log).")
		return
	end

	-- row.href is the episode's titulky page (with a "#content" fragment
	-- that's only meaningful in a browser) - the real file is that same
	-- page's "?direct=1" fallback link.
	local direct_url = string.gsub(row.href, "#.*$", "") .. "?direct=1"

	local userdir = vlc.config.userdatadir()
	local header_file = userdir .. "/edna_last_headers.txt"
	local body_file = userdir .. "/edna_last_sub.tmp"

	local cmd = string.format(
		'curl -sS -L %s -A "%s" -b "%s" -c "%s" -e "%s" -D "%s" -o "%s" "%s"',
		HF_CURL_DOWNLOAD, USER_AGENT, cookie_jar(), cookie_jar(), direct_url, header_file, body_file, direct_url
	)
	local out, err = run(cmd)
	if out == nil then
		status_label:set_text("curl did not run: " .. tostring(err))
		return
	end

	local hf = io.open(header_file, "r")
	local header_text = hf and hf:read("*a") or ""
	if hf then hf:close() end

	local bf = io.open(body_file, "rb")
	local body_sample = bf and bf:read(200) or ""
	if bf then bf:close() end

	if body_sample == nil or body_sample == "" then
		status_label:set_text("Download failed - empty response (see debug log). Try again in a moment.")
		vlc.msg.dbg("[Edna] download got empty body for " .. row.ep_label .. " [" .. row.lang .. "]")
		return
	end

	local ext = ".srt"
	local cd_filename = string.match(header_text, 'filename%*?=[^\'"]*[\'"]?([^\'";\r\n]+)')
	if cd_filename then
		local cd_ext = string.match(cd_filename, "%.([%a]+)$")
		if cd_ext then ext = "." .. cd_ext end
	elseif string.find(body_sample, "^%s*%[Script Info%]") then
		ext = ".ass"
	end
	os.remove(header_file)
	local result_text = hf_finish({
		tag = "[Edna]", prefix = "edna", body_path = body_file, ext = ext,
		name_stem = "edna_" .. string.gsub(row.ep_label, "[^%w]+", "_") .. "_" .. row.lang,
	})
	if string.find(result_text, "web page", 1, true) then
		session_user = nil -- probably logged out: the next click logs in fresh
		result_text = result_text .. " If this keeps happening, click Search again to log in fresh."
	end
	status_label:set_text(result_text)
end
