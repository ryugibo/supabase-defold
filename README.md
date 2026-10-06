# supabase-defold

A [Supabase](https://supabase.com) client for the [Defold](https://defold.com) game engine, written in pure Lua.
It follows the official [supabase-js](https://github.com/supabase/supabase-js) API, adapted to Lua callbacks.

| Service | Module | What you get |
|---|---|---|
| Auth | `sb.auth` | Anonymous, email/phone + password, magic link / OTP, OAuth, SSO, native ID token, PKCE, MFA, identities, session persistence and auto refresh, admin API |
| Database | `sb:from()` / `sb.db` | Full PostgREST query builder: all filters, ordering, pagination, counts, upsert options, CSV/GeoJSON/EXPLAIN, custom schemas |
| RPC | `sb.rpc` / `sb.db:rpc()` | Function calls with POST/GET/HEAD, counts and filters on the result |
| Storage | `sb.storage` | Buckets, upload/download (binary safe), signed and public URLs, image transforms, list/move/copy/remove |
| Edge Functions | `sb.functions` | `invoke` with JSON or text bodies, custom methods and regions |
| Realtime | `sb:channel()` | Postgres changes, broadcast (WebSocket and REST), presence, auto reconnect |

- Works on every platform Defold supports. Only Realtime needs a native extension ([extension-websocket](https://github.com/defold/extension-websocket)).
- All Defold-specific APIs live in [`supabase/platform.lua`](supabase/platform.lua). HTTP, JSON, timers, storage and WebSocket can be replaced, so the library is unit-tested on plain LuaJIT.

## Installation

Add the library to your project's **dependencies** in `game.project` (Project → Dependencies):

```
https://github.com/ryugibo/supabase-defold/archive/refs/heads/main.zip
```

To use **Realtime**, also add extension-websocket. Defold does not fetch dependencies of dependencies, so list it yourself:

```
https://github.com/defold/extension-websocket/archive/refs/tags/4.2.4.zip
```

Pin a version tag in production (`.../archive/refs/tags/v0.2.0.zip`): the branch URL always fetches the latest
`main`. Then run **Project → Fetch Libraries**. At runtime the library version is `require("supabase.client").VERSION`. Only the `supabase/` folder is shared (`[library] include_dirs = supabase`).

## Supabase project setup

1. Create a project at [supabase.com](https://supabase.com/dashboard).
2. Copy the **Project URL** and the **publishable / anon key** from *Project Settings → API Keys* (and *Data API*).
   The publishable key is safe to ship in a client. Protect your data with Row Level Security (RLS), not by hiding the key.
   **Never** put the `service_role` / secret key in a game build.
3. Enable the sign-in methods you use under *Authentication → Sign In / Providers* (anonymous sign-ins, email, phone, OAuth providers, ...).
4. For OAuth, magic links and password recovery, add your app's redirect URL (e.g. `mygame://auth-callback`) to
   *Authentication → URL Configuration → Redirect URLs*.
5. For Realtime Postgres changes, add the tables to the `supabase_realtime` publication (*Database → Publications*, or
   `alter publication supabase_realtime add table my_table;`).
6. **(Optional) custom schema**: to keep an app's tables outside `public`, create the schema, grant access to the
   `anon` / `authenticated` roles, and add it to *Project Settings → Data API → Exposed schemas*. Then pass `schema = "my_app"` to `supabase.new`.

## Quick start

```lua
local supabase = require("supabase.client")

function init(self)
	self.sb = supabase.new({
		url = "https://YOUR-PROJECT.supabase.co",
		anon_key = "YOUR-PUBLISHABLE-KEY",
		persist_session = true, -- keep the user signed in across launches
	})
	-- or set these in game.project and call supabase.new() (see below)

	self.sb.auth:initialize(function(err, session)
		if session then
			return load_todos(self)
		end
		self.sb.auth:sign_in_anonymously(function(err)
			if not err then load_todos(self) end
		end)
	end)
end

function load_todos(self)
	self.sb:from("todos"):select("id,title,done"):eq("done", false):order("id", { ascending = false }):limit(20)
		:execute(function(err, rows)
			pprint(err, rows)
		end)
end
```

### Configure in game.project

The library ships an [`ext.properties`](supabase/ext.properties), so after **Fetch Libraries** the editor shows a
**Supabase** section in `game.project` (Runtime group). `supabase.new()` reads it for every option you don't pass:

```ini
[supabase]
url = https://YOUR-PROJECT.supabase.co
anon_key = YOUR-PUBLISHABLE-KEY
schema = public
persist_session = 1
auto_refresh_token = 1
flow_type = implicit
timeout = 15
```

```lua
local sb = supabase.new()                          -- everything from game.project
local sb = supabase.new({ schema = "other_app" })  -- explicit options win over game.project
```

To point development and release builds at different projects, keep the development values in `game.project` and
override them when bundling with `bob.jar --settings release.ini` (a file with its own `[supabase]` section), or pass
the values to `supabase.new` from code.

## Conventions

- All network calls are asynchronous and take a callback as the last argument: `callback(err, data, ...)`.
  Options tables are optional: `f(args, callback)` and `f(args, opts, callback)` both work.
- `err` is `nil` on success, otherwise a table:

  ```lua
  { status = 400, message = "...", code = "P0001", details = "...", hint = "...", body = <decoded response> }
  -- status 0 = network error
  ```

- Names follow supabase-js in `snake_case` (`signInWithOtp` → `sign_in_with_otp`). Lua keywords get a trailing
  underscore: `in_`, `is_`, `not_`, `or_`.
- Timers (auto refresh, Realtime heartbeats) and the WebSocket must be created from a script or gui_script context,
  e.g. in `init()`.
- Defold's native HTTP client sends request bodies only for POST, PUT and PATCH. The library avoids DELETE bodies
  (`storage:remove()` deletes one file per request), but `auth.admin:delete_user(id, true)` (soft delete) and
  `functions:invoke` with `method = "DELETE"` and a body only work on HTML5.

## Client

Options not given here fall back to the `[supabase]` section of `game.project` (url, anon_key, schema,
persist_session, auto_refresh_token, flow_type, timeout).

```lua
local sb = supabase.new({
	url = "...", anon_key = "...",
	schema = "public",            -- default PostgREST schema
	headers = {},                 -- extra headers on every request
	timeout = 15,                 -- HTTP timeout (seconds)
	auto_refresh_token = true,    -- refresh an expiring session before requests
	persist_session = false,      -- save the session with sys.save (see auth:initialize)
	storage = nil,                -- custom storage adapter { get(key), set(key, value), remove(key) }
	storage_key = nil,            -- key prefix in storage (default "sb-<project ref>-auth-token")
	flow_type = "implicit",       -- "implicit" or "pkce" for OAuth / magic links / SSO / recovery
	realtime = {                  -- see Realtime
		heartbeat_interval = 25, timeout = 10, reconnect_after = function(tries) return 5 end,
		params = {}, websocket_params = {}, logger = function(kind, msg, data) end,
	},
	transport = nil, codec = nil, timer = nil, open_url = nil, -- adapters, see supabase/platform.lua
})
```

| Function | Description |
|---|---|
| `sb:from(table)` | Query builder (same as `sb.db:from`) |
| `sb:schema(name)` | Query builder for another schema: `sb:schema("other"):from("t")` |
| `sb:channel(name, config?)` | Realtime channel |
| `sb:remove_channel(ch, cb?)`, `sb:remove_all_channels(cb?)`, `sb:get_channels()` | Realtime channel management |
| `sb:user_id()` | Current user id, or `nil` |
| `sb:access_token()` | Session access token, or the anon key when signed out |
| `sb:request(method, path, opts, cb)` | Low-level request to any Supabase endpoint. `opts = { query, body, raw_body, headers, raw_response, timeout }`, `cb(err, data, status, headers)` |
| `supabase.memory_storage()` | In-memory storage adapter |

## Auth — `sb.auth`

### Sign up and sign in

```lua
sb.auth:sign_in_anonymously(cb)                                    -- or ({ options = { data, captcha_token } }, cb)
sb.auth:sign_up("a@b.c", "password", cb)                           -- or ({ email | phone, password, options = { data, email_redirect_to, captcha_token, channel } }, cb)
sb.auth:sign_in_with_password("a@b.c", "password", cb)             -- or ({ email | phone, password, options = { captcha_token } }, cb)

-- Magic link / one-time password
sb.auth:sign_in_with_otp({ email = "a@b.c", options = { email_redirect_to = "mygame://auth-callback" } }, cb)
sb.auth:sign_in_with_otp({ phone = "+821012345678" }, cb)
sb.auth:verify_otp({ phone = "+821012345678", token = "123456", type = "sms" }, cb)  -- also { token_hash, type }
sb.auth:resend({ type = "signup", email = "a@b.c" }, cb)

-- Native ID token (Sign in with Apple, Google Sign-In through a native extension)
sb.auth:sign_in_with_id_token({ provider = "apple", token = id_token, nonce = raw_nonce }, cb)

-- OAuth / SSO open the browser (sys.open_url) and return to your app through a redirect URL
sb.auth:sign_in_with_oauth({ provider = "github", options = { redirect_to = "mygame://auth-callback", scopes = "read:user" } })
sb.auth:sign_in_with_sso({ domain = "company.com", options = { redirect_to = "mygame://auth-callback" } }, cb)

-- When the app is opened with the redirect URL (implicit #access_token=... or PKCE ?code=...):
sb.auth:get_session_from_url(url, function(err, session) end)
sb.auth:exchange_code_for_session(code, cb)                        -- PKCE only, if you parse the code yourself
```

Defold has no built-in API to receive the URL your app was opened with. Use
[extension-iac](https://github.com/defold/extension-iac) on iOS/Android (`iac.set_listener`), or read
`html5.run("location.href")` on HTML5. With `flow_type = "pkce"` the code verifier is kept in the configured storage,
so set `persist_session = true` (or a custom `storage`) if the app may be restarted during the OAuth round trip.

### Session

| Function | Description |
|---|---|
| `initialize(cb)` | Load the persisted session, refresh it if needed, emit `INITIAL_SESSION`. `cb(err, session \| nil)` |
| `get_session()` | Current session table (synchronous) |
| `restore(session, cb)` | Use a session you stored yourself (like `setSession`), refreshing it if it is about to expire |
| `set_session(session, event?)` | Replace the local session without a request (`event = false` to stay silent) |
| `refresh_session(cb, refresh_token?)` | Refresh now. Concurrent calls share one request. A rejected refresh token signs out |
| `needs_refresh()` | `true` when the access token expires within 60 s |
| `start_auto_refresh(interval?)` / `stop_auto_refresh()` | Timer-based refresh (requests also refresh on demand when `auto_refresh_token` is on) |
| `get_claims()` | Decoded JWT claims of the access token (signature not verified) |
| `sign_out(cb)` / `sign_out({ scope = "global" \| "local" \| "others" }, cb)` | End sessions and clear the local one (not for `"others"`) |
| `on_auth_state_change(fn)` | `fn(event, session)`; returns `{ unsubscribe = function }` |
| `on_change(fn)` | `fn(session)` on every change |

Events: `INITIAL_SESSION`, `SIGNED_IN`, `SIGNED_OUT`, `TOKEN_REFRESHED`, `USER_UPDATED`, `PASSWORD_RECOVERY`, `MFA_CHALLENGE_VERIFIED`.

### User

```lua
sb.auth:get_user(cb)                         -- or get_user(jwt, cb)
sb.auth:update_user({ email = "new@b.c" }, { email_redirect_to = "mygame://auth-callback" }, cb)
sb.auth:update_user({ password = "new", nonce = "123456" }, cb)   -- nonce from reauthenticate() if required
sb.auth:update_user({ data = { nickname = "baker" } }, cb)
sb.auth:reauthenticate(cb)
sb.auth:reset_password_for_email("a@b.c", { redirect_to = "mygame://reset" }, cb)
sb.auth:get_user_identities(cb)              -- cb(err, { identities })
sb.auth:link_identity({ provider = "google", options = { redirect_to = "mygame://auth-callback" } }, cb)
sb.auth:unlink_identity(identity, cb)
```

An anonymous user becomes a permanent account with `update_user({ email })`, then `update_user({ password })` once the email is confirmed.

### MFA — `sb.auth.mfa`

```lua
sb.auth.mfa:enroll({ factor_type = "totp", friendly_name = "Phone" }, cb)  -- data.totp.qr_code (SVG data URI), .secret, .uri
sb.auth.mfa:challenge({ factor_id = id }, cb)                             -- cb(err, { id = challenge_id, ... })
sb.auth.mfa:verify({ factor_id = id, challenge_id = cid, code = "123456" }, cb)
sb.auth.mfa:challenge_and_verify({ factor_id = id, code = "123456" }, cb)
sb.auth.mfa:unenroll({ factor_id = id }, cb)
sb.auth.mfa:list_factors(cb)                                              -- cb(err, { all, totp, phone })
local aal = sb.auth.mfa:get_authenticator_assurance_level()               -- { current_level, next_level, current_authentication_methods }
```

### Admin — `sb.auth.admin`

Requires a client created with the **secret / service_role key** as `anon_key`. Only use it in trusted server-side
tools, never in a shipped game.

`list_users({ page, per_page }, cb)`, `create_user(attrs, cb)`, `get_user_by_id(id, cb)`, `update_user_by_id(id, attrs, cb)`,
`delete_user(id, should_soft_delete?, cb)`, `invite_user_by_email(email, { data, redirect_to }, cb)`,
`generate_link({ type, email, password, new_email, options }, cb)`, `sign_out(jwt, scope?, cb)`,
`list_factors({ user_id }, cb)`, `delete_factor({ user_id, id }, cb)`.

## Database — `sb:from(table)`

```lua
sb:from("todos"):select("id,title,author:profiles(name)"):eq("done", false):execute(cb)
sb:from("todos"):insert({ title = "a" }):execute(cb)                                  -- returns the inserted rows
sb:from("todos"):insert({ { title = "a" }, { title = "b" } }, { default_to_null = false }):select("id"):execute(cb)
sb:from("profiles"):upsert({ id = uid, gold = 10 }, { on_conflict = "id" }):execute(cb)
sb:from("todos"):update({ done = true }):eq("id", 1):execute(cb)
sb:from("todos"):delete():in_("id", { 1, 2, 3 }):execute(cb)
sb:from("todos"):select("*", { count = "exact", head = true }):execute(function(err, _, res) print(res.count) end)
```

`execute(callback)` calls `callback(err, data, res)` with `res = { status, count, headers }`.

| Group | Methods |
|---|---|
| Query type | `select(columns?, { head, count })`, `insert(values, { count, default_to_null, returning })`, `upsert(values, { on_conflict, ignore_duplicates, count, default_to_null, returning })`, `update(values, { count, returning })`, `delete({ count, returning })` |
| Comparison | `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `like`, `ilike`, `is_`, `in_` |
| Pattern lists | `like_all_of`, `like_any_of`, `ilike_all_of`, `ilike_any_of` |
| Arrays / JSON / ranges | `contains`, `contained_by`, `overlaps`, `range_gt`, `range_gte`, `range_lt`, `range_lte`, `range_adjacent` |
| Full-text search | `text_search(column, query, { config, type = "plain" \| "phrase" \| "websearch" })` |
| Combinators | `match({ col = value })`, `not_(column, operator, value)`, `or_("a.eq.1,b.gt.2", { referenced_table })`, `filter(column, operator, value)` |
| Modifiers | `order(column, { ascending, nulls_first, referenced_table })`, `limit(n, { referenced_table })`, `range(from, to, { referenced_table })` |
| Result shape | `single()` (exactly one row), `maybe_single()` (zero or one), `csv()`, `geojson()`, `explain({ analyze, verbose, settings, buffers, wal, format })` |
| Other | `in_schema(name)`, `rollback()`, `max_affected(n)`, `returns_minimal()`, `header(name, value)`, `build()` |

`returning` defaults to `"representation"`, so mutations return the affected rows without calling `select()`.
Pass `{ returning = "minimal" }` to skip the response body.

## RPC

```lua
sb.rpc:call("add_numbers", { a = 2, b = 3 }, function(err, result) print(result) end)        -- POST
sb.db:rpc("search_items", { q = "cake" }):eq("in_stock", true):order("price"):limit(5):execute(cb)
sb.db:rpc("item_count", {}, { get = true }):execute(cb)                                      -- GET (read-only functions)
sb.db:rpc("list_items", {}, { head = true, count = "exact" }):execute(function(err, _, res) print(res.count) end)
sb:schema("other"):rpc("fn", {}):execute(cb)
```

## Storage — `sb.storage`

File contents are Lua strings (binary safe), e.g. from `sys.load_resource()` or `io.open(path, "rb"):read("*a")`.

```lua
local avatars = sb.storage:from("avatars")
avatars:upload(uid .. "/avatar.png", png_bytes, { content_type = "image/png", upsert = true }, cb)  -- cb(err, { path, id, full_path })
avatars:download(uid .. "/avatar.png", function(err, bytes) end)
avatars:download(uid .. "/avatar.png", { transform = { width = 128, height = 128, resize = "cover" } }, cb)
local url = avatars:get_public_url(uid .. "/avatar.png").public_url                                 -- public buckets
avatars:create_signed_url(uid .. "/avatar.png", 3600, function(err, data) print(data.signed_url) end)
```

| Group | Methods |
|---|---|
| Buckets | `list_buckets(cb)`, `get_bucket(id, cb)`, `create_bucket(id, { public, file_size_limit, allowed_mime_types }, cb)`, `update_bucket(id, opts, cb)`, `empty_bucket(id, cb)`, `delete_bucket(id, cb)` |
| Files (`sb.storage:from(bucket)`) | `upload(path, data, { content_type, cache_control, upsert, metadata }, cb)`, `update(...)`, `download(path, { transform }, cb)`, `info(path, cb)`, `exists(path, cb)`, `list(prefix, { limit, offset, sort_by, search }, cb)`, `move(from, to, { destination_bucket }, cb)`, `copy(from, to, opts, cb)`, `remove(paths, cb)` |
| URLs | `get_public_url(path, { download, transform })` (synchronous), `create_signed_url(path, expires_in, { download, transform }, cb)`, `create_signed_urls(paths, expires_in, opts, cb)`, `create_signed_upload_url(path, { upsert }, cb)`, `upload_to_signed_url(path, token, data, opts, cb)` |

## Edge Functions — `sb.functions`

```lua
sb.functions:invoke("hello", { body = { name = "Defold" } }, function(err, data, res)
	-- data: decoded JSON (or a string for other content types); on non-2xx, err.body holds the response
end)
sb.functions:invoke("report", { method = "GET", headers = { ["X-Custom"] = "1" }, region = "ap-northeast-2" }, cb)
```

## Realtime — `sb:channel(name, config?)`

Requires extension-websocket (see Installation). The socket connects when the first channel subscribes, sends
heartbeats, reconnects with backoff and rejoins channels. The access token follows auth changes automatically.

```lua
local channel = sb:channel("room-1", { broadcast = { self = true, ack = true }, presence = { key = sb:user_id() } })

channel:on("postgres_changes", { event = "INSERT", schema = "public", table = "messages", filter = "room_id=eq.1" },
	function(change)
		-- change = { eventType, schema, table, commit_timestamp, new, old, errors }
	end)
channel:on("broadcast", { event = "cursor" }, function(msg) print(msg.payload.x) end)
channel:on("presence", { event = "sync" }, function() pprint(channel:presence_state()) end)
channel:on("presence", { event = "join" }, function(e) print(e.key, #e.new_presences) end)
channel:on("presence", { event = "leave" }, function(e) print(e.key, #e.left_presences) end)

channel:subscribe(function(status, err)
	-- "SUBSCRIBED" | "CHANNEL_ERROR" | "TIMED_OUT" | "CLOSED"
	if status == "SUBSCRIBED" then
		channel:track({ online_at = os.time() })
		channel:send({ type = "broadcast", event = "cursor", payload = { x = 10 } }, function(result) end)
	end
end)

sb:remove_channel(channel)
```

| Function | Description |
|---|---|
| `channel:on(type, filter, fn)` | `postgres_changes`, `broadcast`, `presence` (`sync` / `join` / `leave`), `system` |
| `channel:subscribe(cb, timeout?)` / `channel:unsubscribe(cb)` | Join / leave |
| `channel:send({ type = "broadcast", event, payload }, cb)` | Over the socket when joined, otherwise through the REST broadcast API. `cb("ok" \| "error" \| "timed out")` |
| `channel:http_send(event, payload, cb)` | Broadcast through REST only (no WebSocket needed) |
| `channel:track(state, cb)` / `channel:untrack(cb)` / `channel:presence_state()` | Presence |
| `sb.realtime:connect()` / `disconnect()` / `is_connected()` / `set_auth(token)` | Socket control |

`SUBSCRIBED` means the channel is joined, but Postgres changes start flowing only after the server sends a `system`
message with `extension = "postgres_changes"` and `status = "ok"` ("Subscribed to PostgreSQL"). Wait for it when the
first change matters:

```lua
channel:on("system", {}, function(msg)
	if msg.extension == "postgres_changes" and msg.status == "ok" then
		-- changes from now on are delivered
	end
end)
```

Private channels (`config.private = true`) use Realtime Authorization policies on `realtime.messages`.

## Feature coverage

Compared with supabase-js v2. ✅ supported · ⚠️ supported with differences · ❌ not available · ➖ not applicable

### Auth

| Feature | supabase-js | Status |
|---|---|---|
| Anonymous sign-in | `signInAnonymously` | ✅ |
| Email / phone + password | `signUp`, `signInWithPassword` | ✅ |
| Magic link / OTP | `signInWithOtp`, `verifyOtp`, `resend` | ✅ |
| OAuth | `signInWithOAuth` | ✅ opens the browser; you pass the redirect URL to `get_session_from_url` (see the deep-link note above) |
| SSO (SAML) | `signInWithSSO` | ✅ |
| Native ID token | `signInWithIdToken` | ✅ |
| PKCE flow | `flowType: 'pkce'`, `exchangeCodeForSession` | ✅ |
| Implicit redirect handling | `detectSessionInUrl` | ⚠️ manual: call `get_session_from_url(url)` |
| Session get / set / refresh | `getSession`, `setSession`, `refreshSession` | ✅ (`get_session`, `restore`, `refresh_session`) |
| Persist session | `persistSession`, `storage` | ✅ `persist_session = true` (sys.save) or a custom adapter |
| Auto refresh | `autoRefreshToken` | ✅ on demand before requests, plus optional `start_auto_refresh()` timer |
| Auth state events | `onAuthStateChange` | ✅ |
| User / identities | `getUser`, `updateUser`, `getUserIdentities`, `linkIdentity`, `unlinkIdentity` | ✅ |
| Password recovery, reauthentication | `resetPasswordForEmail`, `reauthenticate` | ✅ |
| Sign out scopes | `signOut({ scope })` | ✅ |
| MFA (TOTP, phone) | `mfa.*` | ✅ |
| MFA WebAuthn | `mfa.webauthn` | ❌ needs platform passkey APIs |
| JWT claims | `getClaims` | ⚠️ decoded locally without verifying the signature |
| Admin API | `auth.admin.*` | ✅ users, invites, links, sign-out, factors (secret key, server-side only) |
| Web3 wallet sign-in | `signInWithWeb3` | ❌ |
| Multi-tab session sync / locks | `BroadcastChannel`, `lock` | ➖ not applicable to games |

### Database & RPC

| Feature | supabase-js | Status |
|---|---|---|
| select / insert / upsert / update / delete | ✅ | ✅ (mutations return rows by default; `returning = "minimal"` to opt out) |
| All filter operators | `eq` ... `textSearch`, `match`, `not`, `or`, `filter` | ✅ (`in_`, `is_`, `not_`, `or_`) |
| Ordering, limit, range, referenced tables | `order`, `limit`, `range` | ✅ |
| Count, head | `{ count, head }` | ✅ `res.count` |
| single / maybeSingle | ✅ | ✅ |
| CSV, GeoJSON, EXPLAIN | `csv`, `geojson`, `explain` | ✅ |
| Rollback, max affected | `rollback`, `maxAffected` | ✅ |
| Custom schema | `schema()` | ✅ client-wide, per builder and per query |
| RPC with GET/HEAD/count/filters | `rpc(fn, args, { get, head, count })` | ✅ `sb.db:rpc` |
| Abort signal | `abortSignal` | ❌ Defold's HTTP requests cannot be cancelled (use `timeout`) |
| Generated TypeScript types | `Database` generics | ➖ not applicable to Lua |

### Storage

| Feature | supabase-js | Status |
|---|---|---|
| Bucket management | `listBuckets` ... `deleteBucket` | ✅ |
| Upload / update / download | `upload`, `update`, `download` | ✅ binary-safe strings |
| Image transformations | `transform` | ✅ |
| Public / signed / signed upload URLs | `getPublicUrl`, `createSignedUrl(s)`, `createSignedUploadUrl`, `uploadToSignedUrl` | ✅ |
| list / move / copy / remove / info / exists | ✅ | ✅ (`remove` sends one DELETE per file) |
| Resumable uploads (TUS) | via tus-js-client | ❌ |
| Vector / analytics buckets | `storage.vectors`, `storage.analytics` | ❌ |

### Edge Functions & Realtime

| Feature | supabase-js | Status |
|---|---|---|
| Invoke functions (JSON/text, method, headers, region) | `functions.invoke` | ✅ |
| Binary request bodies / streamed responses | `Blob`, `ReadableStream` | ⚠️ string bodies only, responses are buffered |
| Postgres changes | `on('postgres_changes')` | ✅ |
| Broadcast (WebSocket + REST, ack, self) | `on('broadcast')`, `send`, `httpSend` | ✅ |
| Presence | `track`, `untrack`, `presenceState` | ✅ |
| Reconnect, heartbeat, token updates | ✅ | ✅ |
| Private channels | `config.private` | ✅ |
| Realtime protocol v2 (binary) | `vsn=2.0.0` | ❌ uses the JSON protocol `vsn=1.0.0` |

## Testing

### Unit tests (no network, no Defold)

Every module is tested with fake HTTP, timer and WebSocket adapters on plain LuaJIT:

```sh
luajit tests/run.lua tests/test_*.lua
# or: syntax check + tests (+ editor compile when the Defold editor is open)
tools/verify.sh            # add --no-compile to skip the editor step
```

If `luajit` is not on your `PATH`, `tools/verify.sh` uses the copy that ships with the Defold editor.

### Live smoke test against a real project

This repository is also a runnable Defold project. [`example/smoke_test.script`](example/smoke_test.script) signs in
anonymously and runs every service: auth, insert/select/update/delete with counts and filters, RPC, a custom schema,
Realtime (Postgres changes, broadcast with ack, presence), Storage (upload, download, list, signed URL, remove),
Edge Functions, session refresh and sign-out.

Everything the test needs on the server lives in [`example/supabase/`](example/supabase), in the layout the official
clients use for their integration tests:

| Path | Contents |
|---|---|
| `config.toml` | Auth and API settings (anonymous sign-ins on, `smoke_custom` exposed in the Data API) |
| `migrations/` | `todos` table with RLS, Realtime publication, `add_numbers()`, private `smoke-test` bucket, `smoke_custom` schema |
| `functions/hello/` | Edge Function used by the `functions.invoke` step |

It sits under `example/` rather than the repo root because `supabase/` is the library folder shipped to users, so every
CLI command runs with `--workdir example`. [`tools/setup_supabase.sh`](tools/setup_supabase.sh) wraps them.

**Requirements:** [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started)
(`brew install supabase/tap/supabase`). Docker is only needed for the local stack.

#### Against a hosted project (CLI only)

Use a **dedicated test project**: users, buckets, functions, rate limits and the migration history are per project,
and `config push` overwrites the project's auth settings.

```sh
supabase login                                   # once, opens the browser
tools/setup_supabase.sh link <project-ref>       # once, asks for the database password
tools/setup_supabase.sh remote                   # db push + config push + functions deploy, fills game.project
```

`db push` only applies migrations that are not yet recorded in the project's `supabase_migrations.schema_migrations`
table, so `remote` can be re-run after adding migrations. Migrations are forward-only: change the schema with a new
migration file (`supabase --workdir example migration new <name>`), never by editing an applied one or through the
dashboard.

#### Against a local stack (Docker)

```sh
tools/setup_supabase.sh local    # supabase start: Postgres, Auth, PostgREST, Storage, Realtime, Functions on 127.0.0.1:54321
tools/setup_supabase.sh reset    # recreate the database from the migrations
tools/setup_supabase.sh stop
```

#### Run it

`remote` and `local` write the URL and publishable key into `game.project` (the smoke test calls `supabase.new()`
with no options). That is a local change, so don't commit it. You can also fill the values by hand:

```ini
[supabase]
url = https://YOUR-PROJECT.supabase.co
anon_key = YOUR-PUBLISHABLE-KEY

[smoke_test]
function_name = hello
```

Open the project in the Defold editor, run **Project → Fetch Libraries**, then **Project → Build**. Each step prints
`PASS` / `FAIL` / `SKIP` to the console and on screen, ending with a summary line. The functions step is skipped when
`[smoke_test] function_name` is empty. Each run creates one anonymous user; on a hosted project, clean them up under
*Authentication → Users*.

## Project layout

```
supabase/              the library (shared through include_dirs)
  client.lua           client, HTTP layer
  auth.lua             Auth (GoTrue) incl. MFA and admin
  db.lua               PostgREST query builder
  rpc.lua              Postgres function calls
  storage.lua          Storage
  functions.lua        Edge Functions
  realtime.lua         Realtime (Phoenix channels)
  util.lua             URL, base64, SHA-256 (PKCE), JWT helpers
  platform.lua         Defold adapters (http, json, timer, sys.save, websocket, game.project config)
  ext.properties       Supabase section of the game.project editor form
example/               live smoke test (bootstrap collection)
  supabase/            Supabase CLI project for the smoke test: config.toml, migrations, functions
tests/                 LuaJIT unit tests, fakes and runner
tools/verify.sh        syntax check + unit tests + editor compile
tools/setup_supabase.sh  link / push / start the smoke test's Supabase project
```

## License

[MIT](LICENSE)
