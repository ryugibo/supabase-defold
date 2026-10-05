-- Call Postgres functions (POST /rest/v1/rpc/<name>)
local M = {}

local Rpc = {}
Rpc.__index = Rpc

function M.new(client)
	return setmetatable({ client = client }, Rpc)
end

--- params: function arguments table. callback(err, result). schema defaults to the client schema
function Rpc:call(name, params, callback, schema)
	self.client:request("POST", "/rest/v1/rpc/" .. name, {
		body = params or {},
		headers = self.client:profile_headers("POST", schema),
	}, function(err, data)
		callback(err, data)
	end)
end

return M
