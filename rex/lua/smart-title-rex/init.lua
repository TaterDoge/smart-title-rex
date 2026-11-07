local M = {}

local source = debug.getinfo(1, "S").source
local init_path = source:sub(1, 1) == "@" and source:sub(2) or source
local daemon_path = init_path:gsub("init%.lua$", "daemon.lua")
local launcher_path = init_path:gsub("init%.lua$", "launcher.sh")
local watcher

local function stop_watcher()
	local running = watcher and watcher:running()
	if running then
		watcher:kill()
	end
	watcher = nil
	return running == true
end

---@class SmartTitleOptions
---@field url? string OpenAI-compatible chat completions URL.
---@field api_key? string Bearer token; empty sends no Authorization header.
---@field model? string Model name sent to the endpoint.
---@field language? string Language of the generated title, such as "English" or "Chinese". Defaults to "English".
---@field reasoning_effort? string Provider-specific reasoning budget, such as "none" or "low".
---@field poll_interval? number Seconds between fallback scans. Defaults to 30.
---@field poll_all_tabs? boolean Scan every tab instead of only each session's active tab. Defaults to false.

---@param opts? SmartTitleOptions
function M.setup(opts)
	opts = opts or {}
	local config = {
		url = opts.url or "https://api.openai.com/v1/chat/completions",
		api_key = opts.api_key or "",
		model = opts.model or "gpt-4o-mini",
		language = opts.language or "English",
		reasoning_effort = opts.reasoning_effort,
		poll_interval = opts.poll_interval or 30,
		poll_all_tabs = opts.poll_all_tabs == true,
	}
	if type(config.url) ~= "string" or not config.url:match("^https?://%S+$") then
		error("smart-title-rex: opts.url must be an HTTP(S) URL", 0)
	end
	if type(config.api_key) ~= "string" then
		error("smart-title-rex: opts.api_key must be a string", 0)
	end
	if type(config.model) ~= "string" or not config.model:match("%S") then
		error("smart-title-rex: opts.model must not be empty", 0)
	end
	if type(config.language) ~= "string" or not config.language:match("%S") or config.language:match("%c") then
		error("smart-title-rex: opts.language must be a language name without line breaks, such as \"English\"", 0)
	end
	if config.reasoning_effort ~= nil and (type(config.reasoning_effort) ~= "string" or config.reasoning_effort == "") then
		error("smart-title-rex: opts.reasoning_effort must be a non-empty string", 0)
	end
	if type(config.poll_interval) ~= "number" or config.poll_interval <= 0 then
		error("smart-title-rex: opts.poll_interval must be a positive number", 0)
	end
	if opts.poll_all_tabs ~= nil and type(opts.poll_all_tabs) ~= "boolean" then
		error("smart-title-rex: opts.poll_all_tabs must be a boolean", 0)
	end

	local encoded_config, encode_err = rex.json.encode(config)
	if not encoded_config then
		error("smart-title-rex: " .. encode_err, 0)
	end

	local function start_watcher()
		if watcher and watcher:running() then
			return true
		end
		local process, err = rex.exec.start({ "/bin/sh", launcher_path, daemon_path }, {
			detach = true,
			env = { SMART_TITLE_CONFIG = encoded_config },
			stdout = false,
			stderr = function(data)
				rex.log("warn", "smart-title-rex: " .. data)
			end,
		})
		if not process then
			error("smart-title-rex: " .. err, 0)
		end
		watcher = process
		return false
	end

	rex.action({
		name = "smart_title_start",
		title = "Smart Title: Start Watcher",
		description = "Restart the automatic tab-title watcher after smart_title_stop.",
		category = "Smart Title",
		run = function()
			local already_running = start_watcher()
			return { pid = watcher.pid, already_running = already_running }
		end,
	})

	rex.action({
		name = "smart_title_stop",
		title = "Smart Title: Stop Watcher",
		category = "Smart Title",
		run = function()
			return { stopped = stop_watcher() }
		end,
	})

	-- Config reload applies new opts; config-check children reject themselves by parent PID.
	stop_watcher()
	start_watcher()
end

return M
