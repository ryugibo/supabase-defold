-- Supabase client for Defold: shared HTTP layer for Auth, Database (PostgREST), RPC, Storage, Functions and Realtime.
--   local supabase = require("supabase.client")
--   local sb = supabase.new({ url = "https://xxx.supabase.co", anon_key = "...", schema = "my_app" })
--   sb.auth:sign_in_anonymously(function(err, session) ... end)
--   sb:from("profiles"):select("*"):eq("id", uid):single():execute(function(err, row) ... end)
--   sb.rpc:call("my_function", { arg = 1 }, function(err, result) ... end)
local util = require("supabase.util")
local platform = require("supabase.platform")

local M = {}

M.VERSION = "0.2.0"
M.urlencode = util.urlencode
M.build_query = util.build_query
M.memory_storage = platform.memory_storage

local Client = {}
Client.__index = Client

--- opts (any option left out is read from the [supabase] section of game.project, see supabase/ext.properties):
--   url, anon_key                 required (here or in game.project)
--   schema                        default PostgREST schema (public when omitted). Must be in the Data API's Exposed schemas.
--   headers                       extra headers sent with every request
--   timeout                       HTTP timeout in seconds (default 15)
--   auto_refresh_token            refresh an expiring session before requests (default true)
--   persist_session               save the session with `storage` and load it in auth:initialize() (default false)
--   storage, storage_key          storage adapter { get, set, remove } (default: sys.save file) and key prefix
--   flow_type                     "implicit" (default) or "pkce" for OAuth / magic links / SSO
--   realtime                      { websocket = adapter, websocket_params, heartbeat_interval, timeout, params, logger }
--   transport, codec, timer       injectable adapters (tests, other runtimes). See supabase/platform.lua
function M.new(opts)
	local merged = platform.config()
	for k, v in pairs(opts or {}) do
		merged[k] = v
	end
	opts = merged
	assert(opts.url and opts.anon_key, "supabase.new: url and anon_key are required (pass them or set [supabase] in game.project)")
	local self = setmetatable({
		url = opts.url:gsub("/+$", ""),
		anon_key = opts.anon_key,
		db_schema = opts.schema, -- default PostgREST schema (nil = public)
		headers = opts.headers or {},
		timeout = opts.timeout,
		transport = opts.transport or platform.transport,
		codec = opts.codec or platform.codec(),
		timer = opts.timer or platform.timer,
		open_url = opts.open_url or platform.open_url,
		session = nil, -- { access_token, refresh_token, expires_at, user }
	}, Client)
	self.auth = require("supabase.auth").new(self, opts)
	self.db = require("supabase.db").new(self)
	self.rpc = require("supabase.rpc").new(self)
	self.storage = require("supabase.storage").new(self)
	self.functions = require("supabase.functions").new(self)
	self.realtime = require("supabase.realtime").new(self, opts.realtime)
	return self
end

--- Shortcuts in the style of supabase-js
function Client:from(table_name) return self.db:from(table_name) end
function Client:schema(name) return self.db:schema(name) end
function Client:channel(name, config) return self.realtime:channel(name, config) end
function Client:remove_channel(channel, callback) return self.realtime:remove_channel(channel, callback) end
function Client:remove_all_channels(callback) return self.realtime:remove_all_channels(callback) end
function Client:get_channels() return self.realtime:get_channels() end

--- PostgREST schema headers (GET/HEAD: Accept-Profile, others: Content-Profile). Empty table when no schema
function Client:profile_headers(method, schema)
	schema = schema or self.db_schema
	if not schema or schema == "" then
		return {}
	end
	if method == "GET" or method == "HEAD" then
		return { ["Accept-Profile"] = schema }
	end
	return { ["Content-Profile"] = schema }
end

function Client:access_token()
	return self.session and self.session.access_token or self.anon_key
end

function Client:user_id()
	return self.session and self.session.user and self.session.user.id
end

--- Generic request to any Supabase endpoint.
-- opts: {
--   query = {...}, body = table (JSON) | nil, raw_body = string (sent as-is), headers = {...},
--   raw_response = bool (do not JSON-decode the response), timeout = seconds, skip_refresh = bool
-- }
-- callback(err, data, status, headers): err is { status, message, code, details, hint, body } or nil
function Client:request(method, path, opts, callback)
	opts = opts or {}
	callback = callback or function() end
	if not opts.skip_refresh and self.auth:should_refresh() then
		self.auth:refresh_session(function()
			self:send(method, path, opts, callback)
		end)
		return
	end
	self:send(method, path, opts, callback)
end

function Client:send(method, path, opts, callback)
	local url = path:find("^https?://") and path or (self.url .. path)
	local query = util.build_query(opts.query)
	if query ~= "" then
		url = url .. (url:find("?", 1, true) and "&" or "?") .. query
	end
	local headers = {
		["apikey"] = self.anon_key,
		["Authorization"] = "Bearer " .. self:access_token(),
		["Accept"] = "application/json",
		["X-Client-Info"] = "supabase-defold/" .. M.VERSION,
	}
	for k, v in pairs(self.headers) do
		headers[k] = v
	end
	for k, v in pairs(opts.headers or {}) do
		headers[k] = v
	end
	local body = opts.raw_body
	if body == nil and opts.body ~= nil then
		body = self.codec.encode(opts.body)
	end
	-- Defold's native HTTP client only sends bodies for POST/PUT/PATCH; without a body some servers
	-- (Storage) reject a JSON Content-Type, so only declare it when there is something to send.
	if body ~= nil and not headers["Content-Type"] then
		headers["Content-Type"] = "application/json"
	end

	self.transport(url, method, headers, body, function(status, response_body, response_headers)
		local data = nil
		if response_body and response_body ~= "" then
			if opts.raw_response then
				data = response_body
			else
				local ok, decoded = pcall(self.codec.decode, response_body)
				data = ok and decoded or response_body
			end
		end
		if status == 0 or status == nil then
			callback({ status = 0, message = "network error" }, nil, 0, response_headers)
		elseif status >= 400 then
			local err = { status = status, message = "request failed", body = data }
			local fields = data
			if type(data) == "string" and opts.raw_response then
				local ok, decoded = pcall(self.codec.decode, data)
				fields = ok and decoded or nil
			end
			if type(fields) == "table" then
				err.message = fields.message or fields.msg or fields.error_description
					or (type(fields.error) == "string" and fields.error) or err.message
				err.code = fields.code or fields.error_code or (type(fields.error) == "string" and fields.error or nil)
				err.details = fields.details
				err.hint = fields.hint
			end
			callback(err, nil, status, response_headers)
		else
			callback(nil, data, status, response_headers)
		end
	end, { timeout = opts.timeout or self.timeout })
end

return M
