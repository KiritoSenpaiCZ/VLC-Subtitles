--[[
HNS (hns.sk) Subtitles - VLC extension

Search an anime, browse its subtitles, download one and load it into
whatever is playing.

Site notes:
- hns.sk hosts Czech and Slovak anime subtitles from several fansub
  groups. The site doesn't mark which of the two languages a subtitle is
  in.
- Every page needs a logged-in account (login is by e-mail). A
  logged-out request is redirected to /site/login, recognisable by its
  id="login-form". The login form posts _csrf, LoginForm[email],
  LoginForm[password] and LoginForm[rememberMe]; a logged-in page has a
  /site/logout link. The cookie jar is kept between runs, so the
  extension logs in only when the site asks for it.
- /animelist lists every anime (slug + title) on one page. It is cached
  for 24 hours (CATALOG_MAX_AGE).
- /anime/<slug> lists all episodes. Each episode is its own table: the
  header links to /anime/episode/<slug>/<episode id> with the text
  "<title> <episode number>", and every release row holds the release
  name, translator, date, version and a form with the subtitle id and
  file name.
- Downloading: the forms on the show page lack the "action" field (the
  site's JavaScript adds it), so the download goes through the episode
  page instead. Its form (id, name, _csrf, action=download) is posted back
  to the episode page and the response is the subtitle file itself.
]]

function descriptor()
	return {
		title = "HNS Subtitles v1.0.0",
		version = "1.0.0",
		author = "Highflight Studio",
		shortdesc = "HNS subtitles",
		description = "Search hns.sk and download/apply Czech and Slovak anime subtitles.",
		capabilities = {}
	}
end

local TAG = "[HNS]"
local BASE_URL = "https://hns.sk"
local CATALOG_MAX_AGE = 24 * 60 * 60

local dlg = nil
local email_input, pass_input, search_input, episode_input = nil, nil, nil, nil
local results_list = nil
local status_label = nil

-- current_stage: "search" (results_list holds shows, id = index into
-- show_matches) or "subs" (results_list holds releases, id = index into
-- releases)
local current_stage = "search"
local show_matches = {} -- [n] = {slug=, title=}
local releases = {} -- [n] = {episode=, episode_url=, sub_id=, name=, release=, translator=, version=}
local current_show = nil
-- the e-mail the cookie jar belongs to
local jar_email = nil

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
	pcall(hf_start, TAG)
	pcall(hf_cleanup_old, TAG, "hns")
	show_dialog()
end

function deactivate()
	if dlg then dlg:delete() end
end

function close()
	vlc.deactivate()
end

local function playing_name()
	if not (vlc.input and vlc.input.item) then return nil end
	local ok, item = pcall(vlc.input.item)
	if not ok or not item then return nil end
	local uri = item:uri()
	if not uri then return nil end
	local name = string.match(uri, "([^/\\]+)$") or uri
	if vlc.strings and vlc.strings.decode_uri then
		name = vlc.strings.decode_uri(name)
	end
	return (string.gsub(name, "%.%w+$", "")) -- drop file extension
end

-- best-effort guess at a show title from the currently playing file,
-- so the search box starts pre-filled
local function guess_title_from_playing()
	local name = playing_name()
	if not name then return nil end
	name = string.gsub(name, "%[[^%]]*%]", " ") -- drop [tags]
	name = string.gsub(name, "%([^%)]*%)", " ") -- drop (tags)
	name = string.gsub(name, "[%._]", " ") -- dots/underscores -> spaces

	-- cut everything from the earliest episode marker, resolution, source,
	-- codec or audio tag onward, so "Show Name S02E01 1080p BluRay x265"
	-- becomes "Show Name S02" (the season stays: it picks the right entry)
	local lower = string.lower(name)
	local cut_at = nil
	local se_start, _, season = string.find(lower, "s(%d%d?)e%d%d?")
	if se_start then
		name = string.sub(name, 1, se_start - 1) .. "S" .. tonumber(season) .. " "
		lower = string.lower(name)
	end
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

-- episode number from the playing file name: "S01E03" or "Title - 03 [..]"
local function guess_episode_from_playing()
	local name = playing_name()
	if not name then return nil end
	local ep = string.match(name, "[Ss]%d%d?[Ee](%d%d?%d?%d?)")
		or string.match(name, "%s%-%s*(%d%d?%d?%d?)%f[^%d]")
	return ep and tonumber(ep) or nil
end

function show_dialog()
	dlg = vlc.dialog("HNS Subtitles v1.0.0")
	local saved_email, saved_password = load_credentials()
	hf_remember_credentials(nil, saved_email, saved_password)
	jar_email = saved_email
	local guessed_title = guess_title_from_playing()
	local guessed_ep = guess_episode_from_playing()

	dlg:add_label(L("E-mail:", "E-mail:"), 1, 1, 1, 1)
	email_input = dlg:add_text_input(saved_email, 2, 1, 2, 1)
	dlg:add_label(L("Password:", "Heslo:"), 1, 2, 1, 1)
	pass_input = dlg:add_password(saved_password, 2, 2, 2, 1)

	dlg:add_label(L("Search:", "Hledat:"), 1, 3, 1, 1)
	search_input = dlg:add_text_input(guessed_title or "", 2, 3, 2, 1)
	dlg:add_label(L("Episode (optional):", "Epizoda (nepovinné):"), 1, 4, 1, 1)
	episode_input = dlg:add_text_input(guessed_ep and tostring(guessed_ep) or "", 2, 4, 2, 1)
	dlg:add_button(L("Search", "Hledat"), do_search, 1, 5, 1, 1)
	dlg:add_button(L("View Subtitles", "Zobrazit titulky"), do_view_subs, 2, 5, 1, 1)
	dlg:add_button(L("Download Selected", "Stáhnout vybrané"), do_download, 3, 5, 1, 1)

	results_list = dlg:add_list(1, 6, 3, 1)
	local initial_status
	if saved_email == "" then
		initial_status = L("Enter the e-mail and password of your hns.sk account, then Search.", "Zadejte e-mail a heslo svého účtu na hns.sk a klikněte na Hledat.")
	elseif guessed_title then
		initial_status = L("Guessed '%s'%s from the playing file. Edit if wrong, then Search.",
			"Odhadnutý název „%s“%s podle přehrávaného souboru - případně ho upravte a klikněte na Hledat.",
			guessed_title, guessed_ep and L(", episode %s", ", epizoda %s", guessed_ep) or "")
	else
		initial_status = L("Type a show title, then Search.", "Napište název anime a klikněte na Hledat.")
	end
	status_label = dlg:add_label(initial_status, 1, 7, 3, 1)
	dlg:show()
end

local function set_status(text)
	status_label:set_text(text)
	dlg:update()
end

--[[ ---------------- helpers ---------------- ]]

local function trim(s)
	return (string.gsub(s or "", "^%s*(.-)%s*$", "%1"))
end

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

local function strip_tags(html)
	local text = string.gsub(html or "", "<[^>]+>", " ")
	text = decode_entities(text)
	text = string.gsub(text, "%s+", " ")
	return trim(text)
end

-- log_line, if given, is logged INSTEAD OF cmd - keeps credentials out of
-- VLC's debug console
local function run(cmd, log_line)
	return hf_run(TAG, cmd, log_line)
end

local function log(msg)
	hf_log(TAG, msg)
end

local function cookie_jar()
	return hf_join(vlc.config.userdatadir(), "hns_cookies.txt")
end

local function get(url)
	return run(string.format('curl -sS -L %s -b "%s" -c "%s" "%s"', HF_CURL_PAGE, cookie_jar(), cookie_jar(), url))
end

-- POST via a temporary data file; out_file, if given, receives the body
-- (and the call returns "" on success instead of the body)
local function post(url, data, log_data, out_file)
	local data_opt, data_file = hf_post_file("hns", data)
	local out_opt = out_file and string.format(' -o "%s"', out_file) or ""
	local limits = out_file and HF_CURL_DOWNLOAD or HF_CURL_PAGE
	local cmd = string.format('curl -sS -L %s -b "%s" -c "%s" -e "%s" %s%s "%s"',
		limits, cookie_jar(), cookie_jar(), url, data_opt, out_opt, url)
	local log_cmd = log_data and (cmd .. " (data: " .. log_data .. ")") or nil
	local out = run(cmd, log_cmd)
	os.remove(data_file)
	return out
end

local function extract_attr(attr_str, name)
	return string.match(" " .. attr_str, "%s" .. name .. '="([^"]*)"')
end

-- every <input ...> inside a chunk of HTML, as a name -> value table
local function parse_inputs(form_html)
	local fields = {}
	for attrs in string.gmatch(form_html, "<input%s+([^>]-)/?>") do
		local name = extract_attr(attrs, "name")
		if name then
			fields[name] = decode_entities(extract_attr(attrs, "value") or "")
		end
	end
	return fields
end

local function form_data(fields)
	local parts = {}
	for name, value in pairs(fields) do
		table.insert(parts, urlencode(name) .. "=" .. urlencode(value))
	end
	table.sort(parts)
	return table.concat(parts, "&")
end

--[[ ---------------- credentials ----------------
E-mail in a small plain-text file. The password is never written to disk
in plain text: macOS Keychain via the `security` CLI, or on Windows, DPAPI
via a short-lived PowerShell temp script.
]]

local function email_file()
	return hf_join(vlc.config.userdatadir(), "hns_username.txt")
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

local KEYCHAIN_SERVICE = "VLC HNS Extension"

local function mac_save_password(email, password)
	local cmd = string.format('security add-generic-password -a %s -s %s -w %s -U',
		sh_dquote(email), sh_dquote(KEYCHAIN_SERVICE), sh_dquote(password))
	local log_cmd = string.format('security add-generic-password -a %s -s %s -w *** -U',
		sh_dquote(email), sh_dquote(KEYCHAIN_SERVICE))
	run(cmd, log_cmd)
end

local function mac_load_password(email)
	if email == "" then return "" end
	local cmd = string.format('security find-generic-password -a %s -s %s -w 2>/dev/null',
		sh_dquote(email), sh_dquote(KEYCHAIN_SERVICE))
	local out = run(cmd)
	if not out then return "" end
	return (string.gsub(out, "\r?\n$", ""))
end

local function win_password_file()
	return hf_join(vlc.config.userdatadir(), "hns_password.dat")
end

local function win_save_password(password)
	local script_path = hf_join(vlc.config.userdatadir(), "hns_pwtmp.ps1")
	local script = "$s = ConvertTo-SecureString -String " .. ps_squote(password) .. " -AsPlainText -Force\n"
		.. "$enc = ConvertFrom-SecureString -SecureString $s\n"
		.. "Set-Content -Path " .. ps_squote(win_password_file()) .. " -Value $enc -NoNewline\n"
	if not hf_write(script_path, script) then return end
	run(string.format('powershell -NoProfile -ExecutionPolicy Bypass -File "%s"', script_path),
		'powershell -NoProfile -ExecutionPolicy Bypass -File "(save-password script, contents not logged)"')
	os.remove(script_path)
end

local function win_load_password()
	local existing = io.open(win_password_file(), "r")
	if not existing then return "" end
	existing:close()

	local script_path = hf_join(vlc.config.userdatadir(), "hns_pwtmp_read.ps1")
	local script = "$enc = Get-Content -Path " .. ps_squote(win_password_file()) .. " -Raw\n"
		.. "$s = ConvertTo-SecureString -String $enc\n"
		.. "$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)\n"
		.. "[System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)\n"
	if not hf_write(script_path, script) then return "" end
	local out = run(string.format('powershell -NoProfile -ExecutionPolicy Bypass -File "%s"', script_path))
	os.remove(script_path)
	if not out then return "" end
	return (string.gsub(out, "\r?\n$", ""))
end

save_credentials = function(email, password)
	hf_write(email_file(), email .. "\n")
	if hf_is_windows() then
		win_save_password(password)
	else
		mac_save_password(email, password)
	end
end

load_credentials = function()
	local f = io.open(email_file(), "r")
	if not f then return "", "" end
	local email = f:read("*l") or ""
	f:close()
	if email == "" then return "", "" end

	local password = hf_is_windows() and win_load_password() or mac_load_password(email)
	return email, password
end

--[[ ---------------- site access ---------------- ]]

local function is_login_page(html)
	return string.find(html or "", 'id="login-form"', 1, true) ~= nil
end

-- fresh login from an empty cookie jar (a logged-in session would be
-- redirected away from the login page). Returns true/false.
local function login(email, password)
	os.remove(cookie_jar())
	local page = get(BASE_URL .. "/site/login")
	if page == nil then return false end
	local form = string.match(page, '<form[^>]-id="login%-form".-</form>') or ""
	local csrf = parse_inputs(form)["_csrf"]
	if not csrf then log("login: _csrf not found on the login page") end

	local function data(pass)
		return "_csrf=" .. urlencode(csrf or "")
			.. "&LoginForm%5Bemail%5D=" .. urlencode(email)
			.. "&LoginForm%5Bpassword%5D=" .. pass
			.. "&LoginForm%5BrememberMe%5D=1"
	end
	local result = post(BASE_URL .. "/site/login", data(urlencode(password)), data("***"))
	local ok = result ~= nil and string.find(result, "/site/logout", 1, true) ~= nil
	log("login " .. (ok and "OK" or "failed"))
	return ok
end

-- one click's view of the site: logs in only when a page asks for it, and
-- at most once per click
local function new_site(email, password)
	return { email = email, password = password, logged_in = false }
end

local function relogin(site)
	if site.logged_in then return false end
	site.logged_in = true
	return login(site.email, site.password)
end

-- page text, or nil plus "network" / "login"
local function site_get(site, url)
	local html = get(url)
	if html == nil or html == "" then return nil, "network" end
	if not is_login_page(html) then return html end
	log("not logged in, logging in")
	if not relogin(site) then return nil, "login" end
	html = get(url)
	if html == nil or html == "" then return nil, "network" end
	if is_login_page(html) then return nil, "login" end
	return html
end

local function error_text(why)
	if why == "login" then
		return L("Login failed - check the e-mail and password (see debug log).", "Přihlášení selhalo - zkontrolujte e-mail a heslo (podrobnosti v logu).")
	end
	return L("Request failed (see debug log). Try again in a moment.", "Požadavek selhal (podrobnosti v logu). Zkuste to za chvíli znovu.")
end

-- the fields' e-mail and password, saved when they changed; a different
-- e-mail than the cookie jar's starts from an empty jar
local function current_site()
	local email = trim(email_input:get_text())
	local password = pass_input:get_text()
	if email == "" or password == "" then return nil end
	if email ~= jar_email then
		os.remove(cookie_jar())
		jar_email = email
	end
	hf_remember_credentials(save_credentials, email, password)
	return new_site(email, password)
end

--[[ ---------------- catalog ---------------- ]]

local function catalog_file()
	return hf_join(vlc.config.userdatadir(), "hns_catalog.txt")
end

-- first line: save time; then one "slug<TAB>title" line per show
local function load_catalog()
	local text = hf_read(catalog_file())
	if not text then return nil end
	local lines = hf_lines(text)
	local saved_at = tonumber(lines[1] or "")
	if not saved_at or os.time() - saved_at > CATALOG_MAX_AGE then return nil end
	local shows = {}
	for i = 2, #lines do
		local slug, title = string.match(lines[i], "^([^\t]+)\t(.+)$")
		if slug then table.insert(shows, { slug = slug, title = title }) end
	end
	if #shows == 0 then return nil end
	return shows
end

local function parse_catalog(html)
	local shows, seen = {}, {}
	for slug, title in string.gmatch(html or "", '<a%s+href="/anime/([^"/]+)">([^<]+)</a>') do
		if not seen[slug] then
			seen[slug] = true
			title = trim(string.gsub(decode_entities(title), "[\t\r\n]+", " "))
			table.insert(shows, { slug = slug, title = title })
		end
	end
	return shows
end

local function get_catalog(site)
	local shows = load_catalog()
	if shows then
		log("using cached catalog (" .. #shows .. " shows)")
		return shows
	end
	local html, why = site_get(site, BASE_URL .. "/animelist")
	if not html then return nil, why end
	shows = parse_catalog(html)
	log("catalog: " .. #shows .. " shows")
	if #shows > 0 then
		local out = { tostring(os.time()) }
		for _, s in ipairs(shows) do table.insert(out, s.slug .. "\t" .. s.title) end
		hf_write(catalog_file(), table.concat(out, "\n") .. "\n")
	end
	return shows
end

--[[ ---------------- matching ---------------- ]]

local function normalize(text)
	text = string.lower(text or "")
	text = string.gsub(text, "[%s%p]+", " ")
	return trim(text)
end

local ROMAN = { ii = 2, iii = 3, iv = 4, v = 5, vi = 6 }

-- season a title adds to the searched words: 1 for nothing extra, nil for
-- extra words without a season marker (a spin-off, a movie...)
local function remainder_season(rest)
	if rest == "" then return 1 end
	local n = string.match(rest, "^season (%d%d?)%f[%D]") or string.match(rest, "^s(%d%d?)%f[%D]")
		or string.match(rest, "^(%d%d?)%a%a season%f[%A]") or string.match(rest, "^(%d%d?)%f[%D]")
	if n then return tonumber(n) end
	local r = string.match(rest, "^(%a+)%f[%A]")
	return r and ROMAN[r] or nil
end

-- splits "Show S2" / "Show Season 2" / "Show 2nd Season" into the title
-- and the season number (nil when not given)
local function split_season(query)
	local q = normalize(query)
	local base, n = string.match(q, "^(.-) s(%d%d?)$")
	if not base then base, n = string.match(q, "^(.-) season (%d%d?)$") end
	if not base then base, n = string.match(q, "^(.-) (%d%d?)%a%a season$") end
	if base and base ~= "" then return base, tonumber(n) end
	return q, nil
end

-- shows whose title has every searched word, the requested season (or the
-- bare title) first; then titles with only some of the words
local function rank_shows(query, shows)
	local base, season = split_season(query)
	local words = {}
	for w in string.gmatch(base, "%S+") do table.insert(words, w) end
	if #words == 0 then return {} end
	local full, partial = {}, {}
	for _, s in ipairs(shows) do
		local t = normalize(s.title)
		local padded = " " .. t .. " "
		local hits = 0
		for _, w in ipairs(words) do
			if string.find(padded, " " .. w .. " ", 1, true) then hits = hits + 1 end
		end
		if hits == #words then
			local rest
			if string.sub(t, 1, #base) == base then
				rest = trim(string.sub(t, #base + 1))
			else
				local kept = {}
				for w in string.gmatch(t, "%S+") do
					local in_query = false
					for _, q in ipairs(words) do if q == w then in_query = true end end
					if not in_query then table.insert(kept, w) end
				end
				rest = table.concat(kept, " ")
			end
			local ss = remainder_season(rest)
			local key
			if season and ss == season then key = 0
			elseif ss then key = ss
			else key = 1000 end
			table.insert(full, { show = s, key = key, len = #rest })
		elseif hits > 0 then
			table.insert(partial, { show = s, key = -hits, len = #t })
		end
	end
	local function by_key(a, b)
		if a.key ~= b.key then return a.key < b.key end
		if a.len ~= b.len then return a.len < b.len end
		return a.show.title < b.show.title
	end
	table.sort(full, by_key)
	table.sort(partial, by_key)
	local out = {}
	for _, e in ipairs(full) do table.insert(out, e.show) end
	if #out == 0 then
		for i = 1, math.min(#partial, 30) do table.insert(out, partial[i].show) end
	end
	return out
end

--[[ ---------------- show and episode pages ---------------- ]]

-- one release row: release, translator (<br> uploader), date,
-- "version / note", download form
local function parse_release_row(row)
	local cells = {}
	for cell in string.gmatch(row, "<td[^>]*>(.-)</td>") do table.insert(cells, cell) end
	local form = string.match(row, "<form.-</form>")
	if #cells < 5 or not form then return nil end
	local fields = parse_inputs(form)
	if not fields.id or fields.id == "" or fields.download == "all" then return nil end
	local name = fields.name
	if not name or name == "" then name = decode_entities(string.match(form, 'data%-name="([^"]*)"') or "") end
	local translator = strip_tags(string.match(cells[2], "^(.-)<br") or cells[2])
	return {
		sub_id = fields.id,
		name = name,
		release = strip_tags(cells[1]),
		translator = translator,
		version = string.match(strip_tags(cells[4]), "^(%d+)") or "",
	}
end

local function parse_show_page(html)
	local out = {}
	local pos = 1
	while true do
		local s = string.find(html, "<table", pos, true)
		if not s then break end
		local e = string.find(html, "</table>", s, true) or #html
		local chunk = string.sub(html, s, e)
		pos = e + 1
		local url, text = string.match(chunk, '<a%s+href="(/anime/episode/[^"]+/%d+)"%s*>([^<]*)</a>')
		if url then
			local episode = tonumber(string.match(trim(decode_entities(text)), "(%d+)$") or "")
			for row in string.gmatch(chunk, "<tr[^>]*>(.-)</tr>") do
				local r = parse_release_row(row)
				if r then
					r.episode = episode
					r.episode_url = BASE_URL .. url
					table.insert(out, r)
				end
			end
		end
	end
	return out
end

local function find_download_form(html, sub_id)
	for form in string.gmatch(html or "", "<form.-</form>") do
		local f = parse_inputs(form)
		if f.id == sub_id and f.action == "download" then return f end
	end
	return nil
end

local function release_label(r)
	local label = string.format("E%02d - %s", r.episode or 0, r.release ~= "" and r.release or "?")
	if r.version ~= "" and r.version ~= "1" then label = label .. " v" .. r.version end
	if r.translator ~= "" then label = label .. " (" .. r.translator .. ")" end
	return label
end

local function episode_filter()
	local n = tonumber(trim(episode_input:get_text()))
	if n and n >= 0 and n == math.floor(n) then return n end
	return nil
end

local function selected_index()
	local sel = results_list:get_selection()
	for id, _ in pairs(sel or {}) do return id end
	return nil
end

--[[ ---------------- actions ---------------- ]]

function do_search()
	local site = current_site()
	if not site then
		set_status(L("Enter the e-mail and password of your hns.sk account first.", "Nejdřív zadejte e-mail a heslo svého účtu na hns.sk."))
		return
	end
	local query = trim(search_input:get_text())
	if query == "" then
		set_status(L("Type a show title to search for.", "Napište název, který chcete hledat."))
		return
	end

	set_status(L("Searching...", "Hledám..."))
	local shows, why = get_catalog(site)
	if not shows then
		set_status(error_text(why))
		return
	end

	show_matches = rank_shows(query, shows)
	log("search '" .. query .. "' -> " .. #show_matches .. " matches")
	results_list:clear()
	for i, s in ipairs(show_matches) do
		results_list:add_value(s.title, i)
	end
	current_stage = "search"

	if #show_matches == 0 then
		set_status(L("No results for '%s'.", "Pro „%s“ nebylo nic nalezeno.", query))
	else
		set_status(L("%s result(s). Select one, then click 'View Subtitles'.", "Výsledky: %s. Vyberte jeden a klikněte na „Zobrazit titulky“.", #show_matches))
	end
end

function do_view_subs()
	if current_stage ~= "search" then
		set_status(L("Do a search first, then select a show from the list.", "Nejdřív vyhledávejte, pak vyberte pořad ze seznamu."))
		return
	end
	local idx = selected_index()
	local show = idx and show_matches[idx]
	if not show then
		set_status(L("Select a show from the list first.", "Nejdřív vyberte pořad ze seznamu."))
		return
	end
	local site = current_site()
	if not site then
		set_status(L("Enter the e-mail and password of your hns.sk account first.", "Nejdřív zadejte e-mail a heslo svého účtu na hns.sk."))
		return
	end

	set_status(L("Loading subtitle list...", "Načítám seznam titulků..."))
	local html, why = site_get(site, BASE_URL .. "/anime/" .. show.slug)
	if not html then
		set_status(error_text(why))
		return
	end
	local all = parse_show_page(html)
	log(show.slug .. ": " .. #all .. " release(s)")

	local ep = episode_filter()
	local list = all
	if ep then
		list = {}
		for _, r in ipairs(all) do
			if r.episode == ep then table.insert(list, r) end
		end
		if #list == 0 then list = all end
	end

	current_show = show
	releases = list
	results_list:clear()
	for i, r in ipairs(releases) do
		results_list:add_value(release_label(r), i)
	end
	current_stage = "subs"

	if #all == 0 then
		set_status(L("No subtitles found for '%s' (see debug log).", "Pro „%s“ nebyly nalezeny žádné titulky (podrobnosti v logu).", show.title))
	elseif ep and list == all then
		set_status(L("Nothing for episode %s, showing all %s subtitle(s). Select one, then Download.", "Pro epizodu %s nic není, zobrazuji všechny titulky (%s). Vyberte jedny a klikněte na Stáhnout.", ep, #all))
	else
		set_status(L("%s subtitle(s) for '%s'. Select one, then Download.", "Nalezené titulky (%s) pro „%s“. Vyberte jedny a klikněte na Stáhnout.", #releases, show.title))
	end
end

function do_download()
	if current_stage ~= "subs" then
		set_status(L("View a show's subtitles first, then select one to download.", "Nejdřív zobrazte titulky, pak vyberte ty ke stažení."))
		return
	end
	local idx = selected_index()
	local r = idx and releases[idx]
	if not r then
		set_status(L("Select a subtitle from the list first.", "Nejdřív vyberte titulky ze seznamu."))
		return
	end
	local site = current_site()
	if not site then
		set_status(L("Enter the e-mail and password of your hns.sk account first.", "Nejdřív zadejte e-mail a heslo svého účtu na hns.sk."))
		return
	end

	set_status(L("Downloading...", "Stahuji..."))
	local body_file = hf_join(vlc.config.userdatadir(), "hns_download.tmp")
	-- the episode page's form carries a fresh _csrf; if the answer is a
	-- page instead of the file (e.g. the session ran out), log in again
	-- and repeat once
	for attempt = 1, 2 do
		local html, why = site_get(site, r.episode_url)
		if not html then
			set_status(error_text(why))
			return
		end
		local fields = find_download_form(html, r.sub_id)
		if not fields then
			log("no download form for subtitle " .. r.sub_id .. " on " .. r.episode_url)
			set_status(L("This subtitle is no longer on the site - search again.", "Tyto titulky už na webu nejsou - vyhledejte znovu."))
			return
		end
		os.remove(body_file)
		if post(r.episode_url, form_data(fields), nil, body_file) == nil then
			set_status(error_text("network"))
			return
		end
		if not hf_looks_like_page(body_file) or attempt == 2 or site.logged_in then break end
		log("download returned a page, logging in again")
		if not relogin(site) then
			os.remove(body_file)
			set_status(error_text("login"))
			return
		end
	end

	local ext = string.lower(string.match(r.name or "", "%.(%w+)$") or "")
	if not HF_SUB_EXTS[ext] then
		local head = string.gsub(string.sub(hf_read(body_file) or "", 1, 200), "^\239\187\191", "")
		ext = string.find(head, "^%s*%[Script Info%]") and "ass" or "srt"
	end
	set_status(hf_finish({
			tag = TAG, prefix = "hns", body_path = body_file, ext = ext,
			name_stem = string.format("hns_%s_E%02d", current_show and current_show.slug or "sub", r.episode or 0),
		}))
end
