--!nonstrict
-- Unit tests for config.luau and engine.luau against a fake window.
-- Run from the repository root with the Luau CLI:  luau test/test.luau
-- No Tern, daemon or network needed; test/e2e.sh is the real-window check.

local config = require("../config")
local engine_mod = require("../engine")

local HOME = "/home/u"
local failures = 0
local count = 0

local function check(name, cond, detail)
	count += 1
	if not cond then
		failures += 1
		print("FAIL: " .. name .. (if detail then " (" .. tostring(detail) .. ")" else ""))
	end
end

local function eq(name, got, want)
	check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

local function joined(list)
	return table.concat(list, ",")
end

----------------------------------------------------------------------------------------------------
-- config: paths
----------------------------------------------------------------------------------------------------
eq("normalize collapses // . ..", config.normalize("/a//b/./c/../d/"), "/a/b/d")
eq("normalize clamps .. at root", config.normalize("/../.."), "/")
eq("normalize rejects relative", config.normalize("a/b"), nil)
eq("expand ~", config.expand("~", HOME), HOME)
eq("expand ~/x", config.expand("~/x/y", HOME), HOME .. "/x/y")
eq("expand rejects ~user", config.expand("~bob/x", HOME), nil)
eq("expand needs a home", config.expand("~/x", nil), nil)
eq("expand leaves absolute alone", config.expand("/opt/x", HOME), "/opt/x")
check("contains itself", config.contains("/a/b", "/a/b"))
check("contains below", config.contains("/a/b", "/a/b/c/d"))
check("not a sibling with the same prefix", not config.contains("/a/b", "/a/bc"))
check("not the parent", not config.contains("/a/b", "/a"))

