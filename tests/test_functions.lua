local H = require("tests.helpers")

local json_codec = {
	encode = H.json,
	decode = function(s)
		if s == '{"message":"hi"}' then return { message = "hi" } end
		if s == '{"error":"boom"}' then return { error = "boom" } end
		error("not json")
	end,
}

test("invoke with a JSON body decodes JSON responses", function()
	local sb, log = H.fake({
		["POST /functions/v1/hello"] = { 200, '{"message":"hi"}', { ["content-type"] = "application/json" } },
	}, { codec = json_codec })
	local got, res
	sb.functions:invoke("hello", { body = { name = "x" }, region = "us-east-1", headers = { ["X-Custom"] = "1" } },
		function(err, data, r) got, res = data, r end)
	assert(got.message == "hi" and res.status == 200)
	assert(log[1].body == '{"name":"x"}' and log[1].headers["x-region"] == "us-east-1" and log[1].headers["X-Custom"] == "1")
	assert(log[1].headers.Authorization == "Bearer ANON")
end)

test("invoke with text body, GET method and text response", function()
	local sb, log = H.fake({
		["POST /functions/v1/echo"] = { 200, "plain text", { ["content-type"] = "text/plain" } },
		["GET /functions/v1/echo"] = { 200, "ok", { ["content-type"] = "text/plain" } },
	}, { codec = json_codec })
	local got
	sb.functions:invoke("echo", { body = "hello" }, function(err, data) got = data end)
	assert(got == "plain text" and log[1].body == "hello" and log[1].headers["Content-Type"] == "text/plain")
	sb.functions:invoke("echo", { method = "GET" }, function(err, data) got = data end)
	assert(got == "ok" and log[2].body == nil)
end)

test("non-2xx responses become errors with the decoded body", function()
	local sb = H.fake({
		["POST /functions/v1/fail"] = { 500, '{"error":"boom"}', { ["content-type"] = "application/json" } },
	}, { codec = json_codec })
	local err
	sb.functions:invoke("fail", function(e) err = e end)
	assert(err.status == 500 and err.body.error == "boom")
end)
