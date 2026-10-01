--[[
Legie Kondor (anime4.legiekondor.cz) Subtitles - VLC extension

VLC's Lua HTTP API is too limited, so every request goes through the
system curl via io.popen. No login, no cookies, no credentials: the
whole site is public.

Site notes:
  - The catalog lives at /p/vypis/. Anime titles there are baked into
    cover images, so each card only gives a slug, via
    onclick="window.location.href='/a/<slug>/'". The real title comes
    from each anime page's own <title> tag ("Title || Legie Kondor").
  - An anime page lists its episodes only as cached thumbnails:
    /epcache/<slug>/<code>.webp, where code = season*100 + episode
    ("104" = S01E04, "601" = S06E01).
  - The subtitle downloads publicly from /subdwl/<slug>.<code>/ and is
    normally a plain .ass file. A zip is handled too, just in case.

The catalog (slug -> title) takes one request per anime to build, so it
is cached for 24h in VLC's own data folder. All titles are fetched with
a single curl call (one command window flash on Windows, not ~25).

Safety and housekeeping:
  - Downloads are rejected if empty, if they look like an HTML page, or if
    they're over MAX_DOWNLOAD_BYTES.
  - Zips are checked before extracting: total uncompressed size (zip-bomb
    guard) and entry names (no absolute paths or "..").
  - Finished subtitles go to a dedicated folder shared by all these
    extensions: Documents/VLC Subtitles. Files this extension saved there
    are deleted after SUB_MAX_AGE_DAYS. The temporary work folder is wiped
    before every download.

Debug: enable VLC's debug log (Tools -> Messages, verbosity 2) and look for
lines starting with "[LegieKondor]".
]]

local VERSION = "1.0.2"
local TAG = "[LegieKondor]"
local PREFIX = "legiekondor" -- file-name prefix for everything this extension creates
local BASE_URL = "https://anime4.legiekondor.cz"
local CATALOG_URL = BASE_URL .. "/p/vypis/"

local CATALOG_TTL = 24 * 60 * 60               -- seconds
local MAX_DOWNLOAD_BYTES = 20 * 1024 * 1024     -- 20 MB
local MAX_EXTRACTED_BYTES = 200 * 1024 * 1024   -- 200 MB
local SUB_MAX_AGE_DAYS = 30

function descriptor()
	return {
		title = "Legie Kondor Subtitles v" .. VERSION,
		version = VERSION,
		author = "Highflight Studio",
		shortdesc = "Legie Kondor subtitles",
		description = "Search anime4.legiekondor.cz and download/apply Czech anime subtitles. No account needed.",
		capabilities = {}
	}
end

local dlg = nil
local search_input = nil
local results_list = nil
local status_label = nil

-- current_stage: "search" (results_list holds shows, id = index into
-- show_matches) or "episodes" (results_list holds episodes, id = index
-- into ep_rows)
local current_stage = "search"
local show_matches = {} -- [n] = {slug=, title=}
local ep_rows = {}      -- [n] = {season=, episode=, code=}
local current_show = nil

-- >>> shared block "platform" - edit dev/shared/platform.lua in VLC-Subtitles, then run dev/sync.py
--[[ ---------------- platform helpers ---------------- ]]

-- VLC doesn't provide the standard "package" table while it scans
-- extensions at startup, so this must
-- not rely on it, and nothing may call it at load time - only from inside
-- functions that run after the dialog opens.
local windows_cached = nil
local function is_windows()
	if windows_cached == nil then
		if package and package.config then
			windows_cached = package.config:sub(1, 1) == "\\"
		else
			windows_cached = os.getenv("WINDIR") ~= nil or os.getenv("OS") == "Windows_NT"
		end
	end
	return windows_cached
end

local function join(...)
	return table.concat({...}, is_windows() and "\\" or "/")
end

local function log(msg)
	vlc.msg.dbg(TAG .. " " .. msg)
end

-- log_line, if given, is logged instead of cmd (keeps secrets out of the
-- debug log)
local function run(cmd, log_line)
	log("running: " .. (log_line or cmd))
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
local function quiet_console()
	if not is_windows() or not (vlc.win and vlc.win.console_init) then return end
	local ok, err = pcall(vlc.win.console_init)
	if not ok then
		log("couldn't create the hidden console: " .. tostring(err))
		return
	end
	run("powershell -NoProfile -WindowStyle Hidden -Command exit")
end

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local data = f:read("*a")
	f:close()
	return data
end

local function write_file(path, data)
	local f = io.open(path, "wb")
	if not f then return false end
	f:write(data)
	f:close()
	return true
