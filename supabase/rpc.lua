-- Call Postgres functions (POST /rest/v1/rpc/<name>)
--   sb.rpc:call("add_numbers", { a = 1, b = 2 }, function(err, result) end)
-- For GET/HEAD calls, counts, filters or modifiers use the query builder: sb.db:rpc(name, args, opts)
local M = {}

local Rpc = {}
Rpc.__index = Rpc

function M.new(client)
	return setmetatable({ client = client }, Rpc)
end

--- params: function arguments table. callback(err, result, res). schema defaults to the client schema
function Rpc:call(name, params, callback, schema)
	self.client.db:schema(schema):rpc(name, params):execute(callback)
end

--- Query builder for a function call (same as sb.db:rpc)
function Rpc:query(name, params, opts)
	return self.client.db:rpc(name, params, opts)
end

return M
