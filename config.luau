--!strict
-- config.json: parsing, validation and path matching. Pure apart from `reader`
-- and `load_or_create`, which touch tern.fs / tern.json. Shared by both halves:
-- the host half validates at plugin load (so a bad config shows up in
-- `tern plugin list`), the window half applies the rules.
local M = {}

export type Place = "right" | "down" | "tab"
export type Of = "shell" | "previous"
export type Entry = { block: string, place: Place, ratio: number, of: Of }
export type Rule = { index: number, path: string, blocks: { Entry } }
export type Config = {
	auto_open: boolean,
	max_opens_per_minute: number,
	max_blocks_per_tab: number,
	rules: { Rule },
	-- Human-readable validation problems. Invalid rules/entries are skipped.
	problems: { string },
}

M.MAX_FILE_BYTES = 65536
M.MAX_RULES = 64
M.MAX_BLOCKS_PER_RULE = 8
M.DEFAULT_RATIO = 0.5
M.MIN_RATIO = 0.1
M.MAX_RATIO = 0.9

local DEFAULT_OPENS_PER_MINUTE = 6
local DEFAULT_BLOCKS_PER_TAB = 8

M.DEFAULT_TEXT = [[{
  "auto_open": true,
  "max_opens_per_minute": 6,
  "max_blocks_per_tab": 8,
  "rules": []
}
]]

local TOP_KEYS = { auto_open = true, max_opens_per_minute = true, max_blocks_per_tab = true, rules = true }
local RULE_KEYS = { path = true, blocks = true }
local ENTRY_KEYS = { block = true, place = true, ratio = true, of = true }

--- Collapses `//`, `.` and `..` and drops a trailing slash. nil unless `path` is absolute.
function M.normalize(path: string): string?
	if string.sub(path, 1, 1) ~= "/" then
		return nil
	end
	local parts: { string } = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return "/" .. table.concat(parts, "/")
end

--- Expands a leading `~`; nil when it cannot (`~user`, or no home).
function M.expand(path: string, home: string?): string?
	if path == "~" or string.sub(path, 1, 2) == "~/" then
		if home == nil or home == "" then
			return nil
		end
		return home .. string.sub(path, 2)
	end
	if string.sub(path, 1, 1) == "~" then
		return nil
	end
	return path
end

