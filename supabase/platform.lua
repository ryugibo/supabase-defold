-- Default adapters backed by Defold APIs. This is the only module that touches Defold globals,
-- and only when an adapter is used, so the rest of the library runs on plain LuaJIT in tests.
local M = {}

--- HTTP: transport(url, method, headers, body, callback(status, body, headers), options{ timeout })
function M.transport(url, method, headers, body, callback, options)
	http.request(url, method, function(_, _, response)
		callback(response.status, response.response, response.headers)
	end, headers, body, { timeout = options and options.timeout or 15 })
end

function M.codec()
	return {
		encode = function(t) return json.encode(t) end,
		decode = function(s) return json.decode(s) end,
	}
end

--- Timers (must be used from a script/gui_script context)
M.timer = {
	delay = function(seconds, repeating, fn)
		return timer.delay(seconds, repeating, function() fn() end)
	end,
	cancel = function(handle)
		timer.cancel(handle)
	end,
}

--- [supabase] values from game.project (see supabase/ext.properties). Empty table outside Defold.
function M.config()
	if type(sys) ~= "table" or not sys.get_config_string then
		return {}
	end
	local function str(key)
		local v = sys.get_config_string("supabase." .. key, "")
		return v ~= "" and v or nil
	end
	local function int(key)
		local v = str(key)
		return v and tonumber(v) or nil
	end
	local function bool(key)
		local v = int(key)
		if v == nil then
			return nil
		end
		return v ~= 0
	end
	return {
		url = str("url"),
		anon_key = str("anon_key"),
		schema = str("schema"),
		flow_type = str("flow_type"),
		persist_session = bool("persist_session"),
		auto_refresh_token = bool("auto_refresh_token"),
		timeout = int("timeout"),
	}
end

function M.open_url(url)
	return sys.open_url(url)
end

--- Key/value storage persisted with sys.save. app_id defaults to the project title.
function M.storage(app_id)
	app_id = app_id or sys.get_config_string("project.title", "defold"):gsub("[^%w%-_]", "_")
	local path = sys.get_save_file(app_id, "supabase")
	local data
	local function load()
		if not data then
			local ok, loaded = pcall(sys.load, path)
			data = ok and loaded or {}
		end
		return data
	end
	return {
		get = function(key) return load()[key] end,
		set = function(key, value)
			load()[key] = value
			sys.save(path, data)
		end,
		remove = function(key)
			load()[key] = nil
			sys.save(path, data)
		end,
	}
end

--- In-memory storage (tests, or when persistence is not wanted)
function M.memory_storage()
	local data = {}
	return {
		get = function(key) return data[key] end,
		set = function(key, value) data[key] = value end,
		remove = function(key) data[key] = nil end,
	}
end

--- WebSocket adapter over extension-websocket: connect(url, on_event(event, data)) -> conn, send(conn, text), close(conn)
-- events: "open", "message" (data = text), "close", "error"
function M.websocket(params)
	assert(websocket, "supabase realtime needs extension-websocket: add "
		.. "https://github.com/defold/extension-websocket/archive/refs/tags/4.2.4.zip to your project dependencies")
	return {
		connect = function(url, on_event)
			return websocket.connect(url, params or {}, function(_, _, data)
				if data.event == websocket.EVENT_CONNECTED then
					on_event("open")
				elseif data.event == websocket.EVENT_MESSAGE then
					on_event("message", data.message)
				elseif data.event == websocket.EVENT_DISCONNECTED then
					on_event("close", data)
				elseif data.event == websocket.EVENT_ERROR then
					on_event("error", data)
				end
			end)
		end,
		send = function(conn, text)
			websocket.send(conn, text, { type = websocket.DATA_TYPE_TEXT })
		end,
		close = function(conn)
			websocket.disconnect(conn)
		end,
	}
end

return M