end

local function copy_file(src, dst)
	local data = read_file(src)
	if not data then return false end
	return write_file(dst, data)
end

local function make_dir(path)
	if is_windows() then
		run('mkdir "' .. path .. '" 2>nul')
	else
		run('mkdir -p "' .. path .. '"')
	end
end

local function remove_dir(path)
	if is_windows() then
		run('rmdir /s /q "' .. path .. '" 2>nul')
	else
		run('rm -rf "' .. path .. '"')
	end
end

-- names (not full paths) of the files directly inside dir
local function list_files(dir)
	local out
	if is_windows() then
		out = run('dir /b /a-d "' .. dir .. '" 2>nul')
	else
		out = run('ls -1 "' .. dir .. '" 2>/dev/null')
	end
	local names = {}
	for line in string.gmatch(out or "", "[^\r\n]+") do
		table.insert(names, line)
	end
	return names
end

-- full paths of every file anywhere under dir
local function list_files_recursive(dir)
	local out
	if is_windows() then
		out = run('dir /b /s /a-d "' .. dir .. '" 2>nul')
	else
		out = run('find "' .. dir .. '" -type f 2>/dev/null')
	end
	local paths = {}
	for line in string.gmatch(out or "", "[^\r\n]+") do
		table.insert(paths, line)
	end
	return paths
end

-- temporary work folder (downloads, zip extraction), wiped before use
local function work_dir()
	return join(vlc.config.userdatadir(), PREFIX .. "_work")
end

-- the shared, user-visible folder all these extensions save subtitles to
local function subtitles_dir()
	local home
	if is_windows() then
		home = os.getenv("USERPROFILE")
	else
		home = os.getenv("HOME")
	end
	if not home or home == "" then
		return join(vlc.config.userdatadir(), "VLC Subtitles")
	end
	return join(home, "Documents", "VLC Subtitles")
end

