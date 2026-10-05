-- Supabase Auth (GoTrue) wrapper: anonymous/email sign-in, session refresh, sign-out
local M = {}

local Auth = {}
Auth.__index = Auth

function M.new(client)
	return setmetatable({ client = client, listeners = {} }, Auth)
end

--- Session change listener (e.g. to persist the session). fn(session|nil)
function Auth:on_change(fn)
	self.listeners[#self.listeners + 1] = fn
end

local function now()
	return os.time()
end

function Auth:set_session(session)
	if session and session.expires_in and not session.expires_at then
		session.expires_at = now() + session.expires_in
	end
	self.client.session = session
	for _, fn in ipairs(self.listeners) do
		fn(session)
	end
end

function Auth:get_session()
	return self.client.session
end

--- True when the access token expires within 60 seconds
function Auth:needs_refresh()
	local s = self.client.session
	return s ~= nil and s.expires_at ~= nil and s.expires_at - 60 <= now()
end

local function session_callback(self, callback)
	return function(err, data)
		if err then
			callback(err, nil)
			return
		end
		-- sign_up with email confirmation enabled returns a user without tokens: keep the current session
		if type(data) == "table" and data.access_token then
			self:set_session(data)
		end
		callback(nil, data)
	end
end

--- Anonymous sign-in (requires Anonymous Sign-Ins to be enabled in the dashboard)
function Auth:sign_in_anonymously(callback, metadata)
	self.client:request("POST", "/auth/v1/signup", { body = { data = metadata or {} } }, session_callback(self, callback))
end

function Auth:sign_up(email, password, callback)
	self.client:request("POST", "/auth/v1/signup", { body = { email = email, password = password } }, session_callback(self, callback))
end

function Auth:sign_in_with_password(email, password, callback)
	self.client:request("POST", "/auth/v1/token", {
		query = { { "grant_type", "password" } },
		body = { email = email, password = password },
	}, session_callback(self, callback))
end

--- Refresh the session with a refresh_token (defaults to the current session's)
function Auth:refresh_session(callback, refresh_token)
	refresh_token = refresh_token or (self.client.session and self.client.session.refresh_token)
	if not refresh_token then
		callback({ status = 0, message = "no refresh token" }, nil)
		return
	end
	self.client:request("POST", "/auth/v1/token", {
		query = { { "grant_type", "refresh_token" } },
		body = { refresh_token = refresh_token },
	}, session_callback(self, callback))
end

--- Restore a saved session, refreshing it first if it is about to expire
function Auth:restore(session, callback)
	self.client.session = session
	if self:needs_refresh() then
		self:refresh_session(callback)
	else
		callback(nil, session)
	end
end

--- Update the current user (PUT /auth/v1/user). attrs: { email?, password?, data? }
-- Anonymous -> permanent account: update_user({ email }) -> confirm email -> update_user({ password })
-- callback(err, user). With email confirmation on, the pending address is in user.new_email.
function Auth:update_user(attrs, callback)
	self.client:request("PUT", "/auth/v1/user", { body = attrs }, function(err, user)
		if not err and type(user) == "table" and self.client.session then
			self.client.session.user = user
		end
		callback(err, user)
	end)
end

function Auth:get_user(callback)
	self.client:request("GET", "/auth/v1/user", nil, callback)
end

function Auth:sign_out(callback)
	self.client:request("POST", "/auth/v1/logout", nil, function(err)
		self:set_session(nil)
		if callback then
			callback(err)
		end
	end)
end

return M
