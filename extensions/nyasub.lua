--[[
NyaSub (nyasub.cz) Subtitles - VLC extension

VLC's Lua HTTP API is too limited, so every request goes through the
system curl via io.popen. No login, no cookies, no credentials: the
whole site (a public WordPress blog using the WPDM download plugin) is
browsable and downloadable without an account.

Site notes:
  - The catalog lives at /hotove-preklady/: every anime is an <h2>
    heading followed by one or more links to that title's season / movie /
    OVA pages (labelled "1.serie", "2.serie", "cast prvni", a film name...).
    This extension lists one row per such page.
  - A season page lists its episodes through the WPDM plugin. Each
    episode's "Titulky" button is a plain, pre-rendered
    <a href="...?wpdmdl=<id>&masterkey=<key>"> in on-screen order, so
    episode N = the Nth such link (episode numbers aren't in the markup).
  - That link downloads the file directly. The site has been seen to
    report odd HTTP status codes even on downloads that worked, so the
    status is ignored: a response counts as good if it isn't empty and
    isn't an HTML page, with one automatic retry.
  - The file is normally a plain .srt/.ass, but a zip is handled too.

The catalog is one page, cached for 24h in VLC's own data folder.

Safety and housekeeping:
  - Downloads are rejected if empty, if they look like an HTML page, or if
    they're over MAX_DOWNLOAD_BYTES.
  - Zips are checked before extracting: total uncompressed size (zip-bomb
    guard) and entry names (no absolute paths or "..").
  - Finished subtitles go to a dedicated folder shared by all these
    extensions: Documents/VLC Subtitles. Files this extension saved there
    are deleted after SUB_MAX_AGE_DAYS. The temporary work folder is
    removed after every download attempt.

IMPORTANT: VLC doesn't provide the standard "package" table while it scans
extensions at startup, so nothing at this file's top level may touch it.

Debug: enable VLC's debug log (Tools -> Messages, verbosity 2) and look for
lines starting with "[NyaSub]".
]]

local VERSION = "1.1.1"
local TAG = "[NyaSub]"
local PREFIX = "nyasub" -- file-name prefix for everything this extension creates
local BASE_URL = "https://nyasub.cz"
local CATALOG_URL = BASE_URL .. "/hotove-preklady/"

local CATALOG_TTL = 24 * 60 * 60               -- seconds
local MAX_DOWNLOAD_BYTES = 20 * 1024 * 1024     -- 20 MB
local MAX_EXTRACTED_BYTES = 200 * 1024 * 1024   -- 200 MB
local SUB_MAX_AGE_DAYS = 30

function descriptor()
	return {
		title = "NyaSub Subtitles v" .. VERSION,
		version = VERSION,
		author = "Highflight Studio",
		shortdesc = "NyaSub subtitles",
		description = "Search nyasub.cz and download/apply Czech anime subtitles. No account needed.",
		capabilities = {}
	}
end

local dlg = nil
local search_input = nil
local results_list = nil
local status_label = nil

-- current_stage: "search" (results_list holds season/movie pages, id =
-- index into page_matches) or "episodes" (results_list holds episodes,
-- id = index into ep_rows)
local current_stage = "search"
local page_matches = {} -- [n] = {title=, label=, href=, slug=}
local ep_rows = {}      -- [n] = {episode=, url=}
local current_page = nil

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
-- The same PowerShell call also reports the Windows display language.
--
-- The UI is in Czech when the system language is Czech or Slovak, and in
-- English otherwise. start_extension runs both when the extension opens.
local ui_lang = "en"

-- L("english", "czech", ...): the text for the UI language, with %s
-- placeholders filled in like string.format
local function L(en, cs, ...)
	return string.format((ui_lang == "cs") and cs or en, ...)
end

local function language_of(code)
	code = string.lower(code or "")
	if string.match(code, "^%s*cs") or string.match(code, "^%s*sk") then return "cs" end
	return "en"
end

local function start_extension()
	local env = os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or os.getenv("LANG")
	if is_windows() then
		if vlc.win and vlc.win.console_init then
			local ok, err = pcall(vlc.win.console_init)
			if not ok then log("couldn't create the hidden console: " .. tostring(err)) end
		end
		local culture = run('powershell -NoProfile -WindowStyle Hidden -Command "(Get-UICulture).Name"')
		ui_lang = language_of(culture)
	elseif env and env ~= "" and env ~= "C" and env ~= "POSIX" and not string.match(env, "^C%.") then
		ui_lang = language_of(env)
	else
		-- macOS apps started from the Dock or Finder get no LANG
		local langs = run("defaults read -g AppleLanguages 2>/dev/null") or ""
		ui_lang = language_of(string.match(langs, '"?([%a%-_]+)'))
	end
	log("UI language: " .. ui_lang)
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

local function strip_tags(s)
	return (string.gsub(s or "", "<[^>]+>", ""))
end

-- One entry per season/movie/OVA link, in page order:
-- {title = <the <h2> heading>, label = <link text>, href =, slug =}
local function parse_catalog(html)
	html = html or ""
	local headings = {}
	local pos = 1
	while true do
		local s, e, inner = string.find(html, "<h2[^>]*>(.-)</h2>", pos)
		if not s then break end
		table.insert(headings, { start = s, stop = e, title = trim(decode_entities(strip_tags(inner))) })
		pos = e + 1
	end
	local pages = {}
	for i, h in ipairs(headings) do
		local section_end = headings[i + 1] and (headings[i + 1].start - 1) or #html
		local section = string.sub(html, h.stop + 1, section_end)
		if h.title ~= "" then
			for href, label in string.gmatch(section,
				'<a%s[^>]-href="(https://nyasub%.cz/hotove%-preklady/[%w%-]+/)"[^>]->%s*([^<]-)%s*</a>') do
				label = trim(decode_entities(label))
				if label ~= "" then
					table.insert(pages, {
						title = h.title, label = label, href = href,
						slug = string.match(href, "/hotove%-preklady/([%w%-]+)/$") or "page",
					})
				end
			end
		end
	end
	return pages
end

local function save_catalog(pages)
	local lines = { tostring(os.time()) }
	for _, p in ipairs(pages) do
		table.insert(lines, p.title .. "\t" .. p.label .. "\t" .. p.href)
	end
	write_file(catalog_file(), table.concat(lines, "\n") .. "\n")
end

local function load_catalog()
	local data = read_file(catalog_file())
	if not data then return nil end
	local ts = tonumber(string.match(data, "^(%d+)"))
	if not ts or os.time() - ts > CATALOG_TTL then return nil end
	local pages = {}
	for title, label, href in string.gmatch(data, "\n([^\t\n]+)\t([^\t\n]+)\t([^\t\n]+)") do
		table.insert(pages, {
			title = title, label = label, href = href,
			slug = string.match(href, "/hotove%-preklady/([%w%-]+)/$") or "page",
		})
	end
	if #pages == 0 then return nil end
	return pages
end

local function get_catalog()
	local cached = load_catalog()
	if cached then
		log("using cached catalog (" .. #cached .. " pages)")
		return cached
	end
	log("catalog cache missing or stale, rebuilding")
	local pages = parse_catalog(curl_get(CATALOG_URL))
	log("catalog: " .. #pages .. " season/movie page(s) on " .. CATALOG_URL)
	if #pages > 0 then save_catalog(pages) end
	return pages
end

local function page_display(p)
	if string.lower(p.label) == string.lower(p.title) then return p.title end
	return p.title .. " - " .. p.label
end

-- ranks pages by how many query words appear in "title - label"; the whole
-- query appearing as-is ranks highest. Returns matches only (may be empty).
local function rank_pages(query, pages)
	local q = string.lower(trim(query))
	local words = {}
	for w in string.gmatch(q, "[^%s%p]+") do table.insert(words, w) end
	local scored = {}
	for i, p in ipairs(pages) do
		local t = string.lower(page_display(p))
		local score = 0
		if q ~= "" and string.find(t, q, 1, true) then score = score + 100 end
		for _, w in ipairs(words) do
			if string.find(t, w, 1, true) then score = score + 1 end
		end
		if score > 0 then table.insert(scored, { page = p, score = score, order = i }) end
	end
	table.sort(scored, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		return a.order < b.order -- keep the site's own season order
	end)
	local out = {}
	for _, e in ipairs(scored) do table.insert(out, e.page) end
	return out
end

-- episode download links in on-screen order: episode N = Nth "Titulky" link
local function parse_episode_links(html)
	local rows = {}
	for href, inner in string.gmatch(html or "", '<a%s[^>]-href="([^"]*%?wpdmdl=%d+[^"]*)"[^>]->(.-)</a>') do
		if string.find(string.lower(inner), "titulky", 1, true) then
			local url = decode_entities(href)
			if not string.match(url, "^https?://") then
				url = BASE_URL .. (string.sub(url, 1, 1) == "/" and "" or "/") .. url
			end
			table.insert(rows, { episode = #rows + 1, url = url })
		end
	end
	return rows
end

local function pause(seconds)
	if vlc.misc and vlc.misc.mwait and vlc.misc.mdate then
		pcall(function() vlc.misc.mwait(vlc.misc.mdate() + seconds * 1000000) end)
	end
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
	pcall(start_extension)
	pcall(cleanup_old_subtitles)
	show_dialog()
end

function deactivate()
	if dlg then dlg:delete() end
end

function close()
	vlc.deactivate()
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
	dlg = vlc.dialog("NyaSub Subtitles v" .. VERSION)
	local guessed_title = guess_title_from_playing()

	dlg:add_label(L("Search:", "Hledat:"), 1, 1, 1, 1)
	search_input = dlg:add_text_input(guessed_title or "", 2, 1, 2, 1)
	dlg:add_button(L("Search", "Hledat"), do_search, 1, 2, 1, 1)
	dlg:add_button(L("View Episodes", "Zobrazit epizody"), do_view_episodes, 2, 2, 1, 1)
	dlg:add_button(L("Download Selected", "Stáhnout vybrané"), do_download, 3, 2, 1, 1)

	results_list = dlg:add_list(1, 3, 3, 1)
	local initial_status = guessed_title
		and L("Guessed '%s' from the playing file. Edit if wrong, then Search.", "Odhadnutý název „%s“ podle přehrávaného souboru - případně ho upravte a klikněte na Hledat.", guessed_title)
		or L("Type a show title (or leave empty to list everything), then Search.", "Napište název anime (nebo nechte prázdné pro celý seznam) a klikněte na Hledat.")
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
	set_status(L("Loading the list of translations...", "Načítám seznam překladů..."))

	local pages = get_catalog()
	if #pages == 0 then
		set_status(L("Couldn't load the list of translations from the site (see debug log).", "Nepodařilo se načíst seznam překladů ze stránky (podrobnosti v logu)."))
		return
	end

	local base, season = split_season_title(query)
	local matches = season_first(rank_pages(base, pages), season, page_display)
	local note
	if query == "" or #matches == 0 then
		matches = {}
		for _, p in ipairs(pages) do table.insert(matches, p) end
		note = (query == "") and L("%s seasons/movies on the site.", "Série a filmy na stránce: %s.", #matches)
			or L("No match for '%s', showing everything (%s).", "Pro „%s“ nic nenalezeno, zobrazuji vše (%s).", query, #matches)
	else
		note = L("%s match(es) for '%s'.", "Nalezené výsledky (%s) pro „%s“.", #matches, query)
	end

	page_matches = matches
	results_list:clear()
	for i, p in ipairs(page_matches) do
		results_list:add_value(page_display(p), i)
	end
	current_stage = "search"
	set_status(L("%s Select one, then 'View Episodes'.", "%s Vyberte jednu a klikněte na „Zobrazit epizody“.", note))
end

function do_view_episodes()
	if current_stage ~= "search" then
		set_status(L("Search first, then select a season or movie from the list.", "Nejdřív vyhledávejte, pak vyberte sérii nebo film ze seznamu."))
		return
	end
	local idx = selected_index()
	if not idx or not page_matches[idx] then
		set_status(L("Select a season or movie from the list first.", "Nejdřív vyberte sérii nebo film ze seznamu."))
		return
	end
	current_page = page_matches[idx]
	local name = page_display(current_page)
	set_status(L("Loading episodes for '%s'...", "Načítám epizody pro „%s“...", name))

	ep_rows = parse_episode_links(curl_get(current_page.href))
	log(#ep_rows .. " episode link(s) on " .. current_page.href)

	results_list:clear()
	for i, row in ipairs(ep_rows) do
		results_list:add_value(L("Episode %s", "Epizoda %s", row.episode), i)
	end
	current_stage = "episodes"

	if #ep_rows == 0 then
		set_status(L("No episodes found for '%s' (see debug log).", "Pro „%s“ nebyly nalezeny žádné epizody (podrobnosti v logu).", name))
	else
		set_status(L("%s episode(s) for '%s'. Select one, then Download.", "Nalezené epizody (%s) pro „%s“. Vyberte jednu a klikněte na Stáhnout.", #ep_rows, name))
	end
end

-- downloads url into dl_path, retrying once if the response looks wrong
-- (see the header comment: this site's status codes aren't trustworthy).
-- Returns data, or nil plus "too_large".
local function download_with_retry(url, dl_path, hdr_path)
	for attempt = 1, 2 do
		os.remove(dl_path)
		os.remove(hdr_path)
		local curl_err = run(string.format('curl -sS -L --max-time 60 --max-filesize %d -D "%s" -o "%s" "%s" 2>&1',
			MAX_DOWNLOAD_BYTES, hdr_path, dl_path, url)) or ""
		if string.find(curl_err, "(63)", 1, true) then return nil, "too_large" end
		local data = read_file(dl_path)
		local ok, reason = check_download(data)
		if ok then return data end
		log("attempt " .. attempt .. " rejected: " .. reason)
		if attempt == 1 then pause(1.5) end
	end
	return read_file(dl_path)
end

local function download_selected()
	if current_stage ~= "episodes" then
		set_status(L("View a season's episodes first, then select one to download.", "Nejdřív zobrazte epizody série, pak vyberte jednu ke stažení."))
		return
	end
	local idx = selected_index()
	if not idx or not ep_rows[idx] then
		set_status(L("Select an episode from the list first.", "Nejdřív vyberte epizodu ze seznamu."))
		return
	end
	local row = ep_rows[idx]
	local label = string.format("E%02d", row.episode)
	set_status(L("Downloading episode %s...", "Stahuji epizodu %s...", row.episode))

	local work = work_dir()
	remove_dir(work)
	make_dir(work)
	local dl_path = join(work, "download.bin")
	local hdr_path = join(work, "headers.txt")

	local data, err = download_with_retry(row.url, dl_path, hdr_path)
	if err == "too_large" then
		log("download refused by curl: over " .. MAX_DOWNLOAD_BYTES .. " bytes")
		set_status(L("Download refused: the file is larger than a subtitle should be.", "Stažení odmítnuto: soubor je na titulky příliš velký."))
		return
	end
	local ok, reason = check_download(data)
	if not ok then
		log("download rejected: " .. reason)
		set_status(L("Download failed: %s. Try again in a moment.", "Stažení selhalo: %s. Zkuste to za chvíli znovu.", reason))
		return
	end

	local sub_path, ext
	if string.sub(data, 1, 2) == "PK" then
		local total, info = inspect_zip(data)
		if not total then
			log("zip refused: " .. tostring(info))
			set_status(L("Downloaded a zip but it looks broken or unsafe (see debug log).", "ZIP se stáhl, ale vypadá poškozeně nebo nebezpečně (podrobnosti v logu)."))
			return
		end
		if total > MAX_EXTRACTED_BYTES then
			log("zip refused: " .. total .. " bytes uncompressed")
			set_status(L("Download refused: the archive is far too large when unpacked.", "Stažení odmítnuto: archiv by byl po rozbalení příliš velký."))
			return
		end
		local zip_path = join(work, "download.zip")
		os.rename(dl_path, zip_path)
		sub_path = extract_zip(zip_path, join(work, "extract"))
		if not sub_path then
			set_status(L("Downloaded a zip but found no subtitle inside (see debug log).", "ZIP se stáhl, ale nejsou v něm žádné titulky (podrobnosti v logu)."))
			return
		end
		ext = string.lower(string.match(sub_path, "%.(%w+)$") or "srt")
	else
		sub_path = dl_path
		ext = guess_extension(read_file(hdr_path), data)
	end

	local dest_dir = subtitles_dir()
	make_dir(dest_dir)
	local final_name = string.format("%s_%s_%s_%d.%s", PREFIX, current_page.slug, label, os.time(), ext)
	local final_path = join(dest_dir, final_name)
	if not copy_file(sub_path, final_path) then
		log("could not write " .. final_path)
		set_status(L("Downloaded, but couldn't save into %s (see debug log).", "Staženo, ale nepodařilo se uložit do %s (podrobnosti v logu).", dest_dir))
		return
	end
	log("saved subtitle to " .. final_path)

	if attach_subtitle(final_path) then
		set_status(L("Downloaded and applied: %s", "Staženo a načteno: %s", final_name))
	else
		set_status(L("Saved to %s (no video playing, open one and add it manually).", "Uloženo do %s (nehraje žádné video, otevřete ho a titulky přidejte ručně).", final_path))
	end
end

function do_download()
	local ok, err = pcall(download_selected)
	remove_dir(work_dir())
	if not ok then
		log("download error: " .. tostring(err))
		set_status(L("Something went wrong during the download (see debug log).", "Při stahování se něco pokazilo (podrobnosti v logu)."))
	end
end
