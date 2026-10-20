#!/usr/bin/env bash
# scripts/dotfiles.sh files: --json from chezmoi status, diff/apply/keep
# argument mapping (paths with spaces), template keep refused. chezmoi is a stub.
# shellcheck disable=SC2016 # stub bodies expand when the stubs run
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$TESTS_REPO/scripts/dotfiles.sh"
mk_home
mkdir -p "$HOME/bin"
real_jq=""
IFS=: read -ra _dirs <<<"$PATH"
for d in "${_dirs[@]}"; do
	case "$d" in */shims | */shims/) continue ;; esac
	[ -x "$d/jq" ] && real_jq="$d/jq" && break
done
[ -n "$real_jq" ] || {
	[ -z "${CI:-}" ] || fail "no non-shim jq on PATH (CI must not skip)"
	echo "SKIP: no non-shim jq on PATH" >&2
	exit 0
}
ln -s "$real_jq" "$HOME/bin/jq"
export STUB_CALL="$HOME/call.txt"
# status: changed here + pending, pending only, a path with spaces
cat >"$HOME/bin/chezmoi" <<'STUB'
#!/bin/sh
# record argv one per line (skipping the global flags)
for a in "$@"; do case "$a" in --no-pager | --no-tty) ;; *) printf '%s\n' "$a" ;; esac; done >"$STUB_CALL"
case "$*" in
*" status --exclude scripts") printf 'MM .config/a.toml\n M .config/b.lua\n M Library/Application Support/x/y.json\n' ;;
*" managed --include templates") printf '.config/b.lua\n' ;;
*" source-path "*) echo "/src/dot_config/b.lua.tmpl" ;;
esac
STUB
chmod +x "$HOME/bin/chezmoi"

run() { # run ARGS...: sets out, rc
	out="$(env -i HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" STUB_CALL="$STUB_CALL" sh "$script" "$@" 2>&1 </dev/null)"
	rc=$?
}

# files_json: one object per status line, the two columns split
run files --json
assert_eq 0 "$rc" "files --json: exit 0 ($out)"
assert_eq '[{"path":".config/a.toml","local":true,"pending":true,"template":false},{"path":".config/b.lua","local":false,"pending":true,"template":true},{"path":"Library/Application Support/x/y.json","local":false,"pending":true,"template":false}]' \
	"$(jq -c . <<<"$out")" "files --json: path, local, pending, template"

# files_actions: relative paths become ~/PATH, one argument each
run files diff "Library/Application Support/x/y.json" .config/a.toml
assert_eq 0 "$rc" "files diff: exit 0 ($out)"
assert_eq "diff|$HOME/Library/Application Support/x/y.json|$HOME/.config/a.toml" "$(paste -sd'|' "$STUB_CALL")" "files diff: one argument per path, spaces kept"
run files apply .config/a.toml
assert_eq "apply|--force|$HOME/.config/a.toml" "$(paste -sd'|' "$STUB_CALL")" "files apply: --force on just that path"
run files keep .config/a.toml
assert_eq "re-add|$HOME/.config/a.toml" "$(paste -sd'|' "$STUB_CALL")" "files keep: re-add"

# keep_template_refused: a template's target can't be re-added
rm -f "$STUB_CALL"
run files keep .config/b.lua
assert_eq 2 "$rc" "files keep template: exit 2"
assert_contains "$out" "edit /src/dot_config/b.lua.tmpl instead" "files keep template: names the source to edit"
assert_not_contains "$(cat "$STUB_CALL" 2>/dev/null)" "re-add" "files keep template: nothing re-added"

# unsafe_paths: absolute or .. paths are refused before chezmoi runs
for p in /etc/passwd ../x .config/../../x; do
	run files apply "$p"
	assert_eq 2 "$rc" "files apply $p: refused"
done
run files apply
assert_eq 2 "$rc" "files apply: needs a path"
