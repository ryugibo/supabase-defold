local util = require("supabase.util")

test("sha256 matches known vectors", function()
	assert(util.to_hex(util.sha256("")) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	assert(util.to_hex(util.sha256("abc")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	assert(util.to_hex(util.sha256(string.rep("a", 1000))) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
end)

test("PKCE S256 challenge (RFC 7636 appendix B)", function()
	assert(util.pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
	local v = util.random_string(56)
	assert(#v == 56 and v:match("^[%w%-%._~]+$"))
end)

test("base64 round trips (standard and url-safe)", function()
	for _, s in ipairs({ "", "f", "fo", "foo", "foob", "fooba", "foobar", "\0\255\254\253" }) do
		assert(util.base64_decode(util.base64_encode(s)) == s, s)
		assert(util.base64_decode(util.base64url_encode(s)) == s, s)
	end
	assert(util.base64_encode("foobar") == "Zm9vYmFy" and util.base64_encode("fo") == "Zm8=")
	assert(util.base64url_encode("\255\254\253") == "__79")
end)

test("query parsing, path encoding and header lookup", function()
	local q = util.parse_query("a=1&b=x%20y&c=a+b&d")
	assert(q.a == "1" and q.b == "x y" and q.c == "a b" and q.d == "")
	assert(util.encode_path("/folder/my file.png/") == "folder/my%20file.png")
	assert(util.header({ ["Content-Range"] = "0-1/2" }, "content-range") == "0-1/2")
end)

test("jwt payload decoding", function()
	local payload = '{"sub":"u1"}'
	local token = "x." .. util.base64url_encode(payload) .. ".y"
	local claims = util.jwt_payload(token, function(s)
		assert(s == payload)
		return { sub = "u1" }
	end)
	assert(claims.sub == "u1")
	assert(util.jwt_payload("nope", function() end) == nil)
end)
