--[[
Hiyori.cz Subtitles - VLC extension

Search a show, browse its subtitle list, download a subtitle and load it
into whatever is playing. Subtitles hosted on other fansub sites are
marked EXTERNAL and their link is copied to the clipboard instead.

The login is reused between clicks (see hf_login in the download handling
block); login() itself always starts from an empty cookie jar.
]]

function descriptor()
	return {
		title = "Hiyori Subtitles v1.3.1",
		version = "1.3.1",
		author = "Highflight Studio",
		shortdesc = "Hiyori subtitles",
		description = "Search hiyori.cz and download/apply subtitles.",
		capabilities = {}
	}
end

local dlg = nil
local user_input, pass_input, search_input = nil, nil, nil
local results_list = nil
local status_label = nil

-- current_stage: "search" (results_list holds anime matches, id = anime id)
-- or "subs" (results_list holds subtitle rows, id = index into sub_rows)
local current_stage = "search"
local sub_rows = {} -- [n] = {ep=, title=, lang=, fansub=, href=, internal=(bool)}
local current_anime_title = ""

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
-- The same PowerShell call also reports the Windows display language.
--
-- The UI is in Czech when the system language is Czech or Slovak, and in
-- English otherwise. hf_start runs both when the extension opens.
local hf_lang = "en"

-- L("english", "czech", ...): the text for the UI language, with %s
-- placeholders filled in like string.format
local function L(en, cs, ...)
	return string.format((hf_lang == "cs") and cs or en, ...)
end

local function hf_language_of(code)
	code = string.lower(code or "")
	if string.match(code, "^%s*cs") or string.match(code, "^%s*sk") then return "cs" end
	return "en"
end

local function hf_start(tag)
	local env = os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or os.getenv("LANG")
	if hf_is_windows() then
		if vlc.win and vlc.win.console_init then
			local ok, err = pcall(vlc.win.console_init)
			if not ok then hf_log(tag, "couldn't create the hidden console: " .. tostring(err)) end
		end
		local culture = hf_run(tag, 'powershell -NoProfile -WindowStyle Hidden -Command "(Get-UICulture).Name"')
		hf_lang = hf_language_of(culture)
	elseif env and env ~= "" and env ~= "C" and env ~= "POSIX" and not string.match(env, "^C%.") then
		hf_lang = hf_language_of(env)
	else
		-- macOS apps started from the Dock or Finder get no LANG
		local langs = hf_run(tag, "defaults read -g AppleLanguages 2>/dev/null") or ""
		hf_lang = hf_language_of(string.match(langs, '"?([%a%-_]+)'))
	end
	hf_log(tag, "UI language: " .. hf_lang)
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
	if not data or #data == 0 then return false, L("empty response", "prázdná odpověď") end
	if #data > HF_MAX_DOWNLOAD_BYTES then return false, L("larger than a subtitle should be", "soubor je na titulky příliš velký") end
	local head = string.gsub(string.sub(data, 1, 512), "^\239\187\191", "")
	if string.match(head, "^%s*<") then return false, L("the site returned a web page instead of a subtitle", "stránka místo titulků vrátila webovou stránku") end
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
		return L("Download failed: %s. Try again in a moment.", "Stažení selhalo: %s. Zkuste to za chvíli znovu.", reason)
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
			return done(L("Downloaded a zip but it looks broken or unsafe (see debug log).", "ZIP se stáhl, ale vypadá poškozeně nebo nebezpečně (podrobnosti v logu)."))
		end
		if total > HF_MAX_EXTRACTED_BYTES then
			hf_log(tag, "zip refused: " .. total .. " bytes uncompressed")
			return done(L("Download refused: the archive is far too large when unpacked.", "Stažení odmítnuto: archiv by byl po rozbalení příliš velký."))
		end
		if encrypted and (not o.zip_password or o.zip_password == "") then
			hf_log(tag, "zip is password-protected and no zip password is set")
			return done(L("This zip needs a password - fill in the zip password field, then download again.", "Tento ZIP potřebuje heslo - vyplňte heslo k ZIPu a stáhněte znovu."))
		end
		local zip_path = hf_join(work, "download.zip")
		hf_write(zip_path, data)
		src = hf_extract(tag, zip_path, hf_join(work, "extract"), o.zip_password, encrypted)
		if not src then
			return done(encrypted
					and L("Couldn't unpack the zip - check the zip password (see debug log).", "ZIP se nepodařilo rozbalit - zkontrolujte heslo k ZIPu (podrobnosti v logu).")
					or L("Downloaded a zip but found no subtitle inside (see debug log).", "ZIP se stáhl, ale nejsou v něm žádné titulky (podrobnosti v logu)."))
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
		return done(L("Downloaded, but couldn't save into %s (see debug log).", "Staženo, ale nepodařilo se uložit do %s (podrobnosti v logu).", dest_dir))
	end
	hf_log(tag, "saved subtitle to " .. final_path)

	if hf_attach(final_path) then
		return done(L("Downloaded and applied: %s", "Staženo a načteno: %s", final_name))
	end
	return done(L("Saved to %s (no video playing, open one and add it manually).", "Uloženo do %s (nehraje žádné video, otevřete ho a titulky přidejte ručně).", final_path))
