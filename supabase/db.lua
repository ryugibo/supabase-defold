-- PostgREST query builder: select/insert/upsert/update/delete + filters
--   sb.db:from("todos"):select("id,title"):eq("user_id", uid):order("id", false):execute(cb)
--   sb.db:from("profiles"):upsert({ id = uid, gold = 10 }, "id"):execute(cb)
local M = {}

local Db = {}
Db.__index = Db

local Query = {}
Query.__index = Query

function M.new(client)
	return setmetatable({ client = client }, Db)
end

function Db:from(table_name)
	return setmetatable({
		client = self.client,
		table_name = table_name,
		method = "GET",
		params = {}, -- ordered { {key, value}, ... }
		headers = {},
		body = nil,
		is_single = false,
		schema = nil, -- nil = client default schema
	}, Query)
end

--- Target a different schema for this query only (default: client schema)
function Query:in_schema(schema)
	self.schema = schema
	return self
end

local function add(self, key, value)
	self.params[#self.params + 1] = { key, value }
	return self
end

local function pg_value(v)
	if type(v) == "boolean" then
		return v and "true" or "false"
	end
	return tostring(v)
end

function Query:select(columns)
	return add(self, "select", columns or "*")
end

function Query:eq(column, value) return add(self, column, "eq." .. pg_value(value)) end
function Query:neq(column, value) return add(self, column, "neq." .. pg_value(value)) end
function Query:gt(column, value) return add(self, column, "gt." .. pg_value(value)) end
function Query:gte(column, value) return add(self, column, "gte." .. pg_value(value)) end
function Query:lt(column, value) return add(self, column, "lt." .. pg_value(value)) end
function Query:lte(column, value) return add(self, column, "lte." .. pg_value(value)) end

function Query:in_(column, values)
	local items = {}
	for i, v in ipairs(values) do
		items[i] = pg_value(v)
	end
	return add(self, column, "in.(" .. table.concat(items, ",") .. ")")
end

--- ascending defaults to true
function Query:order(column, ascending)
	return add(self, "order", column .. (ascending == false and ".desc" or ".asc"))
end

function Query:limit(n)
	return add(self, "limit", n)
end

--- Return the first row instead of an array (nil data, not an error, when no rows match)
function Query:single()
	self.is_single = true
	return self
end

function Query:insert(rows)
	self.method = "POST"
	self.body = rows
	self.headers["Prefer"] = "return=representation"
	return self
end

--- on_conflict: conflict target column(s) (default: primary key)
function Query:upsert(rows, on_conflict)
	self.method = "POST"
	self.body = rows
	self.headers["Prefer"] = "return=representation,resolution=merge-duplicates"
	if on_conflict then
		add(self, "on_conflict", on_conflict)
	end
	return self
end

function Query:update(values)
	self.method = "PATCH"
	self.body = values
	self.headers["Prefer"] = "return=representation"
	return self
end

function Query:delete()
	self.method = "DELETE"
	self.headers["Prefer"] = "return=representation"
	return self
end

--- Request path and query params (for tests/debugging)
function Query:build()
	return "/rest/v1/" .. self.table_name, self.params
end

function Query:execute(callback)
	local path, params = self:build()
	local headers = self.client:profile_headers(self.method, self.schema)
	for k, v in pairs(self.headers) do
		headers[k] = v
	end
	self.client:request(self.method, path, { query = params, body = self.body, headers = headers },
		function(err, data, status)
			if not err and self.is_single and type(data) == "table" then
				data = data[1]
			end
			callback(err, data, status)
		end)
end

return M
