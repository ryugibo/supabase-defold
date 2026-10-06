#!/usr/bin/env bash
# Verification script
#  1) Syntax-check every Lua source with LuaJIT
#  2) Run tests/test_*.lua unit tests (luajit)
#  3) Compile the project through a running Defold editor's HTTP API (/command/compile)
# Usage: tools/verify.sh [--no-compile]
set -u
cd "$(dirname "$0")/.."

fail=0

# --- 1. Lua syntax check ------------------------------------------------------
LUAJIT="$(command -v luajit || true)"
if [ -z "$LUAJIT" ]; then
	LUAJIT="$(ls -1 "$HOME"/Library/Application\ Support/Defold/unpack/*/*/bin/luajit-64 2>/dev/null | tail -n 1)"
fi

if [ -z "$LUAJIT" ]; then
	echo "[lua] luajit not found, skipping syntax check and unit tests."
else
	count=0
	while IFS= read -r -d '' f; do
		count=$((count + 1))
		if ! out="$("$LUAJIT" - "$f" 2>&1 <<< 'local f, e = loadfile(arg[1]); if not f then io.stderr:write(e); os.exit(1) end')"; then
			echo "[lua] FAIL $f"
			echo "      $out"
			fail=1
		fi
	done < <(find . -path ./build -prune -o -path ./.internal -prune -o \
		\( -name '*.lua' -o -name '*.script' -o -name '*.gui_script' -o -name '*.render_script' \) -type f -print0)
	echo "[lua] ${count} files syntax-checked"

	if ls tests/test_*.lua >/dev/null 2>&1; then
		"$LUAJIT" tests/run.lua tests/test_*.lua || fail=1
	fi
fi

# --- 2. Version numbers --------------------------------------------------------
# game.project [project] version and supabase/client.lua M.VERSION must match (tag releases as v<version>)
project_version="$(sed -n 's/^version *= *//p' game.project | head -n 1)"
lib_version="$(sed -n 's/^M.VERSION = "\(.*\)"/\1/p' supabase/client.lua)"
if [ "$project_version" = "$lib_version" ]; then
	echo "[version] $lib_version"
else
	echo "[version] FAIL game.project version ($project_version) != supabase/client.lua M.VERSION ($lib_version)"
	fail=1
fi

# --- 3. Defold editor compile -------------------------------------------------
if [ "${1:-}" != "--no-compile" ]; then
	if [ -f .internal/editor.port ] && [ -f .internal/editor.token ]; then
		port="$(cat .internal/editor.port)"
		token="$(cat .internal/editor.token)"
		if result="$(curl -s -m 300 -X POST -H "Authorization: Bearer $token" "http://localhost:$port/command/compile")" && [ -n "$result" ]; then
			# Summary: success flag + one line per issue (all errors, warnings outside tests/)
			if ! printf '%s' "$result" | python3 -c '
import json, sys
r = json.load(sys.stdin)
issues = [i for i in r.get("issues", []) if i.get("severity") == "error" or not i.get("resource", "").startswith("/tests/")]
for i in issues:
    line = i.get("range", {}).get("start", {}).get("line", -1) + 1
    print("[defold] %s %s:%d %s" % (i.get("severity"), i.get("resource"), line, i.get("message")))
print("[defold] compile %s (%d issues shown)" % ("OK" if r.get("success") else "FAILED", len(issues)))
sys.exit(0 if r.get("success") else 1)
'; then
				fail=1
			fi
		else
			echo "[defold] Cannot reach the editor. Open this project in the Defold editor."
			fail=1
		fi
	else
		echo "[defold] .internal/editor.port missing - the editor is not running (use --no-compile to skip)."
		fail=1
	fi
fi

if [ "$fail" -eq 0 ]; then echo "VERIFY OK"; else echo "VERIFY FAILED"; fi
exit "$fail"
