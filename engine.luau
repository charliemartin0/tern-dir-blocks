--!strict
-- The window half's logic: given a `cwd` event, decide which configured blocks
-- to open in the pane's tab, and open them. Everything the engine reads from
-- Tern goes through the `cx` it is handed and the `Deps` below, so test/test.luau
-- drives it with a fake window.
--
-- Invariants:
--   * only blocks listed by the single most specific matching rule are opened;
--   * each (tab, rule, block) is opened at most once until close_on_leave forgets it,
--     and never when that block is already in the tab;
--   * at most `max_blocks_per_tab` opens per tab and `max_opens_per_minute`
--     auto opens per window, however many events arrive (closing a block gives its slot back to the tab);
--   * only layout:split / layout:new_tab (open) and layout:close (close_on_leave, off by default) are
--     used: no new windows, and only blocks this plugin opened are ever closed;
--   * nothing here raises into Tern: every entry point is pcall'd.
local config = require("./config")

local M = {}

export type Log = { info: (...any) -> (), warn: (...any) -> () }
export type Deps = {
	load: () -> config.Config,
	kv_get: (key: string) -> any,
	kv_set: (key: string, value: any) -> (),
	--- Monotonic milliseconds.
	now: () -> number,
	log: Log,
	--- Called when the problem set or the enabled flag changed (redraw the status line).
	changed: () -> (),
}

-- A completed entry. A pane id means this plugin owns the block; nil only resets the
-- already-present entry's completion on leave, never closing someone else's block.
type Owned = { pane: number?, kind: string, key: string }

type TabState = {
	done: { [string]: boolean },
	opened: number,
	-- Completed entries by rule path, in opening order. Only filled while `close_on_leave` is on.
	owned: { [string]: { Owned } },
}

type Fields = {
	deps: Deps,
	tabs: { [number]: TabState },
	recent: { number },
	-- Problems seen at runtime (missing plugin, failed open), by key; cleared when that key later works.
	runtime_problems: { [string]: string? },
	logged: { [string]: boolean },
	config_problems: number,
	-- `auto_open` from the last config read, so the status formatter needs no file access.
	config_auto_open: boolean,
	-- The config object of the last read, to notice an edit; and the enabled flag last drawn in the status line.
	last_cfg: config.Config?,
	last_enabled: boolean,
}

local Engine = {}
Engine.__index = Engine

export type Engine = typeof(setmetatable({} :: Fields, Engine))

local MINUTE_MS = 60 * 1000

-- Runs `f`, returning its error message (nil on success).
local function try(f: () -> ()): string?
	local ok, err = pcall(f :: () -> any)
	if ok then
		return nil
	end
	return tostring(err)
end

-- A toast that can never raise.
local function toast(cx: WindowCx, level: ToastLevel, text: string, sub: string?)
	try(function()
		cx:toast(level, text, sub)
	end)
end

function M.new(deps: Deps): Engine
	return setmetatable({
		deps = deps,
		tabs = {},
		recent = {},
		runtime_problems = {},
		logged = {},
		config_problems = 0,
		config_auto_open = true,
		last_cfg = nil,
		last_enabled = true,
	}, Engine) :: any
end

-- Log each distinct message once per window session, so a bad rule cannot flood the log on every `cd`.
local function log_once(self: Engine, level: "info" | "warn", message: string)
	if self.logged[message] then
		return
	end
	self.logged[message] = true
	if level == "warn" then
		self.deps.log.warn("dir-blocks: " .. message)
	else
		self.deps.log.info("dir-blocks: " .. message)
	end
end

local function set_problem(self: Engine, key: string, message: string?)
	local before = self.runtime_problems[key]
	if before == message then
		return
	end
	self.runtime_problems[key] = message
	if message then
		log_once(self, "warn", message)
	end
	self.deps.changed()
end

