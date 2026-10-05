-- Test doubles: fake HTTP server, timers, WebSocket and codecs
local supabase = require("supabase.client")
local util = require("supabase.util")

local H = {}

-- Tables pass through unchanged, so tests can inspect request bodies directly.
-- Strings registered in H.decoded (e.g. JWT payloads) decode to their table.
H.decoded = {}
H.codec = {
	encode = function(t) return t end,
	decode = function(s)
		if type(s) == "string" and H.decoded[s] then
			return H.decoded[s]
		end
		return s
	end,
}

--- Minimal JSON encoder for flat values (used where the library embeds JSON in URLs)
function H.json(v)
	if type(v) == "table" then
		local keys = {}
		for k in pairs(v) do
			keys[#keys + 1] = k
		end
		table.sort(keys)
		local parts = {}
		for _, k in ipairs(keys) do
			parts[#parts + 1] = string.format("%q:%s", k, H.json(v[k]))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

--- Unsigned JWT whose payload decodes to `claims` through H.codec
function H.jwt(claims)
	local payload = H.json(claims)
	H.decoded[payload] = claims
	return "eyJhbGciOiJIUzI1NiJ9." .. util.base64url_encode(payload) .. ".sig"
end

--- Fake server: records requests and replies with routes[method .. " " .. path]
-- A route is { status, body, headers } or fn(entry) -> route. Unknown routes reply 404.
function H.fake(routes, opts)
	local log = {}
	local transport = function(url, method, headers, body, callback)
		local path = url:gsub("^https://test%.supabase%.co", ""):gsub("%?.*$", "")
		local entry = { url = url, method = method, headers = headers, body = body, path = path,
			query = util.parse_query(url:match("%?(.*)$")) }
		log[#log + 1] = entry
		local route = routes[method .. " " .. path] or { 404, { message = "not found" } }
		if type(route) == "function" then
			route = route(entry)
		end
		callback(route[1], route[2], route[3] or {})
	end
	local options = { url = "https://test.supabase.co/", anon_key = "ANON", transport = transport, codec = H.codec,
		timer = H.fake_timer(), open_url = function() end }
	for k, v in pairs(opts or {}) do
		options[k] = v
	end
	return supabase.new(options), log
end

--- Manually driven timers. fire() runs every due callback once (repeating timers stay scheduled)
function H.fake_timer()
	local t = { pending = {}, next_id = 0 }
	t.delay = function(seconds, repeating, fn)
		t.next_id = t.next_id + 1
		t.pending[t.next_id] = { seconds = seconds, repeating = repeating, fn = fn }
		return t.next_id
	end
	t.cancel = function(id)
		t.pending[id] = nil
	end
	--- Run timers (optionally only those with the given delay)
	t.fire = function(seconds)
		local ids = {}
		for id in pairs(t.pending) do
			ids[#ids + 1] = id
		end
		table.sort(ids)
		for _, id in ipairs(ids) do
			local entry = t.pending[id]
			if entry and (seconds == nil or entry.seconds == seconds) then
				if not entry.repeating then
					t.pending[id] = nil
				end
				entry.fn()
			end
		end
	end
	return t
end

--- Fake WebSocket adapter. sent: list of decoded messages
function H.fake_socket()
	local s = { sent = {}, connects = 0, closed = 0 }
	s.connect = function(url, on_event)
		s.url = url
		s.connects = s.connects + 1
		s.on_event = on_event
		return { id = s.connects }
	end
	s.send = function(_, msg)
		s.sent[#s.sent + 1] = msg
	end
	s.close = function()
		s.closed = s.closed + 1
	end
	s.open = function() s.on_event("open") end
	s.receive = function(msg) s.on_event("message", msg) end
	s.drop = function() s.on_event("close", {}) end
	--- Last sent message with the given event (and topic)
	s.last = function(event, topic)
		for i = #s.sent, 1, -1 do
			local m = s.sent[i]
			if m.event == event and (topic == nil or m.topic == topic) then
				return m
			end
		end
	end
	return s
end

return H
