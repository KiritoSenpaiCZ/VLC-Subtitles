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