-- Drops runtime problems of rule/block pairs the config no longer has (an edit fixed them).
local function prune_problems(self: Engine, cfg: config.Config)
	local live: { [string]: boolean } = {}
	for _, rule in cfg.rules do
		for _, entry in rule.blocks do
			live[rule.path .. "|" .. entry.block] = true
		end
	end
	local removed = false
	for key in self.runtime_problems do
		if not live[key] then
			self.runtime_problems[key] = nil
			removed = true
		end
	end
	if removed then
		self.deps.changed()
	end
end

local function load_config(self: Engine): config.Config
	local ok, cfg = pcall(self.deps.load)
	if not ok then
		log_once(self, "warn", "could not load config: " .. tostring(cfg))
		return config.parse({}, nil)
	end
	for _, problem in cfg.problems do
		log_once(self, "warn", "config.json: " .. problem)
	end
	self.config_auto_open = cfg.auto_open
	if cfg ~= self.last_cfg then
		self.last_cfg = cfg
		prune_problems(self, cfg)
	end
	if #cfg.problems ~= self.config_problems then
		self.config_problems = #cfg.problems
		self.deps.changed()
	end
	return cfg
end

function Engine.enabled(self: Engine): boolean
	local ok, value = pcall(self.deps.kv_get, "auto_open")
	if ok and type(value) == "boolean" then
		return value
	end
	return load_config(self).auto_open
end

-- Like `enabled`, and redraws the status line when another window flipped the shared switch.
local function sync_enabled(self: Engine): boolean
	local enabled = Engine.enabled(self)
	if enabled ~= self.last_enabled then
		self.last_enabled = enabled
		self.deps.changed()
	end
	return enabled
end

--- Problems for the status line / status command: config problems first, then runtime ones.
function Engine.problems(self: Engine): { string }
	local out: { string } = {}
	local ok, cfg = pcall(self.deps.load)
	if ok then
		for _, p in cfg.problems do
			table.insert(out, "config.json: " .. p)
		end
	end
	local keys: { string } = {}
	for key in self.runtime_problems do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in keys do
		local message = self.runtime_problems[key]
		if message then
			table.insert(out, message)
		end
	end
	return out
end

--- Reads the config once so problems are logged and shown in the status line. Never raises.
function Engine.check_config(self: Engine)
	load_config(self)
	sync_enabled(self)
end

local function tab_state(self: Engine, tab: number): TabState
	local state = self.tabs[tab]
	if state == nil then
		state = { done = {}, opened = 0, owned = {} }
		self.tabs[tab] = state
	end
	return state
end

--- A tab closed: forget what was opened in it.
function Engine.forget_tab(self: Engine, tab: number)
	self.tabs[tab] = nil
end

local function is_shell(pane: PaneInfo): boolean
	return pane.kind == "terminal" or pane.kind == "agent"
end

local function is_local(cx: WindowCx, pane: number): boolean
	for _, host in cx.hosts:list() do
		for _, id in host.panes do
			if id == pane then
				return host.kind == "local"
			end
		end
	end
	return false
end

