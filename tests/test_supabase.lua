local supabase = require("supabase.client")

local H = require("tests.helpers")

local function fake(routes)
	return H.fake(routes)
end

test("urlencode / build_query", function()
	assert(supabase.urlencode("a b&c=d/é") == "a%20b%26c%3Dd%2F%C3%A9")
	assert(supabase.build_query({ { "select", "*" }, { "id", "eq.1" } }) == "select=%2A&id=eq.1")
	assert(supabase.build_query({ b = 2, a = 1 }) == "a=1&b=2")
end)

test("requests send apikey and anon Bearer by default", function()
	local sb, log = fake({ ["GET /rest/v1/things"] = { 200, { { id = 1 } } } })
	local got
	sb.db:from("things"):select():execute(function(err, data) got = { err, data } end)
	assert(got[1] == nil and got[2][1].id == 1)
	assert(log[1].headers.apikey == "ANON" and log[1].headers.Authorization == "Bearer ANON")
	assert(log[1].url == "https://test.supabase.co/rest/v1/things?select=%2A")
end)

test("anonymous sign-in, then requests use the session token", function()
	local sb, log = fake({
		["POST /auth/v1/signup"] = { 200, { access_token = "AT", refresh_token = "RT", expires_in = 3600, user = { id = "u1" } } },
		["GET /rest/v1/profiles"] = function(e)
			assert(e.headers.Accept == "application/vnd.pgrst.object+json", "single() asks for one object")
			return { 200, { id = "u1", gold = 5 } }
		end,
	})
	local changed
	sb.auth:on_change(function(s) changed = s end)
	sb.auth:sign_in_anonymously(function(err, session) assert(not err and session.access_token == "AT") end)
	assert(changed and changed.expires_at and sb:user_id() == "u1")
	assert(type(log[1].body.data) == "table")
	sb.db:from("profiles"):select():eq("id", "u1"):single():execute(function(err, row)
		assert(row.gold == 5)
	end)
	assert(log[2].headers.Authorization == "Bearer AT")
	assert(log[2].url:find("id=eq.u1", 1, true))
end)

