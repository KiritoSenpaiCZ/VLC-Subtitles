--[[
Hanabi (hanabi.fan) Subtitle Downloader - VLC Extension

Unlike the other extensions in this family, this one doesn't scrape web
pages: it uses Hanabi's own official REST API
(https://hanabi.fan/wp-json/hanabi/v1), which the site's owner built and
published so tools like this can integrate. Logic ported from the Kodi
addon (service.subtitles.hanabi 1.1.x), which implements the API
maintainer's own review feedback.

Auth: a personal access token, created at hanabi.fan under account
settings -> "Pristupovy token", entered once in this extension's Token
field. It is stored like the other extensions store passwords (macOS
Keychain / Windows DPAPI-encrypted file), never in plain text. It is sent
to curl through a short-lived header file (curl -H @file) rather than on
the command line, so it never appears in the debug log or a process list,
and is never put in a URL.

Endpoints used:
  - GET /projects?query=<text>&page=N           search projects (paginated)
  - GET /projects/{id}/subtitles?episode=N&page=N releases of a project
  - the release's own download_url              the file, always a ZIP
Every listing is paginated via page/total_pages, and every page is read
(with safety caps). A project can have several releases per episode
(different groups or versions): all are listed, the user chooses.

Rate limits (account-wide, set by Hanabi): 60 requests/min for search and
listings, 10 downloads/min. An HTTP 429 carries Retry-After (seconds):
a wait up to MAX_RATE_LIMIT_WAIT is absorbed automatically (one retry),
a longer one is reported instead of freezing VLC.

Downloads: the API serves an existing ZIP from storage (worst case about
30 s server-side, normally instant), capped at 50 MB by the API itself.
Safety rules as in the Kodi addon: size cap, must really be a ZIP, zip-bomb
guard and unsafe-path check before extracting. A whole-season pack is
handled by picking the file that matches the Episode field.

Housekeeping: finished subtitles go to Documents/VLC Subtitles (shared
with the other extensions); files this extension saved there are deleted
after SUB_MAX_AGE_DAYS. Temporary files are removed after every action.

IMPORTANT: VLC doesn't provide the standard "package" table while it scans
extensions at startup, so nothing at this file's top level may touch it.

Debug: enable VLC's debug log (Tools -> Messages, verbosity 2) and look for
lines starting with "[Hanabi]". The token is never logged.
]]

local VERSION = "1.0.0"
local TAG = "[Hanabi]"
local PREFIX = "hanabi" -- file-name prefix for everything this extension creates
local API_BASE = "https://hanabi.fan/wp-json/hanabi/v1"

local REQUEST_TIMEOUT = 15                      -- seconds, listings
local DOWNLOAD_TIMEOUT = 40                     -- seconds, matches the API's own worst case
local MAX_RATE_LIMIT_WAIT = 60                  -- seconds
local MAX_DOWNLOAD_BYTES = 55 * 1024 * 1024     -- the API caps a ZIP at 50 MB
local MAX_EXTRACTED_BYTES = 200 * 1024 * 1024   -- zip-bomb guard
local SUB_MAX_AGE_DAYS = 30

function descriptor()
	return {
		title = "Hanabi Subtitles v" .. VERSION,
		version = VERSION,
		author = "Highflight Studio",
		shortdesc = "Hanabi subtitles",
		description = "Search hanabi.fan through its official API and download/apply Czech anime subtitles. Needs a personal access token.",
		capabilities = {}
	}
end

local dlg = nil
local token_input, search_input, episode_input = nil, nil, nil
local results_list = nil
local status_label = nil
local loaded_token = ""

-- current_stage: "search" (results_list holds projects, id = index into
-- projects) or "releases" (results_list holds subtitle releases, id = index
-- into releases)
local current_stage = "search"
local projects = {}
local releases = {}
local current_project = nil

local set_status -- assigned in the dialog section, used by the API code

--[[ ---------------- platform helpers ---------------- ]]

-- VLC doesn't provide the standard "package" table while it scans
-- extensions at startup (confirmed from a Windows VLC 3 log), so this must
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
-- debug log - nothing secret here, but same helper as the other extensions)
local function run(cmd, log_line)
	log("running: " .. (log_line or cmd))
	local p = io.popen(cmd, "r")
	if not p then return nil end
	local out = p:read("*a")
	p:close()
	return out
end