end
-- <<< shared block "hf_download"

function activate()
	pcall(hf_start, "[Hiyori]")
	pcall(hf_cleanup_old, "[Hiyori]", "hiyori")
	show_dialog()
end

function deactivate()
	if dlg then dlg:delete() end
end

function close()
	vlc.deactivate()
end

-- best-effort guess at a show title from the currently playing file,
-- so the search box starts pre-filled - VLC 3.x has no event to trigger
-- an actual automatic search, so this is "auto-fill", not "auto-search"
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

	-- release names pack a lot of extra info the site's search chokes on
	-- (season/episode markers, resolution, source, codec, audio, release
	-- group) - cut everything from the earliest one of these onward, so
	-- "Show Name S02E01 1080p BluRay Dual-Audio Opus 2 0 x265-GROUP"
	-- becomes just "Show Name"
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
	name = string.gsub(name, "[%-–—]+%s*$", "") -- drop a leftover trailing dash
	name = string.gsub(name, "%s+", " ")
	name = string.match(name, "^%s*(.-)%s*$") -- trim

	if name == "" then return nil end
	return name
end

-- >>> shared block "season_title" - edit dev/shared/season_title.lua in VLC-Subtitles, then run dev/sync.py
-- removes a season / cour ending from a show title and returns the base
-- title plus the season number (nil when none), e.g. "Tensei Shitara Slime
-- Datta Ken 4th Season Part 1 & 2" -> "Tensei Shitara Slime Datta Ken", 4.
-- The site searches need every word to match, so the full name finds
-- nothing. "Part N" (a cour split) is dropped without giving a season.
local SEASON_SEP = "[%s:%-]*"
local SEASON_PARTS = {
	"%f[%a]part%s*%d+%s*&%s*%d+%s*$",
	"%f[%a]part%s*%d+%s*and%s*%d+%s*$",
	"%f[%a]part%s*%d+%s*%+%s*%d+%s*$",
	"%f[%a]part%s*%d+%s*$",
}
local SEASON_ENDINGS = {
	"%f[%w](%d%d?)%a%a%s+season$",
	"%f[%a]season%s*(%d%d?)$",
	"%f[%a]s(%d%d?)$",
}

local function season_cut(text, patterns)
	local lower = string.lower(text)
	for _, p in ipairs(patterns) do
		local s, _, n = string.find(lower, SEASON_SEP .. p)
		if s then return string.sub(text, 1, s - 1), n end
	end
	return text, nil
end

local function split_season_title(title)
	if not title then return title, nil end
	local base = string.match(title, "^%s*(.-)%s*$")
	base = season_cut(base, SEASON_PARTS)
	local base2, n = season_cut(base, SEASON_ENDINGS)
	base = season_cut(base2, SEASON_PARTS)
	base = string.gsub(base, "[%s:%-]+$", "")
	base = string.match(base, "^%s*(.-)%s*$")
	if base == "" then return title, nil end
	return base, n and tonumber(n) or nil
end

-- puts the entries whose own title names the wanted season (a title without
-- one counts as season 1) first, keeping the order otherwise
local function season_first(items, season, title_of)
	if not season then return items end
	local wanted, rest = {}, {}
	for _, item in ipairs(items) do
		local _, n = split_season_title(title_of(item) or "")
		table.insert((n or 1) == season and wanted or rest, item)
	end
	for _, item in ipairs(rest) do table.insert(wanted, item) end
	return wanted
end
-- <<< shared block "season_title"