-- The plugin block kind for a configured `block`: a full kind (`jira.issues`) or a plugin id (`jira`)
-- that has exactly one block.
local function resolve(cx: WindowCx, name: string): (string?, string?)
	local prefix = name .. "."
	local matches: { string } = {}
	for _, info in cx.session:block_types() do
		if info.kind == name then
			return name, nil
		end
		if string.sub(info.kind, 1, #prefix) == prefix then
			table.insert(matches, info.kind)
		end
	end
	if #matches == 1 then
		return matches[1], nil
	end
	if #matches > 1 then
		table.sort(matches)
		return nil, "block `" .. name .. "` is ambiguous (" .. table.concat(matches, ", ") .. "); name the full block kind"
	end
	return nil, "no block `" .. name .. "`: is that plugin installed and ready on this host?"
end

local function pane_in_tab(cx: WindowCx, tab: number, kind: string): number?
	for _, pane in cx.session:panes() do
		if pane.tab == tab and pane.block == kind then
			return pane.pane
		end
	end
	return nil
end

-- The split node whose child leaf is `pane`.
local function parent_of(node: TabTree, pane: number): TabTree?
	for i = 1, 2 do
		local child = node[i]
		if child ~= nil then
			if child.pane == pane then
				return node
			end
			local deeper = parent_of(child, pane)
			if deeper then
				return deeper
			end
		end
	end
	return nil
end

-- Gives the new pane `share` of its split. The window API can only move a divider by cells, so the cell
-- size of one ratio step is measured from a one-cell move, then the rest is done in one resize.
local function apply_ratio(self: Engine, cx: WindowCx, tab: number, pane: number, dir: "right" | "down", share: number)
	local function node_ratio(): number?
		local layout = cx.session:layout(tab)
		local node = layout and parent_of(layout.root, pane)
		return node and node.ratio
	end
	local start = node_ratio()
	if start == nil then
		return
	end
	-- The new pane is the second child: it grows toward the first one (left / up).
	local toward: Dir = if dir == "right" then "left" else "up"
	local want = 1 - share
	if math.abs(start - want) < 0.005 then
		return
	end
	local grow = start > want
	if not cx.layout:resize(pane, toward, if grow then 1 else -1) then
		return
	end
	local after = node_ratio()
	if after == nil then
		return
	end
	local step = math.abs(after - start)
	if step <= 0 then
		return
	end
	local cells = math.floor((after - want) / step + 0.5)
	-- one cell is already applied in the right direction; `cells` is what remains, signed like the first move
	if (grow and cells > 0) or (not grow and cells < 0) then
		cx.layout:resize(pane, toward, cells)
	end
end

type Outcome = { opened: { string }, present: { string }, failed: { string }, limited: string? }

local function allow(self: Engine, cfg: config.Config, tab: number, manual: boolean): string?
	local state = tab_state(self, tab)
	if state.opened >= cfg.max_blocks_per_tab then
		return "limit of " .. cfg.max_blocks_per_tab .. " auto-opened blocks per tab reached"
	end
	if not manual then
		local now = self.deps.now()
		local keep: { number } = {}
		for _, at in self.recent do
			if now - at < MINUTE_MS then
				table.insert(keep, at)
			end
		end
		self.recent = keep
		if #keep >= cfg.max_opens_per_minute then
			return "rate limit of " .. cfg.max_opens_per_minute .. " opens per minute reached"
		end
	end
	return nil
end

-- Opens one block; both split and new_tab return the new pane id, nil + reason on failure.
local function open_block(
	self: Engine,
	cx: WindowCx,
	entry: config.Entry,
	kind: string,
	source: number,
	tab: number,
	dir: string
): (number?, string?)
	local launch: Launch = { block = kind, cwd = dir }
	local reveal: Reveal = { focus = false }
	if entry.place == "tab" then
		local id: number? = nil
		local err = try(function()
			id = cx.layout:new_tab(launch, reveal)
		end)
		if err then
			return nil, err
		end
		return id, if id == nil then "Tern did not open a tab for it" else nil
	end
	local pane: number? = nil
	local split_err = try(function()
		pane = cx.layout:split(source, entry.place, launch, reveal)
	end)
	if split_err then
		return nil, split_err
	end
	if pane == nil then
		return nil, "Tern did not open a split for it"
	end
	if entry.ratio ~= config.DEFAULT_RATIO then
		local err = try(function()
			apply_ratio(self, cx, tab, pane :: number, entry.place, entry.ratio)
		end)
		if err then
			log_once(self, "warn", "could not set ratio for `" .. entry.block .. "`: " .. err)
		end
	end
	return pane, nil
end

local function remember(state: TabState, path: string, owned: Owned)
	local list = state.owned[path] or {}
	state.owned[path] = list
	table.insert(list, owned)
end

-- Opens the rule's blocks that are not done / visible yet, in order. `manual` skips the once-per-tab
-- memory and the rate limit (not the per-tab cap).
local function apply(
	self: Engine,
	cx: WindowCx,
	cfg: config.Config,
	rule: config.Rule,
	source: number,
	tab: number,
	dir: string,
	manual: boolean
): Outcome
	local out: Outcome = { opened = {}, present = {}, failed = {}, limited = nil }
	local state = tab_state(self, tab)
	-- The pane of the previous entry's block, for `of = "previous"`.
	local prev_pane: number? = nil
	for _, entry in rule.blocks do
		local key = rule.path .. "|" .. entry.block
		if not manual and state.done[key] then
			local done_kind = resolve(cx, entry.block)
			prev_pane = if done_kind then pane_in_tab(cx, tab, done_kind) else nil
			continue
		end
		local kind, why = resolve(cx, entry.block)
		if kind == nil then
			prev_pane = nil
			set_problem(self, key, "rule " .. rule.path .. ": " .. tostring(why))
			table.insert(out.failed, entry.block)
			continue
		end
		local existing = pane_in_tab(cx, tab, kind)
		if existing then
			prev_pane = existing
			if cfg.close_on_leave and not state.done[key] then
				remember(state, rule.path, { pane = nil, kind = kind, key = key })
			end
			state.done[key] = true
			set_problem(self, key, nil)
			table.insert(out.present, entry.block)
			continue
		end
		local limit = allow(self, cfg, tab, manual)
		if limit then
			out.limited = limit
			log_once(self, "warn", "tab " .. tab .. ": " .. limit .. "; not opening `" .. entry.block .. "`")
			break
		end
		local target = source
		if entry.of == "previous" then
			if prev_pane ~= nil and cx.session:tab_of(prev_pane) == tab then
				target = prev_pane
			else
				log_once(self, "warn", "rule " .. rule.path .. ": the block before `" .. entry.block .. "` is not in the tab; splitting the shell instead")
			end
		end
		local id, err = open_block(self, cx, entry, kind, target, tab, dir)
		if id == nil then
			prev_pane = nil
			set_problem(self, key, "rule " .. rule.path .. ": could not open `" .. entry.block .. "`: " .. tostring(err))
			table.insert(out.failed, entry.block)
			continue
		end
		-- A tab placement's pane is outside the source tab, so later entries cannot split it.
		prev_pane = if entry.place == "tab" then nil else id
		set_problem(self, key, nil)
		state.done[key] = true
		state.opened += 1
		if cfg.close_on_leave then
			remember(state, rule.path, { pane = id, kind = kind, key = key })
		end
		table.insert(self.recent, self.deps.now())
		table.insert(out.opened, entry.block)
		self.deps.log.info("dir-blocks: opened " .. kind .. " " .. entry.place .. " in tab " .. tab .. " for " .. rule.path)
	end
	return out
end

local function all_done(self: Engine, rule: config.Rule, tab: number): boolean
	local state = self.tabs[tab]
	if state == nil then
		return false
	end
	for _, entry in rule.blocks do
		if not state.done[rule.path .. "|" .. entry.block] then
			return false
		end
	end
	return true
end

-- Whether `pane` reacts to rules: a tiled terminal or agent on this machine. Blocks (including the ones
-- this plugin opens) and floating panes never do.
local function is_trigger(cx: WindowCx, pane: PaneInfo): boolean
	return is_shell(pane) and pane.floating ~= true and is_local(cx, pane.pane)
end

-- Whether a shell of `tab` other than `except` is still in `path` or below it.
local function shell_remains(cx: WindowCx, tab: number, except: number, path: string): boolean
	for _, pane in cx.session:panes() do
		if pane.tab == tab and pane.pane ~= except and is_trigger(cx, pane) then
			local dir = config.normalize(pane.cwd or "")
			if dir ~= nil and config.contains(path, dir) then
				return true
			end
		end
	end
	return false
end

-- Closes what the rule at `path` opened in this tab and forgets it, so entering the directory again opens
-- it again. A block the user already closed is just forgotten.
local function close_owned(self: Engine, cx: WindowCx, state: TabState, path: string)
	local list = state.owned[path]
	if list == nil then
		return
	end
	for i = #list, 1, -1 do
		local owned = list[i]
		local pane = owned.pane
		local info = if pane then cx.session:pane(pane) else nil
		if pane ~= nil and info ~= nil and info.block == owned.kind then
			local err = try(function()
				cx.layout:close(pane)
			end)
			if err then
				log_once(self, "warn", "could not close `" .. owned.kind .. "`: " .. err)
				-- Still owned and counted: a failed close must not turn it into an untracked block.
				continue
			else
				self.deps.log.info("dir-blocks: closed " .. owned.kind .. " after leaving " .. path)
			end
		end
		state.done[owned.key] = nil
		if pane ~= nil then
			state.opened = math.max(0, state.opened - 1)
		end
		table.remove(list, i)
	end
	if #list == 0 then
		state.owned[path] = nil
	end
end

-- A pane of `tab` moved to `dir`: closes the blocks of every rule whose directory it is no longer in, unless
-- another shell of the tab is still there. Moving into a deeper rule's directory leaves the outer rule's
-- blocks open, since the pane is still inside the outer directory.
local function close_left(self: Engine, cx: WindowCx, pane_id: number, tab: number, dir: string)
	local state = self.tabs[tab]
	if state == nil or next(state.owned) == nil then
		return
	end
	local pane = cx.session:pane(pane_id)
	if pane == nil or not is_trigger(cx, pane) then
		return
	end
	local paths: { string } = {}
	for path in state.owned do
		if not config.contains(path, dir) then
			table.insert(paths, path)
		end
	end
	table.sort(paths)
	for _, path in paths do
		if not shell_remains(cx, tab, pane_id, path) then
			close_owned(self, cx, state, path)
		end
	end
end

local function on_cwd(self: Engine, ev: CwdEvent, cx: WindowCx)
	if not sync_enabled(self) then
		return
	end
	local cfg = load_config(self)
	local dir = config.normalize(ev.path)
	if dir == nil then
		return
	end
	local rule = config.best(cfg.rules, dir)
	if rule == nil and not cfg.close_on_leave then
		return
	end
	local tab = cx.session:tab_of(ev.pane)
	if tab == nil then
		return
	end
	if cfg.close_on_leave then
		close_left(self, cx, ev.pane, tab, dir)
	end
	if rule == nil or all_done(self, rule, tab) then
		return
	end
	-- Only shells react: blocks this plugin opens (and any other block) never trigger more opens.
	-- `~` and the rule paths are this machine's; another host's panes have their own filesystem.
	local pane = cx.session:pane(ev.pane)
	if pane == nil or not is_trigger(cx, pane) then
		return
	end
	apply(self, cx, cfg, rule, ev.pane, tab, dir, false)
end

--- The `cwd` event handler. Never raises.
function Engine.on_cwd(self: Engine, ev: CwdEvent, cx: WindowCx)
	local err = try(function()
		on_cwd(self, ev, cx)
	end)
	if err then
		log_once(self, "warn", "cwd handler failed: " .. err)
	end
end

local function summarize(out: Outcome): string
	local parts: { string } = {}
	if #out.opened > 0 then
		table.insert(parts, "opened " .. table.concat(out.opened, ", "))
	end
	if #out.present > 0 then
		table.insert(parts, table.concat(out.present, ", ") .. " already open")
	end
	if #out.failed > 0 then
		table.insert(parts, "could not open " .. table.concat(out.failed, ", "))
	end
	if out.limited then
		table.insert(parts, out.limited)
	end
	return table.concat(parts, "; ")
end

local function open_now(self: Engine, cx: WindowCx)
	local cfg = load_config(self)
	local focused = cx.session:focused()
	local source: PaneInfo? = if focused then cx.session:pane(focused) else nil
	if source == nil then
		cx:toast("info", "dir-blocks: no focused pane")
		return
	end
	if not is_shell(source) or source.floating == true then
		-- A block is focused: use a shell in the same tab.
		local alt: PaneInfo? = nil
		for _, pane in cx.session:panes() do
			if pane.tab == source.tab and is_shell(pane) and pane.floating ~= true then
				alt = pane
				break
			end
		end
		if alt == nil then
			cx:toast("info", "dir-blocks: no terminal in this tab")
			return
		end
		source = alt
	end
	local dir = config.normalize(source.cwd or "")
	local rule = if dir then config.best(cfg.rules, dir) else nil
	if dir == nil or rule == nil then
		cx:toast("info", "dir-blocks: no rule matches " .. (source.cwd or "this directory"))
		return
	end
	local tab = source.tab or cx.session:tab_of(source.pane)
	if tab == nil then
		return
	end
	if not is_local(cx, source.pane) then
		cx:toast("info", "dir-blocks: rules only apply to panes on this machine")
		return
	end
	local out = apply(self, cx, cfg, rule, source.pane, tab, dir, true)
	local text = summarize(out)
	local level: ToastLevel = if #out.failed > 0 or out.limited then "error" else if #out.opened > 0 then "success" else "info"
	cx:toast(level, "dir-blocks: " .. rule.path, text)
end

--- "Open blocks for this directory now" command. Never raises.
function Engine.open_now(self: Engine, cx: WindowCx)
	local err = try(function()
		open_now(self, cx)
	end)
	if err then
		log_once(self, "warn", "open now failed: " .. err)
		toast(cx, "error", "dir-blocks: failed", err)
	end
end

--- Flips auto-open for every window (stored in tern.kv); returns the new state.
function Engine.toggle(self: Engine, cx: WindowCx): boolean
	local now = not Engine.enabled(self)
	-- Back to what config.json says: drop the override so the config's `auto_open` applies again.
	local value: boolean? = if now == load_config(self).auto_open then nil else now
	local err = try(function()
		self.deps.kv_set("auto_open", value)
	end)
	if err then
		log_once(self, "warn", "could not save the auto-open switch: " .. err)
		toast(cx, "error", "dir-blocks: could not save the switch", err)
		return not now
	end
	self.deps.changed()
	toast(cx, "info", if now then "dir-blocks: auto-open on" else "dir-blocks: auto-open off")
	return now
end

--- "Show status" command: state, rule count, problems.
function Engine.status(self: Engine, cx: WindowCx)
	local cfg = load_config(self)
	local problems = Engine.problems(self)
	local head = "dir-blocks: auto-open " .. (if Engine.enabled(self) then "on" else "off") .. ", " .. #cfg.rules .. " rule(s)"
	local sub: string? = nil
	if #problems > 0 then
		local shown: { string } = {}
		for i = 1, math.min(3, #problems) do
			table.insert(shown, problems[i])
		end
		sub = #problems .. " problem(s): " .. table.concat(shown, " | ")
	end
	toast(cx, if #problems > 0 then "error" else "info", head, sub)
end

--- The status line segment: only shown while auto-open is off or something is wrong.
function Engine.segment(self: Engine, status_action: string, toggle_action: string): StatusSegment?
	if self.config_problems > 0 or next(self.runtime_problems) ~= nil then
		return { text = "dir-blocks !", icon = "folder", tone = "error", command = status_action }
	end
	local ok, value = pcall(self.deps.kv_get, "auto_open")
	local enabled = if ok and type(value) == "boolean" then value else self.config_auto_open
	if not enabled then
		return { text = "dir-blocks off", icon = "folder", tone = "muted", command = toggle_action }
	end
	return nil
end

return M
