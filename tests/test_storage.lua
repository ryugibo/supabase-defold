local H = require("tests.helpers")

test("bucket management", function()
	local sb, log = H.fake({
		["GET /storage/v1/bucket"] = { 200, { { id = "b" } } },
		["POST /storage/v1/bucket"] = { 200, { name = "b" } },
		["PUT /storage/v1/bucket/b"] = { 200, {} },
		["POST /storage/v1/bucket/b/empty"] = { 200, {} },
		["DELETE /storage/v1/bucket/b"] = { 200, {} },
		["GET /storage/v1/bucket/b"] = { 200, { id = "b", public = true } },
	})
	local buckets
	sb.storage:list_buckets(function(err, data) buckets = data end)
	assert(buckets[1].id == "b")
	sb.storage:create_bucket("b", { public = true, file_size_limit = "1MB", allowed_mime_types = { "image/png" } })
	assert(log[2].body.id == "b" and log[2].body.public == true and log[2].body.allowed_mime_types[1] == "image/png")
	sb.storage:update_bucket("b", { public = false })
	sb.storage:empty_bucket("b")
	sb.storage:delete_bucket("b")
	sb.storage:get_bucket("b")
	assert(log[3].body.public == false and log[4].path == "/storage/v1/bucket/b/empty" and log[5].method == "DELETE")
end)

test("upload sends raw bytes with headers and encoded path", function()
	local sb, log = H.fake({
		["POST /storage/v1/object/avatars/u1/my%20pic.png"] = { 200, { Key = "avatars/u1/my pic.png", Id = "id1" } },
		["PUT /storage/v1/object/avatars/u1/a.png"] = { 200, { Key = "avatars/u1/a.png" } },
	}, { codec = { encode = H.json, decode = function(s) return s end } })
	local got
	sb.storage:from("avatars"):upload("u1/my pic.png", "\137PNG\0bytes", { content_type = "image/png", upsert = true, metadata = { a = 1 } },
		function(err, data) got = data end)
	assert(got.path == "u1/my pic.png" and got.id == "id1" and got.full_path == "avatars/u1/my pic.png")
	assert(log[1].body == "\137PNG\0bytes" and log[1].headers["Content-Type"] == "image/png")
	assert(log[1].headers["x-upsert"] == "true" and log[1].headers["cache-control"] == "max-age=3600")
	assert(require("supabase.util").base64_decode(log[1].headers["x-metadata"]) == '{"a":1}')
	sb.storage:from("avatars"):update("u1/a.png", "x", function() end)
	assert(log[2].method == "PUT" and log[2].headers["x-upsert"] == "false")
end)

test("download (raw and transformed), info, exists", function()
	local sb, log = H.fake({
		["GET /storage/v1/object/b/f.bin"] = { 200, "\0\1\2" },
		["GET /storage/v1/render/image/authenticated/b/i.png"] = { 200, "img" },
		["GET /storage/v1/object/info/b/f.bin"] = { 200, { name = "f.bin", size = 3 } },
		["HEAD /storage/v1/object/b/f.bin"] = { 200, nil },
		["HEAD /storage/v1/object/b/missing"] = { 400, nil },
	})
	local bytes, img, info, yes, no
	local file = sb.storage:from("b")
	file:download("f.bin", function(err, data) bytes = data end)
	file:download("i.png", { transform = { width = 64, height = 64, resize = "cover" } }, function(err, data) img = data end)
	file:info("f.bin", function(err, data) info = data end)
	file:exists("f.bin", function(err, v) yes = v end)
	file:exists("missing", function(err, v) no = v end)
	assert(bytes == "\0\1\2" and img == "img" and info.size == 3 and yes == true and no == false)
	assert(log[2].query.width == "64" and log[2].query.resize == "cover")
end)

