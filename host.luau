--!strict
-- The host half only validates config.json when the plugin loads. A plugin
-- that fails to load is the one thing `tern plugin list` (and the exit status
-- of `tern plugin reload`) reports, so a config problem raises here and shows
-- up as `failed: dir-blocks: …`. The window half is independent: it keeps
-- running and applies every valid rule, skipping the bad ones.
local config = require("./config")

local cfg = config.load_or_create(tern.plugin.data .. "/config.json", tern.getenv("HOME"))
if #cfg.problems > 0 then
	local shown: { string } = {}
	for i = 1, math.min(3, #cfg.problems) do
		table.insert(shown, cfg.problems[i])
	end
	local more = if #cfg.problems > 3 then " (+" .. (#cfg.problems - 3) .. " more, see the Tern log)" else ""
	for _, problem in cfg.problems do
		tern.log.warn("dir-blocks: config.json: " .. problem)
	end
	error("dir-blocks config problem: " .. table.concat(shown, " | ") .. more, 0)
end