test("session refresh and expiry check", function()
	local sb, log = fake({
		["POST /auth/v1/token"] = function(e)
			assert(e.url:find("grant_type=refresh_token", 1, true) and e.body.refresh_token == "OLD")
			return { 200, { access_token = "NEW", refresh_token = "RT2", expires_in = 3600, user = { id = "u1" } } }
		end,
	})
	local restored
	sb.auth:restore({ access_token = "X", refresh_token = "OLD", expires_at = os.time() - 10 }, function(err, s) restored = s end)
	assert(restored.access_token == "NEW" and not sb.auth:needs_refresh())
	local fresh
	sb.auth:restore({ access_token = "Y", refresh_token = "R", expires_at = os.time() + 3000 }, function(err, s) fresh = s end)
	assert(fresh.access_token == "Y" and #log == 1, "no refresh needed")
end)

test("HTTP errors become err tables", function()
	local sb = fake({ ["POST /rest/v1/rpc/boom"] = { 400, { message = "bad", code = "P0001", hint = "h" } } })
	local e
	sb.rpc:call("boom", nil, function(err, data) e = err; assert(data == nil) end)
	assert(e.status == 400 and e.message == "bad" and e.code == "P0001" and e.hint == "h")
	local sb2 = fake({ ["GET /rest/v1/x"] = { 0, nil } })
	sb2.db:from("x"):select():execute(function(err) e = err end)
	assert(e.status == 0 and e.message == "network error")
end)

test("upsert/update/delete/rpc request shapes", function()
	local sb, log = fake({
		["POST /rest/v1/profiles"] = { 201, { { id = "u1" } } },
		["PATCH /rest/v1/profiles"] = { 200, {} },
		["DELETE /rest/v1/todos"] = { 200, {} },
		["POST /rest/v1/rpc/do_thing"] = { 200, { pulled = 1 } },
	})
	sb.db:from("profiles"):upsert({ id = "u1", gold = 1 }, "id"):execute(function() end)
	assert(log[1].headers.Prefer:find("merge-duplicates", 1, true) and log[1].url:find("on_conflict=id", 1, true))
	sb.db:from("profiles"):update({ gold = 2 }):eq("id", "u1"):execute(function() end)
	assert(log[2].method == "PATCH" and log[2].body.gold == 2)
	sb.db:from("todos"):delete():eq("slot", 1):in_("user_id", { "a", "b" }):execute(function() end)
	assert(log[3].url:find("user_id=in.%28a%2Cb%29", 1, true))
	local result
	sb.rpc:call("do_thing", { p_count = 1 }, function(err, data) result = data end)
	assert(result.pulled == 1 and log[4].body.p_count == 1)
end)

test("custom schema: reads use Accept-Profile, writes/RPC use Content-Profile, auth has none", function()
	local log = {}
	local transport = function(url, method, headers, body, cb)
		log[#log + 1] = { url = url, method = method, headers = headers }
		cb(200, {}, {})
	end
	local pass = { encode = function(t) return t end, decode = function(s) return s end }
	local sb = supabase.new({ url = "https://t.supabase.co", anon_key = "A", schema = "my_app", transport = transport, codec = pass })
	sb.db:from("profiles"):select():execute(function() end)
	sb.db:from("profiles"):update({ settings = {} }):eq("id", "u"):execute(function() end)
	sb.rpc:call("do_thing", { p_count = 1 }, function() end)
	sb.auth:sign_in_anonymously(function() end)
	sb.db:from("shared"):in_schema("public"):select():execute(function() end)
	sb.rpc:call("ping", nil, function() end, "other_app")
	assert(log[1].headers["Accept-Profile"] == "my_app" and log[1].headers["Content-Profile"] == nil)
	assert(log[2].headers["Content-Profile"] == "my_app" and log[2].headers.Prefer)
	assert(log[3].headers["Content-Profile"] == "my_app")
	assert(log[4].headers["Content-Profile"] == nil and log[4].headers["Accept-Profile"] == nil, "auth untouched")
	assert(log[5].headers["Accept-Profile"] == "public")
	assert(log[6].headers["Content-Profile"] == "other_app")
end)

test("no profile headers without a schema (public default)", function()
	local h
	local sb = supabase.new({ url = "https://t.supabase.co", anon_key = "A",
		transport = function(u, m, headers, b, cb) h = headers; cb(200, {}, {}) end,
		codec = { encode = function(t) return t end, decode = function(s) return s end } })
	sb.rpc:call("x", {}, function() end)
	assert(h["Content-Profile"] == nil and h["Accept-Profile"] == nil)
end)

test("sign_up without tokens (email confirmation pending) does not replace the session", function()
	local sb = fake({ ["POST /auth/v1/signup"] = { 200, { id = "u2", email = "a@b.c", confirmation_sent_at = "now" } } })
	local changed, got = 0
	sb.auth:on_change(function() changed = changed + 1 end)
	sb.auth:sign_up("a@b.c", "pw", function(err, data) got = data end)
	assert(got.id == "u2" and changed == 0 and sb.auth:get_session() == nil)
end)

test("omitted options come from game.project [supabase]; explicit options win", function()
	local values = {
		["supabase.url"] = "https://cfg.supabase.co", ["supabase.anon_key"] = "CFGKEY", ["supabase.schema"] = "app",
		["supabase.persist_session"] = "0", ["supabase.auto_refresh_token"] = "0", ["supabase.flow_type"] = "pkce",
		["supabase.timeout"] = "30",
	}
	local saved = _G.sys
	_G.sys = { get_config_string = function(key, default) return values[key] or default end }
	local ok, err = pcall(function()
		local h, opts
		local transport = function(url, m, headers, b, cb, o) h, opts = { url = url, headers = headers }, o; cb(200, {}, {}) end
		local sb = supabase.new({ transport = transport, codec = { encode = function(t) return t end, decode = function(s) return s end } })
		assert(sb.url == "https://cfg.supabase.co" and sb.anon_key == "CFGKEY" and sb.auth.flow_type == "pkce")
		assert(sb.auth.auto_refresh == false and sb.auth.storage == nil)
		sb:from("t"):select():execute(function() end)
		assert(h.url:find("^https://cfg.supabase.co/rest/v1/t") and h.headers["Accept-Profile"] == "app" and opts.timeout == 30)
		local sb2 = supabase.new({ url = "https://x.supabase.co", schema = "other", transport = transport, codec = sb.codec })
		assert(sb2.url == "https://x.supabase.co" and sb2.anon_key == "CFGKEY" and sb2.db_schema == "other")
		values["supabase.url"] = ""
		assert(not pcall(supabase.new, { transport = transport }), "url is still required")
	end)
	_G.sys = saved
	assert(ok, err)
end)

test("Content-Type is only sent with a body", function()
	local sb, log = H.fake({ ["GET /rest/v1/t"] = { 200, {} }, ["POST /rest/v1/rpc/f"] = { 200, 1 } })
	sb:from("t"):select():execute()
	sb.rpc:call("f", { a = 1 }, function() end)
	assert(log[1].headers["Content-Type"] == nil and log[2].headers["Content-Type"] == "application/json")
end)
