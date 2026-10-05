-- Standalone LuaJIT test runner (pure Lua modules only, no Defold APIs)
-- Usage from the project root: `luajit tests/run.lua tests/test_*.lua`
package.path = "./?.lua;" .. package.path

local total, failed = 0, 0

_G.test = function(name, fn)
	total = total + 1
	local ok, err = pcall(fn)
	if not ok then
		failed = failed + 1
		print("  FAIL " .. name .. "\n       " .. tostring(err))
	end
end

for i = 1, #arg do
	print("[test] " .. arg[i])
	dofile(arg[i])
end

print(string.format("[test] %d/%d passed", total - failed, total))
os.exit(failed == 0 and 0 or 1)
