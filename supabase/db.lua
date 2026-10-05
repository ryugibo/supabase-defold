-- PostgREST query builder (postgrest-js equivalent): select/insert/upsert/update/delete, RPC, filters and modifiers.
--   sb.db:from("todos"):select("id,title"):eq("user_id", uid):order("id", { ascending = false }):range(0, 9):execute(cb)
--   sb.db:from("profiles"):upsert({ id = uid, gold = 10 }, { on_conflict = "id" }):execute(cb)
--   sb.db:rpc("search_items", { q = "cake" }):limit(5):execute(cb)
-- execute(callback(err, data, res)): res = { status, count, headers }
local util = require("supabase.util")

local M = {}

local Db = {}
Db.__index = Db

local Query = {}
Query.__index = Query

function M.new(client, schema)
	return setmetatable({ client = client, schema_name = schema }, Db)
end

--- Builder bound to another schema: sb.db:schema("other"):from("t")
function Db:schema(name)
	return M.new(self.client, name)
end

local function new_query(db, path, method)
	return setmetatable({
		client = db.client,
		path = path,
		method = method or "GET",
		params = {}, -- ordered { {key, value}, ... }
		headers = {},
		prefer = {}, -- ordered Prefer parts
		body = nil,
		result = nil, -- nil | "single" | "maybe_single"
		raw = false, -- do not JSON-decode the response (csv, explain text)
		schema = db.schema_name, -- nil = client default schema
	}, Query)
end

function Db:from(table_name)
	return new_query(self, "/rest/v1/" .. util.urlencode(table_name))
end

local function format_value(v)
	if type(v) == "boolean" then
		return v and "true" or "false"
	elseif v == nil then
		return "null"
	end
	return tostring(v)
end

--- Postgres array literal for filters: {a,b,c}
local function pg_array(values)
	local items = {}
	for i, v in ipairs(values) do
		items[i] = format_value(v)
	end
	return "{" .. table.concat(items, ",") .. "}"
end

