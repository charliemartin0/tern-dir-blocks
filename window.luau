--!strict
-- The window half: registration only. Loading this file subscribes to events and
-- declares commands and the status segment, nothing else: no file access, no
-- processes, and no require of config.luau / engine.luau (compiling them cost
-- ~15 ms of the 50 ms load budget). The first event or command builds the engine
-- (requires both modules); the engine reads config.json on first use and
-- re-reads it on later calls. The logic is in engine.luau.
local TOGGLE_ACTION = "plugin.dir-blocks.toggle"
local STATUS_ACTION = "plugin.dir-blocks.status"

local function build()
	local config = require("./config")
	local engine_mod = require("./engine")
	return engine_mod.new({
		load = config.reader(tern.plugin.data .. "/config.json", tern.getenv("HOME")),
		kv_get = tern.kv.get,
		kv_set = tern.kv.set,
		now = tern.now,
		log = tern.log,
		changed = function()
			-- Not allowed from a formatter; `changed` is only called from events and commands.
			pcall(tern.chrome.refresh)
		end,
	})
end

local engine: typeof(build())? = nil

local function get_engine(): typeof(build())
	local current = engine
	if current ~= nil then
		return current
	end
	local built = build()
	engine = built
	return built
end

tern.on("cwd", function(ev: CwdEvent, cx: WindowCx)
	get_engine():on_cwd(ev, cx)
end)

tern.on("tab_closed", function(ev: TabEvent, _cx: WindowCx)
	-- No engine yet means no tab state to forget.
	local current = engine
	if current ~= nil then
		current:forget_tab(ev.tab)
	end
end)

tern.command({
	id = "open_now",
	title = "Open blocks for this directory",
	icon = "folder",
	run = function(cx: WindowCx)
		get_engine():open_now(cx)
	end,
})

tern.command({
	id = "toggle",
	title = "Toggle directory auto-open",
	icon = "folder",
	run = function(cx: WindowCx)
		get_engine():toggle(cx)
	end,
})

tern.command({
	id = "status",
	title = "Directory blocks: show status",
	icon = "folder",
	run = function(cx: WindowCx)
		get_engine():status(cx)
	end,
})

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	local current = engine
	if current ~= nil then
		local segment = current:segment(STATUS_ACTION, TOGGLE_ACTION)
		return if segment then { segment } else nil
	end
	-- Before the engine exists config.json is unread and has no problems to show; only the stored
	-- switch can say anything. A formatter must stay cheap, so it never builds the engine.
	local ok, value = pcall(tern.kv.get, "auto_open")
	if ok and value == false then
		return { { text = "dir-blocks off", icon = "folder", tone = "muted", command = TOGGLE_ACTION } }
	end
	return nil
end)
