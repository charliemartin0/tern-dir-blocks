--!strict
-- The window half: subscribes to the `cwd` window event and wires the
-- commands and the status line segment. The logic is in engine.luau.
local config = require("./config")
local engine_mod = require("./engine")

local TOGGLE_ACTION = "plugin.dir-blocks.toggle"
local STATUS_ACTION = "plugin.dir-blocks.status"

local engine = engine_mod.new({
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

tern.on("cwd", function(ev: CwdEvent, cx: WindowCx)
	engine:on_cwd(ev, cx)
end)

tern.on("tab_closed", function(ev: TabEvent, _cx: WindowCx)
	engine:forget_tab(ev.tab)
end)

tern.command({
	id = "open_now",
	title = "Open blocks for this directory",
	icon = "folder",
	run = function(cx: WindowCx)
		engine:open_now(cx)
	end,
})

tern.command({
	id = "toggle",
	title = "Toggle directory auto-open",
	icon = "folder",
	run = function(cx: WindowCx)
		engine:toggle(cx)
	end,
})

tern.command({
	id = "status",
	title = "Directory blocks: show status",
	icon = "folder",
	run = function(cx: WindowCx)
		engine:status(cx)
	end,
})

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	local segment = engine:segment(STATUS_ACTION, TOGGLE_ACTION)
	return if segment then { segment } else nil
end)

tern.on("window_start", function(_cx: WindowCx)
	engine:check_config()
end)

