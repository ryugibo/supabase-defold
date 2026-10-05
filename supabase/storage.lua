-- Supabase Storage (storage-js equivalent): buckets and files.
--   sb.storage:from("avatars"):upload("user1/avatar.png", png_bytes, { content_type = "image/png", upsert = true }, cb)
--   local url = sb.storage:from("avatars"):get_public_url("user1/avatar.png").public_url
-- File data is a Lua string (binary safe), e.g. from sys.load_resource or io.open(path, "rb"):read("*a").
local util = require("supabase.util")

local M = {}

local Storage = {}
Storage.__index = Storage

local Bucket = {}
Bucket.__index = Bucket

local function noop() end

function M.new(client)
	return setmetatable({ client = client }, Storage)
end

local function request(client, method, path, opts, callback)
	client:request(method, "/storage/v1" .. path, opts, callback or noop)
end

-- Buckets --------------------------------------------------------------------------

function Storage:list_buckets(callback)
	request(self.client, "GET", "/bucket", nil, callback)
end

function Storage:get_bucket(id, callback)
	request(self.client, "GET", "/bucket/" .. util.urlencode(id), nil, callback)
end

local function bucket_body(id, opts)
	return {
		id = id,
		name = id,
		public = opts.public == true,
		file_size_limit = opts.file_size_limit,
		allowed_mime_types = opts.allowed_mime_types,
	}
end

--- opts: { public = false, file_size_limit = number | "10MB", allowed_mime_types = { "image/png" } }
function Storage:create_bucket(id, a, b)
	local opts, callback = util.opts_cb(a, b)
	request(self.client, "POST", "/bucket", { body = bucket_body(id, opts) }, callback)
end

function Storage:update_bucket(id, opts, callback)
	request(self.client, "PUT", "/bucket/" .. util.urlencode(id), { body = bucket_body(id, opts or {}) }, callback)
end

function Storage:empty_bucket(id, callback)
	request(self.client, "POST", "/bucket/" .. util.urlencode(id) .. "/empty", { body = {} }, callback)
end

function Storage:delete_bucket(id, callback)
	request(self.client, "DELETE", "/bucket/" .. util.urlencode(id), nil, callback)
end

--- File API for a bucket
function Storage:from(bucket_id)
	return setmetatable({ client = self.client, bucket = bucket_id }, Bucket)
end

-- Files ----------------------------------------------------------------------------

local function object_path(self, path)
	return util.urlencode(self.bucket) .. "/" .. util.encode_path(path)
end

