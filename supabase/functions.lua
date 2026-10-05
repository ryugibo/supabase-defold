-- Supabase Edge Functions (functions-js equivalent)
--   sb.functions:invoke("hello", { body = { name = "Defold" } }, function(err, data) end)
local util = require("supabase.util")

local M = {}

local Functions = {}
Functions.__index = Functions

function M.new(client)
	return setmetatable({ client = client }, Functions)
end

--- invoke(name, opts?, callback). opts: { body = table | string, headers, method = "POST", region, query }
-- A table body is sent as JSON, a string as text/plain (override with headers["Content-Type"]).
-- callback(err, data, res): data is decoded JSON for JSON responses, otherwise the raw string.
-- On a non-2xx response err.body holds the function's response body.
function Functions:invoke(name, a, b)
	local opts, callback = util.opts_cb(a, b)
	local headers = {}
	local body
	if type(opts.body) == "table" then
		body = self.client.codec.encode(opts.body)
	elseif opts.body ~= nil then
		body = tostring(opts.body)
		headers["Content-Type"] = "text/plain"
	end
	if opts.region and opts.region ~= "any" then
		headers["x-region"] = opts.region
	end
	for k, v in pairs(opts.headers or {}) do
		headers[k] = v
	end
	self.client:request(opts.method or "POST", "/functions/v1/" .. name, {
		raw_body = body,
		headers = headers,
		query = opts.query,
		raw_response = true,
	}, function(err, data, status, response_headers)
		local res = { status = status, headers = response_headers }
		local content_type = util.header(response_headers, "content-type") or ""
		local function decode(s)
			if type(s) == "string" and content_type:find("json", 1, true) then
				local ok, decoded = pcall(self.client.codec.decode, s)
				if ok then
					return decoded
				end
			end
			return s
		end
		if err then
			err.body = decode(err.body)
			if err.message == "request failed" then
				err.message = "Edge Function returned a non-2xx status code"
			end
			return callback(err, nil, res)
		end
		callback(nil, decode(data), res)
	end)
end

return M
