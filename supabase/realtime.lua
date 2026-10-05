-- Supabase Realtime (realtime-js equivalent): Postgres changes, broadcast and presence over the Phoenix protocol.
-- Needs a WebSocket: extension-websocket in your dependencies (default adapter) or opts.websocket.
--   local channel = sb:channel("room1")
--   channel:on("postgres_changes", { event = "INSERT", schema = "public", table = "todos" }, function(payload) end)
--   channel:on("broadcast", { event = "cursor" }, function(message) end)
--   channel:subscribe(function(status, err) end)
local util = require("supabase.util")
local platform = require("supabase.platform")

local M = {}

local Realtime = {}
Realtime.__index = Realtime

local Channel = {}
Channel.__index = Channel

local function noop() end

--- opts: { websocket = adapter, websocket_params, timer, heartbeat_interval = 25, timeout = 10,
--          reconnect_after = fn(tries) -> seconds, params = { ... extra query params }, logger = fn(kind, msg, data) }
function M.new(client, opts)
	opts = opts or {}
	local self = setmetatable({
		client = client,
		opts = opts,
		timer = opts.timer or client.timer,
		heartbeat_interval = opts.heartbeat_interval or 25,
		timeout = opts.timeout or 10,
		reconnect_after = opts.reconnect_after or function(tries)
			return ({ 1, 2, 5, 10 })[tries] or 10
		end,
		logger = opts.logger,
		channels = {},
		ref = 0,
		state = "closed", -- closed | connecting | open
		send_buffer = {},
		reconnect_tries = 0,
		access_token = nil,
	}, Realtime)
	client.auth:on_auth_state_change(function(event, session)
		if event == "SIGNED_OUT" then
			self:set_auth(nil)
		elseif session and session.access_token then
			self:set_auth(session.access_token)
		end
	end)
	return self
end

function Realtime:log(kind, msg, data)
	if self.logger then
		self.logger(kind, msg, data)
	end
end

function Realtime:make_ref()
	self.ref = self.ref + 1
	return tostring(self.ref)
end

