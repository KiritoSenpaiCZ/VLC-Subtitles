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
