-- Supabase Auth (GoTrue): sessions, password / anonymous / OTP / OAuth / SSO / ID token sign-in,
-- user management, identities, MFA and the admin API.
-- Auth state events: INITIAL_SESSION, SIGNED_IN, SIGNED_OUT, TOKEN_REFRESHED, USER_UPDATED,
--                    PASSWORD_RECOVERY, MFA_CHALLENGE_VERIFIED
local util = require("supabase.util")
local platform = require("supabase.platform")

local M = {}

local Auth = {}
Auth.__index = Auth

local Mfa = {}
Mfa.__index = Mfa

local Admin = {}
Admin.__index = Admin

local EXPIRY_MARGIN = 60

local function now()
	return os.time()
end

local function noop() end

function M.new(client, opts)
	opts = opts or {}
	local self = setmetatable({
		client = client,
		listeners = {},
		auto_refresh = opts.auto_refresh_token ~= false,
		flow_type = opts.flow_type or "implicit",
		storage = opts.storage,
		storage_key = opts.storage_key or ("sb-" .. (client.url:match("^https?://([^.:/]+)") or "supabase") .. "-auth-token"),
		refresh_waiters = nil, -- callbacks waiting for an in-flight refresh
	}, Auth)
	if opts.persist_session and not self.storage then
		self.storage = platform.storage()
	end
	self.mfa = setmetatable({ auth = self }, Mfa)
	self.admin = setmetatable({ auth = self }, Admin)
	return self
end

-- Events & session state ---------------------------------------------------------

