-- Pure Lua helpers: URL encoding, base64, SHA-256 (PKCE), JWT payload decoding.
-- Uses only the `bit` library, which both LuaJIT and Defold (all platforms) provide.
local bit = bit or require("bit")

local M = {}

--- Percent-encode a string (everything except RFC 3986 unreserved characters)
function M.urlencode(s)
	return (tostring(s):gsub("[^%w%-%._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

function M.urldecode(s)
	s = s:gsub("+", " ")
	return (s:gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
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

--- "a=1&b=x%20y" -> { a = "1", b = "x y" }
function M.parse_query(s)
	local result = {}
	for pair in (s or ""):gmatch("[^&]+") do
		local k, v = pair:match("^([^=]*)=?(.*)$")
		result[M.urldecode(k)] = M.urldecode(v)
	end
	return result
end

--- Encode each segment of a storage path, keeping the slashes
function M.encode_path(path)
	local parts = {}
	for segment in tostring(path):gmatch("[^/]+") do
		parts[#parts + 1] = M.urlencode(segment)
	end
	return table.concat(parts, "/")
end

--- Case-insensitive header lookup
function M.header(headers, name)
	if not headers then
		return nil
	end
	name = name:lower()
	for k, v in pairs(headers) do
		if tostring(k):lower() == name then
			return v
		end
	end
	return nil
end

--- True for a non-empty sequence (Lua array)
function M.is_array(t)
	return type(t) == "table" and #t > 0
end

-- Base64 --------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, #B64 do
	B64_INDEX[B64:byte(i)] = i - 1
end

function M.base64_encode(s)
	local out = {}
	for i = 1, #s, 3 do
		local a, b, c = s:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local c1 = math.floor(n / 262144) % 64
		local c2 = math.floor(n / 4096) % 64
		local c3 = math.floor(n / 64) % 64
		local c4 = n % 64
		out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
			.. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
	end
	return table.concat(out)
end

--- Accepts standard and URL-safe alphabets, with or without padding
function M.base64_decode(s)
	s = s:gsub("%-", "+"):gsub("_", "/"):gsub("[^%w%+/]", "")
	local out = {}
	for i = 1, #s, 4 do
		local n, count = 0, 0
		for j = i, math.min(i + 3, #s) do
			n = n * 64 + B64_INDEX[s:byte(j)]
			count = count + 1
		end
		for _ = count + 1, 4 do
			n = n * 64
		end
		local bytes = string.char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
		out[#out + 1] = bytes:sub(1, count - 1)
	end
	return table.concat(out)
end

function M.base64url_encode(s)
	return (M.base64_encode(s):gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
end

-- SHA-256 -------------------------------------------------------------------------

local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rshift, ror, tobit = bit.rshift, bit.ror, bit.tobit

local K = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

--- Raw 32-byte SHA-256 digest
function M.sha256(msg)
	local len = #msg
	local bits = len * 8
	msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
		.. string.char(
			math.floor(bits / 2 ^ 56) % 256, math.floor(bits / 2 ^ 48) % 256,
			math.floor(bits / 2 ^ 40) % 256, math.floor(bits / 2 ^ 32) % 256,
			math.floor(bits / 2 ^ 24) % 256, math.floor(bits / 2 ^ 16) % 256,
			math.floor(bits / 2 ^ 8) % 256, bits % 256)

	local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
	for i = 1, 8 do
		h[i] = tobit(h[i])
	end
	local w = {}
	for chunk = 1, #msg, 64 do
		for i = 0, 15 do
			local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
			w[i] = tobit(a * 16777216 + b * 65536 + c * 256 + d)
		end
		for i = 16, 63 do
			local s0 = bxor(ror(w[i - 15], 7), ror(w[i - 15], 18), rshift(w[i - 15], 3))
			local s1 = bxor(ror(w[i - 2], 17), ror(w[i - 2], 19), rshift(w[i - 2], 10))
			w[i] = tobit(w[i - 16] + s0 + w[i - 7] + s1)
		end
		local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
		for i = 0, 63 do
			local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
			local ch = bxor(band(e, f), band(bnot(e), g))
			local t1 = tobit(hh + S1 + ch + K[i + 1] + w[i])
			local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
			local maj = bxor(band(a, b), band(a, c), band(b, c))
			local t2 = tobit(S0 + maj)
			hh, g, f, e, d, c, b, a = g, f, e, tobit(d + t1), c, b, a, tobit(t1 + t2)
		end
		h[1], h[2], h[3], h[4] = tobit(h[1] + a), tobit(h[2] + b), tobit(h[3] + c), tobit(h[4] + d)
		h[5], h[6], h[7], h[8] = tobit(h[5] + e), tobit(h[6] + f), tobit(h[7] + g), tobit(h[8] + hh)
	end
	local out = {}
	for i = 1, 8 do
		local v = h[i]
		out[i] = string.char(band(rshift(v, 24), 255), band(rshift(v, 16), 255), band(rshift(v, 8), 255), band(v, 255))
	end
	return table.concat(out)
end

function M.to_hex(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

-- Random / PKCE / JWT -------------------------------------------------------------

local VERIFIER_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

--- Random string for PKCE verifiers. math.random is not a CSPRNG; the verifier only has to stay
-- unguessable for the few minutes of an OAuth round trip.
function M.random_string(length)
	local out = {}
	for i = 1, length do
		local n = math.random(1, #VERIFIER_CHARS)
		out[i] = VERIFIER_CHARS:sub(n, n)
	end
	return table.concat(out)
end

--- PKCE S256 challenge for a verifier
function M.pkce_challenge(verifier)
	return M.base64url_encode(M.sha256(verifier))
end

--- Decode a JWT payload (no signature verification). decode: JSON decoder
function M.jwt_payload(token, decode)
	if type(token) ~= "string" then
		return nil
	end
	local payload = token:match("^[^.]+%.([^.]+)%.")
	if not payload then
		return nil
	end
	local ok, claims = pcall(decode, M.base64_decode(payload))
	return ok and type(claims) == "table" and claims or nil
end

--- Shallow merge of several tables into a new one (later wins)
function M.merge(...)
	local out = {}
	for i = 1, select("#", ...) do
		local t = select(i, ...)
		if t then
			for k, v in pairs(t) do
				out[k] = v
			end
		end
	end
	return out
end

--- (opts, cb) argument normalization: allows f(cb) as well as f(opts, cb)
function M.opts_cb(opts, cb)
	if type(opts) == "function" then
		return {}, opts
	end
	return opts or {}, cb or function() end
end

return M