----------------------------------------------------------------------------------------------------
-- config: parse / validate
----------------------------------------------------------------------------------------------------
local ok = config.parse({
	rules = {
		{ path = "~/code/my-project", blocks = { { block = "jira", place = "right" }, { block = "graphite", place = "down", ratio = 0.4 } } },
		{ path = "~/code/my-project/Backend", blocks = { "graphite" } },
	},
}, HOME)
eq("valid config has no problems", #ok.problems, 0)
eq("two rules", #ok.rules, 2)
eq("tilde expanded in rule", ok.rules[1].path, HOME .. "/code/my-project")
eq("entry place", ok.rules[1].blocks[2].place, "down")
eq("entry ratio", ok.rules[1].blocks[2].ratio, 0.4)
eq("string entry defaults to right", ok.rules[2].blocks[1].place, "right")
eq("string entry default ratio", ok.rules[2].blocks[1].ratio, 0.5)
eq("auto_open defaults true", ok.auto_open, true)

local function rules_of(cfg)
	local p = {}
	for _, r in cfg.rules do
		table.insert(p, r.path)
	end
	return joined(p)
end

local bad = config.parse({
	rules = {
		"nope",
		{ path = 5, blocks = { "jira" } },
		{ path = "relative/dir", blocks = { "jira" } },
		{ path = "/", blocks = { "jira" } },
		{ path = "~bob/x", blocks = { "jira" } },
		{ path = "/ok/empty", blocks = {} },
		{ path = "/ok/place", blocks = { { block = "jira", place = "left" } } },
		{ path = "/ok/ratio", blocks = { { block = "jira", ratio = 2 } } },
		{ path = "/ok/ratio0", blocks = { { block = "jira", ratio = 0 } } },
		{ path = "/ok/nan", blocks = { { block = "jira", ratio = 0 / 0 } } },
		{ path = "/ok/noblock", blocks = { { place = "tab" } } },
		{ path = "/ok/fine", blocks = { "jira", { block = "graphite", place = "bogus" } } },
		{ path = "/ok/fine/", blocks = { "jira" } },
		{ path = "/ok/typo", blocks = { "jira" }, block = "x" },
	},
	auto_open = "yes",
	max_blocks_per_tab = "many",
	surprise = 1,
}, HOME)
eq("only usable rules survive", rules_of(bad), "/ok/fine,/ok/typo")
eq("surviving rule keeps only its good entries", #bad.rules[1].blocks, 1)
check("every defect reported", #bad.problems >= 15, #bad.problems)
eq("auto_open falls back", bad.auto_open, true)
eq("max_blocks_per_tab falls back", bad.max_blocks_per_tab, 8)
check("duplicate path reported", string.find(joined(bad.problems), "same path as", 1, true) ~= nil)
check("unknown top-level key reported", string.find(joined(bad.problems), "unknown key `surprise`", 1, true) ~= nil)
check("unknown rule key reported", string.find(joined(bad.problems), "unknown key `block`", 1, true) ~= nil)

local notobj = config.parse({ "a", "b" }, HOME)
eq("array root rejected", #notobj.problems, 1)
eq("non-table root rejected", #config.parse("x", HOME).problems, 1)
eq("empty object is fine", #config.parse({}, HOME).problems, 0)
eq("opens per minute clamped", config.parse({ max_opens_per_minute = 9999 }, HOME).max_opens_per_minute, 60)
eq("blocks per tab clamped", config.parse({ max_blocks_per_tab = 0 }, HOME).max_blocks_per_tab, 1)

local many = {}
for i = 1, 100 do
	table.insert(many, { path = "/r/" .. i, blocks = { "jira" } })
end
eq("rule count capped", #config.parse({ rules = many }, HOME).rules, config.MAX_RULES)
local wide = {}
for i = 1, 20 do
	table.insert(wide, "b" .. i)
end
eq("blocks per rule capped", #config.parse({ rules = { { path = "/r", blocks = wide } } }, HOME).rules[1].blocks, config.MAX_BLOCKS_PER_RULE)

----------------------------------------------------------------------------------------------------
-- config: most specific path wins
----------------------------------------------------------------------------------------------------
local nest = config.parse({
	rules = {
		{ path = "/w/repo", blocks = { "a" } },
		{ path = "/w/repo/deep/er", blocks = { "c" } },
		{ path = "/w/repo/deep", blocks = { "b" } },
	},
}, HOME)
eq("repo itself", config.best(nest.rules, "/w/repo").blocks[1].block, "a")
eq("below repo", config.best(nest.rules, "/w/repo/src/x").blocks[1].block, "a")
eq("nested wins over parent", config.best(nest.rules, "/w/repo/deep/x").blocks[1].block, "b")
eq("nested wins regardless of rule order", config.best(nest.rules, "/w/repo/deep/er/x").blocks[1].block, "c")
eq("outside matches nothing", config.best(nest.rules, "/w/repo2"), nil)
eq("unnormalized event path matches", config.best(nest.rules, "/w//repo/./x").blocks[1].block, "a")

----------------------------------------------------------------------------------------------------
-- engine against a fake window
----------------------------------------------------------------------------------------------------
local function new_world(opts)
	opts = opts or {}
	local w = {
		panes = {}, -- {pane, tab, kind, block, floating, cwd}
		hosts = { { kind = "local", name = "here", panes = {} } },
		types = opts.types or { "jira.issues", "graphite.inbox" },
		calls = {}, -- split / new_tab records
		toasts = {},
		next_pane = 100,
		next_tab = 50,
		trees = {},
		fail_split = opts.fail_split,
		throw_split = opts.throw_split,
	}
	function w:add_pane(p)
		table.insert(self.panes, p)
		table.insert(self.hosts[1].panes, p.pane)
		if not self.trees[p.tab] then
			self.trees[p.tab] = { pane = p.pane }
		end
	end
	local function find_leaf(node, pane, parent)
		if node.pane == pane then
			return node, parent
		end
		for i = 1, 2 do
			if node[i] then
				local n, par = find_leaf(node[i], pane, node)
				if n then
					return n, par
				end
			end
		end
		return nil, nil
	end
	local cx = { toasts = w.toasts }
	cx.hosts = {
		list = function(_)
			return w.hosts
		end,
	}
	cx.session = {
		pane = function(_, id)
			for _, p in w.panes do
				if p.pane == id then
					return p
				end
			end
			return nil
		end,
		tab_of = function(_, id)
			for _, p in w.panes do
				if p.pane == id then
					return p.tab
				end
			end
			return nil
		end,
		panes = function(_)
			return w.panes
		end,
		block_types = function(_)
			local out = {}
			for _, k in w.types do
				table.insert(out, { kind = k, title = k, icon = "", palette = true })
			end
			return out
		end,
		focused = function(_)
			return w.focus
		end,
		layout = function(_, tab)
			return { tab = tab, root = w.trees[tab], floats = {}, zoomed = false, focus = 0 }
		end,
	}
	cx.layout = {
		split = function(_, target, dir, launch, reveal)
			table.insert(w.calls, { op = "split", target = target, dir = dir, launch = launch, reveal = reveal })
			if w.throw_split then
				error("split exploded")
			end
			if w.fail_split then
				return nil
			end
			w.next_pane += 1
			local id = w.next_pane
			local tab = cx.session:tab_of(target)
			w:add_pane({ pane = id, tab = tab, kind = "plugin", block = launch.block, cwd = launch.cwd or "" })
			local leaf = find_leaf(w.trees[tab], target)
			leaf.pane = nil
			leaf.split = dir
			leaf.ratio = 0.5
			leaf[1] = { pane = target }
			leaf[2] = { pane = id }
			return id
		end,
		new_tab = function(_, launch, reveal)
			table.insert(w.calls, { op = "new_tab", launch = launch, reveal = reveal })
			w.next_tab += 1
			w.next_pane += 1
			w:add_pane({ pane = w.next_pane, tab = w.next_tab, kind = "plugin", block = launch.block, cwd = launch.cwd or "" })
			return w.next_tab
		end,
		resize = function(_, pane, dir, cells)
			-- 100 cells across: moving the divider toward the first child by n cells lowers its ratio by n/100
			for _, tree in w.trees do
				local _leaf, parent = find_leaf(tree, pane)
				if parent then
					parent.ratio -= cells / 100
					table.insert(w.calls, { op = "resize", pane = pane, dir = dir, cells = cells })
					return true
				end
			end
			return false
		end,
	}
	function cx:toast(level, text, sub)
		table.insert(w.toasts, { level = level, text = text, sub = sub })
	end
	w.cx = cx
	return w
end

local function new_engine(cfg_table, kv, now)
	local store = kv or {}
	local clock = { t = now or 0 }
	local logs = { warn = {}, info = {} }
	local changes = { n = 0 }
	local cfg = config.parse(cfg_table, HOME)
	local e = engine_mod.new({
		load = function()
			return cfg
		end,
		kv_get = function(k)
			return store[k]
		end,
		kv_set = function(k, v)
			store[k] = v
		end,
		now = function()
			return clock.t
		end,
		log = {
			warn = function(...)
				table.insert(logs.warn, table.concat({ ... }, " "))
			end,
			info = function(...)
				table.insert(logs.info, table.concat({ ... }, " "))
			end,
		},
		changed = function()
			changes.n += 1
		end,
	})
	return e, { store = store, clock = clock, logs = logs, changes = changes, set = function(t) cfg = config.parse(t, HOME) end }
end

local REPO = HOME .. "/code/my-project"
local PERSONAL = {
	rules = {
		{ path = "~/code/my-project", blocks = { { block = "jira", place = "right" }, { block = "graphite", place = "down" } } },
	},
}

local function shell_world()
	local w = new_world()
	w:add_pane({ pane = 1, tab = 10, kind = "terminal", cwd = HOME })
	w.focus = 1
	return w
end

local function cwd(e, w, pane, path)
	e:on_cwd({ pane = pane, path = path }, w.cx)
end

local function opened(w)
	local out = {}
	for _, c in w.calls do
		if c.op ~= "resize" then
			table.insert(out, (c.dir or c.op) .. ":" .. c.launch.block)
		end
	end
	return joined(out)
end

-- 1. entering opens both blocks, once
do
	local w = shell_world()
	local e = new_engine(PERSONAL)
	cwd(e, w, 1, HOME)
	eq("outside the repo opens nothing", #w.calls, 0)
	cwd(e, w, 1, REPO)
	eq("entering the repo opens jira right and graphite down", opened(w), "right:jira.issues,down:graphite.inbox")
	eq("opened from the shell pane", w.calls[1].target, 1)
	eq("block gets the directory", w.calls[1].launch.cwd, REPO)
	eq("focus is not stolen", w.calls[1].reveal.focus, false)
	-- cd around inside
	for _, p in { REPO .. "/Backend", REPO .. "/Backend/src", REPO, REPO .. "/Frontend", REPO .. "/Backend/../docs" } do
		cwd(e, w, 1, p)
	end
	eq("cd inside the repo opens nothing more", #w.calls, 2)
	-- leave and come back
	cwd(e, w, 1, HOME)
	cwd(e, w, 1, REPO)
	eq("re-entering does not reopen", #w.calls, 2)
end

-- 2. a second pane in the same tab, and a new tab
do
	local w = shell_world()
	w:add_pane({ pane = 2, tab = 10, kind = "terminal", cwd = HOME })
	w:add_pane({ pane = 3, tab = 11, kind = "terminal", cwd = HOME })
	local e = new_engine(PERSONAL)
	cwd(e, w, 1, REPO)
	cwd(e, w, 2, REPO)
	eq("another pane in the tab opens nothing", #w.calls, 2)
	cwd(e, w, 3, REPO .. "/Backend")
	eq("another tab gets its own blocks", #w.calls, 4)
	eq("second tab target", w.calls[3].target, 3)
end

-- 3. already visible
do
	local w = shell_world()
	w:add_pane({ pane = 9, tab = 10, kind = "plugin", block = "jira.issues" })
	local e = new_engine(PERSONAL)
	cwd(e, w, 1, REPO)
	eq("a visible block is not opened again", opened(w), "down:graphite.inbox")
	-- jira in another tab does not count
	local w2 = shell_world()
	w2:add_pane({ pane = 9, tab = 99, kind = "plugin", block = "jira.issues" })
	local e2 = new_engine(PERSONAL)
	cwd(e2, w2, 1, REPO)
	eq("a block in another tab does not count", opened(w2), "right:jira.issues,down:graphite.inbox")
end

-- 4. most specific rule wins and only its blocks open
do
	local w = shell_world()
	local e = new_engine({
		rules = {
			{ path = "/w/repo", blocks = { "jira" } },
			{ path = "/w/repo/api", blocks = { { block = "graphite", place = "tab" } } },
		},
	})
	cwd(e, w, 1, "/w/repo/api/handlers")
	eq("only the nested rule's blocks", opened(w), "new_tab:graphite.inbox")
	cwd(e, w, 1, "/w/repo")
	eq("parent rule then opens its own", opened(w), "new_tab:graphite.inbox,right:jira.issues")
end

-- 5. auto-open off, toggle, manual command
do
	local w = shell_world()
	local e, h = new_engine(PERSONAL)
	e:toggle(w.cx)
	eq("toggle stores the switch", h.store.auto_open, false)
	eq("toggle says so", w.toasts[1].text, "dir-blocks: auto-open off")
	cwd(e, w, 1, REPO)
	eq("auto-open off opens nothing", #w.calls, 0)
	eq("segment shows off", e:segment("s", "t").text, "dir-blocks off")
	-- manual works while auto is off
	w.panes[1].cwd = REPO
	e:open_now(w.cx)
	eq("manual open works with auto-open off", opened(w), "right:jira.issues,down:graphite.inbox")
	check("manual open toasts success", w.toasts[#w.toasts].level == "success", w.toasts[#w.toasts].level)
	e:open_now(w.cx)
	eq("manual open twice does not duplicate", #w.calls, 2)
	check("manual open says already open", string.find(w.toasts[#w.toasts].sub, "already open", 1, true) ~= nil, w.toasts[#w.toasts].sub)
	e:toggle(w.cx)
	eq("toggling back drops the override", h.store.auto_open, nil)
	eq("segment hidden when on", e:segment("s", "t"), nil)
end

-- 6. manual open retries blocks the user closed; auto does not
do
	local w = shell_world()
	local e = new_engine(PERSONAL)
	cwd(e, w, 1, REPO)
	-- user closes jira
	for i = #w.panes, 1, -1 do
		if w.panes[i].block == "jira.issues" then
			table.remove(w.panes, i)
		end
	end
	cwd(e, w, 1, REPO .. "/x")
	eq("auto-open does not reopen a block the user closed", #w.calls, 2)
	w.panes[1].cwd = REPO .. "/x"
	e:open_now(w.cx)
	eq("manual open brings it back", #w.calls, 3)
end

-- 7. tab closed forgets
do
	local w = shell_world()
	local e = new_engine(PERSONAL)
	cwd(e, w, 1, REPO)
	e:forget_tab(10)
	for i = #w.panes, 1, -1 do
		if w.panes[i].block then
			table.remove(w.panes, i)
		end
	end
	cwd(e, w, 1, REPO)
	eq("a new tab with a recycled id starts fresh", #w.calls, 4)
end

-- 8. only shells trigger; floats and remote panes do not
do
	local w = shell_world()
	w:add_pane({ pane = 5, tab = 10, kind = "plugin", block = "jira.issues" })
	w:add_pane({ pane = 6, tab = 12, kind = "browser" })
	w:add_pane({ pane = 7, tab = 13, kind = "terminal", floating = true })
	w:add_pane({ pane = 8, tab = 14, kind = "terminal" })
	table.remove(w.hosts[1].panes) -- pane 8 is on no local host
	table.insert(w.hosts, { kind = "remote", name = "far", panes = { 8 } })
	local e = new_engine(PERSONAL)
	cwd(e, w, 5, REPO)
	cwd(e, w, 6, REPO)
	cwd(e, w, 7, REPO)
	cwd(e, w, 8, REPO)
	cwd(e, w, 404, REPO)
	eq("block, browser, floating and remote panes never trigger", #w.calls, 0)
end

-- 9. block resolution: plugin id, full kind, ambiguity, missing plugin
do
	local w = new_world({ types = { "jira.issues", "multi.a", "multi.b", "graphite.inbox" } })
	w:add_pane({ pane = 1, tab = 10, kind = "terminal" })
	local e, h = new_engine({
		rules = {
			{ path = "/r", blocks = { "jira.issues", "multi", "ghost", "graphite" } },
		},
	})
	cwd(e, w, 1, "/r")
	eq("full kind and plugin id resolve; ambiguous and missing are skipped", opened(w), "right:jira.issues,right:graphite.inbox")
	eq("problems are recorded", #e:problems(), 2)
	eq("segment flags problems", e:segment("s", "t").text, "dir-blocks !")
	check("missing plugin logged once", #h.logs.warn == 2, #h.logs.warn)
	cwd(e, w, 1, "/r/sub")
	cwd(e, w, 1, "/r/sub2")
	eq("failed blocks do not spam the log", #h.logs.warn, 2)
	eq("and do not open anything else", #w.calls, 2)
	-- the plugin appears later: the next cwd picks it up
	table.insert(w.types, "ghost.panel")
	cwd(e, w, 1, "/r/sub3")
	eq("a block that was missing opens once it exists", #w.calls, 3)
	eq("only the ambiguous problem remains", #e:problems(), 1)
end

-- 10. failures never raise
do
	local w = new_world({ fail_split = true })
	w:add_pane({ pane = 1, tab = 10, kind = "terminal" })
	local e = new_engine(PERSONAL)
	cwd(e, w, 1, REPO)
	eq("nil from split is a problem, not a crash", #e:problems(), 2)
	local w2 = new_world({ throw_split = true })
	w2:add_pane({ pane = 1, tab = 10, kind = "terminal" })
	local e2 = new_engine(PERSONAL)
	cwd(e2, w2, 1, REPO)
	eq("a raising split is a problem, not a crash", #e2:problems(), 2)
	-- a raising config loader
	local e3 = engine_mod.new({
		load = function()
			error("disk on fire")
		end,
		kv_get = function() end,
		kv_set = function() end,
		now = function() return 0 end,
		log = { warn = function() end, info = function() end },
		changed = function() end,
	})
	cwd(e3, w, 1, REPO)
	e3:open_now(w.cx)
	e3:toggle(w.cx)
	e3:status(w.cx)
	check("a broken loader is survived", true)
	-- a raising toast and a raising kv
	local cx = table.clone(w.cx)
	cx.toast = function() error("no toast") end
	e:open_now(cx)
	e:status(cx)
	local e4 = engine_mod.new({
		load = function() return config.parse(PERSONAL, HOME) end,
		kv_get = function() error("kv unreadable") end,
		kv_set = function() error("kv read-only") end,
		now = function() return 0 end,
		log = { warn = function() end, info = function() end },
		changed = function() end,
	})
	e4:toggle(cx)
	eq("auto-open still works when kv is unreadable", e4:enabled(), true)
	check("a raising toast and kv are survived", true)
end

-- 11. rate limit and per-tab cap
do
	local w = new_world()
	for i = 1, 6 do
		w:add_pane({ pane = i, tab = 10 + i, kind = "terminal" })
	end
	local e, h = new_engine({
		max_opens_per_minute = 3,
		rules = { { path = "/r", blocks = { "jira", "graphite" } } },
	})
	for i = 1, 6 do
		cwd(e, w, i, "/r")
	end
	eq("auto opens are capped per minute", #w.calls, 3)
	h.clock.t = 61 * 1000
	cwd(e, w, 3, "/r/again")
	eq("the limit lifts after a minute (tab 13 gets both of its blocks)", #w.calls, 5)
	check("limit is logged", string.find(joined(h.logs.warn), "rate limit", 1, true) ~= nil)
end
do
	local w = new_world({ types = { "a.x", "b.x", "c.x", "d.x" } })
	w:add_pane({ pane = 1, tab = 10, kind = "terminal" })
	w.panes[1].cwd = "/r"
	w.focus = 1
	local e = new_engine({
		max_blocks_per_tab = 2,
		max_opens_per_minute = 60,
		rules = { { path = "/r", blocks = { "a", "b", "c", "d" } } },
	})
	cwd(e, w, 1, "/r")
	eq("per-tab cap stops auto opens", #w.calls, 2)
	e:open_now(w.cx)
	eq("the cap also holds for the manual command", #w.calls, 2)
	check("manual command reports the cap", w.toasts[#w.toasts].level == "error", w.toasts[#w.toasts].level)
end

-- 12. ratio
do
	local w = shell_world()
	local e = new_engine({ rules = { { path = "/r", blocks = { { block = "jira", place = "right", ratio = 0.3 }, { block = "graphite", place = "down", ratio = 0.5 } } } } })
	cwd(e, w, 1, "/r")
	local tree = w.trees[10]
	-- jira takes 30% on the right, so the first child keeps 70%
	local node = tree[1]
	check("graphite split below the shell", node ~= nil and node.split == "down")
	check("jira share applied to the right split", math.abs(tree.ratio - 0.7) < 0.011, tree.ratio)
	check("default ratio leaves the split alone", math.abs(node.ratio - 0.5) < 1e-9, node.ratio)
	local w2 = shell_world()
	local e2 = new_engine({ rules = { { path = "/r", blocks = { { block = "jira", place = "down", ratio = 0.8 } } } } })
	cwd(e2, w2, 1, "/r")
	check("a share above half moves the divider the other way", math.abs(w2.trees[10].ratio - 0.2) < 0.011, w2.trees[10].ratio)
end

-- 13. status command
do
	local w = shell_world()
	local e = new_engine({ rules = { { path = "/r", blocks = { "ghost" } } } })
	cwd(e, w, 1, "/r")
	e:status(w.cx)
	local t = w.toasts[#w.toasts]
	check("status toast lists the problem", t.level == "error" and string.find(t.sub, "ghost", 1, true) ~= nil, t.sub)
end

-- 14. an edit that fixes a problem clears it from the status line; toggling back returns control to config
do
	local w = shell_world()
	local e, h = new_engine({ rules = { { path = "/r", blocks = { "ghost" } } } })
	cwd(e, w, 1, "/r")
	eq("problem recorded", #e:problems(), 1)
	eq("status line flags it", e:segment("s", "t").text, "dir-blocks !")
	h.set({ rules = { { path = "/r", blocks = { "jira" } } } })
	cwd(e, w, 1, "/r/sub")
	eq("fixing the config clears the stale problem", #e:problems(), 0)
	eq("status line is quiet again", e:segment("s", "t"), nil)
	eq("and the fixed rule opened its block", opened(w), "right:jira.issues")

	local w2 = shell_world()
	local e2, h2 = new_engine({ auto_open = false, rules = { { path = "/r", blocks = { "jira" } } } })
	cwd(e2, w2, 1, "/r")
	eq("config auto_open=false opens nothing", #w2.calls, 0)
	e2:toggle(w2.cx)
	eq("toggle on overrides the config", h2.store.auto_open, true)
	e2:toggle(w2.cx)
	eq("toggle off returns control to the config", h2.store.auto_open, nil)
	eq("auto-open follows the config again", e2:enabled(), false)
end

-- 15. another window flipped the shared switch: the status line is redrawn here
do
	local w = shell_world()
	local e, h = new_engine(PERSONAL)
	cwd(e, w, 1, HOME)
	local before = h.changes.n
	h.store.auto_open = false
	cwd(e, w, 1, HOME)
	check("status line redraws after a toggle elsewhere", h.changes.n == before + 1, h.changes.n - before)
	cwd(e, w, 1, HOME)
	check("and only once", h.changes.n == before + 1, h.changes.n - before)
end

-- 16. manual command from a floating terminal splits a tiled shell instead
do
	local w = new_world()
	w:add_pane({ pane = 1, tab = 10, kind = "terminal", cwd = "/r" })
	w:add_pane({ pane = 2, tab = 10, kind = "terminal", cwd = "/r", floating = true })
	w.focus = 2
	local e = new_engine({ rules = { { path = "/r", blocks = { "jira" } } } })
	e:open_now(w.cx)
	eq("blocks split the tiled shell, not the floating one", w.calls[1].target, 1)
end

if failures > 0 then
	print(("%d of %d checks FAILED"):format(failures, count))
	error("tests failed", 0)
end
print(("ok: %d checks"):format(count))