--- Whether `path` is `root` itself or below it. Both normalized.
function M.contains(root: string, path: string): boolean
	if root == "/" then
		return true
	end
	return path == root or string.sub(path, 1, #root + 1) == root .. "/"
end

--- The most specific (longest path) rule containing `path`; nil when none.
function M.best(rules: { Rule }, path: string): Rule?
	local norm = M.normalize(path)
	if norm == nil then
		return nil
	end
	local found: Rule? = nil
	for _, rule in rules do
		if M.contains(rule.path, norm) and (found == nil or #rule.path > #found.path) then
			found = rule
		end
	end
	return found
end

local function is_array(t: any): boolean
	if type(t) ~= "table" then
		return false
	end
	for k in t do
		if type(k) ~= "number" then
			return false
		end
	end
	return true
end

local function clamp_int(value: any, lo: number, hi: number, fallback: number, name: string, problems: { string }): number
	if value == nil then
		return fallback
	end
	if type(value) ~= "number" or value ~= value then
		table.insert(problems, name .. " must be a number")
		return fallback
	end
	return math.clamp(math.floor(value), lo, hi)
end

local function parse_entry(raw: any, label: string, problems: { string }): Entry?
	if type(raw) == "string" then
		raw = { block = raw }
	end
	if type(raw) ~= "table" or is_array(raw) and next(raw) ~= nil then
		table.insert(problems, label .. ": must be a block id string or an object")
		return nil
	end
	local ok = true
	for key in raw do
		if not ENTRY_KEYS[key] then
			table.insert(problems, label .. ": unknown key `" .. tostring(key) .. "`")
		end
	end
	local block = raw.block
	if type(block) ~= "string" or block == "" then
		table.insert(problems, label .. ": `block` must be a non-empty string")
		ok = false
	end
	local place: Place = "right"
	if raw.place ~= nil then
		if raw.place == "right" or raw.place == "down" or raw.place == "tab" then
			place = raw.place
		else
			table.insert(problems, label .. ": `place` must be \"right\", \"down\" or \"tab\"")
			ok = false
		end
	end
	local ratio = M.DEFAULT_RATIO
	if raw.ratio ~= nil then
		local r = raw.ratio
		if type(r) ~= "number" or r ~= r or r < M.MIN_RATIO or r > M.MAX_RATIO then
			table.insert(problems, label .. ": `ratio` must be a number from " .. M.MIN_RATIO .. " to " .. M.MAX_RATIO)
			ok = false
		else
			ratio = r
		end
	end
	local of: Of = "shell"
	if raw.of ~= nil then
		if raw.of == "shell" or raw.of == "previous" then
			of = raw.of
		else
			table.insert(problems, label .. ": `of` must be \"shell\" or \"previous\"")
			ok = false
		end
	end
	if of == "previous" and place == "tab" then
		table.insert(problems, label .. ": `of` does not apply to `place` \"tab\"")
		ok = false
	end
	if not ok then
		return nil
	end
	return { block = block, place = place, ratio = ratio, of = of }
end

local function parse_rule(raw: any, index: number, home: string?, problems: { string }): Rule?
	local label = "rules[" .. index .. "]"
	if type(raw) ~= "table" or is_array(raw) and next(raw) ~= nil then
		table.insert(problems, label .. ": must be an object")
		return nil
	end
	for key in raw do
		if not RULE_KEYS[key] then
			table.insert(problems, label .. ": unknown key `" .. tostring(key) .. "`")
		end
	end
	if type(raw.path) ~= "string" or raw.path == "" then
		table.insert(problems, label .. ": `path` must be a non-empty string")
		return nil
	end
	label = label .. " (" .. raw.path .. ")"
	local expanded = M.expand(raw.path, home)
	if expanded == nil then
		table.insert(problems, label .. ": cannot expand `~` here; use `~/…` or an absolute path")
		return nil
	end
	local path = M.normalize(expanded)
	if path == nil then
		table.insert(problems, label .. ": `path` must be absolute or start with `~/`")
		return nil
	end
	if path == "/" then
		table.insert(problems, label .. ": refusing to match the filesystem root; use a narrower path")
		return nil
	end
	if not is_array(raw.blocks) or #raw.blocks == 0 then
		table.insert(problems, label .. ": `blocks` must be a non-empty list")
		return nil
	end
	local blocks: { Entry } = {}
	for i, item in raw.blocks do
		if #blocks >= M.MAX_BLOCKS_PER_RULE then
			table.insert(problems, label .. ": more than " .. M.MAX_BLOCKS_PER_RULE .. " blocks; the rest are ignored")
			break
		end
		local entry = parse_entry(item, label .. " blocks[" .. i .. "]", problems)
		if entry and entry.of == "previous" and #blocks == 0 then
			table.insert(problems, label .. " blocks[" .. i .. "]: `of` \"previous\" needs an earlier block in the rule")
			entry = nil
		end
		if entry then
			table.insert(blocks, entry)
		end
	end
	if #blocks == 0 then
		return nil
	end
	return { index = index, path = path, blocks = blocks }
end

--- Validates a decoded config. Never raises; bad parts are skipped and reported in `problems`.
function M.parse(data: any, home: string?): Config
	local problems: { string } = {}
	local cfg: Config = {
		auto_open = true,
		max_opens_per_minute = DEFAULT_OPENS_PER_MINUTE,
		max_blocks_per_tab = DEFAULT_BLOCKS_PER_TAB,
		rules = {},
		problems = problems,
	}
	if type(data) ~= "table" or (is_array(data) and next(data) ~= nil) then
		table.insert(problems, "config.json must be a JSON object")
		return cfg
	end
	for key in data do
		if not TOP_KEYS[key] then
			table.insert(problems, "unknown key `" .. tostring(key) .. "`")
		end
	end
	if data.auto_open ~= nil then
		if type(data.auto_open) == "boolean" then
			cfg.auto_open = data.auto_open
		else
			table.insert(problems, "`auto_open` must be true or false")
		end
	end
	cfg.max_opens_per_minute =
		clamp_int(data.max_opens_per_minute, 1, 60, DEFAULT_OPENS_PER_MINUTE, "`max_opens_per_minute`", problems)
	cfg.max_blocks_per_tab = clamp_int(data.max_blocks_per_tab, 1, 16, DEFAULT_BLOCKS_PER_TAB, "`max_blocks_per_tab`", problems)
	if data.rules ~= nil then
		if not is_array(data.rules) then
			table.insert(problems, "`rules` must be a list")
		else
			local seen: { [string]: number } = {}
			for i, raw in data.rules do
				if #cfg.rules >= M.MAX_RULES then
					table.insert(problems, "more than " .. M.MAX_RULES .. " rules; the rest are ignored")
					break
				end
				local rule = parse_rule(raw, i, home, problems)
				if rule then
					local first = seen[rule.path]
					if first then
						table.insert(
							problems,
							"rules[" .. i .. "] (" .. rule.path .. "): same path as rules[" .. first .. "]; ignored"
						)
					else
						seen[rule.path] = i
						table.insert(cfg.rules, rule)
					end
				end
			end
		end
	end
	return cfg
end

local function failed(message: string, home: string?): Config
	local cfg = M.parse({}, home)
	table.insert(cfg.problems, message)
	return cfg
end

--- Parses config.json's text. Never raises.
function M.parse_text(text: string, home: string?): Config
	local decode_ok, data = pcall(tern.json.decode, text)
	if not decode_ok then
		return failed("config.json is not valid JSON: " .. tostring(data), home)
	end
	return M.parse(data, home)
end

-- The file's text, nil when it does not exist, or an error message.
local function read(path: string): (string?, string?)
	if not tern.fs.exists(path) then
		return nil, nil
	end
	local ok, text = pcall(tern.fs.read, path, M.MAX_FILE_BYTES)
	if not ok then
		return nil, "cannot read config.json: " .. tostring(text)
	end
	return text, nil
end

--- Reads and validates `path`. A missing file gives the defaults without problems.
function M.load(path: string, home: string?): Config
	local text, err = read(path)
	if err then
		return failed(err, home)
	end
	if text == nil then
		return M.parse({}, home)
	end
	return M.parse_text(text, home)
end

--- A loader that re-reads the file on every call but only re-parses when its text changed.
function M.reader(path: string, home: string?): () -> Config
	local cached_text: string? = nil
	local cached: Config? = nil
	return function(): Config
		local text, err = read(path)
		if err then
			return failed(err, home)
		end
		if cached ~= nil and text == cached_text then
			return cached
		end
		local cfg = if text == nil then M.parse({}, home) else M.parse_text(text, home)
		cached_text = text
		cached = cfg
		return cfg
	end
end

--- Host-half entry: validates, creating a default file on first run.
function M.load_or_create(path: string, home: string?): Config
	if not tern.fs.exists(path) then
		pcall(tern.fs.mkdir, (string.match(path, "^(.*)/[^/]*$")) or ".")
		pcall(tern.fs.write, path, M.DEFAULT_TEXT)
	end
	return M.load(path, home)
end

return M
