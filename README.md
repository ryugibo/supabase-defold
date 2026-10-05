# supabase-defold

A lightweight [Supabase](https://supabase.com) client for the [Defold](https://defold.com) game engine, written in pure Lua.

- **Auth** (GoTrue): anonymous / email+password sign-in, session refresh & restore, user update, sign-out
- **Database** (PostgREST): chainable query builder for select / insert / upsert / update / delete with filters
- **RPC**: call Postgres functions
- Custom schema support (`Accept-Profile` / `Content-Profile`), so several apps can share one Supabase project
- No native code: works on every platform Defold supports (iOS, Android, HTML5, desktop)
- Pluggable HTTP transport and JSON codec, so the library is unit-tested with plain LuaJIT

## Installation

Add the library to your project's **dependencies** in `game.project` (Project → Dependencies):

```
https://github.com/ryugibo/supabase-defold/archive/refs/heads/main.zip
```

Pin a tag or commit in production (e.g. `.../archive/refs/tags/v0.1.0.zip`). Then run **Project → Fetch Libraries**.

Only the `supabase/` folder is shared (`[library] include_dirs = supabase`).

## Supabase project setup

1. Create a project at [supabase.com](https://supabase.com/dashboard).
2. Copy the **Project URL** and the **publishable / anon key** from *Project Settings → API Keys* (and *Data API*).
   The publishable key is safe to ship in a client. Protect your data with Row Level Security (RLS), not by hiding the key.
   **Never** put the `service_role` / secret key in a game build.
3. If you use anonymous sign-in, enable it in *Authentication → Sign In / Providers → Allow anonymous sign-ins*.
4. If you use email sign-up, decide whether *Confirm email* is on. When it is, `sign_up` returns the user without a session until the email is confirmed.
5. **(Optional) custom schema**: to keep an app's tables outside `public`, create the schema, grant access to the
   `anon` / `authenticated` roles, and add it to *Project Settings → Data API → Exposed schemas*. Then pass `schema = "my_app"` to `supabase.new`.

## Quick start

```lua
local supabase = require("supabase.client")

local sb = supabase.new({
	url = "https://YOUR-PROJECT.supabase.co",
	anon_key = "YOUR-PUBLISHABLE-KEY",
	-- schema = "my_app",       -- optional, defaults to public
})

sb.auth:sign_in_anonymously(function(err, session)
	if err then
		print("sign-in failed", err.status, err.message)
		return
	end
	print("user id", sb:user_id())

	sb.db:from("todos"):select("id,title,done"):eq("done", false):order("id", false):limit(20)
		:execute(function(err, rows)
			pprint(err, rows)
		end)
end)
```

Configuration values can live in `game.project` and be read with `sys.get_config_string`:

```ini
[supabase]
url = https://YOUR-PROJECT.supabase.co
anon_key = YOUR-PUBLISHABLE-KEY
schema =
```

```lua
local sb = supabase.new({
	url = sys.get_config_string("supabase.url"),
	anon_key = sys.get_config_string("supabase.anon_key"),
})
```

## API

All calls are asynchronous and take a Node-style callback. On failure `err` is a table:

```lua
{ status = 400, message = "...", code = "P0001", details = "..." }  -- status 0 = network error
```

### Client

| Function | Description |
|---|---|
| `supabase.new({ url, anon_key, schema?, transport?, codec? })` | Create a client. `transport` / `codec` replace `http.request` / `json` (tests, other runtimes). |
| `sb:user_id()` | Current user id, or `nil`. |
| `sb:access_token()` | Session access token, or the anon key when signed out. |
| `sb:request(method, path, opts, callback)` | Low-level authenticated request to any Supabase endpoint. `opts = { query, body, headers }`. `callback(err, data, status, headers)`. |
| `supabase.urlencode(s)`, `supabase.build_query(t)` | URL helpers. |

### Auth — `sb.auth`

| Function | Endpoint |
|---|---|
| `sign_in_anonymously(callback, metadata?)` | `POST /auth/v1/signup` |
| `sign_up(email, password, callback)` | `POST /auth/v1/signup` |
| `sign_in_with_password(email, password, callback)` | `POST /auth/v1/token?grant_type=password` |
| `refresh_session(callback, refresh_token?)` | `POST /auth/v1/token?grant_type=refresh_token` |
| `restore(session, callback)` | Restore a saved session, refreshing first if it expires within 60 s |
| `get_user(callback)` | `GET /auth/v1/user` |
| `update_user({ email?, password?, data? }, callback)` | `PUT /auth/v1/user` (e.g. upgrade an anonymous user to an email account) |
| `sign_out(callback?)` | `POST /auth/v1/logout`, then clears the local session |
| `get_session()` / `set_session(session)` | Read / replace the in-memory session |
| `needs_refresh()` | `true` when the access token expires within 60 s |
| `on_change(fn)` | `fn(session_or_nil)` after every sign-in, refresh and sign-out |

**Persisting the session**: the library keeps the session in memory only. Save it yourself and restore it on startup:

```lua
local path = sys.get_save_file("my_game", "session")

sb.auth:on_change(function(session)
	sys.save(path, session and {
		access_token = session.access_token,
		refresh_token = session.refresh_token,
		expires_at = session.expires_at,
	} or {})
end)

local saved = sys.load(path)
if saved.refresh_token then
	sb.auth:restore(saved, function(err)
		if err then sb.auth:sign_in_anonymously(on_ready) else on_ready() end
	end)
else
	sb.auth:sign_in_anonymously(on_ready)
end
```

Tokens are not refreshed automatically. Call `needs_refresh()` / `refresh_session()` before requests in long sessions,
or refresh on a timer.

### Database — `sb.db:from(table)`

```lua
sb.db:from("todos"):select("*"):eq("user_id", sb:user_id()):execute(cb)       -- GET
sb.db:from("todos"):insert({ title = "a" }):execute(cb)                        -- POST, returns rows
sb.db:from("profiles"):upsert({ id = uid, gold = 10 }, "id"):execute(cb)       -- POST + merge-duplicates
sb.db:from("todos"):update({ done = true }):eq("id", 1):execute(cb)            -- PATCH
sb.db:from("todos"):delete():in_("id", { 1, 2, 3 }):execute(cb)                -- DELETE
sb.db:from("settings"):in_schema("public"):select():single():execute(cb)       -- per-query schema
```

| Method | PostgREST |
|---|---|
| `select(columns?)` | `select=` (default `*`, embedded resources work via the column string, e.g. `"id,author(name)"`) |
| `insert(rows)` / `upsert(rows, on_conflict?)` / `update(values)` / `delete()` | `POST` / `POST` + `Prefer: resolution=merge-duplicates` / `PATCH` / `DELETE`, all with `Prefer: return=representation` |
| `eq` `neq` `gt` `gte` `lt` `lte` `(column, value)` | `column=op.value` |
| `in_(column, values)` | `column=in.(a,b,c)` |
| `order(column, ascending?)` | `order=column.asc\|desc` (call several times for multiple columns) |
| `limit(n)` | `limit=n` |
| `single()` | Returns the first row instead of an array (`nil` when there are no rows, like `maybeSingle()`) |
| `in_schema(schema)` | Overrides the client schema for this query |
| `execute(callback)` | Sends the request. `callback(err, data, status)` |
| `build()` | Returns `path, params` without sending (debugging) |

### RPC — `sb.rpc`

```lua
sb.rpc:call("add_numbers", { a = 2, b = 3 }, function(err, result) print(result) end)  -- 5
sb.rpc:call("other_fn", {}, cb, "other_schema")                                         -- per-call schema
```

## Feature coverage

Compared with the official clients ([supabase-js](https://github.com/supabase/supabase-js), [supabase-py](https://github.com/supabase/supabase-py), [supabase-swift](https://github.com/supabase/supabase-swift)):

✅ supported · ⚠️ partial / different · ❌ not implemented (use `sb:request` as an escape hatch)

### Auth

| Feature | supabase-js equivalent | Status |
|---|---|---|
| Anonymous sign-in | `signInAnonymously` | ✅ |
| Email + password sign-up | `signUp` | ✅ (no `options.emailRedirectTo` / `captchaToken`) |
| Email + password sign-in | `signInWithPassword` | ✅ email only |
| Phone + password sign-up / sign-in | `signUp` / `signInWithPassword` (phone) | ❌ |
| Refresh session | `refreshSession` | ✅ |
| Get / set session | `getSession` / `setSession` | ⚠️ local only, `set_session` does not validate the token with the server |
| Get user | `getUser` | ✅ |
| Update user (email, password, metadata) | `updateUser` | ✅ |
| Sign out | `signOut` | ⚠️ current session only (no `scope` option) |
| Auth state listener | `onAuthStateChange` | ⚠️ `on_change(session)`, no event names, no unsubscribe |
| Session persistence | `persistSession` storage | ❌ do it in `on_change` (see above) |
| Automatic token refresh | `autoRefreshToken` | ❌ `restore` / `needs_refresh` / `refresh_session` are provided |
| Magic link / email OTP / SMS OTP | `signInWithOtp`, `verifyOtp`, `resend` | ❌ |
| OAuth providers / SSO / PKCE | `signInWithOAuth`, `signInWithSSO`, `exchangeCodeForSession` | ❌ |
| Native ID token (Apple, Google) | `signInWithIdToken` | ❌ |
| Password recovery | `resetPasswordForEmail` | ❌ |
| Identity linking | `linkIdentity`, `unlinkIdentity` | ❌ |
| MFA | `auth.mfa.*` | ❌ |
| Admin API | `auth.admin.*` | ❌ (needs the secret key, which must not ship in a client) |

### Database (PostgREST)

| Feature | supabase-js equivalent | Status |
|---|---|---|
| Select columns (incl. embedded resources) | `select()` | ✅ |
| Insert / update / delete | `insert` / `update` / `delete` | ✅ always returns the affected rows |
| Upsert with conflict target | `upsert({ onConflict })` | ✅ (no `ignoreDuplicates`, `defaultToNull`) |
| `eq` `neq` `gt` `gte` `lt` `lte` `in` | same | ✅ |
| `like` `ilike` `is` `match` `not` `or` `filter` | same | ❌ |
| Array / range / JSON / full-text operators (`contains`, `overlaps`, `textSearch`, ...) | same | ❌ |
| Order / limit | `order` / `limit` | ✅ (no `nullsFirst`, `referencedTable`) |
| Pagination | `range` / offset | ❌ |
| Single row | `single` / `maybeSingle` | ⚠️ `single()` behaves like `maybeSingle()` (returns the first row, `nil` if none) |
| Row count / head requests | `{ count, head }` | ❌ |
| Return options | `returning: minimal` | ❌ representation only |
| CSV / GeoJSON / explain | `csv()`, `geojson()`, `explain()` | ❌ |
| Custom schema | `schema()` / `db.schema` option | ✅ client-wide and per query |

### RPC

| Feature | supabase-js equivalent | Status |
|---|---|---|
| Call function with arguments | `rpc(fn, args)` | ✅ (POST) |
| Custom schema | `schema().rpc()` | ✅ |
| Read-only GET call / `head` / `count` | `rpc(fn, args, { get, head, count })` | ❌ |
| Filters / modifiers on results | `rpc().eq()...` | ❌ |

### Other services

| Service | supabase-js | Status |
|---|---|---|
| Storage (buckets, upload, download, signed URLs) | `storage` | ❌ |
| Realtime (Postgres changes, broadcast, presence) | `channel()` | ❌ (needs WebSockets, e.g. [extension-websocket](https://github.com/defold/extension-websocket)) |
| Edge Functions | `functions.invoke` | ❌ but can be called with `sb:request("POST", "/functions/v1/<name>", { body = ... }, cb)` |

## Testing

### Unit tests (no network, no Defold)

The test suite uses a fake transport and runs on plain LuaJIT:

```sh
luajit tests/run.lua tests/test_*.lua
# or: syntax check + tests (+ editor compile when the Defold editor is open)
tools/verify.sh            # add --no-compile to skip the editor step
```

If `luajit` is not on your `PATH`, `tools/verify.sh` uses the copy that ships with the Defold editor.

### Live smoke test against a real project

This repository is also a runnable Defold project. `example/smoke_test.script` signs in anonymously and exercises
insert / select / update / RPC / delete / refresh / sign-out against your Supabase project:

1. Enable anonymous sign-ins (see *Supabase project setup*).
2. Run [`example/setup.sql`](example/setup.sql) in the dashboard's SQL Editor. It creates a `public.todos` table with RLS
   (each user only sees their own rows) and a `public.add_numbers(a, b)` function.
3. Fill in the `[supabase]` section of this repo's `game.project`:
   ```ini
   [supabase]
   url = https://YOUR-PROJECT.supabase.co
   anon_key = YOUR-PUBLISHABLE-KEY
   schema =
   ```
   If you set a custom `schema`, create `todos` / `add_numbers` in that schema instead of `public` and expose it in the Data API.
4. Open the project in the Defold editor and choose **Project → Build**. Each step prints `PASS` / `FAIL` to the console
   and is drawn on screen. The script finishes with `Done: 9/9 steps passed`.

Each run creates one anonymous user. You can clean them up under *Authentication → Users*.

## Project layout

```
supabase/          the library (shared through include_dirs)
  client.lua       client, HTTP layer, URL helpers
  auth.lua         Auth (GoTrue)
  db.lua           PostgREST query builder
  rpc.lua          Postgres function calls
example/           live smoke test (bootstrap collection) + setup.sql
tests/             LuaJIT unit tests and runner
tools/verify.sh    syntax check + unit tests + editor compile
```

## License

Add a license before publishing (MIT is common for Defold libraries).