local function file_size(path)
	local f = io.open(path, "rb")
	if not f then return 0 end
	local size = f:seek("end") or 0
	f:close()
	return size
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

--[[ ---------------- text helpers ---------------- ]]

local function urlencode(str)
	if str == nil then return "" end
	str = string.gsub(str, "([^%w%-%_%.%~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	return str
end

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
-- the search box starts pre-filled (same helper as the other extensions)
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

--[[ ---------------- JSON ----------------
Small JSON decoder (VLC's Lua has no JSON library that can be relied on
here). Objects become tables with string keys, arrays become 1-based
tables, null becomes the JSON_NULL sentinel (so a field that is present
but null can be told apart from a missing one where it matters), and
\uXXXX escapes (including surrogate pairs) become UTF-8.
json_decode returns the value, or nil plus an error message.
]]

-- a unique marker table, compared by identity. Plain {} on purpose: VLC's
-- startup scan provides almost no standard functions (not even
-- setmetatable), so the top level of this file must not call anything.
local JSON_NULL = {}

local function json_decode(text)
	if type(text) ~= "string" then return nil, "not a string" end
	local pos = 1

	local function fail(msg)
		error({ json_error = msg .. " at position " .. pos }, 0)
	end

	local function skip_ws()
		pos = string.find(text, "[^ \t\r\n]", pos) or (#text + 1)
	end

	local parse_value

	local function parse_string()
		-- pos is at the opening quote
		local out = {}
		pos = pos + 1
		while true do
			local c = string.sub(text, pos, pos)
			if c == "" then fail("unterminated string") end
			if c == '"' then
				pos = pos + 1
				return table.concat(out)
			elseif c == "\\" then
				local e = string.sub(text, pos + 1, pos + 1)
				local simple = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
				if simple[e] then
					table.insert(out, simple[e])
					pos = pos + 2
				elseif e == "u" then
					local hex = string.sub(text, pos + 2, pos + 5)
					if not string.match(hex, "^%x%x%x%x$") then fail("bad \\u escape") end
					local cp = tonumber(hex, 16)
					pos = pos + 6
					if cp >= 0xD800 and cp <= 0xDBFF and string.sub(text, pos, pos + 1) == "\\u" then
						local low = tonumber(string.sub(text, pos + 2, pos + 5), 16)
						if low and low >= 0xDC00 and low <= 0xDFFF then
							cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
							pos = pos + 6
						end
					end
					table.insert(out, utf8_char(cp))
				else
					fail("bad escape")
				end
			else
				-- copy a run of ordinary characters in one go
				local stop = string.find(text, '["\\]', pos) or (#text + 1)
				table.insert(out, string.sub(text, pos, stop - 1))
				pos = stop
			end
		end
	end

	local function parse_number()
		local num = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
		if not num or num == "" or num == "-" then fail("bad number") end
		pos = pos + #num
		local n = tonumber(num)
		if n == nil then fail("bad number") end
		return n
	end

	local function parse_array()
		local arr = {}
		pos = pos + 1
		skip_ws()
		if string.sub(text, pos, pos) == "]" then
			pos = pos + 1
			return arr
		end
		while true do
			table.insert(arr, parse_value())
			skip_ws()
			local c = string.sub(text, pos, pos)
			pos = pos + 1
			if c == "]" then return arr end
			if c ~= "," then fail("expected , or ] in array") end
		end
	end

	local function parse_object()
		local obj = {}
		pos = pos + 1
		skip_ws()
		if string.sub(text, pos, pos) == "}" then
			pos = pos + 1
			return obj
		end
		while true do
			skip_ws()
			if string.sub(text, pos, pos) ~= '"' then fail("expected a key") end
			local key = parse_string()
			skip_ws()
			if string.sub(text, pos, pos) ~= ":" then fail("expected :") end
			pos = pos + 1
			obj[key] = parse_value()
			skip_ws()
			local c = string.sub(text, pos, pos)
			pos = pos + 1
			if c == "}" then return obj end
			if c ~= "," then fail("expected , or } in object") end
		end
	end

	parse_value = function()
		skip_ws()
		local c = string.sub(text, pos, pos)
		if c == "{" then return parse_object() end
		if c == "[" then return parse_array() end
		if c == '"' then return parse_string() end
		if c == "-" or string.match(c, "%d") then return parse_number() end
		if string.sub(text, pos, pos + 3) == "true" then pos = pos + 4; return true end
		if string.sub(text, pos, pos + 4) == "false" then pos = pos + 5; return false end
		if string.sub(text, pos, pos + 3) == "null" then pos = pos + 4; return JSON_NULL end
		fail("unexpected character '" .. c .. "'")
	end

	local ok, result = pcall(function()
		local v = parse_value()
		skip_ws()
		if pos <= #text then fail("trailing characters") end
		return v
	end)
	if ok then return result end
	if type(result) == "table" and result.json_error then return nil, result.json_error end
	return nil, tostring(result)
end

-- a JSON value as a plain Lua value: JSON_NULL -> nil
local function jv(v)
	if v == JSON_NULL then return nil end
	return v
end

-- integers stay integers, floats are left alone, for display
local function num_str(v)
	v = jv(v)
	if type(v) == "number" and v == math.floor(v) then return string.format("%d", v) end
	return v ~= nil and tostring(v) or nil
end

--[[ ---------------- token storage ----------------
Same secure-storage approach the other extensions use for passwords:
macOS Keychain via the `security` CLI, Windows DPAPI via a short-lived
PowerShell script (the encrypted blob can only be decrypted by the same
Windows user).
]]

local KEYCHAIN_SERVICE = "VLC Hanabi Extension"
local KEYCHAIN_ACCOUNT = "access-token"

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

local function win_token_file()
	return join(vlc.config.userdatadir(), PREFIX .. "_token.dat")
end

local function run_ps_script(script, name)
	local script_path = join(vlc.config.userdatadir(), PREFIX .. "_" .. name .. ".ps1")
	if not write_file(script_path, script) then return nil end
	local out = run(string.format('powershell -NoProfile -ExecutionPolicy Bypass -File "%s"', script_path),
		"powershell (" .. name .. " script, contents not logged)")
	os.remove(script_path)
	return out
end

local function save_token(token)
	if is_windows() then
		run_ps_script("$s = ConvertTo-SecureString -String " .. ps_squote(token) .. " -AsPlainText -Force\n"
			.. "$enc = ConvertFrom-SecureString -SecureString $s\n"
			.. "Set-Content -Path " .. ps_squote(win_token_file()) .. " -Value $enc -NoNewline\n", "save_token")
	else
		run(string.format("security add-generic-password -a %s -s %s -w %s -U",
			sh_dquote(KEYCHAIN_ACCOUNT), sh_dquote(KEYCHAIN_SERVICE), sh_dquote(token)),
			"security add-generic-password (token not logged)")
	end
end

local function load_token()
	local out
	if is_windows() then
		local f = io.open(win_token_file(), "r")
		if not f then return "" end
		f:close()
		out = run_ps_script("$enc = Get-Content -Path " .. ps_squote(win_token_file()) .. " -Raw\n"
			.. "$s = ConvertTo-SecureString -String $enc\n"
			.. "$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)\n"
			.. "[System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)\n", "load_token")
	else
		out = run(string.format("security find-generic-password -a %s -s %s -w 2>/dev/null",
			sh_dquote(KEYCHAIN_ACCOUNT), sh_dquote(KEYCHAIN_SERVICE)))
	end
	return trim(out or "")
end

--[[ ---------------- API access ---------------- ]]

local function api_file(name)
	return join(vlc.config.userdatadir(), PREFIX .. "_" .. name)
end

local function pause(seconds)
	if vlc.misc and vlc.misc.mwait and vlc.misc.mdate then
		pcall(function() vlc.misc.mwait(vlc.misc.mdate() + seconds * 1000000) end)
	end
end

-- One authenticated GET. The token goes to curl through a header file
-- that is deleted right after (never on the command line, never logged).
-- Returns status (0 if curl failed to get any response), response headers,
-- and curl's own error text.
local function api_http(url, token, out_path, timeout, max_bytes)
	local auth_path = api_file("auth.txt")
	local hdr_path = api_file("resp_headers.txt")
	write_file(auth_path, "Authorization: Bearer " .. token .. "\n")
	os.remove(hdr_path)
	os.remove(out_path)
	local size_opt = max_bytes and (" --max-filesize " .. max_bytes) or ""
	-- note: the -w text must not start with "@" (curl would read it as a file name)
	local cmd = string.format('curl -sS -L --max-time %d%s -H "@%s" -H "Accept: application/json" -D "%s" -o "%s" -w "\\n@@STATUS@@%%{http_code}" "%s" 2>&1',
		timeout, size_opt, auth_path, hdr_path, out_path, url)
	local out = run(cmd, "curl GET " .. url .. " (token sent from a header file, not logged)") or ""
	os.remove(auth_path)
	local headers = read_file(hdr_path) or ""
	os.remove(hdr_path)
	local status = tonumber(string.match(out, "@@STATUS@@(%d+)") or "0") or 0
	local curl_err = string.gsub(out, "@@STATUS@@%d*", "")
	return status, headers, trim(curl_err)
end

-- last Retry-After value in the response headers (seconds), if any
local function retry_after(headers)
	local v = nil
	for val in string.gmatch(headers or "", "[Rr][Ee][Tt][Rr][Yy]%-[Aa][Ff][Tt][Ee][Rr]:%s*(%d+)") do
		v = tonumber(val)
	end
	return v
end

-- human-readable text for an API error, using the API's documented JSON
-- error body ({code, message, data:{status}}) when there is one
local function api_error_text(status, body)
	local data = json_decode(body or "")
	local msg = (type(data) == "table") and jv(data.message) or nil
	if type(msg) ~= "string" then msg = nil end
	if status == 401 or status == 403 then
		return "Hanabi rejected the token (missing, wrong, or account not approved)."
			.. (msg and (" Hanabi says: " .. msg) or "")
	end
	if status == 0 then return "Couldn't reach Hanabi (see debug log)." end
	if status == 429 then return "Hanabi rate limit hit, please wait a bit and try again." end
	return msg or ("Hanabi returned HTTP " .. status .. ".")
end

-- Runs a GET with Hanabi's rate-limit handling: on HTTP 429 it waits the
-- Retry-After time (if short enough) and retries exactly once.
-- Returns status, headers, curl error text.
local function api_get_with_retry(url, token, out_path, timeout, max_bytes)
	local status, headers, curl_err = api_http(url, token, out_path, timeout, max_bytes)
	if status == 429 then
		local wait = retry_after(headers) or 5
		if wait <= MAX_RATE_LIMIT_WAIT then
			log("HTTP 429, waiting " .. wait .. "s (Retry-After) and retrying once")
			set_status("Hanabi rate limit hit, waiting " .. wait .. " s...")
			pause(wait)
			status, headers, curl_err = api_http(url, token, out_path, timeout, max_bytes)
		else
			log("HTTP 429, Retry-After=" .. wait .. "s is too long, not retrying")
			return status, headers, curl_err, "Hanabi rate limit hit, try again in about "
				.. math.max(1, math.floor(wait / 60)) .. " minute(s)."
		end
	end
	return status, headers, curl_err
end

-- GET + JSON decode. Returns (true, data) or (false, message).
local function api_get_json(path_and_query, token)
	local out_path = api_file("api_body.json")
	local status, _, curl_err, long_wait_msg = api_get_with_retry(API_BASE .. path_and_query, token, out_path, REQUEST_TIMEOUT)
	local body = read_file(out_path) or ""
	os.remove(out_path)
	if long_wait_msg then return false, long_wait_msg end
	if status == 200 then
		local data, err = json_decode(body)
		if data == nil then
			log("bad JSON from " .. path_and_query .. ": " .. tostring(err))
			return false, "Unexpected response from Hanabi (see debug log)."
		end
		return true, data
	end
	log(path_and_query .. " -> HTTP " .. status .. (curl_err ~= "" and (" (" .. curl_err .. ")") or ""))
	return false, api_error_text(status, body)
end

-- Reads every page of a paginated listing (page/total_pages), with safety
-- caps. If a later page fails, what was already collected is kept.
-- Returns items, or nil plus a message.
local function api_get_all(path, query_params, per_page, token, max_pages, max_items)
	local items = {}
	local base = path .. "?" .. ((query_params ~= "") and (query_params .. "&") or "")
	for page = 1, max_pages do
		local ok, data = api_get_json(base .. "per_page=" .. per_page .. "&page=" .. page, token)
		if not ok then
			if #items > 0 then
				log("pagination for " .. path .. " stopped early on page " .. page .. ": " .. data)
				break
			end
			return nil, data
		end
		local page_items = (type(data) == "table") and jv(data.items) or nil
		if type(page_items) ~= "table" or #page_items == 0 then break end
		for _, it in ipairs(page_items) do
			table.insert(items, it)
			if #items >= max_items then
				log("hit max_items=" .. max_items .. " for " .. path)
				return items
			end
		end
		local total_pages = tonumber(jv(data.total_pages))
		if total_pages then
			if page >= total_pages then break end
		elseif #page_items < per_page then
			break -- no total_pages field: a short page is the last one
		end
		if page == max_pages then log("pagination for " .. path .. " hit max_pages=" .. max_pages) end
	end
	return items
end

local function search_projects(query, token)
	return api_get_all("/projects", "query=" .. urlencode(query), 20, token, 5, 100)
end

-- all releases of a project; episode (a number) narrows it to one episode
local function fetch_releases(project_id, episode, token)
	return api_get_all("/projects/" .. num_str(project_id) .. "/subtitles",
		episode and ("episode=" .. episode) or "", 50, token, 6, 300)
end

--[[ ---------------- display helpers ---------------- ]]

local function str_field(t, key)
	local v = jv(t[key])
	if type(v) == "string" then
		v = trim(v)
		if v ~= "" then return v end
		return nil
	end
	if type(v) == "number" then return num_str(v) end
	return nil
end

local function project_display(p)
	local title = str_field(p, "title") or "?"
	local alt = str_field(p, "english_title") or str_field(p, "original_title")
	if alt and string.lower(alt) ~= string.lower(title) then
		return title .. " / " .. alt
	end
	return title
end

local function release_display(r)
	local ep = num_str(r.episode)
	local text = (ep and ("E" .. (tonumber(ep) and tonumber(ep) < 10 and "0" or "") .. ep) or "(whole-season pack)")
		.. " - " .. (str_field(r, "release") or "?")
	local version = str_field(r, "version")
	if version then text = text .. " v" .. version end
	local note = str_field(r, "note")
	if note then text = text .. " (" .. note .. ")" end
	local lang = str_field(r, "language")
	if lang and lang ~= "cs" then text = "[" .. lang .. "] " .. text end
	return text
end

-- "name of the show" -> "name-of-the-show", for file names
local function slugify(s)
	s = string.lower(s or "")
	s = string.gsub(s, "[^%w]+", "-")
	s = string.gsub(s, "^%-+", "")
	s = string.gsub(s, "%-+$", "")
	if #s > 40 then s = string.gsub(string.sub(s, 1, 40), "%-+$", "") end
	if s == "" then s = "project" end
	return s
end

-- episode number from the playing file name: "S01E03" or "Title - 03 [..]"
local function guess_episode_from_playing()
	if not (vlc.input and vlc.input.item) then return nil end
	local ok, item = pcall(vlc.input.item)
	if not ok or not item then return nil end
	local uri = item:uri()
	if not uri then return nil end
	local name = string.match(uri, "([^/\\]+)$") or uri
	if vlc.strings and vlc.strings.decode_uri then name = vlc.strings.decode_uri(name) end
	name = string.gsub(name, "%.%w+$", "")
	local ep = string.match(name, "[Ss]%d%d?[Ee](%d%d?%d?)")
		or string.match(name, "%s%-%s*(%d%d?%d?)%f[^%d]")
		or string.match(name, "%s[Ee][Pp]?%s?(%d%d?%d?)%f[^%d]")
	return ep and tonumber(ep) or nil
end

-- the subtitle file in an extracted pack that matches episode ep (nil if
-- ep is unknown or nothing matches: the user is asked, never guessed for)
local function pick_episode_file(paths, ep)
	if not ep then return nil end
	for _, p in ipairs(paths) do
		local name = string.match(p, "([^/\\]+)$") or p
		name = string.gsub(name, "%.%w+$", "")
		for num in string.gmatch(name, "%d+") do
			if tonumber(num) == ep and #num <= 3 then return p end
		end
	end
	return nil
end

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

--[[ ---------------- dialog ---------------- ]]

function activate()
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
	dlg = vlc.dialog("Hanabi Subtitles v" .. VERSION)
	local ok, tok = pcall(load_token)
	loaded_token = (ok and tok) or ""
	local guessed_title = guess_title_from_playing()
	local guessed_ep = guess_episode_from_playing()

	dlg:add_label("Access token:", 1, 1, 1, 1)
	token_input = dlg:add_password(loaded_token, 2, 1, 2, 1)
	dlg:add_label("Search:", 1, 2, 1, 1)
	search_input = dlg:add_text_input(guessed_title or "", 2, 2, 2, 1)
	dlg:add_label("Episode (optional):", 1, 3, 1, 1)
	episode_input = dlg:add_text_input(guessed_ep and tostring(guessed_ep) or "", 2, 3, 2, 1)
	dlg:add_button("Search", do_search, 1, 4, 1, 1)
	dlg:add_button("View Subtitles", do_view_releases, 2, 4, 1, 1)
	dlg:add_button("Download Selected", do_download, 3, 4, 1, 1)

	results_list = dlg:add_list(1, 5, 3, 1)
	local initial_status
	if loaded_token == "" then
		initial_status = "Paste your access token (hanabi.fan > account settings > 'P\197\153\195\173stupov\195\189 token'), then Search."
	elseif guessed_title then
		initial_status = "Guessed '" .. guessed_title .. "'" .. (guessed_ep and (", episode " .. guessed_ep) or "")
			.. " from the playing file. Edit if wrong, then Search."
	else
		initial_status = "Type a show title, then Search."
	end
	status_label = dlg:add_label(initial_status, 1, 6, 3, 1)
	dlg:show()
end

set_status = function(text)
	status_label:set_text(text)
	dlg:update()
end

local function selected_index()
	local sel = results_list:get_selection()
	for id, _ in pairs(sel or {}) do return id end
	return nil
end

-- the token from the field; saved to secure storage when it changed
local function current_token()
	local token = trim(token_input:get_text())
	if token ~= "" and token ~= loaded_token then
		save_token(token)
		loaded_token = token
	end
	return token
end

local function episode_filter()
	local n = tonumber(trim(episode_input:get_text()))
	if n and n >= 0 and n == math.floor(n) then return n end
	return nil
end

--[[ ---------------- actions ---------------- ]]

function do_search()
	local token = current_token()
	if token == "" then
		set_status("Paste your Hanabi access token first.")
		return
	end
	local query = trim(search_input:get_text())
	if query == "" then
		set_status("Type a show title to search for.")
		return
	end

	set_status("Searching Hanabi...")
	local found, err = search_projects(query, token)
	if not found then
		set_status(err)
		return
	end
	projects = found
	log("search '" .. query .. "' -> " .. #projects .. " project(s)")

	results_list:clear()
	for i, p in ipairs(projects) do
		results_list:add_value(project_display(p), i)
	end
	current_stage = "search"
	if #projects == 0 then
		set_status("No projects found for '" .. query .. "'.")
	else
		set_status(#projects .. " project(s) found. Select one, then 'View Subtitles'.")
	end
end

function do_view_releases()
	if current_stage ~= "search" then
		set_status("Search first, then select a project from the list.")
		return
	end
	local idx = selected_index()
	if not idx or not projects[idx] then
		set_status("Select a project from the list first.")
		return
	end
	local token = current_token()
	current_project = projects[idx]
	local name = project_display(current_project)
	local ep = episode_filter()
	set_status("Loading subtitles for '" .. name .. "'" .. (ep and (", episode " .. ep) or "") .. "...")

	local found, err = fetch_releases(current_project.id, ep, token)
	if not found then
		set_status(err)
		return
	end
	local fell_back = false
	if #found == 0 and ep then
		fell_back = true
		-- nothing for that episode: show everything rather than an empty list
		log("no releases for episode " .. ep .. ", loading the full list")
		found, err = fetch_releases(current_project.id, nil, token)
		if not found then
			set_status(err)
			return
		end
	end
	releases = found
	log(#releases .. " release(s) for project " .. tostring(num_str(current_project.id)))

	results_list:clear()
	for i, r in ipairs(releases) do
		results_list:add_value(release_display(r), i)
	end
	current_stage = "releases"
	if #releases == 0 then
		set_status("No subtitles found for '" .. name .. "'.")
	elseif fell_back then
		set_status("Nothing for episode " .. ep .. ", showing all " .. #releases .. " subtitle(s). Select one, then Download.")
	else
		set_status(#releases .. " subtitle(s). Select one, then Download.")
	end
end

local function download_selected()
	if current_stage ~= "releases" then
		set_status("View a project's subtitles first, then select one to download.")
		return
	end
	local idx = selected_index()
	if not idx or not releases[idx] then
		set_status("Select a subtitle from the list first.")
		return
	end
	local release = releases[idx]
	local token = current_token()
	local url = str_field(release, "download_url")
	if not url then
		log("release has no download_url")
		set_status("This subtitle has no download link (see debug log).")
		return
	end
	-- the token is only ever sent to Hanabi itself
	if not string.match(url, "^https://hanabi%.fan/") then
		log("refusing to send the token to a non-Hanabi download URL: " .. url)
		set_status("Download link points outside hanabi.fan, refusing for safety (see debug log).")
		return
	end

	set_status("Downloading...")
	local work = work_dir()
	remove_dir(work)
	make_dir(work)
	local zip_path = join(work, "download.zip")
	local status, _, curl_err, long_wait_msg = api_get_with_retry(url, token, zip_path, DOWNLOAD_TIMEOUT, MAX_DOWNLOAD_BYTES)
	if long_wait_msg then
		set_status(long_wait_msg)
		return
	end
	if string.find(curl_err or "", "(63)", 1, true) then
		set_status("Download refused: the file is larger than expected.")
		return
	end
	local data = read_file(zip_path)
	if status ~= 200 then
		log("download -> HTTP " .. status .. ((curl_err or "") ~= "" and (" (" .. curl_err .. ")") or ""))
		set_status("Download failed: " .. api_error_text(status, data))
		return
	end
	local ok, reason = check_download(data)
	if not ok then
		log("download rejected: " .. reason)
		set_status("Download failed: " .. reason .. ".")
		return
	end
	-- the API always serves a ZIP: anything else is an error page or junk,
	-- rejected rather than guessed at and saved as a subtitle
	if string.sub(data, 1, 2) ~= "PK" then
		log("download isn't a ZIP (first bytes: " .. string.gsub(string.sub(data, 1, 16), "[^%w%p ]", "?") .. ")")
		set_status("Download failed: the response wasn't a subtitle archive (see debug log).")
		return
	end
	local total, info = inspect_zip(data)
	if not total then
		log("zip refused: " .. tostring(info))
		set_status("Downloaded archive looks broken or unsafe (see debug log).")
		return
	end
	if total > MAX_EXTRACTED_BYTES then
		log("zip refused: " .. total .. " bytes uncompressed")
		set_status("Download refused: the archive is far too large when unpacked.")
		return
	end

	local extract_dir = join(work, "extract")
	make_dir(extract_dir)
	if is_windows() then
		run(string.format('tar -xf "%s" -C "%s" 2>nul', zip_path, extract_dir))
	else
		run(string.format('unzip -o "%s" -d "%s" >/dev/null 2>&1', zip_path, extract_dir))
	end
	local subs = {}
	for _, path in ipairs(list_files_recursive(extract_dir)) do
		local ext = string.lower(string.match(path, "%.(%w+)$") or "")
		if SUBTITLE_EXTS[ext] then table.insert(subs, path) end
	end
	table.sort(subs)
	if #subs == 0 then
		set_status("Downloaded, but there was no subtitle file in the archive (see debug log).")
		return
	end

	local ep = tonumber(num_str(release.episode)) or episode_filter()
	local chosen = subs[1]
	local note = ""
	if #subs > 1 then
		chosen = pick_episode_file(subs, ep)
		if not chosen then
			log("pack with " .. #subs .. " files, none matched episode " .. tostring(ep))
			set_status("This is a pack of " .. #subs .. " files. Put the episode number in the Episode field, then Download again.")
			return
		end
		note = " (from a pack of " .. #subs .. ")"
	end

	local ext = string.lower(string.match(chosen, "%.(%w+)$") or "srt")
	local label = ep and string.format("E%02d", ep) or "sub"
	local final_name = string.format("%s_%s_%s_%d.%s", PREFIX, slugify(str_field(current_project, "title")), label, os.time(), ext)
	local dest_dir = subtitles_dir()
	make_dir(dest_dir)
	local final_path = join(dest_dir, final_name)
	if not copy_file(chosen, final_path) then
		log("could not write " .. final_path)
		set_status("Downloaded, but couldn't save into " .. dest_dir .. " (see debug log).")
		return
	end
	log("saved subtitle to " .. final_path)

	if attach_subtitle(final_path) then
		set_status("Downloaded and applied" .. note .. ": " .. final_name)
	else
		set_status("Saved to " .. final_path .. note .. " (no video playing, open one and add it manually).")
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