--- Call a Postgres function. opts: { head = bool, get = bool, count = "exact" | "planned" | "estimated" }
-- Returns a query, so filters and modifiers can be applied to set-returning functions.
function Db:rpc(fn, args, opts)
	opts = opts or {}
	local q = new_query(self, "/rest/v1/rpc/" .. util.urlencode(fn), "POST")
	if opts.head or opts.get then
		q.method = opts.head and "HEAD" or "GET"
		local keys = {}
		for k in pairs(args or {}) do
			keys[#keys + 1] = k
		end
		table.sort(keys)
		for _, k in ipairs(keys) do
			local v = args[k]
			q.params[#q.params + 1] = { k, type(v) == "table" and pg_array(v) or format_value(v) }
		end
	else
		q.body = args or {}
	end
	if opts.count then
		q.prefer[#q.prefer + 1] = "count=" .. opts.count
	end
	return q
end

-- Internal helpers -----------------------------------------------------------------

local function add(self, key, value)
	self.params[#self.params + 1] = { key, value }
	return self
end

local function set_param(self, key, value)
	for _, kv in ipairs(self.params) do
		if kv[1] == key then
			kv[2] = value
			return self
		end
	end
	return add(self, key, value)
end

local function get_param(self, key)
	for _, kv in ipairs(self.params) do
		if kv[1] == key then
			return kv[2]
		end
	end
end

local function set_prefer(self, name, value)
	local part = value and (name .. "=" .. value) or name
	for i, p in ipairs(self.prefer) do
		if p == name or p:sub(1, #name + 1) == name .. "=" then
			self.prefer[i] = part
			return
		end
	end
	self.prefer[#self.prefer + 1] = part
end

--- Strip whitespace outside double quotes ("id, name" -> "id,name")
local function clean_columns(columns)
	local out, quoted = {}, false
	for c in columns:gmatch(".") do
		if c == '"' then
			quoted = not quoted
		end
		if quoted or not c:match("%s") then
			out[#out + 1] = c
		end
	end
	return table.concat(out)
end

-- Query type -----------------------------------------------------------------------

--- Select columns. opts: { head = bool, count = "exact" | "planned" | "estimated" }.
-- On insert/update/upsert/delete it chooses the returned columns instead.
function Query:select(columns, opts)
	opts = opts or {}
	set_param(self, "select", clean_columns(columns or "*"))
	if self.method == "GET" or self.method == "HEAD" then
		if opts.head then
			self.method = "HEAD"
		end
	else
		set_prefer(self, "return", "representation")
	end
	if opts.count then
		set_prefer(self, "count", opts.count)
	end
	return self
end

local function mutation(self, method, body, opts)
	opts = opts or {}
	self.method = method
	self.body = body
	set_prefer(self, "return", opts.returning or "representation")
	if opts.count then
		set_prefer(self, "count", opts.count)
	end
	return self
end

--- Insert rows (table or array of tables). opts: { count, default_to_null = true, returning = "representation" | "minimal" }
function Query:insert(values, opts)
	opts = opts or {}
	mutation(self, "POST", values, opts)
	if opts.default_to_null == false then
		set_prefer(self, "missing", "default")
	end
	if util.is_array(values) and type(values[1]) == "table" then
		local seen, columns = {}, {}
		for _, row in ipairs(values) do
			for k in pairs(row) do
				if not seen[k] then
					seen[k] = true
					columns[#columns + 1] = k
				end
			end
		end
		table.sort(columns)
		for i, c in ipairs(columns) do
			columns[i] = '"' .. c .. '"'
		end
		set_param(self, "columns", table.concat(columns, ","))
	end
	return self
end

--- Upsert. opts: { on_conflict, ignore_duplicates, count, default_to_null, returning } (or the on_conflict string)
function Query:upsert(values, opts)
	if type(opts) == "string" then
		opts = { on_conflict = opts }
	end
	opts = opts or {}
	self:insert(values, opts)
	set_prefer(self, "resolution", opts.ignore_duplicates and "ignore-duplicates" or "merge-duplicates")
	if opts.on_conflict then
		set_param(self, "on_conflict", opts.on_conflict)
	end
	return self
end

--- opts: { count, returning }
function Query:update(values, opts)
	return mutation(self, "PATCH", values, opts)
end

--- opts: { count, returning }
function Query:delete(opts)
	return mutation(self, "DELETE", nil, opts)
end

-- Filters --------------------------------------------------------------------------

local function op(name)
	return function(self, column, value)
		return add(self, column, name .. "." .. format_value(value))
	end
end

Query.eq = op("eq")
Query.neq = op("neq")
Query.gt = op("gt")
Query.gte = op("gte")
Query.lt = op("lt")
Query.lte = op("lte")
Query.like = op("like")
Query.ilike = op("ilike")
Query.range_gt = op("sr")
Query.range_gte = op("nxl")
Query.range_lt = op("sl")
Query.range_lte = op("nxr")
Query.range_adjacent = op("adj")

local function pattern_list(name)
	return function(self, column, patterns)
		return add(self, column, name .. "{" .. table.concat(patterns, ",") .. "}")
	end
end

Query.like_all_of = pattern_list("like(all).")
Query.like_any_of = pattern_list("like(any).")
Query.ilike_all_of = pattern_list("ilike(all).")
Query.ilike_any_of = pattern_list("ilike(any).")

--- is_(column, nil | true | false | "unknown")
function Query:is_(column, value)
	return add(self, column, "is." .. format_value(value))
end

local function in_list(values)
	local items = {}
	for i, v in ipairs(values) do
		if type(v) == "string" and v:find("[,()]") then
			items[i] = '"' .. v .. '"'
		else
			items[i] = format_value(v)
		end
	end
	return "(" .. table.concat(items, ",") .. ")"
end

function Query:in_(column, values)
	return add(self, column, "in." .. in_list(values))
end

--- Array/range/JSON containment: value is a string (range literal), array or JSON object
local function containment(self, name, column, value)
	if type(value) == "string" then
		return add(self, column, name .. "." .. value)
	elseif util.is_array(value) or next(value) == nil then
		return add(self, column, name .. "." .. pg_array(value))
	end
	return add(self, column, name .. "." .. self.client.codec.encode(value))
end

function Query:contains(column, value) return containment(self, "cs", column, value) end
function Query:contained_by(column, value) return containment(self, "cd", column, value) end

function Query:overlaps(column, value)
	if type(value) == "string" then
		return add(self, column, "ov." .. value)
	end
	return add(self, column, "ov." .. pg_array(value))
end

--- Full-text search. opts: { config = "english", type = "plain" | "phrase" | "websearch" }
function Query:text_search(column, query, opts)
	opts = opts or {}
	local prefix = ({ plain = "pl", phrase = "ph", websearch = "w" })[opts.type] or ""
	local config = opts.config and ("(" .. opts.config .. ")") or ""
	return add(self, column, prefix .. "fts" .. config .. "." .. query)
end

--- eq for every key of the table
function Query:match(query)
	local keys = {}
	for k in pairs(query) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		self:eq(k, query[k])
	end
	return self
end

--- not_("status", "eq", "done"), not_("id", "in", { 1, 2 }), not_("name", "is", nil)
function Query:not_(column, operator, value)
	local v
	if type(value) == "table" then
		v = operator == "in" and in_list(value) or pg_array(value)
	else
		v = format_value(value)
	end
	return add(self, column, "not." .. operator .. "." .. v)
end

--- or_("status.eq.done,priority.gt.3", { referenced_table = "items" })
function Query:or_(filters, opts)
	local ref = opts and opts.referenced_table
	return add(self, ref and (ref .. ".or") or "or", "(" .. filters .. ")")
end

--- Raw filter: filter("tags", "cs", "{a,b}")
function Query:filter(column, operator, value)
	return add(self, column, operator .. "." .. format_value(value))
end

-- Modifiers ------------------------------------------------------------------------

--- order(column, ascending_bool) or order(column, { ascending = true, nulls_first, referenced_table })
-- Calling it again adds a secondary ordering.
function Query:order(column, opts)
	if type(opts) == "boolean" then
		opts = { ascending = opts }
	end
	opts = opts or {}
	local key = opts.referenced_table and (opts.referenced_table .. ".order") or "order"
	local value = column .. (opts.ascending == false and ".desc" or ".asc")
	if opts.nulls_first ~= nil then
		value = value .. (opts.nulls_first and ".nullsfirst" or ".nullslast")
	end
	local existing = get_param(self, key)
	return set_param(self, key, existing and (existing .. "," .. value) or value)
end

--- limit(n, { referenced_table })
function Query:limit(n, opts)
	local ref = opts and opts.referenced_table
	return set_param(self, ref and (ref .. ".limit") or "limit", n)
end

--- Rows from..to inclusive (0-based). opts: { referenced_table }
function Query:range(from, to, opts)
	local ref = opts and opts.referenced_table
	set_param(self, ref and (ref .. ".offset") or "offset", from)
	return set_param(self, ref and (ref .. ".limit") or "limit", to - from + 1)
end

--- Exactly one row as an object; an error (PGRST116) when zero or several rows match
function Query:single()
	self.result = "single"
	self.headers["Accept"] = "application/vnd.pgrst.object+json"
	return self
end

--- Zero or one row: nil data when none, an error when several match
function Query:maybe_single()
	self.result = "maybe_single"
	return self
end

--- Response as CSV text
function Query:csv()
	self.headers["Accept"] = "text/csv"
	self.raw = true
	return self
end

--- Response as GeoJSON (PostGIS)
function Query:geojson()
	self.headers["Accept"] = "application/geo+json"
	return self
end

--- EXPLAIN plan (db_plan_enabled must be on). opts: { analyze, verbose, settings, buffers, wal, format = "text" | "json" }
function Query:explain(opts)
	opts = opts or {}
	local format = opts.format or "text"
	local flags = {}
	for _, name in ipairs({ "analyze", "verbose", "settings", "buffers", "wal" }) do
		if opts[name] then
			flags[#flags + 1] = name
		end
	end
	local for_type = self.headers["Accept"] or "application/json"
	self.headers["Accept"] = string.format('application/vnd.pgrst.plan+%s; for="%s"; options=%s;',
		format, for_type, table.concat(flags, "|"))
	self.raw = format == "text"
	return self
end

--- Run the request in a transaction that is rolled back (testing)
function Query:rollback()
	set_prefer(self, "tx", "rollback")
	return self
end

--- Fail mutations that would touch more than n rows (PostgREST 13+)
function Query:max_affected(n)
	set_prefer(self, "handling", "strict")
	set_prefer(self, "max-affected", n)
	return self
end

--- Return no body for a mutation
function Query:returns_minimal()
	set_prefer(self, "return", "minimal")
	return self
end

--- Target a different schema for this query only (default: client schema)
function Query:in_schema(schema)
	self.schema = schema
	return self
end

function Query:header(name, value)
	self.headers[name] = value
	return self
end

--- Request path and query params (for tests/debugging)
function Query:build()
	return self.path, self.params
end

local function parse_count(headers)
	local range = util.header(headers, "content-range")
	local total = range and range:match("/(%d+)$")
	return total and tonumber(total) or nil
end

function Query:execute(callback)
	callback = callback or function() end
	local headers = self.client:profile_headers(self.method, self.schema)
	for k, v in pairs(self.headers) do
		headers[k] = v
	end
	if #self.prefer > 0 then
		headers["Prefer"] = table.concat(self.prefer, ",")
	end
	local body = self.body
	if self.method == "GET" or self.method == "HEAD" then
		body = nil
	end
	self.client:request(self.method, self.path, {
		query = self.params,
		body = body,
		headers = headers,
		raw_response = self.raw,
	}, function(err, data, status, response_headers)
		local res = { status = status, count = parse_count(response_headers), headers = response_headers }
		if err then
			return callback(err, nil, res)
		end
		if self.method == "HEAD" then
			data = nil
		elseif self.result == "maybe_single" and type(data) == "table" then
			if #data > 1 then
				return callback({
					status = 406,
					code = "PGRST116",
					message = "JSON object requested, multiple (or no) rows returned",
					details = "Results contain " .. #data .. " rows, application/vnd.pgrst.object+json requires 1 row",
				}, nil, res)
			end
			data = data[1]
		end
		callback(nil, data, res)
	end)
end

return M
