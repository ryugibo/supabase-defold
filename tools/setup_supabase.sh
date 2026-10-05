#!/usr/bin/env bash
# Set up the Supabase project used by the smoke test (example/supabase: config.toml, migrations, functions).
#   tools/setup_supabase.sh link <project-ref>   link a hosted project once (asks for the database password)
#   tools/setup_supabase.sh remote               push migrations, auth/API config and functions to the linked project
#   tools/setup_supabase.sh local                start the local stack (needs Docker) and apply migrations
#   tools/setup_supabase.sh reset                local only: recreate the database from the migrations
#   tools/setup_supabase.sh stop                 stop the local stack
# remote / local also write url and publishable key into game.project [supabase] (do not commit those values).
set -euo pipefail
cd "$(dirname "$0")/.."

SB=(supabase --workdir example)
REF_FILE=example/supabase/.temp/project-ref

if ! command -v supabase >/dev/null 2>&1; then
	echo "Supabase CLI not found. Install it with: brew install supabase/tap/supabase" >&2
	exit 1
fi

# write_config <url> <key>: set [supabase] url / anon_key and [smoke_test] function_name in game.project
# (sections and keys are added when missing)
write_config() {
	python3 - "$1" "$2" <<'EOF'
import sys
url, key = sys.argv[1], sys.argv[2]
path = "game.project"
lines = open(path).read().rstrip("\n").split("\n")

def set_value(section, name, value):
    header = "[%s]" % section
    if header not in lines:
        lines.extend(["", header])
    start = lines.index(header) + 1
    end = start
    while end < len(lines) and not lines[end].startswith("["):
        end += 1
    for i in range(start, end):
        if lines[i].split("=", 1)[0].strip() == name:
            lines[i] = "%s = %s" % (name, value)
            return
    while end > start and lines[end - 1].strip() == "":
        end -= 1
    lines.insert(end, "%s = %s" % (name, value))

set_value("supabase", "url", url)
set_value("supabase", "anon_key", key)
set_value("smoke_test", "function_name", "hello")
open(path, "w").write("\n".join(lines) + "\n")
EOF
	echo "[setup] game.project [supabase] -> $1 (local change, do not commit)"
}

project_ref() {
	if [ ! -f "$REF_FILE" ]; then
		echo "No linked project. Run: tools/setup_supabase.sh link <project-ref>" >&2
		exit 1
	fi
	cat "$REF_FILE"
}

case "${1:-}" in
	link)
		: "${2:?usage: tools/setup_supabase.sh link <project-ref>}"
		"${SB[@]}" link --project-ref "$2"
		;;
	remote)
		ref="$(project_ref)"
		echo "[setup] migrations -> $ref"
		"${SB[@]}" db push --yes
		echo "[setup] auth / API config -> $ref"
		"${SB[@]}" config push --yes
		echo "[setup] functions -> $ref"
		"${SB[@]}" functions deploy --use-api --project-ref "$ref"
		key="$("${SB[@]}" projects api-keys --project-ref "$ref" -o json | python3 -c '
import json, sys
keys = json.load(sys.stdin)
if isinstance(keys, dict):
    keys = keys.get("keys") or list(keys.values())
pick = [k for k in keys if k.get("type") == "publishable"] or [k for k in keys if k.get("name") == "anon"]
print(pick[0]["api_key"] if pick else "")
')"
		[ -n "$key" ] || { echo "Could not read the publishable key" >&2; exit 1; }
		write_config "https://$ref.supabase.co" "$key"
		;;
	local)
		"${SB[@]}" start
		env_out="$("${SB[@]}" status -o env)"
		url="$(printf '%s\n' "$env_out" | sed -n 's/^API_URL="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')"
		key="$(printf '%s\n' "$env_out" | sed -n 's/^PUBLISHABLE_KEY="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')"
		[ -n "$key" ] || key="$(printf '%s\n' "$env_out" | sed -n 's/^ANON_KEY="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')"
		write_config "$url" "$key"
		;;
	reset)
		"${SB[@]}" db reset
		;;
	stop)
		"${SB[@]}" stop
		;;
	*)
		sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
		exit 1
		;;
esac
