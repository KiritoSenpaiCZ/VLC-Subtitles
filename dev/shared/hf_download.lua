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
