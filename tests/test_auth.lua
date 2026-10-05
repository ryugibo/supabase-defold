local H = require("tests.helpers")
local util = require("supabase.util")

local function session(token, extra)
	local s = { access_token = token or "AT", refresh_token = "RT", expires_in = 3600, user = { id = "u1" } }
	for k, v in pairs(extra or {}) do
		s[k] = v
	end
	return s
end

local function events_of(sb)
	local events = {}
	sb.auth:on_auth_state_change(function(event) events[#events + 1] = event end)
	return events
end

test("password sign-in with table params, phone sign-up and captcha", function()
	local sb, log = H.fake({
		["POST /auth/v1/token"] = { 200, session() },
		["POST /auth/v1/signup"] = { 200, { id = "u2", phone = "123" } },
	})
	local events = events_of(sb)
	sb.auth:sign_in_with_password({ phone = "123", password = "pw", options = { captcha_token = "cap" } })
	assert(log[1].query.grant_type == "password" and log[1].body.phone == "123")
	assert(log[1].body.gotrue_meta_security.captcha_token == "cap" and events[1] == "SIGNED_IN")
	sb.auth:sign_up({ phone = "123", password = "pw", options = { data = { name = "n" } } })
	assert(log[2].body.channel == "sms" and log[2].body.data.name == "n" and sb.auth:get_session().access_token == "AT")
end)

test("OTP, verify (recovery event), resend, reset password, reauthenticate", function()
	local sb, log = H.fake({
		["POST /auth/v1/otp"] = { 200, {} },
		["POST /auth/v1/verify"] = { 200, session("REC") },
		["POST /auth/v1/resend"] = { 200, {} },
		["POST /auth/v1/recover"] = { 200, {} },
		["GET /auth/v1/reauthenticate"] = { 200, {} },
	})
	local events = events_of(sb)
	sb.auth:sign_in_with_otp({ email = "a@b.c", options = { should_create_user = false, email_redirect_to = "app://cb" } })
	assert(log[1].body.email == "a@b.c" and log[1].body.create_user == false and log[1].query.redirect_to == "app://cb")
	assert(log[1].body.code_challenge == nil, "implicit flow sends no PKCE challenge")
	sb.auth:verify_otp({ email = "a@b.c", token = "123456", type = "recovery" })
	assert(log[2].body.token == "123456" and events[1] == "PASSWORD_RECOVERY" and sb.auth:get_session().access_token == "REC")
	sb.auth:resend({ type = "signup", email = "a@b.c" })
	assert(log[3].body.type == "signup")
	sb.auth:reset_password_for_email("a@b.c", { redirect_to = "app://reset" })
	assert(log[4].body.email == "a@b.c" and log[4].query.redirect_to == "app://reset")
	sb.auth:reauthenticate()
	assert(log[5].method == "GET" and log[5].headers.Authorization == "Bearer REC")
end)

test("OAuth with PKCE builds the URL and exchanges the code with the stored verifier", function()
	local opened
	local storage = require("supabase.client").memory_storage()
	local sb, log = H.fake({ ["POST /auth/v1/token"] = { 200, session("PKCE") } },
		{ flow_type = "pkce", storage = storage, open_url = function(u) opened = u end })
	local url = sb.auth:sign_in_with_oauth({ provider = "github", options = { redirect_to = "app://cb", scopes = "repo", query_params = { prompt = "consent" } } })
	assert(opened == url and url:find("^https://test.supabase.co/auth/v1/authorize%?provider=github&redirect_to=app%%3A%%2F%%2Fcb&scopes=repo&code_challenge="))
	assert(url:find("code_challenge_method=s256&prompt=consent", 1, true))
	local challenge = util.parse_query(url:match("%?(.*)$")).code_challenge
	local verifier = storage.get(sb.auth.storage_key .. "-code-verifier")
	assert(util.pkce_challenge(verifier) == challenge)
	sb.auth.code_verifier = nil -- simulate an app restart: the verifier comes from storage
	local got
	sb.auth:get_session_from_url("app://cb?code=CODE", function(err, s) got = s end)
	assert(log[1].query.grant_type == "pkce" and log[1].body.auth_code == "CODE" and log[1].body.code_verifier == verifier)
	assert(got.access_token == "PKCE" and storage.get(sb.auth.storage_key .. "-code-verifier") == nil)
end)

test("implicit redirect fragment becomes a session", function()
	local sb, log = H.fake({ ["GET /auth/v1/user"] = { 200, { id = "u9" } } })
	local events = events_of(sb)
	local got
	sb.auth:get_session_from_url("app://cb#access_token=A1&refresh_token=R1&expires_in=3600&token_type=bearer&type=recovery",
		function(err, s) got = s end)
	assert(got.access_token == "A1" and got.user.id == "u9" and got.expires_at and events[1] == "PASSWORD_RECOVERY")
	assert(log[1].headers.Authorization == "Bearer A1")
	local err
	sb.auth:get_session_from_url("app://cb#error=access_denied&error_description=Denied", function(e) err = e end)
	assert(err.message == "Denied" and err.code == "access_denied")
end)

test("SSO, ID token, identities", function()
	local opened
	local sb, log = H.fake({
		["POST /auth/v1/sso"] = { 200, { url = "https://idp/login" } },
		["POST /auth/v1/token"] = { 200, session("IDT") },
		["GET /auth/v1/user/identities/authorize"] = { 200, { url = "https://github/link" } },
		["GET /auth/v1/user"] = { 200, { id = "u1", identities = { { identity_id = "i1" } } } },
		["DELETE /auth/v1/user/identities/i1"] = { 200, {} },
	}, { open_url = function(u) opened = u end })
	sb.auth:sign_in_with_sso({ domain = "corp.com" })
	assert(log[1].body.domain == "corp.com" and log[1].body.skip_http_redirect == true and opened == "https://idp/login")
	sb.auth:sign_in_with_id_token({ provider = "apple", token = "ID", nonce = "n" })
	assert(log[2].query.grant_type == "id_token" and log[2].body.id_token == "ID" and sb.auth:get_session().access_token == "IDT")
	sb.auth:link_identity({ provider = "github" })
	assert(log[3].query.skip_http_redirect == "true" and opened == "https://github/link")
	local identities
	sb.auth:get_user_identities(function(err, data) identities = data.identities end)
	sb.auth:unlink_identity(identities[1])
	assert(log[5].method == "DELETE")
end)

test("expired session is refreshed once before concurrent requests", function()
	local pending
	local sb, log = H.fake({
		["POST /auth/v1/token"] = function() return { 200, session("NEW") } end,
		["GET /rest/v1/t"] = { 200, {} },
	})
	-- hold the refresh response so both requests queue behind it
	local transport = sb.transport
	sb.transport = function(url, method, headers, body, cb)
		if url:find("/token", 1, true) then
			pending = function() transport(url, method, headers, body, cb) end
		else
			transport(url, method, headers, body, cb)
		end
	end
	local events = events_of(sb)
	sb.session = { access_token = "OLD", refresh_token = "RT", expires_at = os.time() - 5 }
	local done = 0
	sb:from("t"):select():execute(function() done = done + 1 end)
	sb:from("t"):select():execute(function() done = done + 1 end)
	assert(done == 0 and pending)
	pending()
	assert(done == 2 and events[1] == "TOKEN_REFRESHED")
	local refreshes, gets = 0, 0
	for _, e in ipairs(log) do
		if e.path == "/auth/v1/token" then refreshes = refreshes + 1 end
		if e.path == "/rest/v1/t" then
			gets = gets + 1
			assert(e.headers.Authorization == "Bearer NEW")
		end
	end
	assert(refreshes == 1 and gets == 2)
end)

test("rejected refresh token signs out; auto refresh can be disabled", function()
	local sb = H.fake({ ["POST /auth/v1/token"] = { 400, { error = "invalid_grant", error_description = "Invalid Refresh Token" } } })
	local events = events_of(sb)
	sb.session = { access_token = "OLD", refresh_token = "BAD", expires_at = os.time() - 5 }
	local err
	sb.auth:refresh_session(function(e) err = e end)
	assert(err.message == "Invalid Refresh Token" and err.code == "invalid_grant")
	assert(sb.auth:get_session() == nil and events[1] == "SIGNED_OUT")

	local sb2, log2 = H.fake({ ["GET /rest/v1/t"] = { 200, {} } }, { auto_refresh_token = false })
	sb2.session = { access_token = "OLD", refresh_token = "RT", expires_at = os.time() - 5 }
	sb2:from("t"):select():execute()
	assert(#log2 == 1 and log2[1].headers.Authorization == "Bearer OLD")
end)

test("persisted session: initialize restores, sign-out removes", function()
	local storage = require("supabase.client").memory_storage()
	local sb = H.fake({ ["POST /auth/v1/signup"] = { 200, session("S1") }, ["POST /auth/v1/logout"] = { 204, nil } },
		{ storage = storage })
	sb.auth:sign_in_anonymously(function() end)
	assert(storage.get(sb.auth.storage_key).access_token == "S1")

	local sb2 = H.fake({}, { storage = storage })
	local events = events_of(sb2)
	local got
	sb2.auth:initialize(function(err, s) got = s end)
	assert(got.access_token == "S1" and sb2:user_id() == "u1" and events[1] == "INITIAL_SESSION")
	sb2.auth:sign_out({ scope = "local" })
	assert(storage.get(sb2.auth.storage_key) == nil and events[2] == "SIGNED_OUT")

	local sb3 = H.fake({}, { storage = storage })
	local none = "unset"
	sb3.auth:initialize(function(err, s) none = s end)
	assert(none == nil)
end)

test("sign_out scopes and listener unsubscribe", function()
	local sb, log = H.fake({ ["POST /auth/v1/logout"] = { 204, nil } })
	local count = 0
	local sub = sb.auth:on_auth_state_change(function() count = count + 1 end)
	sb.auth:set_session(session())
	sb.auth:sign_out({ scope = "others" })
	assert(log[1].query.scope == "others" and sb.auth:get_session() ~= nil)
	sub.unsubscribe()
	sb.auth:sign_out()
	assert(log[2].query.scope == "global" and sb.auth:get_session() == nil and count == 1)
end)

test("update_user emits USER_UPDATED and keeps the session user in sync", function()
	local sb, log = H.fake({ ["PUT /auth/v1/user"] = { 200, { id = "u1", email = "new@x.y" } } })
	local events = events_of(sb)
	sb.auth:set_session(session(), false)
	local got
	sb.auth:update_user({ email = "new@x.y" }, { email_redirect_to = "app://e" }, function(err, user) got = user end)
	assert(got.email == "new@x.y" and sb.auth:get_session().user.email == "new@x.y" and events[1] == "USER_UPDATED")
	assert(log[1].query.redirect_to == "app://e")
	sb.auth:update_user({ data = { a = 1 } }, function(err, user) got = user end)
	assert(log[2].body.data.a == 1)
end)

test("MFA enroll, challenge_and_verify, list factors and assurance level", function()
	local aal2 = H.jwt({ aal = "aal2", amr = { { method = "totp" } } })
	local sb, log = H.fake({
		["POST /auth/v1/factors"] = { 200, { id = "f1", type = "totp", totp = { qr_code = "data:", secret = "S" } } },
		["POST /auth/v1/factors/f1/challenge"] = { 200, { id = "c1" } },
		["POST /auth/v1/factors/f1/verify"] = { 200, session(aal2, { user = { id = "u1", factors = { { id = "f1", factor_type = "totp", status = "verified" } } } }) },
		["GET /auth/v1/user"] = { 200, { id = "u1", factors = { { id = "f1", factor_type = "totp", status = "verified" }, { id = "f2", factor_type = "phone", status = "unverified" } } } },
		["DELETE /auth/v1/factors/f1"] = { 200, {} },
	})
	sb.auth:set_session(session(H.jwt({ aal = "aal1", amr = { { method = "password" } } })), false)
	assert(sb.auth.mfa:get_authenticator_assurance_level().current_level == "aal1")
	local events = events_of(sb)
	local enrolled
	sb.auth.mfa:enroll({ factor_type = "totp", friendly_name = "phone" }, function(err, f) enrolled = f end)
	assert(enrolled.totp.secret == "S" and log[1].body.factor_type == "totp")
	sb.auth.mfa:challenge_and_verify({ factor_id = "f1", code = "123456" }, function() end)
	assert(log[3].body.challenge_id == "c1" and log[3].body.code == "123456" and events[1] == "MFA_CHALLENGE_VERIFIED")
	local level = sb.auth.mfa:get_authenticator_assurance_level()
	assert(level.current_level == "aal2" and level.next_level == "aal2" and level.current_authentication_methods[1].method == "totp")
	local factors
	sb.auth.mfa:list_factors(function(err, f) factors = f end)
	assert(#factors.all == 2 and #factors.totp == 1 and #factors.phone == 0)
	sb.auth.mfa:unenroll({ factor_id = "f1" })
	assert(log[5].method == "DELETE")
end)

test("admin API always uses the client key", function()
	local sb, log = H.fake({
		["GET /auth/v1/admin/users"] = { 200, { users = {} } },
		["POST /auth/v1/admin/users"] = { 200, { id = "n1" } },
		["DELETE /auth/v1/admin/users/n1"] = { 200, {} },
		["POST /auth/v1/invite"] = { 200, {} },
		["POST /auth/v1/admin/generate_link"] = { 200, { action_link = "x" } },
	}, { anon_key = "SERVICE" })
	sb.auth:set_session(session(), false)
	sb.auth.admin:list_users({ page = 2, per_page = 50 })
	assert(log[1].headers.Authorization == "Bearer SERVICE" and log[1].query.page == "2")
	sb.auth.admin:create_user({ email = "a@b.c", email_confirm = true })
	sb.auth.admin:delete_user("n1", true)
	assert(log[3].body.should_soft_delete == true)
	sb.auth.admin:delete_user("n1")
	assert(log[4].body == nil)
	sb.auth.admin:invite_user_by_email("a@b.c", { redirect_to = "app://i" })
	assert(log[5].query.redirect_to == "app://i" and log[5].headers.Authorization == "Bearer SERVICE")
	sb.auth.admin:generate_link({ type = "magiclink", email = "a@b.c" })
	assert(log[6].body.type == "magiclink")
end)

test("auto refresh timer refreshes an expiring session", function()
	local sb, log = H.fake({ ["POST /auth/v1/token"] = { 200, session("T2") } })
	sb.session = { access_token = "T1", refresh_token = "RT", expires_at = os.time() + 30 }
	sb.auth:start_auto_refresh(5)
	sb.timer.fire(5)
	assert(#log == 1 and sb.auth:get_session().access_token == "T2")
	sb.auth:stop_auto_refresh()
	assert(next(sb.timer.pending) == nil)
end)
