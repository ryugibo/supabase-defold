local H = require("tests.helpers")

local function setup(routes)
	local socket = H.fake_socket()
	local sb, log = H.fake(routes or {}, { realtime = { websocket = socket } })
	return sb, socket, log
end

local function reply(socket, msg, status, response)
	socket.receive({ topic = msg.topic, event = "phx_reply", ref = msg.ref, join_ref = msg.join_ref,
		payload = { status = status or "ok", response = response or {} } })
end

test("connects lazily and joins with postgres_changes config", function()
	local sb, socket = setup()
	local statuses = {}
	local ch = sb:channel("db")
		:on("postgres_changes", { event = "INSERT", schema = "public", table = "todos", filter = "user_id=eq.u1" }, function() end)
		:subscribe(function(status) statuses[#statuses + 1] = status end)
	assert(socket.url == "wss://test.supabase.co/realtime/v1/websocket?apikey=ANON&vsn=1.0.0")
	assert(#socket.sent == 0, "buffered until open")
	socket.open()
	local join = socket.last("phx_join", "realtime:db")
	local cfg = join.payload.config
	assert(cfg.postgres_changes[1].table == "todos" and cfg.postgres_changes[1].filter == "user_id=eq.u1")
	assert(cfg.broadcast.self == false and cfg.presence.enabled == false and join.payload.access_token == "ANON")
	reply(socket, join, "ok", { postgres_changes = { { id = 7, event = "INSERT", schema = "public", table = "todos", filter = "user_id=eq.u1" } } })
	assert(statuses[1] == "SUBSCRIBED" and ch.state == "joined")
end)

test("postgres changes are routed by binding id", function()
	local sb, socket = setup()
	local inserts, all = {}, {}
	sb:channel("db")
		:on("postgres_changes", { event = "INSERT", schema = "public", table = "todos" }, function(p) inserts[#inserts + 1] = p end)
		:on("postgres_changes", { event = "*", schema = "public" }, function(p) all[#all + 1] = p end)
		:subscribe()
	socket.open()
	reply(socket, socket.last("phx_join"), "ok", { postgres_changes = {
		{ id = 1, event = "INSERT", schema = "public", table = "todos" },
		{ id = 2, event = "*", schema = "public" },
	} })
	socket.receive({ topic = "realtime:db", event = "postgres_changes", payload = { ids = { 1, 2 }, data = {
		schema = "public", table = "todos", type = "INSERT", commit_timestamp = "t", record = { id = 5 } } } })
	socket.receive({ topic = "realtime:db", event = "postgres_changes", payload = { ids = { 2 }, data = {
		schema = "public", table = "other", type = "DELETE", old_record = { id = 9 } } } })
	assert(#inserts == 1 and inserts[1].eventType == "INSERT" and inserts[1].new.id == 5)
	assert(#all == 2 and all[2].old.id == 9 and all[2].table == "other")
end)

test("binding mismatch reports CHANNEL_ERROR", function()
	local sb, socket = setup()
	local status
	sb:channel("db"):on("postgres_changes", { event = "INSERT", schema = "public", table = "a" }, function() end)
		:subscribe(function(s) status = status or s end)
	socket.open()
	reply(socket, socket.last("phx_join"), "ok", { postgres_changes = { { id = 1, event = "INSERT", schema = "public", table = "b" } } })
	assert(status == "CHANNEL_ERROR")
end)

test("broadcast send (with ack) and receive, REST fallback when not joined", function()
	local sb, socket, log = setup({ ["POST /realtime/v1/api/broadcast"] = { 202, nil } })
	local received = {}
	local ch = sb:channel("room", { broadcast = { self = true, ack = true } })
		:on("broadcast", { event = "cursor" }, function(m) received[#received + 1] = m end)
	local rest_status
	ch:send({ type = "broadcast", event = "cursor", payload = { x = 1 } }, function(s) rest_status = s end)
	assert(rest_status == "ok" and log[1].body.messages[1].topic == "room" and log[1].body.messages[1].payload.x == 1)
	ch:subscribe()
	socket.open()
	reply(socket, socket.last("phx_join"))
	local ack
	ch:send({ type = "broadcast", event = "cursor", payload = { x = 2 } }, function(s) ack = s end)
	local push = socket.last("broadcast")
	assert(push.payload.event == "cursor" and push.payload.payload.x == 2 and ack == nil)
	reply(socket, push)
	assert(ack == "ok")
	socket.receive({ topic = "realtime:room", event = "broadcast", payload = { type = "broadcast", event = "cursor", payload = { x = 3 } } })
	socket.receive({ topic = "realtime:room", event = "broadcast", payload = { type = "broadcast", event = "other", payload = {} } })
	assert(#received == 1 and received[1].payload.x == 3)
end)

test("presence track, state and diff", function()
	local sb, socket = setup()
	local events = {}
	local ch = sb:channel("lobby", { presence = { key = "u1" } })
		:on("presence", { event = "sync" }, function() events[#events + 1] = "sync" end)
		:on("presence", { event = "join" }, function(e) events[#events + 1] = "join:" .. e.key end)
		:on("presence", { event = "leave" }, function(e) events[#events + 1] = "leave:" .. e.key end)
		:subscribe()
	socket.open()
	local join = socket.last("phx_join")
	assert(join.payload.config.presence.key == "u1" and join.payload.config.presence.enabled == true)
	reply(socket, join)
	ch:track({ online_at = "now" })
	local track = socket.last("presence")
	assert(track.payload.event == "track" and track.payload.payload.online_at == "now")
	socket.receive({ topic = "realtime:lobby", event = "presence_state", payload = {
		u1 = { metas = { { phx_ref = "r1", online_at = "now" } } },
	} })
	assert(ch:presence_state().u1[1].presence_ref == "r1" and ch:presence_state().u1[1].online_at == "now")
	socket.receive({ topic = "realtime:lobby", event = "presence_diff", payload = {
		joins = { u2 = { metas = { { phx_ref = "r2" } } } },
		leaves = { u1 = { metas = { { phx_ref = "r1" } } } },
	} })
	assert(ch:presence_state().u1 == nil and ch:presence_state().u2[1].presence_ref == "r2")
	assert(table.concat(events, ",") == "join:u1,sync,join:u2,leave:u1,sync", table.concat(events, ","))
	ch:untrack()
	assert(socket.last("presence").payload.event == "untrack")
end)

test("heartbeat, timeout reconnect and rejoin", function()
	local sb, socket = setup()
	local statuses = {}
	sb:channel("c"):subscribe(function(s) statuses[#statuses + 1] = s end)
	socket.open()
	reply(socket, socket.last("phx_join"))
	sb.timer.fire(25)
	local hb = socket.last("heartbeat", "phoenix")
	assert(hb)
	socket.receive({ topic = "phoenix", event = "phx_reply", ref = hb.ref, payload = { status = "ok" } })
	sb.timer.fire(25)
	sb.timer.fire(25) -- previous heartbeat unanswered -> reconnect
	assert(socket.closed == 1 and statuses[2] == "CHANNEL_ERROR")
	sb.timer.fire(1) -- reconnect_after(1)
	assert(socket.connects == 2)
	socket.open()
	local rejoin = socket.last("phx_join")
	assert(rejoin.ref ~= nil)
	reply(socket, rejoin)
	assert(statuses[3] == "SUBSCRIBED")
end)

test("token changes are pushed to joined channels", function()
	local sb, socket = setup({ ["POST /auth/v1/token"] = { 200, { access_token = "NEW", refresh_token = "R2", expires_in = 3600 } } })
	sb:channel("c"):subscribe()
	socket.open()
	reply(socket, socket.last("phx_join"))
	sb.session = { access_token = "OLD", refresh_token = "R1", expires_at = os.time() + 3600 }
	sb.auth:refresh_session()
	local push = socket.last("access_token")
	assert(push and push.payload.access_token == "NEW")
	sb.auth:set_session(nil)
	assert(socket.last("access_token").payload.access_token == "ANON")
end)

test("unsubscribe, remove_channel and join timeout", function()
	local sb, socket = setup()
	local statuses = {}
	local ch = sb:channel("c"):subscribe(function(s) statuses[#statuses + 1] = s end)
	socket.open()
	reply(socket, socket.last("phx_join"))
	local removed
	sb:remove_channel(ch, function(s) removed = s end)
	reply(socket, socket.last("phx_leave"))
	assert(removed == "ok" and statuses[2] == "CLOSED" and #sb:get_channels() == 0 and socket.closed == 1)

	local timed_out
	sb:channel("slow"):subscribe(function(s) timed_out = s end)
	socket.open()
	sb.timer.fire(10)
	assert(timed_out == "TIMED_OUT")
end)

test("server channel error triggers a delayed rejoin", function()
	local sb, socket = setup()
	local statuses = {}
	sb:channel("c"):subscribe(function(s) statuses[#statuses + 1] = s end)
	socket.open()
	reply(socket, socket.last("phx_join"))
	local joins = #socket.sent
	socket.receive({ topic = "realtime:c", event = "phx_error", payload = {} })
	assert(statuses[2] == "CHANNEL_ERROR")
	sb.timer.fire(1)
	assert(#socket.sent == joins + 1 and socket.sent[#socket.sent].event == "phx_join")
	reply(socket, socket.last("phx_join"))
	assert(statuses[3] == "SUBSCRIBED")
end)