-- deletes subtitles this extension saved more than SUB_MAX_AGE_DAYS ago;
-- the save time is part of every file name (<prefix>_..._<unix time>.<ext>)
local function cleanup_old_subtitles()
	local dir = subtitles_dir()
	local cutoff = os.time() - SUB_MAX_AGE_DAYS * 24 * 60 * 60
	local removed = 0
	for _, name in ipairs(list_files(dir)) do
		if string.sub(name, 1, #PREFIX + 1) == PREFIX .. "_" then
			local saved_at = tonumber(string.match(name, "_(%d+)%.%w+$") or "")
			if saved_at and saved_at < cutoff then
				if os.remove(join(dir, name)) then removed = removed + 1 end
			end
		end
	end
	if removed > 0 then log("cleanup: removed " .. removed .. " old subtitle file(s)") end
end
-- <<< shared block "platform"

local function catalog_file()
	return join(vlc.config.userdatadir(), PREFIX .. "_catalog.txt")
end

--[[ ---------------- text helpers ---------------- ]]

-- UTF-8 encoding of a code point (Lua 5.1 has no utf8 library)
local function utf8_char(cp)
	if cp < 0x80 then
		return string.char(cp)
	elseif cp < 0x800 then
		return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
	elseif cp < 0x10000 then
		return string.char(0xE0 + math.floor(cp / 0x1000),
			0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	elseif cp < 0x110000 then
		return string.char(0xF0 + math.floor(cp / 0x40000),
			0x80 + math.floor(cp / 0x1000) % 0x40,
			0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	end
	return "?"
end

local function decode_entities(str)
	if not str then return str end
	str = string.gsub(str, "&#[xX](%x+);", function(h) return utf8_char(tonumber(h, 16)) end)
	str = string.gsub(str, "&#(%d+);", function(d) return utf8_char(tonumber(d)) end)
	str = string.gsub(str, "&quot;", '"')
	str = string.gsub(str, "&apos;", "'")
	str = string.gsub(str, "&lt;", "<")
	str = string.gsub(str, "&gt;", ">")
	str = string.gsub(str, "&nbsp;", " ")
	str = string.gsub(str, "&amp;", "&") -- last, so "&amp;lt;" stays "&lt;"
	return str
end

local function trim(s)
	return (string.gsub(s or "", "^%s*(.-)%s*$", "%1"))
end

-- escape Lua pattern magic characters so a literal string can be matched
local function pattern_escape(s)
	return (string.gsub(s, "(%p)", "%%%1"))
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
	name = trim(name)

	if name == "" then return nil end
	return name
end

--[[ ---------------- site access ---------------- ]]

local function curl_get(url)
	return run(string.format('curl -sS -L --max-time 30 "%s"', url))
end

-- slugs from the catalog page's onclick links, in page order, de-duplicated
local function parse_catalog_slugs(html)
	local slugs, seen = {}, {}
	for slug in string.gmatch(html or "", "window%.location%.href='/a/([%w%-]+)/'") do
		if not seen[slug] then
			seen[slug] = true
			table.insert(slugs, slug)
		end
	end
	return slugs
end

-- "Some Title || Legie Kondor" -> "Some Title"
local function parse_page_title(html)
	local t = string.match(html or "", "<title>(.-)</title>")
	if not t then return nil end
	t = string.match(t, "^(.-)%s*||") or t
	t = trim(decode_entities(t))
	if t == "" then return nil end
	return t
end

-- Fetches every anime page's <title> in ONE curl call. curl prints the
-- -w marker (with the final URL) after each page, which is how each body
-- is matched back to its slug.
local function fetch_titles(slugs)
	local urls = {}
	for _, slug in ipairs(slugs) do
		table.insert(urls, '"' .. BASE_URL .. '/a/' .. slug .. '/"')
	end
	local cmd = 'curl -sS -L --max-time 120 -w "\\n@@LK_URL@@%{url_effective}@@\\n" ' .. table.concat(urls, " ")
	local out = run(cmd, "curl (" .. #slugs .. " anime pages for titles)")
	local titles = {}
	local body_start = 1
	for marker_start, url, marker_end in string.gmatch(out or "", "()@@LK_URL@@(.-)@@()") do
		local body = string.sub(out, body_start, marker_start - 1)
		local slug = string.match(url, "/a/([%w%-]+)/?$")
		if slug then titles[slug] = parse_page_title(body) end
		body_start = marker_end
	end
	return titles
end

local function save_catalog(shows)
	local lines = { tostring(os.time()) }
	for _, s in ipairs(shows) do
		table.insert(lines, s.slug .. "\t" .. s.title)
	end
	write_file(catalog_file(), table.concat(lines, "\n") .. "\n")
end

local function load_catalog()
	local data = read_file(catalog_file())
	if not data then return nil end
	local ts = tonumber(string.match(data, "^(%d+)"))
	if not ts or os.time() - ts > CATALOG_TTL then return nil end
	local shows = {}
	for slug, title in string.gmatch(data, "\n([^\t\n]+)\t([^\n]+)") do
		table.insert(shows, { slug = slug, title = title })
	end
	if #shows == 0 then return nil end
	return shows
end

local function build_catalog()
	local slugs = parse_catalog_slugs(curl_get(CATALOG_URL))
	log("catalog: " .. #slugs .. " slug(s) on " .. CATALOG_URL)
	if #slugs == 0 then return {} end
	local titles = fetch_titles(slugs)
	local shows = {}
	for _, slug in ipairs(slugs) do
		if titles[slug] then
			table.insert(shows, { slug = slug, title = titles[slug] })
		else
			log("no title found for slug '" .. slug .. "', skipping")
		end
	end
	if #shows > 0 then save_catalog(shows) end
	return shows
end

local function get_catalog()
	local cached = load_catalog()
	if cached then
		log("using cached catalog (" .. #cached .. " shows)")
		return cached
	end
	log("catalog cache missing or stale, rebuilding")
	return build_catalog()
end

-- ranks shows by how many query words appear in the title; the whole query
-- appearing as-is ranks highest. Returns matches only (may be empty).
local function rank_shows(query, shows)
	local q = string.lower(trim(query))
	local words = {}
	for w in string.gmatch(q, "[^%s%p]+") do table.insert(words, w) end
	local scored = {}
	for _, s in ipairs(shows) do
		local t = string.lower(s.title)
		local score = 0
		if q ~= "" and string.find(t, q, 1, true) then score = score + 100 end
		for _, w in ipairs(words) do
			if string.find(t, w, 1, true) then score = score + 1 end
		end
		if score > 0 then table.insert(scored, { show = s, score = score }) end
	end
	table.sort(scored, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		return a.show.title < b.show.title
	end)
	local out = {}
	for _, e in ipairs(scored) do table.insert(out, e.show) end
	return out
end

-- episodes from the anime page's /epcache/<slug>/<code>.webp thumbnails,
-- sorted by code; code = season*100 + episode
local function parse_episode_codes(html, slug)
	local rows, seen = {}, {}
	local pat = "/epcache/" .. pattern_escape(slug) .. "/(%d%d%d%d?)%.webp"
	for code in string.gmatch(html or "", pat) do
		if not seen[code] then
			seen[code] = true
			local n = tonumber(code)
			table.insert(rows, {
				code = code,
				season = math.floor(n / 100),
				episode = n % 100,
			})
		end
	end
	table.sort(rows, function(a, b) return tonumber(a.code) < tonumber(b.code) end)
	return rows
end

-- >>> shared block "zip_checks" - edit dev/shared/zip_checks.lua in VLC-Subtitles, then run dev/sync.py
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
	if not data or #data == 0 then return false, "empty response" end
	if #data > MAX_DOWNLOAD_BYTES then return false, "larger than expected (" .. #data .. " bytes)" end
	local head = string.gsub(string.sub(data, 1, 512), "^\239\187\191", "") -- drop UTF-8 BOM
	if string.match(head, "^%s*<") then return false, "the site returned a web page instead of a subtitle" end
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
-- <<< shared block "zip_checks"

-- extension from a Content-Disposition header, else from the content
local function guess_extension(headers, data)
	local fname = string.match(headers or "", '[Ff]ilename%*?=[^\r\n]-([^\'"\r\n;=]+%.%w+)')
	if fname then
		local ext = string.lower(string.match(fname, "%.(%w+)$") or "")
		if SUBTITLE_EXTS[ext] then return ext end
	end
	local head = string.gsub(string.sub(data, 1, 200), "^\239\187\191", "")
	if string.match(head, "^%s*%[Script Info%]") then return "ass" end
	return "srt"
end

-- extracts zip_path into dest_dir and returns the path of the first
-- subtitle file found inside, or nil
local function extract_zip(zip_path, dest_dir)
	make_dir(dest_dir)
	if is_windows() then
		run(string.format('tar -xf "%s" -C "%s" 2>nul', zip_path, dest_dir))
	else
		run(string.format('unzip -o "%s" -d "%s" >/dev/null 2>&1', zip_path, dest_dir))
	end
	local first_any = nil
	for _, path in ipairs(list_files_recursive(dest_dir)) do
		local ext = string.lower(string.match(path, "%.(%w+)$") or "")
		if SUBTITLE_EXTS[ext] then return path end
		first_any = first_any or path
	end
	if first_any then log("zip had no subtitle-looking file; first file was " .. first_any) end
	return nil
end

--[[ ---------------- dialog ---------------- ]]

function activate()
	pcall(quiet_console)
	pcall(cleanup_old_subtitles)
	show_dialog()
end

function deactivate()
	if dlg then dlg:delete() end
end

function close()
	vlc.deactivate()
end

function show_dialog()
	dlg = vlc.dialog("Legie Kondor Subtitles v" .. VERSION)
	local guessed_title = guess_title_from_playing()

	dlg:add_label("Search:", 1, 1, 1, 1)
	search_input = dlg:add_text_input(guessed_title or "", 2, 1, 2, 1)
	dlg:add_button("Search", do_search, 1, 2, 1, 1)
	dlg:add_button("View Episodes", do_view_episodes, 2, 2, 1, 1)
	dlg:add_button("Download Selected", do_download, 3, 2, 1, 1)

	results_list = dlg:add_list(1, 3, 3, 1)
	local initial_status = guessed_title
		and ("Guessed '" .. guessed_title .. "' from the playing file. Edit if wrong, then Search.")
		or "Type a show title (or leave empty to list every show), then Search."
	status_label = dlg:add_label(initial_status, 1, 4, 3, 1)
	dlg:show()
end

local function set_status(text)
	status_label:set_text(text)
	dlg:update()
end

local function selected_index()
	local sel = results_list:get_selection()
	for id, _ in pairs(sel or {}) do return id end
	return nil
end

--[[ ---------------- actions ---------------- ]]

function do_search()
	local query = trim(search_input:get_text())
	set_status("Loading the show list (the first search of the day takes a bit longer)...")

	local shows = get_catalog()
	if #shows == 0 then
		set_status("Couldn't load the show list from the site (see debug log).")
		return
	end

	local matches = rank_shows(query, shows)
	local note
	if query == "" or #matches == 0 then
		matches = {}
		for _, s in ipairs(shows) do table.insert(matches, s) end
		table.sort(matches, function(a, b) return a.title < b.title end)
		note = (query == "") and (#matches .. " shows on the site.")
			or ("No match for '" .. query .. "', showing all " .. #matches .. " shows.")
	else
		note = #matches .. " match(es) for '" .. query .. "'."
	end

	show_matches = matches
	results_list:clear()
	for i, s in ipairs(show_matches) do
		results_list:add_value(s.title, i)
	end
	current_stage = "search"
	set_status(note .. " Select one, then 'View Episodes'.")
end

function do_view_episodes()
	if current_stage ~= "search" then
		set_status("Search first, then select a show from the list.")
		return
	end
	local idx = selected_index()
	if not idx or not show_matches[idx] then
		set_status("Select a show from the list first.")
		return
	end
	current_show = show_matches[idx]
	set_status("Loading episodes for '" .. current_show.title .. "'...")

	local html = curl_get(BASE_URL .. "/a/" .. current_show.slug .. "/")
	ep_rows = parse_episode_codes(html, current_show.slug)
	log(#ep_rows .. " episode(s) for slug " .. current_show.slug)

	results_list:clear()
	for i, row in ipairs(ep_rows) do
		results_list:add_value(string.format("S%02dE%02d", row.season, row.episode), i)
	end
	current_stage = "episodes"

	if #ep_rows == 0 then
		set_status("No episodes found for '" .. current_show.title .. "' (see debug log).")
	else
		set_status(#ep_rows .. " episode(s) for '" .. current_show.title .. "'. Select one, then Download.")
	end
end

local function download_selected()
	if current_stage ~= "episodes" then
		set_status("View a show's episodes first, then select one to download.")
		return
	end
	local idx = selected_index()
	if not idx or not ep_rows[idx] then
		set_status("Select an episode from the list first.")
		return
	end
	local row = ep_rows[idx]
	local label = string.format("S%02dE%02d", row.season, row.episode)
	set_status("Downloading " .. label .. "...")

	local work = work_dir()
	remove_dir(work)
	make_dir(work)
	local dl_path = join(work, "download.bin")
	local hdr_path = join(work, "headers.txt")
	local url = BASE_URL .. "/subdwl/" .. current_show.slug .. "." .. row.code .. "/"
	local curl_err = run(string.format('curl -sS -L --max-time 60 --max-filesize %d -D "%s" -o "%s" "%s" 2>&1',
		MAX_DOWNLOAD_BYTES, hdr_path, dl_path, url)) or ""
	if string.find(curl_err, "(63)", 1, true) then
		log("download refused by curl: over " .. MAX_DOWNLOAD_BYTES .. " bytes (" .. url .. ")")
		set_status("Download refused: the file is larger than a subtitle should be.")
		return
	end

	local data = read_file(dl_path)
	local ok, reason = check_download(data)
	if not ok then
		log("download rejected: " .. reason .. " (" .. url .. ")")
		set_status("Download failed: " .. reason .. ". Try again in a moment.")
		return
	end

	local sub_path, ext
	if string.sub(data, 1, 2) == "PK" then
		local total, info = inspect_zip(data)
		if not total then
			log("zip refused: " .. tostring(info))
			set_status("Downloaded a zip but it looks broken or unsafe (see debug log).")
			return
		end
		if total > MAX_EXTRACTED_BYTES then
			log("zip refused: " .. total .. " bytes uncompressed")
			set_status("Download refused: the archive is far too large when unpacked.")
			return
		end
		local zip_path = join(work, "download.zip")
		os.rename(dl_path, zip_path)
		sub_path = extract_zip(zip_path, join(work, "extract"))
		if not sub_path then
			set_status("Downloaded a zip but found no subtitle inside (see debug log).")
			return
		end
		ext = string.lower(string.match(sub_path, "%.(%w+)$") or "srt")
	else
		sub_path = dl_path
		ext = guess_extension(read_file(hdr_path), data)
	end

	local dest_dir = subtitles_dir()
	make_dir(dest_dir)
	local final_name = string.format("%s_%s_%s_%d.%s", PREFIX, current_show.slug, label, os.time(), ext)
	local final_path = join(dest_dir, final_name)
	if not copy_file(sub_path, final_path) then
		log("could not write " .. final_path)
		set_status("Downloaded, but couldn't save into " .. dest_dir .. " (see debug log).")
		return
	end
	log("saved subtitle to " .. final_path)

	if attach_subtitle(final_path) then
		set_status("Downloaded and applied: " .. final_name)
	else
		set_status("Saved to " .. final_path .. " (no video playing, open one and add it manually).")
	end
end

function do_download()
	local ok, err = pcall(download_selected)
	remove_dir(work_dir())
	if not ok then
		log("download error: " .. tostring(err))
		set_status("Something went wrong during the download (see debug log).")
	end
end