function show_dialog()
	dlg = vlc.dialog("Hiyori Subtitles v1.3.1")
	local saved_username, saved_password = load_credentials()
	hf_remember_credentials(nil, saved_username, saved_password)
	local guessed_title = guess_title_from_playing()

	dlg:add_label(L("Username:", "Uživatelské jméno:"), 1, 1, 1, 1)
	user_input = dlg:add_text_input(saved_username, 2, 1, 2, 1)
	dlg:add_label(L("Password:", "Heslo:"), 1, 2, 1, 1)
	pass_input = dlg:add_password(saved_password, 2, 2, 2, 1)

	dlg:add_label(L("Search:", "Hledat:"), 1, 3, 1, 1)
	search_input = dlg:add_text_input(guessed_title or "", 2, 3, 2, 1)
	dlg:add_button(L("Search", "Hledat"), do_search, 1, 4, 1, 1)
	dlg:add_button(L("View Subtitles", "Zobrazit titulky"), do_view_subs, 2, 4, 1, 1)
	dlg:add_button(L("Download Selected", "Stáhnout vybrané"), do_download, 3, 4, 1, 1)

	results_list = dlg:add_list(1, 5, 3, 1)
	local initial_status = guessed_title
		and L("Guessed '%s' from the playing file - edit if wrong, then Search.", "Odhadnutý název „%s“ podle přehrávaného souboru - případně ho upravte a klikněte na Hledat.", guessed_title)
		or L("Enter credentials + a show title, then Search.", "Zadejte přihlašovací údaje a název anime, pak klikněte na Hledat.")
	status_label = dlg:add_label(initial_status, 1, 6, 3, 1)
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
	vlc.msg.dbg("[Hiyori] running: " .. (log_line or cmd))
	local p = io.popen(cmd, "r")
	if not p then return nil, "io.popen failed to start curl" end
	local out = p:read("*a")
	p:close()
	return out
end

local function cookie_jar()
	return vlc.config.userdatadir() .. "/hiyori_cookies.txt"
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

--[[ ---------------- credentials ----------------
Username in a small plain-text file. The password is never written to
disk in plain text: macOS Keychain via the `security` CLI, or on Windows,
DPAPI via a short-lived PowerShell temp script.
]]

local function username_file()
	return vlc.config.userdatadir() .. "/hiyori_username.txt"
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

local KEYCHAIN_SERVICE = "VLC Hiyori Extension"

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
	return vlc.config.userdatadir() .. "/hiyori_password.dat"
end

local function win_save_password(password)
	local script_path = vlc.config.userdatadir() .. "/hiyori_pwtmp.ps1"
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

	local script_path = vlc.config.userdatadir() .. "/hiyori_pwtmp_read.ps1"
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

-- fresh login, returns true/false
local function login(username, password)
	local post_data = "username=" .. urlencode(username)
		.. "&Password=" .. urlencode(password)
		.. "&remember_me=1"
	local log_data = "username=" .. urlencode(username) .. "&Password=***&remember_me=1"
	local data_opt, data_file = hf_post_file("hiyori", post_data)
	local cmd = string.format(
		'curl -sS -L %s -c "%s" %s "https://hiyori.cz/account/login"',
		HF_CURL_PAGE, cookie_jar(), data_opt
	)
	local out = run(cmd, cmd .. " (data: " .. log_data .. ")")
	os.remove(data_file)
	return out ~= nil
end

local function get(url)
	local cmd = string.format('curl -sS %s -b "%s" "%s"', HF_CURL_PAGE, cookie_jar(), url)
	return run(cmd)
end

--[[ ---------------- parsing ---------------- ]]

-- returns ordered list of {id=, title=}
local function parse_search_results(html)
	local out = {}
	for id, title in string.gmatch(html, 'href="/anime/(%d+)"%s+title="([^"]+)"') do
		table.insert(out, {id = tonumber(id), title = decode_entities(title)})
	end
	return out
end

local function extract_attr(attr_str, name)
	return string.match(attr_str, name .. '="([^"]*)"')
end

-- scans every <a ...> tag in a row and returns the href of whichever one
-- is the actual download button - identified by class containing
-- "btn-primary" or onclick starting with "Download", not by exact
-- attribute-string match (attribute order/extra classes vary by page)
local function find_download_link(row_html)
	for attrs in string.gmatch(row_html, "<a%s+([^>]-)>") do
		local class = extract_attr(attrs, "class") or ""
		local href = extract_attr(attrs, "href")
		local onclick = extract_attr(attrs, "onclick") or ""
		if href and (string.find(class, "btn-primary", 1, true) or string.find(onclick, "^Download")) then
			return href
		end
	end
	return nil
end