--- Subscribe to auth events. fn(event, session|nil). Returns { unsubscribe = function }
function Auth:on_auth_state_change(fn)
	local entry = { fn = fn }
	self.listeners[#self.listeners + 1] = entry
	return {
		unsubscribe = function()
			for i, e in ipairs(self.listeners) do
				if e == entry then
					table.remove(self.listeners, i)
					return
				end
			end
		end,
	}
end

--- Simplified listener: fn(session|nil) on every change
function Auth:on_change(fn)
	return self:on_auth_state_change(function(_, session) fn(session) end)
end

function Auth:emit(event, session)
	local listeners = { unpack(self.listeners) }
	for _, e in ipairs(listeners) do
		e.fn(event, session)
	end
end

local function persistable(session)
	return {
		access_token = session.access_token,
		refresh_token = session.refresh_token,
		expires_at = session.expires_at,
		expires_in = session.expires_in,
		token_type = session.token_type,
		provider_token = session.provider_token,
		provider_refresh_token = session.provider_refresh_token,
		user = session.user,
	}
end

--- Replace the in-memory session (and persisted copy). Emits `event` (default SIGNED_IN / SIGNED_OUT)
function Auth:set_session(session, event)
	if session and session.expires_in and not session.expires_at then
		session.expires_at = now() + session.expires_in
	end
	self.client.session = session
	if self.storage then
		if session then
			self.storage.set(self.storage_key, persistable(session))
		else
			self.storage.remove(self.storage_key)
		end
	end
	if event ~= false then
		self:emit(event or (session and "SIGNED_IN" or "SIGNED_OUT"), session)
	end
end

function Auth:get_session()
	return self.client.session
end

--- True when the access token expires within 60 seconds
function Auth:needs_refresh()
	local s = self.client.session
	return s ~= nil and s.expires_at ~= nil and s.expires_at - EXPIRY_MARGIN <= now()
end

function Auth:should_refresh()
	local s = self.client.session
	return self.auto_refresh and s ~= nil and s.refresh_token ~= nil and self:needs_refresh()
end

--- Claims of the current access token (decoded locally, signature not verified)
function Auth:get_claims()
	local s = self.client.session
	return s and util.jwt_payload(s.access_token, self.client.codec.decode)
end

-- Requests -------------------------------------------------------------------------

local function auth_request(self, method, path, opts, callback)
	opts = opts or {}
	opts.skip_refresh = opts.skip_refresh or path:find("^/token") ~= nil or path:find("^/logout") ~= nil
	self.client:request(method, "/auth/v1" .. path, opts, callback)
end

--- Callback that stores the returned session (if it has tokens) and emits `event`
local function session_callback(self, callback, event)
	return function(err, data)
		if err then
			callback(err, nil)
			return
		end
		-- sign_up with email confirmation enabled returns a user without tokens: keep the current session
		if type(data) == "table" and data.access_token then
			self:set_session(data, event or "SIGNED_IN")
		end
		callback(nil, data)
	end
end

local function captcha(options)
	return options and options.captcha_token and { captcha_token = options.captcha_token } or nil
end

--- PKCE: create and store a code verifier, return challenge fields for the request body/query
function Auth:pkce_params()
	if self.flow_type ~= "pkce" then
		return {}
	end
	local verifier = util.random_string(56)
	self.code_verifier = verifier
	if self.storage then
		self.storage.set(self.storage_key .. "-code-verifier", verifier)
	end
	return { code_challenge = util.pkce_challenge(verifier), code_challenge_method = "s256" }
end

local function take_code_verifier(self)
	local verifier = self.code_verifier
	if not verifier and self.storage then
		verifier = self.storage.get(self.storage_key .. "-code-verifier")
	end
	self.code_verifier = nil
	if self.storage then
		self.storage.remove(self.storage_key .. "-code-verifier")
	end
	return verifier
end

local function redirect_query(redirect_to)
	return redirect_to and { redirect_to = redirect_to } or nil
end

-- Sign up / sign in ----------------------------------------------------------------

--- Anonymous sign-in (requires Anonymous Sign-Ins in the dashboard).
-- sign_in_anonymously(callback, metadata?) or sign_in_anonymously({ options = { data, captcha_token } }, callback)
function Auth:sign_in_anonymously(a, b)
	local params, callback
	if type(a) == "function" then
		callback, params = a, { options = { data = b } }
	else
		params, callback = a or {}, b or noop
	end
	local options = params.options or {}
	auth_request(self, "POST", "/signup", {
		body = { data = options.data or {}, gotrue_meta_security = captcha(options) },
	}, session_callback(self, callback))
end

--- sign_up(email, password, callback) or
-- sign_up({ email | phone, password, options = { data, email_redirect_to, captcha_token, channel } }, callback)
-- With email confirmation on, data is the user and no session is stored until confirmation.
function Auth:sign_up(a, b, c)
	local params, callback
	if type(a) == "string" then
		params, callback = { email = a, password = b }, c or noop
	else
		params, callback = a, b or noop
	end
	local options = params.options or {}
	local body = util.merge({
		email = params.email,
		phone = params.phone,
		password = params.password,
		data = options.data or {},
		channel = params.phone and (options.channel or "sms") or nil,
		gotrue_meta_security = captcha(options),
	}, params.email and self:pkce_params() or nil)
	auth_request(self, "POST", "/signup", { body = body, query = redirect_query(options.email_redirect_to) },
		session_callback(self, callback))
end

--- sign_in_with_password(email, password, callback) or
-- sign_in_with_password({ email | phone, password, options = { captcha_token } }, callback)
function Auth:sign_in_with_password(a, b, c)
	local params, callback
	if type(a) == "string" then
		params, callback = { email = a, password = b }, c or noop
	else
		params, callback = a, b or noop
	end
	auth_request(self, "POST", "/token", {
		query = { { "grant_type", "password" } },
		body = {
			email = params.email,
			phone = params.phone,
			password = params.password,
			gotrue_meta_security = captcha(params.options),
		},
	}, session_callback(self, callback))
end

--- Magic link / OTP. params: { email | phone, options = { email_redirect_to, should_create_user, data, captcha_token, channel } }
function Auth:sign_in_with_otp(params, callback)
	local options = params.options or {}
	local body = util.merge({
		email = params.email,
		phone = params.phone,
		data = options.data or {},
		create_user = options.should_create_user ~= false,
		channel = params.phone and (options.channel or "sms") or nil,
		gotrue_meta_security = captcha(options),
	}, params.email and self:pkce_params() or nil)
	auth_request(self, "POST", "/otp", { body = body, query = redirect_query(options.email_redirect_to) }, callback or noop)
end

--- Verify an OTP / token hash. params: { email | phone, token, type } or { token_hash, type }, options = { redirect_to, captcha_token }
-- type: "sms" | "phone_change" | "signup" | "invite" | "magiclink" | "recovery" | "email_change" | "email"
function Auth:verify_otp(params, callback)
	local options = params.options or {}
	auth_request(self, "POST", "/verify", {
		body = {
			email = params.email,
			phone = params.phone,
			token = params.token,
			token_hash = params.token_hash,
			type = params.type,
			gotrue_meta_security = captcha(options),
		},
		query = redirect_query(options.redirect_to),
	}, session_callback(self, callback or noop, params.type == "recovery" and "PASSWORD_RECOVERY" or "SIGNED_IN"))
end

--- Resend a confirmation / OTP. params: { type = "signup" | "email_change" | "sms" | "phone_change", email | phone, options }
function Auth:resend(params, callback)
	local options = params.options or {}
	auth_request(self, "POST", "/resend", {
		body = {
			type = params.type,
			email = params.email,
			phone = params.phone,
			gotrue_meta_security = captcha(options),
		},
		query = redirect_query(options.email_redirect_to),
	}, callback or noop)
end

--- Native ID token sign-in. params: { provider = "apple" | "google" | ..., token, access_token?, nonce?, options = { captcha_token } }
function Auth:sign_in_with_id_token(params, callback)
	auth_request(self, "POST", "/token", {
		query = { { "grant_type", "id_token" } },
		body = {
			provider = params.provider,
			id_token = params.token,
			access_token = params.access_token,
			nonce = params.nonce,
			gotrue_meta_security = captcha(params.options),
		},
	}, session_callback(self, callback or noop))
end

--- OAuth sign-in URL. params: { provider, options = { redirect_to, scopes, query_params, skip_browser_redirect } }
-- Opens the URL with sys.open_url unless skip_browser_redirect. Returns the URL and calls callback(nil, { provider, url }).
-- Finish the flow with get_session_from_url(redirect_url) when the app receives the redirect.
function Auth:sign_in_with_oauth(params, callback)
	local options = params.options or {}
	local query = { { "provider", params.provider } }
	if options.redirect_to then query[#query + 1] = { "redirect_to", options.redirect_to } end
	if options.scopes then query[#query + 1] = { "scopes", options.scopes } end
	local pkce = self:pkce_params()
	if pkce.code_challenge then
		query[#query + 1] = { "code_challenge", pkce.code_challenge }
		query[#query + 1] = { "code_challenge_method", pkce.code_challenge_method }
	end
	local extra = {}
	for k, v in pairs(options.query_params or {}) do
		extra[#extra + 1] = { k, v }
	end
	table.sort(extra, function(x, y) return x[1] < y[1] end)
	for _, kv in ipairs(extra) do
		query[#query + 1] = kv
	end
	local url = self.client.url .. "/auth/v1/authorize?" .. util.build_query(query)
	if not options.skip_browser_redirect then
		self.client.open_url(url)
	end
	if callback then
		callback(nil, { provider = params.provider, url = url })
	end
	return url
end

--- Enterprise SSO (SAML). params: { domain | provider_id, options = { redirect_to, captcha_token, skip_browser_redirect } }
function Auth:sign_in_with_sso(params, callback)
	local options = params.options or {}
	callback = callback or noop
	auth_request(self, "POST", "/sso", {
		body = util.merge({
			domain = params.domain,
			provider_id = params.provider_id,
			redirect_to = options.redirect_to,
			skip_http_redirect = true,
			gotrue_meta_security = captcha(options),
		}, self:pkce_params()),
	}, function(err, data)
		if not err and data and data.url and not options.skip_browser_redirect then
			self.client.open_url(data.url)
		end
		callback(err, data)
	end)
end

--- PKCE: exchange the ?code= from a redirect for a session
function Auth:exchange_code_for_session(auth_code, callback)
	callback = callback or noop
	local verifier = take_code_verifier(self)
	auth_request(self, "POST", "/token", {
		query = { { "grant_type", "pkce" } },
		body = { auth_code = auth_code, code_verifier = verifier },
	}, function(err, data)
		if err then
			return callback(err, nil)
		end
		local event = data and data.redirect_type == "recovery" and "PASSWORD_RECOVERY" or "SIGNED_IN"
		session_callback(self, callback, event)(nil, data)
	end)
end

--- Finish an OAuth / magic link / recovery redirect: parses `#access_token=...` (implicit) or `?code=...` (PKCE)
-- from the URL the app was opened with, stores the session and calls callback(err, session).
function Auth:get_session_from_url(url, callback)
	callback = callback or noop
	local query = util.parse_query(url:match("%?([^#]*)"))
	local fragment = util.parse_query(url:match("#(.*)$"))
	local params = util.merge(query, fragment)
	if params.error or params.error_description then
		return callback({ status = 0, message = params.error_description or params.error, code = params.error_code or params.error }, nil)
	end
	if params.code then
		return self:exchange_code_for_session(params.code, callback)
	end
	if not params.access_token then
		return callback({ status = 0, message = "no session in url" }, nil)
	end
	local session = {
		access_token = params.access_token,
		refresh_token = params.refresh_token,
		token_type = params.token_type,
		expires_in = tonumber(params.expires_in),
		expires_at = tonumber(params.expires_at),
		provider_token = params.provider_token,
		provider_refresh_token = params.provider_refresh_token,
	}
	self.client.session = session
	self:get_user(function(err, user)
		if err then
			self.client.session = nil
			return callback(err, nil)
		end
		session.user = user
		self:set_session(session, params.type == "recovery" and "PASSWORD_RECOVERY" or "SIGNED_IN")
		callback(nil, session)
	end)
end

-- Session lifecycle ----------------------------------------------------------------

--- Refresh the session. refresh_session(callback, refresh_token?). Concurrent calls share one request.
-- A rejected refresh token (4xx) clears the session and emits SIGNED_OUT.
function Auth:refresh_session(callback, refresh_token)
	callback = callback or noop
	refresh_token = refresh_token or (self.client.session and self.client.session.refresh_token)
	if not refresh_token then
		callback({ status = 0, message = "no refresh token" }, nil)
		return
	end
	if self.refresh_waiters then
		self.refresh_waiters[#self.refresh_waiters + 1] = callback
		return
	end
	self.refresh_waiters = { callback }
	auth_request(self, "POST", "/token", {
		query = { { "grant_type", "refresh_token" } },
		body = { refresh_token = refresh_token },
	}, function(err, data)
		local waiters = self.refresh_waiters
		self.refresh_waiters = nil
		if err then
			if err.status >= 400 and err.status < 500 and self.client.session then
				self:set_session(nil, "SIGNED_OUT")
			end
		elseif type(data) == "table" and data.access_token then
			self:set_session(data, "TOKEN_REFRESHED")
		end
		for _, cb in ipairs(waiters) do
			cb(err, err and nil or data)
		end
	end)
end

--- Use a saved session (like supabase-js setSession): refreshes it first if it is about to expire.
-- event: emitted on success (default SIGNED_IN; TOKEN_REFRESHED when a refresh happened)
function Auth:restore(session, callback, event)
	callback = callback or noop
	self.client.session = session
	if self:needs_refresh() then
		self:refresh_session(callback)
	else
		self:set_session(session, event or "SIGNED_IN")
		callback(nil, session)
	end
end

--- Load the persisted session (persist_session / storage), refresh it if needed and emit INITIAL_SESSION.
-- callback(err, session|nil)
function Auth:initialize(callback)
	callback = callback or noop
	local saved = self.storage and self.storage.get(self.storage_key)
	if type(saved) ~= "table" or not saved.access_token then
		self:emit("INITIAL_SESSION", nil)
		return callback(nil, nil)
	end
	self.client.session = saved
	if self:needs_refresh() then
		self:refresh_session(function(err, session)
			self:emit("INITIAL_SESSION", self.client.session)
			callback(err, session)
		end)
	else
		self:emit("INITIAL_SESSION", saved)
		callback(nil, saved)
	end
end

--- Refresh periodically while the app runs (needs a script context for timers). interval: seconds (default 10)
function Auth:start_auto_refresh(interval)
	self:stop_auto_refresh()
	self.refresh_timer = self.client.timer.delay(interval or 10, true, function()
		if self:should_refresh() then
			self:refresh_session()
		end
	end)
end

function Auth:stop_auto_refresh()
	if self.refresh_timer then
		self.client.timer.cancel(self.refresh_timer)
		self.refresh_timer = nil
	end
end

--- sign_out(callback?) or sign_out({ scope = "local" | "global" | "others" }, callback?)
-- "global" (server default) ends every session of the user, "local" only this one, "others" all but this one.
function Auth:sign_out(a, b)
	local opts, callback = util.opts_cb(a, b)
	local scope = opts.scope or "global"
	local function finish(err)
		if scope ~= "others" then
			self:set_session(nil, "SIGNED_OUT")
		end
		callback(err)
	end
	if not self.client.session then
		return finish(nil)
	end
	auth_request(self, "POST", "/logout", { query = { { "scope", scope } } }, function(err)
		-- 401/403/404: the session is already gone on the server
		if err and (err.status == 401 or err.status == 403 or err.status == 404) then
			err = nil
		end
		finish(err)
	end)
end

-- User -----------------------------------------------------------------------------

--- get_user(callback) or get_user(jwt, callback): fetch the user from the server
function Auth:get_user(a, b)
	local jwt, callback = a, b
	if type(a) == "function" then
		jwt, callback = nil, a
	end
	auth_request(self, "GET", "/user", {
		headers = jwt and { Authorization = "Bearer " .. jwt } or nil,
	}, callback or noop)
end

--- Update the current user (PUT /auth/v1/user). attrs: { email?, phone?, password?, nonce?, data? }
-- update_user(attrs, callback) or update_user(attrs, { email_redirect_to }, callback). Emits USER_UPDATED.
-- Anonymous -> permanent account: update_user({ email }) -> confirm email -> update_user({ password })
-- With email confirmation on, the pending address is in user.new_email.
function Auth:update_user(attrs, a, b)
	local opts, callback = util.opts_cb(a, b)
	local body = util.merge(attrs, attrs.email and self:pkce_params() or nil)
	auth_request(self, "PUT", "/user", {
		body = body,
		query = redirect_query(opts.email_redirect_to),
	}, function(err, user)
		if not err and type(user) == "table" and self.client.session then
			self.client.session.user = user
			self:set_session(self.client.session, "USER_UPDATED")
		end
		callback(err, user)
	end)
end

--- Send a nonce for update_user({ password, nonce }) when "Secure password change" is enabled
function Auth:reauthenticate(callback)
	auth_request(self, "GET", "/reauthenticate", nil, callback or noop)
end

--- Password recovery mail. options: { redirect_to, captcha_token }
-- The link signs the user in with a PASSWORD_RECOVERY event; then call update_user({ password }).
function Auth:reset_password_for_email(email, a, b)
	local opts, callback = util.opts_cb(a, b)
	auth_request(self, "POST", "/recover", {
		body = util.merge({ email = email, gotrue_meta_security = captcha(opts) }, self:pkce_params()),
		query = redirect_query(opts.redirect_to),
	}, callback)
end

--- callback(err, { identities = {...} })
function Auth:get_user_identities(callback)
	self:get_user(function(err, user)
		callback(err, not err and { identities = user and user.identities or {} } or nil)
	end)
end

--- Link an OAuth identity to the signed-in user. params: { provider, options = { redirect_to, scopes, query_params, skip_browser_redirect } }
function Auth:link_identity(params, callback)
	local options = params.options or {}
	callback = callback or noop
	local query = { { "provider", params.provider }, { "skip_http_redirect", "true" } }
	if options.redirect_to then query[#query + 1] = { "redirect_to", options.redirect_to } end
	if options.scopes then query[#query + 1] = { "scopes", options.scopes } end
	local pkce = self:pkce_params()
	if pkce.code_challenge then
		query[#query + 1] = { "code_challenge", pkce.code_challenge }
		query[#query + 1] = { "code_challenge_method", pkce.code_challenge_method }
	end
	for k, v in pairs(options.query_params or {}) do
		query[#query + 1] = { k, v }
	end
	auth_request(self, "GET", "/user/identities/authorize", { query = query }, function(err, data)
		if not err and data and data.url and not options.skip_browser_redirect then
			self.client.open_url(data.url)
		end
		callback(err, data)
	end)
end

--- identity: an entry of user.identities (needs identity_id)
function Auth:unlink_identity(identity, callback)
	auth_request(self, "DELETE", "/user/identities/" .. util.urlencode(identity.identity_id), nil, callback or noop)
end

-- MFA ------------------------------------------------------------------------------

--- params: { factor_type = "totp" | "phone", friendly_name?, issuer?, phone? }
-- TOTP result has totp.qr_code (SVG data URI), totp.secret and totp.uri
function Mfa:enroll(params, callback)
	auth_request(self.auth, "POST", "/factors", { body = params }, callback or noop)
end

--- params: { factor_id, channel? = "sms" | "whatsapp" }
function Mfa:challenge(params, callback)
	auth_request(self.auth, "POST", "/factors/" .. util.urlencode(params.factor_id) .. "/challenge", {
		body = { channel = params.channel },
	}, callback or noop)
end

--- params: { factor_id, challenge_id, code }. Upgrades the session to aal2 and emits MFA_CHALLENGE_VERIFIED
function Mfa:verify(params, callback)
	auth_request(self.auth, "POST", "/factors/" .. util.urlencode(params.factor_id) .. "/verify", {
		body = { challenge_id = params.challenge_id, code = params.code },
	}, session_callback(self.auth, callback or noop, "MFA_CHALLENGE_VERIFIED"))
end

--- params: { factor_id, code }
function Mfa:challenge_and_verify(params, callback)
	callback = callback or noop
	self:challenge({ factor_id = params.factor_id }, function(err, challenge)
		if err then
			return callback(err, nil)
		end
		self:verify({ factor_id = params.factor_id, challenge_id = challenge.id, code = params.code }, callback)
	end)
end

--- params: { factor_id }
function Mfa:unenroll(params, callback)
	auth_request(self.auth, "DELETE", "/factors/" .. util.urlencode(params.factor_id), nil, callback or noop)
end

--- callback(err, { all, totp, phone }) where totp / phone contain verified factors only
function Mfa:list_factors(callback)
	self.auth:get_user(function(err, user)
		if err then
			return callback(err, nil)
		end
		local result = { all = user.factors or {}, totp = {}, phone = {} }
		for _, f in ipairs(result.all) do
			if f.status == "verified" and result[f.factor_type] then
				table.insert(result[f.factor_type], f)
			end
		end
		callback(nil, result)
	end)
end

--- Synchronous: { current_level = "aal1" | "aal2" | nil, next_level, current_authentication_methods }
function Mfa:get_authenticator_assurance_level()
	local claims = self.auth:get_claims()
	local session = self.auth:get_session()
	local next_level = claims and claims.aal or nil
	local factors = session and session.user and session.user.factors or {}
	for _, f in ipairs(factors) do
		if f.status == "verified" then
			next_level = "aal2"
			break
		end
	end
	return {
		current_level = claims and claims.aal or nil,
		next_level = next_level,
		current_authentication_methods = claims and claims.amr or {},
	}
end

-- Admin (requires the service_role / secret key as the client's key: server-side tools only) -----------

local function admin_request(self, method, path, opts, callback)
	opts = opts or {}
	opts.headers = util.merge(opts.headers, { Authorization = "Bearer " .. self.auth.client.anon_key })
	opts.skip_refresh = true
	self.auth.client:request(method, "/auth/v1/admin" .. path, opts, callback or noop)
end

--- params: { page?, per_page? }. callback(err, { users, aud })
function Admin:list_users(a, b)
	local params, callback = util.opts_cb(a, b)
	local query = {}
	if params.page then query[#query + 1] = { "page", params.page } end
	if params.per_page then query[#query + 1] = { "per_page", params.per_page } end
	admin_request(self, "GET", "/users", { query = query }, callback)
end

--- attrs: { email, phone, password, email_confirm, phone_confirm, user_metadata, app_metadata, ban_duration, ... }
function Admin:create_user(attrs, callback)
	admin_request(self, "POST", "/users", { body = attrs }, callback)
end

function Admin:get_user_by_id(id, callback)
	admin_request(self, "GET", "/users/" .. util.urlencode(id), nil, callback)
end

function Admin:update_user_by_id(id, attrs, callback)
	admin_request(self, "PUT", "/users/" .. util.urlencode(id), { body = attrs }, callback)
end

function Admin:delete_user(id, should_soft_delete, callback)
	if type(should_soft_delete) == "function" then
		should_soft_delete, callback = false, should_soft_delete
	end
	-- note: Defold's native HTTP client drops DELETE bodies, so soft delete only works on HTML5
	admin_request(self, "DELETE", "/users/" .. util.urlencode(id), {
		body = should_soft_delete and { should_soft_delete = true } or nil,
	}, callback)
end

--- options: { data, redirect_to }
function Admin:invite_user_by_email(email, a, b)
	local opts, callback = util.opts_cb(a, b)
	self.auth.client:request("POST", "/auth/v1/invite", {
		body = { email = email, data = opts.data },
		query = redirect_query(opts.redirect_to),
		headers = { Authorization = "Bearer " .. self.auth.client.anon_key },
		skip_refresh = true,
	}, callback)
end

--- params: { type = "signup" | "invite" | "magiclink" | "recovery" | "email_change_current" | "email_change_new",
--            email, password?, new_email?, options = { data, redirect_to } }
function Admin:generate_link(params, callback)
	local options = params.options or {}
	admin_request(self, "POST", "/generate_link", {
		body = {
			type = params.type,
			email = params.email,
			password = params.password,
			new_email = params.new_email,
			data = options.data,
			redirect_to = options.redirect_to,
		},
	}, callback)
end

--- End sessions of the user that owns `jwt`. scope: "global" (default) | "local" | "others"
function Admin:sign_out(jwt, scope, callback)
	if type(scope) == "function" then
		scope, callback = nil, scope
	end
	self.auth.client:request("POST", "/auth/v1/logout", {
		query = { { "scope", scope or "global" } },
		headers = { Authorization = "Bearer " .. jwt },
		skip_refresh = true,
	}, callback or noop)
end

--- params: { user_id }
function Admin:list_factors(params, callback)
	admin_request(self, "GET", "/users/" .. util.urlencode(params.user_id) .. "/factors", nil, callback)
end

--- params: { user_id, id }
function Admin:delete_factor(params, callback)
	admin_request(self, "DELETE", "/users/" .. util.urlencode(params.user_id) .. "/factors/" .. util.urlencode(params.id), nil, callback)
end

return M
