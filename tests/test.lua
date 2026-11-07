local source = debug.getinfo(1, "S").source
local test_path = source:sub(1, 1) == "@" and source:sub(2) or source
local root = test_path:gsub("tests/test%.lua$", "")

local actions = {}
local starts = 0
local current_process
local encoded_config
local rex_stub = {
	action = function(definition)
		actions[definition.name] = definition
	end,
	json = {
		encode = function(value)
			encoded_config = value
			return "encoded-config"
		end,
	},
	exec = {
		start = function(argv, opts)
			starts = starts + 1
			assert(argv[1] == "/bin/sh" and argv[2]:match("launcher%.sh$"))
			assert(argv[3]:match("daemon%.lua$"))
			assert(opts.detach and opts.stdout == false)
			assert(opts.env.SMART_TITLE_CONFIG == "encoded-config")
			assert(table.concat(argv, " "):find("test-secret", 1, true) == nil)
			current_process = { pid = 100 + starts, alive = true }
			function current_process:running()
				return self.alive
			end
			function current_process:kill()
				self.alive = false
			end
			return current_process
		end,
	},
	log = function() end,
}
_G.rex = rex_stub
local plugin = dofile(root .. "rex/lua/smart-title-rex/init.lua")
assert(not pcall(function()
	plugin.setup({ url = "file:///tmp/model" })
end))
local opts = {
	url = "http://localhost:8080/v1/chat/completions",
	api_key = "test-secret",
	model = "test-model",
	language = "Chinese",
	reasoning_effort = "none",
	poll_interval = 30,
	poll_all_tabs = true,
}
plugin.setup(opts)
local automatic_process = current_process
assert(starts == 1 and automatic_process.alive)
plugin.setup(opts)
assert(starts == 2 and not automatic_process.alive and current_process.alive)
assert(encoded_config.url == opts.url and encoded_config.api_key == opts.api_key)
assert(encoded_config.model == opts.model and encoded_config.reasoning_effort == "none")
assert(encoded_config.language == "Chinese")
assert(encoded_config.poll_interval == 30 and encoded_config.poll_all_tabs == true)
assert(actions.smart_title_start and actions.smart_title_stop)
assert(actions.smart_title_start.run().already_running == true)
assert(starts == 2)
assert(actions.smart_title_stop.run().stopped == true)
assert(actions.smart_title_stop.run().stopped == false)
assert(actions.smart_title_start.run().already_running == false)
assert(starts == 3)
plugin.setup({ url = "http://localhost:8080/v1/chat/completions", model = "test-model" })
assert(encoded_config.language == "English", "language must default to English")

local handlers = {}
local timers = {}
local every_callback
local parent_monitor
local stopped = false
local content = "working on login bug"
local content2 = "second tab content"
local two_windows = false
local ai_output = '\n"Fix login"\nignored explanation'
local exec_count = 0
local renames = {}
local last_argv
local last_request
local use_blob = false

local function timer(delay, callback)
	local value = { delay = delay, callback = callback, cancelled = false }
	function value:cancel()
		self.cancelled = true
	end
	table.insert(timers, value)
	return value
end