-- returns list of row tables, plus debug counters
local function parse_subtitle_rows(html)
	local rows = {}
	local row_count = 0
	local skipped = 0

	for row_html in string.gmatch(html, "<tr.-</tr>") do
		row_count = row_count + 1

		local lang = string.match(row_html, "<td[^>]*>%s*(CZ)%s*</td>")
			or string.match(row_html, "<td[^>]*>%s*(SK)%s*</td>")
		-- episode number + episode title: content-based, not a fixed column
		-- index (column order/count has drifted on this site before) - the
		-- title td always sits directly after the short bare-digit episode
		-- number td
		local ep, title = string.match(row_html, "<td[^>]*>%s*(%d%d?%d?)%s*</td>%s*<td[^>]*>%s*([^<]-)%s*</td>")
		local href = find_download_link(row_html)

		if not lang or not href then
			skipped = skipped + 1
			vlc.msg.dbg("[Hiyori] skipped row " .. row_count .. " (lang=" .. tostring(lang) .. " href=" .. tostring(href) .. ")")
		else
			local internal = string.find(href, "^/anime/downloadsubtitles") ~= nil
			table.insert(rows, {
					ep = ep or "?",
					lang = lang,
					title = decode_entities(title) or "?",
					href = internal and ("https://hiyori.cz" .. href) or href,
					internal = internal
				})
			vlc.msg.dbg("[Hiyori] row " .. row_count .. " OK: ep=" .. tostring(ep) .. " lang=" .. lang .. " title=" .. tostring(title) .. " internal=" .. tostring(internal))
		end
	end

	vlc.msg.dbg("[Hiyori] parsed " .. row_count .. " <tr> rows, " .. #rows .. " usable, " .. skipped .. " skipped")
	return rows
end

--[[ ---------------- actions ---------------- ]]

function do_search()
	local username = user_input:get_text()
	local password = pass_input:get_text()
	local query = search_input:get_text()

	if username == "" or password == "" then
		status_label:set_text(L("Enter your hiyori.cz username and password first.", "Nejdřív zadejte své uživatelské jméno a heslo k hiyori.cz."))
		return
	end
	if query == "" then
		status_label:set_text(L("Type a show title to search for.", "Napište název, který chcete hledat."))
		return
	end

	hf_remember_credentials(save_credentials, username, password)

	status_label:set_text(L("Logging in...", "Přihlašuji se..."))
	dlg:update()
	if not hf_login(username, password, login) then
		status_label:set_text(L("Login request failed to run (see debug log).", "Přihlášení se nepodařilo spustit (podrobnosti v logu)."))
		return
	end

	status_label:set_text(L("Searching...", "Hledám..."))
	dlg:update()
	local base, season = split_season_title(query)
	local search_url = "https://hiyori.cz/rozcestnik?nazev=" .. urlencode(base)
	local html = get(search_url)
	if html == nil then
		status_label:set_text(L("Search request failed to run (see debug log).", "Hledání se nepodařilo spustit (podrobnosti v logu)."))
		return
	end

	local matches = parse_search_results(html)
	if #matches == 0 and hf_login_refresh("[Hiyori]", username, password, login) then
		html = get(search_url)
		matches = html and parse_search_results(html) or {}
	end
	matches = season_first(matches, season, function(m) return m.title end)
	vlc.msg.dbg("[Hiyori] search '" .. query .. "' -> " .. #matches .. " matches")

	results_list:clear()
	for _, m in ipairs(matches) do
		results_list:add_value(m.title, m.id)
	end
	current_stage = "search"

	if #matches == 0 then
		status_label:set_text(L("No results for '%s'.", "Pro „%s“ nebylo nic nalezeno.", query))
	else
		status_label:set_text(L("%s result(s). Select one, then click 'View Subtitles'.", "Výsledky: %s. Vyberte jeden a klikněte na „Zobrazit titulky“.", #matches))
	end
end

function do_view_subs()
	if current_stage ~= "search" then
		status_label:set_text(L("Do a search first, then select a show from the list.", "Nejdřív vyhledávejte, pak vyberte pořad ze seznamu."))
		return
	end
	local sel = results_list:get_selection()
	local anime_id = nil
	for id, text in pairs(sel) do
		anime_id = id
		current_anime_title = text
		break
	end
	if anime_id == nil then
		status_label:set_text(L("Select a show from the list first.", "Nejdřív vyberte pořad ze seznamu."))
		return
	end

	status_label:set_text(L("Loading subtitle list...", "Načítám seznam titulků..."))
	dlg:update()

	local username = user_input:get_text()
	local password = pass_input:get_text()
	hf_login(username, password, login)

	local anime_page = "https://hiyori.cz/anime/" .. tostring(anime_id)
	local html = get(anime_page)
	if html == nil then
		status_label:set_text(L("Request failed to run (see debug log).", "Požadavek se nepodařilo spustit (podrobnosti v logu)."))
		return
	end

	sub_rows = parse_subtitle_rows(html)
	if #sub_rows == 0 and hf_login_refresh("[Hiyori]", username, password, login) then
		html = get(anime_page)
		sub_rows = html and parse_subtitle_rows(html) or {}
	end

	results_list:clear()
	for i, row in ipairs(sub_rows) do
		local prefix = row.internal and "" or L("EXTERNAL - ", "EXTERNÍ - ")
		local label = prefix .. "Ep " .. row.ep .. " [" .. row.lang .. "] " .. row.title
		results_list:add_value(label, i)
	end
	current_stage = "subs"

	if #sub_rows == 0 then
		status_label:set_text(L("No subtitle rows found/parsed for '%s' (see debug log).", "Pro „%s“ nebyly nalezeny žádné titulky (podrobnosti v logu).", current_anime_title))
	else
		status_label:set_text(L("%s subtitle(s) for '%s'. Select one, then Download.", "Nalezené titulky (%s) pro „%s“. Vyberte jedny a klikněte na Stáhnout.", #sub_rows, current_anime_title))
	end
end

local function guess_extension(header_text, body_sample)
	local fname = string.match(header_text or "", 'filename%*?=[^\'"]*[\'"]?([^\'";\r\n]+)')
	if fname then
		local ext = string.match(fname, "%.([%a]+)$")
		if ext then return "." .. ext, fname end
	end
	if string.find(body_sample or "", "^%s*%[Script Info%]") then return ".ass", nil end
	return ".srt", nil
end

function do_download()
	if current_stage ~= "subs" then
		status_label:set_text(L("View a show's subtitles first, then select one to download.", "Nejdřív zobrazte titulky, pak vyberte ty ke stažení."))
		return
	end
	local sel = results_list:get_selection()
	local idx = nil
	for id, _ in pairs(sel) do idx = id break end
	if idx == nil or sub_rows[idx] == nil then
		status_label:set_text(L("Select a subtitle from the list first.", "Nejdřív vyberte titulky ze seznamu."))
		return
	end
	local row = sub_rows[idx]

	if not row.internal then
		if copy_to_clipboard(row.href) then
			status_label:set_text(L("External subtitles - copied into the clipboard", "Externí titulky - odkaz je zkopírovaný do schránky"))
		else
			search_input:set_text(row.href)
			status_label:set_text(L("External subtitle - clipboard copy failed, link put in the search box instead.", "Externí titulky - kopírování do schránky selhalo, odkaz je místo toho v poli Hledat."))
		end
		return
	end

	status_label:set_text(L("Downloading...", "Stahuji..."))
	dlg:update()

	local username = user_input:get_text()
	local password = pass_input:get_text()
	hf_login(username, password, login)

	local userdir = vlc.config.userdatadir()
	local header_file = userdir .. "/hiyori_last_headers.txt"
	local body_file = userdir .. "/hiyori_last_sub.tmp"

	local cmd = string.format(
		'curl -sS %s -b "%s" -D "%s" -o "%s" "%s"',
		HF_CURL_DOWNLOAD, cookie_jar(), header_file, body_file, row.href
	)
	local out, err = run(cmd)
	if out ~= nil and hf_looks_like_page(body_file) and hf_login_refresh("[Hiyori]", username, password, login) then
		out, err = run(cmd)
	end
	if out == nil then
		status_label:set_text(L("curl did not run: %s", "curl se nepodařilo spustit: %s", tostring(err)))
		return
	end

	local hf = io.open(header_file, "r")
	local header_text = hf and hf:read("*a") or ""
	if hf then hf:close() end

	local bf = io.open(body_file, "r")
	local body_sample = bf and bf:read(200) or ""
	if bf then bf:close() end

	local ext = guess_extension(header_text, body_sample)
	os.remove(header_file)
	status_label:set_text(hf_finish({
				tag = "[Hiyori]", prefix = "hiyori", body_path = body_file, ext = ext,
				name_stem = "hiyori_ep" .. row.ep .. "_" .. row.lang,
			}))
end