test("public and signed URLs", function()
	local sb, log = H.fake({
		["POST /storage/v1/object/sign/b/f.png"] = { 200, { signedURL = "/object/sign/b/f.png?token=T" } },
		["POST /storage/v1/object/sign/b"] = { 200, { { path = "a", signedURL = "/object/sign/b/a?token=A" }, { path = "x", error = "not found" } } },
		["POST /storage/v1/object/upload/sign/b/new.png"] = { 200, { url = "/object/upload/sign/b/new.png?token=UP" } },
		["PUT /storage/v1/object/upload/sign/b/new.png"] = { 200, { Key = "b/new.png" } },
	})
	local file = sb.storage:from("b")
	assert(file:get_public_url("f.png").public_url == "https://test.supabase.co/storage/v1/object/public/b/f.png")
	assert(file:get_public_url("f.png", { download = "x.png", transform = { width = 10 } }).public_url
		== "https://test.supabase.co/storage/v1/render/image/public/b/f.png?width=10&download=x.png")
	local signed
	file:create_signed_url("f.png", 60, { download = true }, function(err, data) signed = data.signed_url end)
	assert(signed == "https://test.supabase.co/storage/v1/object/sign/b/f.png?token=T&download=" and log[1].body.expiresIn == 60)
	local list
	file:create_signed_urls({ "a", "x" }, 60, function(err, data) list = data end)
	assert(list[1].signed_url:find("token=A", 1, true) and list[2].error == "not found")
	local upload
	file:create_signed_upload_url("new.png", { upsert = true }, function(err, data) upload = data end)
	assert(upload.token == "UP" and log[3].headers["x-upsert"] == "true")
	local done
	file:upload_to_signed_url("new.png", upload.token, "bytes", { content_type = "image/png" }, function(err, data) done = data end)
	assert(log[4].query.token == "UP" and log[4].body == "bytes" and done.full_path == "b/new.png")
end)

test("list, move, copy, remove", function()
	local sb, log = H.fake({
		["POST /storage/v1/object/list/b"] = { 200, { { name = "a.png" } } },
		["POST /storage/v1/object/move"] = { 200, { message = "ok" } },
		["POST /storage/v1/object/copy"] = { 200, { Key = "b/c.png" } },
		["DELETE /storage/v1/object/b/a.png"] = { 200, { message = "Successfully deleted" } },
		["DELETE /storage/v1/object/b/c%20d.png"] = { 200, { message = "Successfully deleted" } },
	})
	local file = sb.storage:from("b")
	local items
	file:list("folder", { limit = 10, sort_by = { column = "created_at", order = "desc" }, search = "a" }, function(err, data) items = data end)
	assert(items[1].name == "a.png" and log[1].body.prefix == "folder" and log[1].body.limit == 10)
	assert(log[1].body.sortBy.column == "created_at" and log[1].body.search == "a")
	file:list(function() end)
	assert(log[2].body.prefix == "" and log[2].body.limit == 100)
	file:move("a.png", "b.png", { destination_bucket = "other" })
	assert(log[3].body.bucketId == "b" and log[3].body.destinationKey == "b.png" and log[3].body.destinationBucket == "other")
	local copied
	file:copy("a.png", "c.png", function(err, data) copied = data end)
	assert(copied.path == "b/c.png")
	local deleted, rerr
	file:remove({ "a.png", "c d.png", "missing.png" }, function(err, data) rerr, deleted = err, data end)
	assert(log[5].method == "DELETE" and log[5].body == nil and log[5].headers["Content-Type"] == nil)
	assert(#deleted == 2 and deleted[2].name == "c d.png" and rerr.status == 404)
end)

test("storage errors are parsed", function()
	local sb = H.fake({ ["GET /storage/v1/object/b/x"] = { 404, '{"statusCode":"404","error":"not_found","message":"Object not found"}' } },
		{ codec = { encode = H.json, decode = function(s)
			if s:find("Object not found", 1, true) then
				return { statusCode = "404", error = "not_found", message = "Object not found" }
			end
			return s
		end } })
	local err
	sb.storage:from("b"):download("x", function(e) err = e end)
	assert(err.status == 404 and err.message == "Object not found" and err.code == "not_found")
end)