_G.rex = {
	args = {},
	on = function(event, callback)
		handlers[event] = callback
	end,
	after = timer,
	every = function(seconds, callback)
		if seconds == 30 then
			every_callback = callback
		elseif seconds == 2 then
			parent_monitor = callback
		else
			error("unexpected timer")
		end
		return timer(seconds, callback)
	end,
	json = {
		encode = function(value)
			last_request = value
			return "request-json"
		end,
		decode = function(text)
			if text == "daemon-config" then
				return {
					url = "http://localhost:8080/v1/chat/completions",
					api_key = "test-secret",
					model = "test-model",
					language = "Chinese",
					reasoning_effort = "none",
					poll_interval = 30,
					poll_all_tabs = true,
				}
			end
			return { choices = { { message = { content = ai_output } } } }
		end,
	},
	call = function(method)
		if method == "server.status" then
			return { pid = 4242, config = { generation = 1 } }
		end
		assert(method == "session.list")
		return { sessions = { { session_id = "s1", label = "work" } } }
	end,
	session = {
		view = function(args)
			assert(args.session_id == "s1")
			local windows = {
				{
					window_id = "w1",
					focused_block_id = "b1",
					layers = {
						{ blocks = { { block_id = "b1", creator_name = "com.superlogical.terminal" } } },
					},
				},
			}
			if two_windows then
				table.insert(windows, {
					window_id = "w2",
					focused_block_id = "b2",
					layers = {
						{ blocks = { { block_id = "b2", creator_name = "com.superlogical.terminal" } } },
					},
				})
			end
			return {
				active_window_id = "w1",
				windows = windows,
			}
		end,
		describe_block = function(args)
			assert(args.session_id == "s1" and args.block_id == "b1")
			return { block = { block_id = "b1", window_id = "w1" } }
		end,
		set_window_label = function(args)
			table.insert(renames, args)
			return { revision = #renames }
		end,
	},
	block = {
		call = function(creator, method, args)
			assert(creator == "com.superlogical.terminal")
			assert(args.session_id == "s1" and (args.block_id == "b1" or args.block_id == "b2"))
			local block_content = args.block_id == "b2" and content2 or content
			if method == "format" then
				assert(args.max_bytes == 1 and args.format == "text")
				if use_blob then
					return { content = "x", id = 7, total = 20000 }
				end
				return { content = block_content }
			end
			assert(method == "blob_read" and args.id == 7 and args.offset == 8000)
			return { data = block_content }
		end,
	},
	exec = function(argv, exec_opts)
		if argv[1] == "/bin/kill" then
			assert(argv[2] == "-0" and (argv[3] == "4242" or argv[3] == "4243"))
			return { ok = false, code = 1 }
		end
		exec_count = exec_count + 1
		last_argv = argv
		assert(argv[1] == "/usr/bin/curl" and exec_opts.timeout == 45)
		assert(exec_opts.stdin == "request-json")
		assert(exec_opts.env.SMART_TITLE_API_KEY == "test-secret")
		assert(exec_opts.env.SMART_TITLE_CONFIG == false)
		assert(table.concat(argv, " "):find("test-secret", 1, true) == nil)
		return { ok = true, code = 0, stdout = "response-json", stderr = "" }
	end,
	log = function() end,
	stop = function()
		stopped = true
	end,
}

local original_getenv = os.getenv
os.getenv = function(name)
	if name == "SMART_TITLE_CONFIG" then
		return "daemon-config"
	end
	if name == "SMART_TITLE_PARENT_PID" then
		return "4242"
	end
	if name == "SMART_TITLE_LAUNCHER_PID" then
		return "4243"
	end
	return original_getenv(name)
end
dofile(root .. "rex/lua/smart-title-rex/daemon.lua")
os.getenv = original_getenv

assert(handlers.active_window_changed and handlers.window_created and handlers.session_created)
assert(handlers["terminal.process_changed"] and handlers["terminal.pwd_changed"])
assert(handlers["terminal.title_changed"] and every_callback and parent_monitor)
assert(timers[1].delay == 0)

timers[1].callback()
assert(exec_count == 1 and #renames == 1)
assert(renames[1].label == "Fix login" and renames[1].window_id == "w1")
assert(last_request.model == "test-model" and last_request.max_tokens == 1024)
assert(last_request.reasoning_effort == "none")
assert(last_request.messages[1].content:find("in Chinese", 1, true))
assert(last_request.messages[2].content:find("working on login bug", 1, true))
assert(last_argv[#last_argv] == "http://localhost:8080/v1/chat/completions")

every_callback()
assert(exec_count == 1 and #renames == 1, "unchanged content must not call AI")

content = "npm test failed in auth suite"
ai_output = "标题：运行测试\n"
every_callback()
assert(exec_count == 2 and renames[2].label == "运行测试")

content = "git diff in review tab"
ai_output = "Review changes"
handlers["terminal.process_changed"]({ session_id = "s1", block_id = "b1" }, {})
local first_pending = timers[#timers]
handlers["terminal.process_changed"]({ session_id = "s1", block_id = "b1" }, {})
local second_pending = timers[#timers]
assert(first_pending.cancelled and not second_pending.cancelled and second_pending.delay == 2)
second_pending.callback()
assert(exec_count == 3 and renames[3].label == "Review changes")

use_blob = true
content = "partial line\nactual recent terminal content"
ai_output = "Recent work"
every_callback()
assert(exec_count == 4 and renames[4].label == "Recent work")
assert(not last_request.messages[2].content:find("partial line", 1, true))
assert(last_request.messages[2].content:find("actual recent terminal content", 1, true))

two_windows = true
content = "tab one changed"
content2 = "tab two content"
ai_output = "两个标签"
every_callback()
assert(exec_count == 6, "poll_all_tabs should refresh every tab")
assert(renames[5].window_id == "w1" and renames[6].window_id == "w2")

parent_monitor()
assert(stopped)

print("ok")
