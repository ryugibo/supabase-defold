local H = require("tests.helpers")

local function params_of(q)
	local _, params = q:build()
	local out = {}
	for _, kv in ipairs(params) do
		out[#out + 1] = kv[1] .. "=" .. tostring(kv[2])
	end
	return table.concat(out, "&")
end

test("filter operators", function()
	local sb = H.fake({})
	local q = sb:from("t"):select("id, name")
		:eq("a", 1):neq("b", true):gt("c", 2):gte("d", 3):lt("e", 4):lte("f", 5)
		:like("g", "%x%"):ilike("h", "y%"):is_("i", nil):is_("j", false)
		:in_("k", { 1, "a,b", "c" }):contains("l", { "x", "y" }):contained_by("m", "[1,5)")
		:overlaps("n", { 1, 2 }):range_gt("o", "[1,2]"):range_adjacent("p", "[3,4]")
		:text_search("q", "cat & dog", { config = "english", type = "websearch" })
		:like_any_of("r", { "a%", "b%" }):ilike_all_of("s", { "%c", "%d" })
		:not_("t", "in", { 1, 2 }):not_("u", "is", nil):or_("v.eq.1,w.gt.2")
		:or_("x.eq.3", { referenced_table = "items" }):filter("y", "cs", "{1}"):match({ z1 = 1, z2 = "b" })
	assert(params_of(q) == table.concat({
		"select=id,name", "a=eq.1", "b=neq.true", "c=gt.2", "d=gte.3", "e=lt.4", "f=lte.5",
		"g=like.%x%", "h=ilike.y%", "i=is.null", "j=is.false",
		'k=in.(1,"a,b",c)', "l=cs.{x,y}", "m=cd.[1,5)", "n=ov.{1,2}", "o=sr.[1,2]", "p=adj.[3,4]",
		"q=wfts(english).cat & dog", "r=like(any).{a%,b%}", "s=ilike(all).{%c,%d}",
		"t=not.in.(1,2)", "u=not.is.null", "or=(v.eq.1,w.gt.2)", "items.or=(x.eq.3)", "y=cs.{1}",
		"z1=eq.1", "z2=eq.b",
	}, "&"), params_of(q))
end)

test("contains with a JSON object uses the codec", function()
	local sb = H.fake({}, { codec = { encode = H.json, decode = function(s) return s end } })
	local q = sb:from("t"):select():contains("meta", { a = 1 })
	assert(params_of(q) == 'select=*&meta=cs.{"a":1}', params_of(q))
end)

test("order, limit and range modifiers", function()
	local sb = H.fake({})
	local q = sb:from("t"):select():order("a"):order("b", { ascending = false, nulls_first = true })
		:order("c", false):order("name", { referenced_table = "items" }):limit(5, { referenced_table = "items" }):range(10, 19)
	assert(params_of(q) == "select=*&order=a.asc,b.desc.nullsfirst,c.desc&items.order=name.asc&items.limit=5&offset=10&limit=10",
		params_of(q))
end)

test("count and head parse Content-Range", function()
	local sb, log = H.fake({
		["HEAD /rest/v1/t"] = { 200, nil, { ["content-range"] = "*/42" } },
		["GET /rest/v1/t"] = { 206, { { id = 1 } }, { ["content-range"] = "0-0/42" } },
	})
	local got
	sb:from("t"):select("*", { count = "exact", head = true }):execute(function(err, data, res) got = { err, data, res } end)
	assert(got[1] == nil and got[2] == nil and got[3].count == 42 and got[3].status == 200)
	assert(log[1].method == "HEAD" and log[1].headers.Prefer == "count=exact")
	sb:from("t"):select("*", { count = "planned" }):limit(1):execute(function(err, data, res) got = { data, res } end)
	assert(got[1][1].id == 1 and got[2].count == 42 and log[2].headers.Prefer == "count=planned")
end)

test("maybe_single returns nil for no rows and errors on many", function()
	local rows = {}
	local sb = H.fake({ ["GET /rest/v1/t"] = function() return { 200, rows } end })
	local got
	sb:from("t"):select():maybe_single():execute(function(err, data) got = { err, data } end)
	assert(got[1] == nil and got[2] == nil)
	rows = { { id = 1 } }
	sb:from("t"):select():maybe_single():execute(function(err, data) got = { err, data } end)
	assert(got[2].id == 1)
	rows = { { id = 1 }, { id = 2 } }
	sb:from("t"):select():maybe_single():execute(function(err, data) got = { err, data } end)
	assert(got[1].code == "PGRST116" and got[2] == nil)
end)

test("insert / upsert / update / delete options", function()
	local sb, log = H.fake({
		["POST /rest/v1/t"] = { 201, {} },
		["PATCH /rest/v1/t"] = { 204, nil },
		["DELETE /rest/v1/t"] = { 200, {} },
	})
	sb:from("t"):insert({ { a = 1 }, { b = 2 } }, { default_to_null = false, count = "exact" }):select("id"):execute()
	assert(log[1].headers.Prefer == "return=representation,count=exact,missing=default", log[1].headers.Prefer)
	assert(log[1].query.columns == '"a","b"' and log[1].query.select == "id")
	sb:from("t"):upsert({ id = 1 }, { on_conflict = "id", ignore_duplicates = true }):execute()
	assert(log[2].headers.Prefer == "return=representation,resolution=ignore-duplicates" and log[2].query.on_conflict == "id")
	sb:from("t"):upsert({ id = 1 }, "id"):execute()
	assert(log[3].headers.Prefer:find("merge-duplicates", 1, true))
	sb:from("t"):update({ a = 2 }, { returning = "minimal" }):eq("id", 1):execute()
	assert(log[4].method == "PATCH" and log[4].headers.Prefer == "return=minimal")
	sb:from("t"):delete({ count = "exact" }):eq("id", 1):max_affected(1):rollback():execute()
	assert(log[5].headers.Prefer == "return=representation,count=exact,handling=strict,max-affected=1,tx=rollback",
		log[5].headers.Prefer)
end)

test("csv, geojson and explain set Accept", function()
	local sb, log = H.fake({ ["GET /rest/v1/t"] = { 200, "id\n1" } })
	local got
	sb:from("t"):select():csv():execute(function(err, data) got = data end)
	assert(log[1].headers.Accept == "text/csv" and got == "id\n1")
	sb:from("t"):select():geojson():execute()
	assert(log[2].headers.Accept == "application/geo+json")
	sb:from("t"):select():explain({ analyze = true, verbose = true }):execute()
	assert(log[3].headers.Accept == 'application/vnd.pgrst.plan+text; for="application/json"; options=analyze|verbose;',
		log[3].headers.Accept)
end)

test("rpc via query builder: POST body, GET args, filters, schema", function()
	local sb, log = H.fake({
		["POST /rest/v1/rpc/f"] = { 200, { { id = 1 } } },
		["GET /rest/v1/rpc/f"] = { 200, {} },
		["HEAD /rest/v1/rpc/f"] = { 200, nil, { ["content-range"] = "*/3" } },
	}, { schema = "app" })
	sb.db:rpc("f", { a = 1 }):eq("id", 1):limit(1):execute()
	assert(log[1].body.a == 1 and log[1].query.id == "eq.1" and log[1].headers["Content-Profile"] == "app")
	sb.db:rpc("f", { a = 1, tags = { "x", "y" } }, { get = true }):execute()
	assert(log[2].method == "GET" and log[2].query.a == "1" and log[2].query.tags == "{x,y}" and log[2].body == nil)
	assert(log[2].headers["Accept-Profile"] == "app")
	local count
	sb:schema("other"):rpc("f", {}, { head = true, count = "exact" }):execute(function(e, d, res) count = res.count end)
	assert(count == 3 and log[3].headers["Accept-Profile"] == "other")
end)

test("schema() binds a schema for table queries", function()
	local sb, log = H.fake({ ["GET /rest/v1/t"] = { 200, {} } })
	sb:schema("s1"):from("t"):select():execute()
	assert(log[1].headers["Accept-Profile"] == "s1")
end)