local function transform_query(transform, query)
	query = query or {}
	if transform then
		for _, key in ipairs({ "width", "height", "resize", "format", "quality" }) do
			if transform[key] ~= nil then
				query[#query + 1] = { key, transform[key] }
			end
		end
	end
	return query
end

local function download_param(download)
	if download == true then
		return "download="
	elseif type(download) == "string" then
		return "download=" .. util.urlencode(download)
	end
	return nil
end

local function append_param(url, param)
	if not param then
		return url
	end
	return url .. (url:find("?", 1, true) and "&" or "?") .. param
end

local function upload_headers(self, opts)
	local headers = {
		["Content-Type"] = opts.content_type or "application/octet-stream",
		["cache-control"] = "max-age=" .. tostring(opts.cache_control or 3600),
		["x-upsert"] = opts.upsert and "true" or "false",
	}
	if opts.metadata then
		headers["x-metadata"] = util.base64_encode(self.client.codec.encode(opts.metadata))
	end
	return headers
end

local function upload(self, method, path, data, opts, callback)
	request(self.client, method, "/object/" .. object_path(self, path), {
		raw_body = data,
		headers = upload_headers(self, opts),
	}, function(err, result)
		if err then
			return callback(err, nil)
		end
		callback(nil, { path = path, id = result and result.Id, full_path = result and result.Key })
	end)
end

--- upload(path, data, opts?, callback). opts: { content_type, cache_control = 3600, upsert = false, metadata }
-- callback(err, { path, id, full_path })
function Bucket:upload(path, data, a, b)
	local opts, callback = util.opts_cb(a, b)
	upload(self, "POST", path, data, opts, callback)
end

--- Replace an existing file. Same arguments as upload
function Bucket:update(path, data, a, b)
	local opts, callback = util.opts_cb(a, b)
	upload(self, "PUT", path, data, opts, callback)
end

--- opts: { upsert }. callback(err, { signed_url, token, path })
function Bucket:create_signed_upload_url(path, a, b)
	local opts, callback = util.opts_cb(a, b)
	request(self.client, "POST", "/object/upload/sign/" .. object_path(self, path), {
		body = {},
		headers = opts.upsert and { ["x-upsert"] = "true" } or nil,
	}, function(err, result)
		if err then
			return callback(err, nil)
		end
		local signed_url = self.client.url .. "/storage/v1" .. result.url
		local token = util.parse_query(result.url:match("%?(.*)$")).token
		callback(nil, { signed_url = signed_url, token = token, path = path })
	end)
end

--- Upload with a token from create_signed_upload_url (no session needed). opts like upload
function Bucket:upload_to_signed_url(path, token, data, a, b)
	local opts, callback = util.opts_cb(a, b)
	request(self.client, "PUT", "/object/upload/sign/" .. object_path(self, path), {
		query = { { "token", token } },
		raw_body = data,
		headers = upload_headers(self, opts),
	}, function(err, result)
		if err then
			return callback(err, nil)
		end
		callback(nil, { path = path, full_path = result and result.Key })
	end)
end

--- download(path, opts?, callback). opts: { transform = { width, height, resize, format, quality } }
-- callback(err, bytes) where bytes is a Lua string
function Bucket:download(path, a, b)
	local opts, callback = util.opts_cb(a, b)
	local base = opts.transform and "/render/image/authenticated/" or "/object/"
	request(self.client, "GET", base .. object_path(self, path), {
		query = transform_query(opts.transform),
		raw_response = true,
		headers = { Accept = "*/*" },
	}, callback)
end

--- File metadata. callback(err, info)
function Bucket:info(path, callback)
	request(self.client, "GET", "/object/info/" .. object_path(self, path), nil, callback)
end

--- callback(err, exists_bool)
function Bucket:exists(path, callback)
	callback = callback or noop
	request(self.client, "HEAD", "/object/" .. object_path(self, path), nil, function(err)
		if err and (err.status == 400 or err.status == 404) then
			return callback(nil, false)
		end
		callback(err, not err)
	end)
end

--- Synchronous URL for a public bucket. opts: { download = true | "filename", transform }
-- Returns { public_url = "..." }
function Bucket:get_public_url(path, opts)
	opts = opts or {}
	local base = opts.transform and "/render/image/public/" or "/object/public/"
	local url = self.client.url .. "/storage/v1" .. base .. object_path(self, path)
	local query = util.build_query(transform_query(opts.transform))
	if query ~= "" then
		url = url .. "?" .. query
	end
	return { public_url = append_param(url, download_param(opts.download)) }
end

--- create_signed_url(path, expires_in_seconds, opts?, callback). opts: { download, transform }
-- callback(err, { signed_url })
function Bucket:create_signed_url(path, expires_in, a, b)
	local opts, callback = util.opts_cb(a, b)
	request(self.client, "POST", "/object/sign/" .. object_path(self, path), {
		body = { expiresIn = expires_in, transform = opts.transform },
	}, function(err, result)
		if err then
			return callback(err, nil)
		end
		local url = self.client.url .. "/storage/v1" .. result.signedURL
		callback(nil, { signed_url = append_param(url, download_param(opts.download)) })
	end)
end

--- create_signed_urls(paths, expires_in, opts?, callback). callback(err, { { path, signed_url, error }, ... })
function Bucket:create_signed_urls(paths, expires_in, a, b)
	local opts, callback = util.opts_cb(a, b)
	request(self.client, "POST", "/object/sign/" .. util.urlencode(self.bucket), {
		body = { expiresIn = expires_in, paths = paths },
	}, function(err, result)
		if err then
			return callback(err, nil)
		end
		local list = {}
		for i, item in ipairs(result or {}) do
			list[i] = {
				path = item.path,
				error = item.error,
				signed_url = item.signedURL and append_param(self.client.url .. "/storage/v1" .. item.signedURL,
					download_param(opts.download)) or nil,
			}
		end
		callback(nil, list)
	end)
end

--- move(from, to, opts?, callback). opts: { destination_bucket }
function Bucket:move(from, to, a, b)
	local opts, callback = util.opts_cb(a, b)
	request(self.client, "POST", "/object/move", {
		body = { bucketId = self.bucket, sourceKey = from, destinationKey = to, destinationBucket = opts.destination_bucket },
	}, callback)
end

--- copy(from, to, opts?, callback). callback(err, { path })
function Bucket:copy(from, to, a, b)
	local opts, callback = util.opts_cb(a, b)
	request(self.client, "POST", "/object/copy", {
		body = { bucketId = self.bucket, sourceKey = from, destinationKey = to, destinationBucket = opts.destination_bucket },
	}, function(err, result)
		callback(err, not err and { path = result and result.Key } or nil)
	end)
end

--- Delete files. callback(err, { { name = path }, ... }) with the deleted paths; err is the first failure.
-- Sends one DELETE per file: Defold's native HTTP client drops DELETE bodies, which the bulk endpoint needs.
function Bucket:remove(paths, callback)
	callback = callback or noop
	local deleted, first_err, left = {}, nil, #paths
	if left == 0 then
		return callback(nil, deleted)
	end
	for _, path in ipairs(paths) do
		request(self.client, "DELETE", "/object/" .. object_path(self, path), nil, function(err)
			if err then
				first_err = first_err or err
			else
				deleted[#deleted + 1] = { name = path }
			end
			left = left - 1
			if left == 0 then
				callback(first_err, deleted)
			end
		end)
	end
end

--- list(prefix?, opts?, callback). opts: { limit = 100, offset = 0, sort_by = { column = "name", order = "asc" }, search }
function Bucket:list(prefix, a, b)
	if type(prefix) == "function" then
		prefix, a, b = nil, prefix, nil
	end
	local opts, callback = util.opts_cb(a, b)
	local sort_by = opts.sort_by or {}
	request(self.client, "POST", "/object/list/" .. util.urlencode(self.bucket), {
		body = {
			prefix = prefix or "",
			limit = opts.limit or 100,
			offset = opts.offset or 0,
			sortBy = { column = sort_by.column or "name", order = sort_by.order or "asc" },
			search = opts.search,
		},
	}, callback)
end

return M
