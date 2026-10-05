-- Supabase client for Defold: shared HTTP layer for REST (PostgREST), Auth (GoTrue) and RPC.
--   local supabase = require("supabase.client")
--   local sb = supabase.new({ url = "https://xxx.supabase.co", anon_key = "...", schema = "my_app" })
--   sb.auth:sign_in_anonymously(function(err, session) ... end)
--   sb.db:from("profiles"):select("*"):eq("id", uid):single():execute(function(err, row) ... end)
--   sb.rpc:call("my_function", { arg = 1 }, function(err, result) ... end)
local M = {}

local Client = {}
Client.__index = Client

--- Percent-encode a string (everything except RFC 3986 unreserved characters)
function M.urlencode(s)
	return (tostring(s):gsub("[^%w%-%._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

--- Query table { {key, value}, ... } or { key = value } -> "a=1&b=2" (array form keeps order, map form is sorted)
function M.build_query(query)
	if not query then
		return ""
	end
	local parts = {}
	if #query > 0 then
		for _, kv in ipairs(query) do
			parts[#parts + 1] = M.urlencode(kv[1]) .. "=" .. M.urlencode(kv[2])
		end
	else
		local keys = {}
		for k in pairs(query) do
			keys[#keys + 1] = k
		end
		table.sort(keys)
		for _, k in ipairs(keys) do
			parts[#parts + 1] = M.urlencode(k) .. "=" .. M.urlencode(query[k])
		end
	end
	return table.concat(parts, "&")
end

-- Default transport built on Defold's http.request
local function defold_transport(url, method, headers, body, callback)
	http.request(url, method, function(_, _, response)
		callback(response.status, response.response, response.headers)
	end, headers, body, { timeout = 15 })
end

local function defold_codec()
	return { encode = json.encode, decode = function(s) return json.decode(s) end }
end

--- opts: { url, anon_key, schema?, transport?, codec? }
--   schema: default PostgREST schema (public when omitted). Useful when several apps share one project.
--           The schema must be listed under Exposed schemas in the dashboard's Data API settings.
--   transport(url, method, headers, body, callback(status, body_string, headers)) - injectable (tests, non-Defold runtimes)
--   codec: { encode = fn(table) -> string, decode = fn(string) -> table }
function M.new(opts)
	assert(opts and opts.url and opts.anon_key, "supabase.new: url and anon_key are required")
	local self = setmetatable({
		url = opts.url:gsub("/+$", ""),
		anon_key = opts.anon_key,
		schema = opts.schema,
		transport = opts.transport or defold_transport,
		codec = opts.codec or defold_codec(),
		session = nil, -- { access_token, refresh_token, expires_at, user }
	}, Client)
	self.auth = require("supabase.auth").new(self)
	self.db = require("supabase.db").new(self)
	self.rpc = require("supabase.rpc").new(self)
	return self
end

--- PostgREST schema headers (GET/HEAD: Accept-Profile, others: Content-Profile). Empty table when no schema
function Client:profile_headers(method, schema)
	schema = schema or self.schema
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

--- Generic request.
-- opts: { query = {...}, body = table|nil, headers = {...}, raw = bool }
-- callback(err, data, status, headers): err is { status, message, code, details } or nil
function Client:request(method, path, opts, callback)
	opts = opts or {}
	local url = self.url .. path
	local query = M.build_query(opts.query)
	if query ~= "" then
		url = url .. (url:find("?", 1, true) and "&" or "?") .. query
	end
	local headers = {
		["apikey"] = self.anon_key,
		["Authorization"] = "Bearer " .. self:access_token(),
		["Content-Type"] = "application/json",
		["Accept"] = "application/json",
	}
	for k, v in pairs(opts.headers or {}) do
		headers[k] = v
	end
	local body = opts.body ~= nil and self.codec.encode(opts.body) or nil

	self.transport(url, method, headers, body, function(status, response_body, response_headers)
		local data = nil
		if response_body and response_body ~= "" then
			local ok, decoded = pcall(self.codec.decode, response_body)
			data = ok and decoded or response_body
		end
		if status == 0 or status == nil then
			callback({ status = 0, message = "network error" }, nil, 0, response_headers)
		elseif status >= 400 then
			local err = { status = status, message = "request failed" }
			if type(data) == "table" then
				err.message = data.message or data.msg or data.error_description or data.error or err.message
				err.code = data.code or data.error_code
				err.details = data.details or data.hint
			end
			callback(err, nil, status, response_headers)
		else
			callback(nil, data, status, response_headers)
		end
	end)
end

return M