function Realtime:endpoint()
	local query = { { "apikey", self.client.anon_key }, { "vsn", "1.0.0" } }
	local extra = {}
	for k, v in pairs(self.opts.params or {}) do
		extra[#extra + 1] = { k, v }
	end
	table.sort(extra, function(a, b) return a[1] < b[1] end)
	for _, kv in ipairs(extra) do
		query[#query + 1] = kv
	end
	return self.client.url:gsub("^http", "ws") .. "/realtime/v1/websocket?" .. util.build_query(query)
end

--- Token sent with joins: explicit set_auth value, else the session token, else the anon key
function Realtime:token()
	return self.access_token or self.client:access_token()
end

--- Update the token on all joined channels (called automatically on auth changes)
function Realtime:set_auth(token)
	self.access_token = token
	local t = self:token()
	for _, ch in ipairs(self.channels) do
		if ch.state == "joined" then
			ch:push("access_token", { access_token = t })
		end
	end
end

function Realtime:is_connected()
	return self.state == "open"
end

function Realtime:connect()
	if self.state ~= "closed" then
		return
	end
	self.manual_close = false
	self.state = "connecting"
	self.socket = self.socket or self.opts.websocket or platform.websocket(self.opts.websocket_params)
	self:log("transport", "connecting", self:endpoint())
	self.conn = self.socket.connect(self:endpoint(), function(event, data)
		self:on_socket(event, data)
	end)
end

function Realtime:disconnect()
	self.manual_close = true
	self:cancel_timers()
	if self.conn then
		self.socket.close(self.conn)
	end
	self.conn = nil
	self.state = "closed"
	for _, ch in ipairs(self.channels) do
		if ch.state ~= "closed" then
			ch:set_state("closed")
		end
	end
end

function Realtime:cancel_timers()
	if self.heartbeat_timer then
		self.timer.cancel(self.heartbeat_timer)
		self.heartbeat_timer = nil
	end
	if self.reconnect_timer then
		self.timer.cancel(self.reconnect_timer)
		self.reconnect_timer = nil
	end
	self.pending_heartbeat = nil
end

function Realtime:on_socket(event, data)
	if event == "open" then
		self.state = "open"
		self.reconnect_tries = 0
		self:log("transport", "connected")
		self:cancel_timers()
		self.heartbeat_timer = self.timer.delay(self.heartbeat_interval, true, function()
			self:heartbeat()
		end)
		-- channels that lost the connection join again; first joins are still in the send buffer
		for _, ch in ipairs(self.channels) do
			if ch.state == "errored" then
				ch:rejoin()
			end
		end
		local buffer = self.send_buffer
		self.send_buffer = {}
		for _, text in ipairs(buffer) do
			self.socket.send(self.conn, text)
		end
	elseif event == "message" then
		local ok, msg = pcall(self.client.codec.decode, data)
		if ok and type(msg) == "table" then
			self:on_message(msg)
		end
	elseif event == "close" or event == "error" then
		if self.state == "closed" and self.conn == nil then
			return
		end
		self:log("transport", event, data)
		self.state = "closed"
		self.conn = nil
		self:cancel_timers()
		for _, ch in ipairs(self.channels) do
			if ch.state == "joined" or ch.state == "joining" then
				ch:set_state("errored")
			end
		end
		if not self.manual_close then
			self.reconnect_tries = self.reconnect_tries + 1
			self.reconnect_timer = self.timer.delay(self.reconnect_after(self.reconnect_tries), false, function()
				self.reconnect_timer = nil
				self:connect()
			end)
		end
	end
end

function Realtime:heartbeat()
	if self.state ~= "open" then
		return
	end
	if self.pending_heartbeat then
		-- no reply to the previous heartbeat: drop the connection and reconnect
		self:log("transport", "heartbeat timeout")
		self.pending_heartbeat = nil
		if self.conn then
			self.socket.close(self.conn)
		end
		self:on_socket("close", { message = "heartbeat timeout" })
		return
	end
	if self.client.auth:should_refresh() then
		self.client.auth:refresh_session()
	end
	self.pending_heartbeat = self:make_ref()
	self:push_message({ topic = "phoenix", event = "heartbeat", payload = {}, ref = self.pending_heartbeat })
end

function Realtime:push_message(msg)
	local text = self.client.codec.encode(msg)
	self:log("push", msg.topic .. " " .. msg.event, msg.payload)
	if self.state == "open" then
		self.socket.send(self.conn, text)
	else
		self.send_buffer[#self.send_buffer + 1] = text
		self:connect()
	end
end

function Realtime:on_message(msg)
	self:log("receive", tostring(msg.topic) .. " " .. tostring(msg.event), msg.payload)
	if msg.topic == "phoenix" then
		if msg.ref and msg.ref == self.pending_heartbeat then
			self.pending_heartbeat = nil
		end
		return
	end
	for _, ch in ipairs({ unpack(self.channels) }) do
		if ch.topic == msg.topic then
			ch:on_message(msg)
		end
	end
end

--- New channel. config: { broadcast = { self = bool, ack = bool }, presence = { key = "" }, private = bool }
function Realtime:channel(name, config)
	local ch = setmetatable({
		socket = self,
		name = name,
		topic = "realtime:" .. name,
		config = config or {},
		bindings = {},
		state = "closed", -- closed | joining | joined | leaving | errored
		pending = {}, -- ref -> callback(status, response)
		buffer = {}, -- pushes waiting for the join
		presence_map = {},
	}, Channel)
	self.channels[#self.channels + 1] = ch
	return ch
end

function Realtime:get_channels()
	return { unpack(self.channels) }
end

--- Unsubscribe and forget a channel; disconnects when no channels are left
function Realtime:remove_channel(ch, callback)
	callback = callback or noop
	local function forget(status)
		for i, c in ipairs(self.channels) do
			if c == ch then
				table.remove(self.channels, i)
				break
			end
		end
		if #self.channels == 0 then
			self:disconnect()
		end
		callback(status)
	end
	if ch.state == "joined" or ch.state == "joining" then
		ch:unsubscribe(forget)
	else
		forget("ok")
	end
end

function Realtime:remove_all_channels(callback)
	callback = callback or noop
	local channels = { unpack(self.channels) }
	if #channels == 0 then
		return callback({})
	end
	local results, left = {}, #channels
	for i, ch in ipairs(channels) do
		self:remove_channel(ch, function(status)
			results[i] = status
			left = left - 1
			if left == 0 then
				callback(results)
			end
		end)
	end
end

-- Channel --------------------------------------------------------------------------

function Channel:set_state(state)
	self.state = state
	if state == "errored" and self.on_status then
		self.on_status("CHANNEL_ERROR", nil)
	elseif state == "closed" and self.on_status then
		self.on_status("CLOSED", nil)
	end
end

--- on("postgres_changes", { event = "*" | "INSERT" | "UPDATE" | "DELETE", schema, table?, filter? }, fn(payload))
--   payload: { schema, table, commit_timestamp, eventType, new, old, errors }
-- on("broadcast", { event = "name" | "*" }, fn({ type, event, payload }))
-- on("presence", { event = "sync" | "join" | "leave" }, fn(info))
-- on("system", {}, fn(payload))
function Channel:on(type_, filter, callback)
	self.bindings[#self.bindings + 1] = { type = type_, filter = filter or {}, callback = callback }
	return self
end

function Channel:join_payload()
	local postgres_changes = {}
	local has_presence = false
	for _, b in ipairs(self.bindings) do
		if b.type == "postgres_changes" then
			postgres_changes[#postgres_changes + 1] = {
				event = b.filter.event or "*",
				schema = b.filter.schema,
				table = b.filter.table,
				filter = b.filter.filter,
			}
		elseif b.type == "presence" then
			has_presence = true
		end
	end
	local presence = self.config.presence or {}
	return {
		config = {
			broadcast = self.config.broadcast or { ack = false, self = false },
			presence = { key = presence.key or "", enabled = has_presence or presence.enabled == true },
			-- omitted when empty: Defold's json.encode turns {} into an object, the server expects a list
			postgres_changes = #postgres_changes > 0 and postgres_changes or nil,
			private = self.config.private == true,
		},
		access_token = self.socket:token(),
	}
end

--- Join. callback(status, err): "SUBSCRIBED" | "CHANNEL_ERROR" | "TIMED_OUT" | "CLOSED"
function Channel:subscribe(callback, timeout)
	self.on_status = callback or noop
	self.join_timeout = timeout or self.socket.timeout
	self:rejoin()
	return self
end

function Channel:rejoin()
	self.state = "joining"
	self.join_ref = self.socket:make_ref()
	local join_ref = self.join_ref
	if self.join_timer then
		self.socket.timer.cancel(self.join_timer)
	end
	self.join_timer = self.socket.timer.delay(self.join_timeout or self.socket.timeout, false, function()
		self.join_timer = nil
		if self.state == "joining" and self.join_ref == join_ref then
			self.on_status("TIMED_OUT", nil)
		end
	end)
	self.socket:push_message({
		topic = self.topic,
		event = "phx_join",
		payload = self:join_payload(),
		ref = join_ref,
		join_ref = join_ref,
	})
end

function Channel:push(event, payload, callback)
	local ref = self.socket:make_ref()
	if callback then
		self.pending[ref] = callback
	end
	self.socket:push_message({ topic = self.topic, event = event, payload = payload, ref = ref, join_ref = self.join_ref })
	return ref
end

local function on_join_reply(self, payload)
	if self.join_timer then
		self.socket.timer.cancel(self.join_timer)
		self.join_timer = nil
	end
	if payload.status ~= "ok" then
		self.state = "errored"
		self.on_status("CHANNEL_ERROR", payload.response)
		return
	end
	-- map the server's postgres_changes ids onto our bindings (same order)
	local server = payload.response and payload.response.postgres_changes or {}
	local i = 0
	for _, b in ipairs(self.bindings) do
		if b.type == "postgres_changes" then
			i = i + 1
			local s = server[i]
			if not s or s.event ~= (b.filter.event or "*") or s.schema ~= b.filter.schema
				or s.table ~= b.filter.table or s.filter ~= b.filter.filter then
				self.state = "errored"
				self:unsubscribe()
				self.on_status("CHANNEL_ERROR", { message = "mismatch between server and client bindings for postgres changes" })
				return
			end
			b.id = s.id
		end
	end
	self.state = "joined"
	self.on_status("SUBSCRIBED", nil)
	local buffer = self.buffer
	self.buffer = {}
	for _, fn in ipairs(buffer) do
		fn()
	end
end

local function trigger(self, type_, event, payload)
	for _, b in ipairs(self.bindings) do
		if b.type == type_ and (b.filter.event == nil or b.filter.event == "*" or b.filter.event == event) then
			b.callback(payload)
		end
	end
end

function Channel:on_message(msg)
	local event, payload = msg.event, msg.payload or {}
	if event == "phx_reply" then
		if msg.ref == self.join_ref and self.state == "joining" then
			on_join_reply(self, payload)
		elseif self.pending[msg.ref] then
			local cb = self.pending[msg.ref]
			self.pending[msg.ref] = nil
			cb(payload.status, payload.response)
		end
	elseif event == "phx_close" then
		if self.state ~= "closed" and (msg.join_ref == nil or msg.join_ref == self.join_ref) then
			self:set_state("closed")
		end
	elseif event == "phx_error" then
		self:set_state("errored")
		-- the server dropped the channel but the socket is alive: try again after a delay
		self.socket.timer.delay(self.socket.reconnect_after(1), false, function()
			if self.state == "errored" and self.socket.state == "open" then
				self:rejoin()
			end
		end)
	elseif event == "postgres_changes" then
		local data = payload.data or {}
		local ids = {}
		for _, id in ipairs(payload.ids or {}) do
			ids[id] = true
		end
		local change = {
			schema = data.schema,
			table = data.table,
			commit_timestamp = data.commit_timestamp,
			eventType = data.type,
			new = data.record or {},
			old = data.old_record or {},
			errors = data.errors,
		}
		for _, b in ipairs(self.bindings) do
			if b.type == "postgres_changes" and b.id and ids[b.id] then
				b.callback(change)
			end
		end
	elseif event == "broadcast" then
		trigger(self, "broadcast", payload.event, payload)
	elseif event == "presence_state" then
		self:sync_presence_state(payload)
	elseif event == "presence_diff" then
		self:sync_presence_diff(payload)
	elseif event == "system" then
		trigger(self, "system", nil, payload)
	end
end

--- Leave the channel. callback(status): "ok" | "timed out" | "error"
function Channel:unsubscribe(callback)
	callback = callback or noop
	if self.state ~= "joined" and self.state ~= "joining" then
		self.state = "closed"
		return callback("ok")
	end
	self.state = "leaving"
	local done = false
	local function finish(status)
		if done then
			return
		end
		done = true
		self.state = "closed"
		if self.on_status then
			self.on_status("CLOSED", nil)
		end
		callback(status)
	end
	local ref = self:push("phx_leave", {}, function(status)
		finish(status == "ok" and "ok" or "error")
	end)
	self.socket.timer.delay(self.socket.timeout, false, function()
		self.pending[ref] = nil
		finish("timed out")
	end)
end

--- Send a message. message: { type = "broadcast", event, payload } (or type = "presence", see track/untrack)
-- callback(status): "ok" | "error" | "timed out". Uses the REST endpoint when the channel is not joined.
function Channel:send(message, callback)
	callback = callback or noop
	if message.type == "broadcast" and self.state ~= "joined" then
		return self:http_send(message.event, message.payload, callback)
	end
	local function do_send()
		local ack = self.config.broadcast and self.config.broadcast.ack
		if message.type == "broadcast" and not ack then
			self:push("broadcast", message)
			return callback("ok")
		end
		local ref = self:push(message.type, message, function(status)
			callback(status == "ok" and "ok" or "error")
		end)
		self.socket.timer.delay(self.socket.timeout, false, function()
			if self.pending[ref] then
				self.pending[ref] = nil
				callback("timed out")
			end
		end)
	end
	if self.state == "joined" then
		do_send()
	else
		self.buffer[#self.buffer + 1] = do_send
	end
end

--- Broadcast through the REST API (no WebSocket needed). callback(status)
function Channel:http_send(event, payload, callback)
	callback = callback or noop
	self.socket.client:request("POST", "/realtime/v1/api/broadcast", {
		body = { messages = { { topic = self.name, event = event, payload = payload, private = self.config.private == true } } },
	}, function(err)
		callback(err and "error" or "ok", err)
	end)
end

--- Track this client's presence state (any table). callback(status)
function Channel:track(state, callback)
	self:send({ type = "presence", event = "track", payload = state }, callback)
end

function Channel:untrack(callback)
	self:send({ type = "presence", event = "untrack" }, callback)
end

--- Current presence: { [key] = { { presence_ref, ...state }, ... } }
function Channel:presence_state()
	return self.presence_map
end

local function transform_metas(entry)
	local list = {}
	for i, meta in ipairs(entry.metas or {}) do
		local p = {}
		for k, v in pairs(meta) do
			if k ~= "phx_ref" and k ~= "phx_ref_prev" then
				p[k] = v
			end
		end
		p.presence_ref = meta.phx_ref
		list[i] = p
	end
	return list
end

local function refs_of(list)
	local refs = {}
	for _, p in ipairs(list or {}) do
		refs[p.presence_ref] = true
	end
	return refs
end

local function apply_joins_leaves(self, joins, leaves)
	for key, new_presences in pairs(joins) do
		local current = self.presence_map[key] or {}
		local merged = { unpack(current) }
		local known = refs_of(current)
		for _, p in ipairs(new_presences) do
			if not known[p.presence_ref] then
				merged[#merged + 1] = p
			end
		end
		self.presence_map[key] = merged
		trigger(self, "presence", "join", { event = "join", key = key, current_presences = current, new_presences = new_presences })
	end
	for key, left_presences in pairs(leaves) do
		local current = self.presence_map[key]
		if current then
			local gone = refs_of(left_presences)
			local remaining = {}
			for _, p in ipairs(current) do
				if not gone[p.presence_ref] then
					remaining[#remaining + 1] = p
				end
			end
			self.presence_map[key] = #remaining > 0 and remaining or nil
			trigger(self, "presence", "leave", { event = "leave", key = key, current_presences = remaining, left_presences = left_presences })
		end
	end
	trigger(self, "presence", "sync", { event = "sync" })
end

function Channel:sync_presence_state(state)
	local new_state = {}
	for key, entry in pairs(state) do
		new_state[key] = transform_metas(entry)
	end
	local joins, leaves = {}, {}
	for key, presences in pairs(self.presence_map) do
		local keep = refs_of(new_state[key])
		local left = {}
		for _, p in ipairs(presences) do
			if not keep[p.presence_ref] then
				left[#left + 1] = p
			end
		end
		if #left > 0 then
			leaves[key] = left
		end
	end
	for key, presences in pairs(new_state) do
		local known = refs_of(self.presence_map[key])
		local added = {}
		for _, p in ipairs(presences) do
			if not known[p.presence_ref] then
				added[#added + 1] = p
			end
		end
		if #added > 0 then
			joins[key] = added
		end
	end
	apply_joins_leaves(self, joins, leaves)
end

function Channel:sync_presence_diff(diff)
	local joins, leaves = {}, {}
	for key, entry in pairs(diff.joins or {}) do
		joins[key] = transform_metas(entry)
	end
	for key, entry in pairs(diff.leaves or {}) do
		leaves[key] = transform_metas(entry)
	end
	apply_joins_leaves(self, joins, leaves)
end

return M
