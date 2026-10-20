#!/usr/bin/env bash
# scripts/dotfiles.sh add/remove: local.yml edits, idempotence, comment and
# style preservation, validation, native hints, apply/uninstall (stubbed).
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$TESTS_REPO/scripts/dotfiles.sh"
mk_home
mkdir -p "$HOME/bin" "$HOME/nbin"
for t in yq jq; do
	p=""
	IFS=: read -ra dirs <<<"$PATH"
	for d in "${dirs[@]}"; do
		case "$d" in */shims | */shims/) continue ;; esac
		[ -x "$d/$t" ] && {
			p="$d/$t"
			break
		}
	done
	[ -n "$p" ] || {
		echo "SKIP: no non-shim $t on PATH" >&2
		exit 0
	}
	ln -s "$p" "$HOME/bin/$t"
done
# stubs record their argv (and cwd for ansible-playbook)
for s in ansible-playbook mise; do
	cat >"$HOME/bin/$s" <<'STUB'
#!/bin/sh
printf '%s|%s|%s|%s\n' "$(basename "$0")" "$*" "$(pwd)" "${MISE_GLOBAL_CONFIG_FILE-unset}" >>"$STUB_CALLS"
case "$(basename "$0")" in
ansible-playbook) exit "${STUB_ANSIBLE_RC:-0}" ;;
mise) exit "${STUB_MISE_RC:-0}" ;;
esac
STUB
	chmod +x "$HOME/bin/$s"
done
printf '#!/bin/sh\n' >"$HOME/nbin/natbin"
chmod +x "$HOME/nbin/natbin"
STUB_CALLS="$HOME/calls.txt"
export STUB_CALLS

printf '%s\n' \
	'tool_groups: [core, git, dev]' \
	'tools: {' \
	'mise: {group: core, bootstrap: true, version: "1.0.0"},' \
	'core1: {group: core, backend: "aqua:x/core1", version: "1.0.0"},' \
	'gitx: {group: git, backend: "aqua:x/gitx", version: "1.1.0"},' \
	'gity: {group: git, backend: "aqua:x/gity", version: "1.2.0"},' \
	'gitk: {group: git, bin: gitk, provided_by: gity},' \
	'devx: {group: dev, backend: "aqua:x/devx", version: "2.0.0"},' \
	'fzf: {group: dev, backend: "aqua:x/fzf", version: "3.0.0"},' \
	'nat: {group: dev, bin: natbin, native_only: true},' \
	'nat2: {group: dev, bin: nat2bin-missing, native_only: true, native_pkg: {brew: nat2-brew, apt: nat2-apt, dnf: nat2-dnf, pacman: nat2-pac}}}' >"$HOME/tools.yaml"

LOCAL="$HOME/local.yml"
fresh() { # fresh [BODY]: write local.yml (default: identity keys only)
	printf '%s\n' "${1:-git_name: \"A\"
git_email: \"a@b.c\"}" >"$LOCAL"
	: >"$STUB_CALLS"
}
run() { # run ARGS...: sets out, rc
	out="$(env -i HOME="$HOME" PATH="$HOME/bin:$HOME/nbin:/usr/bin:/bin" STUB_CALLS="$STUB_CALLS" \
		${STUB_ANSIBLE_RC:+STUB_ANSIBLE_RC="$STUB_ANSIBLE_RC"} ${STUB_MISE_RC:+STUB_MISE_RC="$STUB_MISE_RC"} \
		DOTFILES_LOCAL_YML="$LOCAL" DOTFILES_TOOLS_YAML="${TOOLS:-$HOME/tools.yaml}" sh "$script" "$@" 2>&1)"
	rc=$?
}
val() { yq -o=json -I0 ".$1" "$LOCAL"; } # val KEY

# add_group: materialises the default (all groups) list first
fresh 'tool_groups: [core, git]'
run add dev --no-apply
assert_eq 0 "$rc" "add_group: exit 0 ($out)"
assert_eq '["core","git","dev"]' "$(val tool_groups)" "add_group: appended"
fresh
run add dev --no-apply
assert_eq 0 "$rc" "add_group_absent: exit 0"
assert_eq "null" "$(val tool_groups)" "add_group_absent: all groups already, key untouched"
assert_contains "$out" "already selected" "add_group_absent: says so"

# add_tool: tools_add; and un-removes a removed tool
fresh 'tool_groups: [core, git]'
run add fzf --no-apply
assert_eq 0 "$rc" "add_tool: exit 0 ($out)"
assert_eq '["fzf"]' "$(val tools_add)" "add_tool: in tools_add"
assert_contains "$(cat "$LOCAL")" "tools_add: [fzf]" "add_tool: new key in flow style"
fresh 'tools_remove: [gitx, gity]'
run add gitx --no-apply
assert_eq '["gity"]' "$(val tools_remove)" "add_tool_unremove: dropped from tools_remove"
assert_eq "null" "$(val tools_add)" "add_tool_unremove: not also added"
run add gity --no-apply
assert_eq "[]" "$(val tools_remove)" "add_tool_unremove: emptied key becomes []"
# a tool whose group is off AND which is removed needs both
fresh 'tool_groups: [core]
tools_remove: [fzf]'
run add fzf --no-apply
assert_eq '["fzf"]' "$(val tools_add)" "add_tool_group_off: added"
assert_eq "[]" "$(val tools_remove)" "add_tool_group_off: unremoved"

# remove_tool: via group -> tools_remove; via tools_add -> dropped from it
fresh
run remove fzf --no-apply
assert_eq 0 "$rc" "remove_tool: exit 0 ($out)"
assert_eq '["fzf"]' "$(val tools_remove)" "remove_tool: group-selected goes to tools_remove"
fresh 'tool_groups: [core]
tools_add: [fzf, devx]'
run remove fzf --no-apply
assert_eq '["devx"]' "$(val tools_add)" "remove_tool_added: dropped from tools_add"
assert_eq "null" "$(val tools_remove)" "remove_tool_added: not in tools_remove"
# remove a group
fresh
run remove git --no-apply
assert_eq '["core","dev"]' "$(val tool_groups)" "remove_group: default list materialised minus git"

# remove_core_fails: exit 2, nothing written, even when mixed with valid args
fresh
cp "$LOCAL" "$HOME/before.yml"
run remove core1 --no-apply
assert_eq 2 "$rc" "remove_core_fails: exit 2"
assert_contains "$out" "dotfiles: core1 is in core and can't be removed" "remove_core_fails: message"
run remove core --no-apply
assert_eq 2 "$rc" "remove_core_group_fails: exit 2"
run remove fzf core1 --no-apply
assert_eq 2 "$rc" "remove_core_mixed: exit 2"
cmp -s "$LOCAL" "$HOME/before.yml" || fail "remove_core_mixed: file untouched"
run remove fzf nope --no-apply
assert_eq 2 "$rc" "unknown_mixed: exit 2"
cmp -s "$LOCAL" "$HOME/before.yml" || fail "unknown_mixed: file untouched"
# core is a no-op for add
run add core1 core --no-apply
assert_eq 0 "$rc" "add_core: exit 0"
cmp -s "$LOCAL" "$HOME/before.yml" || fail "add_core: file untouched"

# idempotent: byte-identical files
fresh '# my machine
tool_groups: [core,   git]   # keep
tools_add: [fzf]
tools_remove: [gity]
'
cp "$LOCAL" "$HOME/before.yml"
for c in "add fzf" "add git" "add core1" "remove devx" "remove dev" "remove gity" "remove gitk"; do
	# shellcheck disable=SC2086
	run $c --no-apply
	assert_eq 0 "$rc" "idempotent($c): exit 0 ($out)"
	cmp -s "$LOCAL" "$HOME/before.yml" || fail "idempotent($c): local.yml byte-identical"
done
run add fzf --no-apply
assert_contains "$out" "already selected" "add_idempotent: message"
run remove devx --no-apply
assert_contains "$out" "not selected" "remove_idempotent: message"
assert_eq "" "$(cat "$STUB_CALLS")" "idempotent: nothing applied"
run add fzf
assert_eq "" "$(cat "$STUB_CALLS")" "add_idempotent: no apply when nothing changed"

# preserves_comments: other keys, comments, flow/block style
printf '%s\n' '# top comment' 'git_name: "A"   # who' 'git_email: "a@b.c"' 'allow_sudo: false' '' \
	'# Tool selection' 'tool_groups:' '  - core' '  - git' '# tools_add: [x]' >"$LOCAL"
run add fzf dev --no-apply
assert_eq 0 "$rc" "preserves_comments: exit 0 ($out)"
body="$(cat "$LOCAL")"
assert_contains "$body" "# top comment" "preserves_comments: top comment"
assert_contains "$body" 'git_name: "A"'
assert_contains "$body" "# who" "preserves_comments: line comment"
assert_contains "$body" "# Tool selection" "preserves_comments: section comment"
assert_contains "$body" "allow_sudo: false" "preserves_comments: other key"
assert_contains "$body" "allow_sudo: false

# Tool selection" "preserves_comments: blank lines kept"
assert_contains "$body" "# tools_add: [x]" "preserves_comments: commented key"
assert_eq '["core","git","dev"]' "$(val tool_groups)" "preserves_comments: block list stays a list"
assert_eq '["fzf"]' "$(val tools_add)" "preserves_comments: tools_add added"
assert_not_contains "$body" "tool_groups: [" "preserves_comments: block style kept"
# new key goes to the end of the file
assert_eq "tools_add: [fzf]" "$(tail -n 1 "$LOCAL")" "preserves_comments: new key appended last"
# flow stays flow
fresh 'tool_groups: [core, git]'
run add dev --no-apply
assert_contains "$(cat "$LOCAL")" "tool_groups: [core, git, dev]" "flow_style_kept"

# unknown_suggests
fresh
cp "$LOCAL" "$HOME/before.yml"
run add fz --no-apply
assert_eq 2 "$rc" "unknown_suggests: exit 2"
assert_contains "$out" "unknown tool: fz" "unknown_suggests: message"
assert_contains "$out" "fzf" "unknown_suggests: nearest name"
run add frz --no-apply
assert_contains "$out" "unknown tool: frz" "unknown_suggests: no-substring typo"
assert_contains "$out" "fzf" "unknown_suggests: fallback to same first letter"
cmp -s "$LOCAL" "$HOME/before.yml" || fail "unknown_suggests: file untouched"

# mixed args are processed in order
fresh 'tool_groups: [core]'
run add fzf remove --no-apply
assert_eq 2 "$rc" "mixed: 'remove' is not a catalog name"
run add dev remove dev
assert_eq 2 "$rc" "mixed_nonames: exit 2"
fresh 'tool_groups: [core]'
run add git fzf --no-apply
assert_eq '["core","git"]' "$(val tool_groups)" "mixed: group then tool"
assert_eq '["fzf"]' "$(val tools_add)" "mixed: tool added"

# provided_by
fresh 'tool_groups: [core]'
run add gitk --no-apply
assert_eq 2 "$rc" "provided_by: adding the bundled tool alone fails"
assert_contains "$out" "gity" "provided_by: names the provider"

# missing local.yml
LOCAL_SAVE="$LOCAL"
LOCAL="$HOME/nope.yml"
run add fzf --no-apply
assert_eq 2 "$rc" "missing_local: exit 2"
assert_contains "$out" "dotfiles: $LOCAL not found; run install.sh or copy ansible/local.yml.example" "missing_local: message"
[ ! -e "$LOCAL" ] || fail "missing_local: not created"
LOCAL="$LOCAL_SAVE"

# usage errors
run add
assert_eq 2 "$rc" "add_no_args: exit 2"
run remove --bogus x
assert_eq 2 "$rc" "remove_bad_flag: exit 2"

# native_remove_prints_command: resolves -> remove_hint; unresolved -> host form
fresh
run remove nat --no-apply
assert_eq 0 "$rc" "native_remove: exit 0"
assert_contains "$out" "installed natively; remove with: rm $HOME/nbin/natbin" "native_remove: path-based hint"
run remove nat2 --no-apply
assert_contains "$out" "remove with:" "native_remove_unresolved: hint"
case "$(uname -s)" in
Darwin) assert_contains "$out" "brew uninstall nat2-brew" "native_remove_unresolved: brew form" ;;
*) assert_contains "$out" "nat2-" "native_remove_unresolved: package name" ;;
esac
assert_eq "" "$(cat "$STUB_CALLS")" "native_remove: nothing run"

# apply: playbook invoked from ansible/ with the tags; mise uninstall after remove
fresh 'tool_groups: [core]
tools_add: [fzf, devx]'
run add git
assert_eq 0 "$rc" "apply_add: exit 0 ($out)"
assert_eq "ansible-playbook|site.yml --tags mise,chezmoi,packages|$TESTS_REPO/ansible|unset" "$(cat "$STUB_CALLS")" "apply_add: playbook call"
: >"$STUB_CALLS"
run remove fzf --no-apply
assert_eq "" "$(cat "$STUB_CALLS")" "no_apply: nothing run"
fresh 'tool_groups: [core]
tools_add: [fzf, devx]'
run remove --no-apply fzf
assert_eq 0 "$rc" "no_apply_first: exit 0 ($out)"
assert_eq "" "$(cat "$STUB_CALLS")" "no_apply_first: nothing run"
fresh 'tool_groups: [core]
tools_add: [fzf, devx, nat]'
run remove fzf nat
assert_eq 0 "$rc" "apply_remove: exit 0 ($out)"
assert_eq "ansible-playbook|site.yml --tags mise,chezmoi,packages|$TESTS_REPO/ansible|unset
mise|-C / uninstall aqua:x/fzf@3.0.0|/|/nonexistent/mise-user.toml" "$(cat "$STUB_CALLS")" "apply_remove: playbook, then masked mise uninstall of the mise tool only"
# remove group: every mise tool of it
fresh
run remove dev
assert_contains "$(cat "$STUB_CALLS")" "mise|-C / uninstall aqua:x/devx@2.0.0|" "apply_remove_group: devx"
assert_contains "$(cat "$STUB_CALLS")" "mise|-C / uninstall aqua:x/fzf@3.0.0|" "apply_remove_group: fzf"
assert_not_contains "$(cat "$STUB_CALLS")" "gitx" "apply_remove_group: other groups kept"

# apply failure: exit 1, file stays edited, uninstall skipped
fresh 'tool_groups: [core]
tools_add: [fzf]'
STUB_ANSIBLE_RC=4 run remove fzf
assert_eq 1 "$rc" "apply_fails: exit 1"
assert_contains "$out" "apply failed" "apply_fails: message"
assert_contains "$out" "Re-running is safe" "apply_fails: says re-run is safe"
assert_eq "[]" "$(val tools_add)" "apply_fails: local.yml stays edited"
assert_not_contains "$(cat "$STUB_CALLS")" "mise|" "apply_fails: no uninstall"

# uninstall failure: warning only
fresh 'tool_groups: [core]
tools_add: [fzf]'
STUB_MISE_RC=1 run remove fzf
assert_eq 0 "$rc" "uninstall_fails: exit 0"
assert_contains "$out" "warning: could not uninstall fzf" "uninstall_fails: warning"

# ---- line-edit guarantees (review repros) ----
# the example file with tool_groups/tools_add uncommented: only their lines change
cp "$TESTS_REPO/ansible/local.yml.example" "$LOCAL"
sed -i.bak -e 's/^# tool_groups: /tool_groups: /' -e 's/^# tools_add: /tools_add: /' "$LOCAL"
rm -f "$LOCAL.bak"
cp "$LOCAL" "$HOME/ex.yml"
: >"$STUB_CALLS"
TOOLS=$TESTS_REPO/home/.chezmoidata/tools.yaml run remove lazydocker --no-apply
assert_eq 0 "$rc" "example_remove: exit 0 ($out)"
got="$(diff "$HOME/ex.yml" "$LOCAL")"
case "$got" in
*"tools_add: []"*"extra tools on top of the groups"*) ;;
*) fail "example_remove: tools_add emptied in place, comment kept ($got)" ;;
esac
assert_eq "2" "$(diff "$HOME/ex.yml" "$LOCAL" | grep -c '^[<>]')" "example_remove: exactly one line changed"
assert_contains "$(cat "$LOCAL")" "#   containers, system, media, dev)" "example_remove: continuation comment kept"
assert_contains "$(cat "$LOCAL")" "# tools_remove: [gh-dash]" "example_remove: commented example kept"
# untouched keys keep spacing and indentation byte-for-byte
printf '%s\n' 'git_name:   "A"   # who' 'personal_git_dirs:' '    - "~/a/"' '    - "~/b/"' '' 'tool_groups:' '- core' '- git' >"$LOCAL"
cp "$LOCAL" "$HOME/before.yml"
run add dev --no-apply
assert_eq 0 "$rc" "untouched_bytes: exit 0 ($out)"
assert_eq "" "$(diff <(head -n 6 "$HOME/before.yml") <(head -n 6 "$LOCAL"))" "untouched_bytes: lines before the edit identical"
assert_eq '["core","git","dev"]' "$(val tool_groups)" "untouched_bytes: block list updated"
assert_contains "$(cat "$LOCAL")" "- dev" "untouched_bytes: item at the list's own indent"
# CRLF stays CRLF (edited lines and appended key)
printf 'git_name: "A"\r\ntool_groups: [core, git]  # c\r\n' >"$LOCAL"
run add dev fzf --no-apply
assert_eq 0 "$rc" "crlf: exit 0 ($out)"
assert_eq "0" "$(tr -d '\r' <"$LOCAL" | grep -c '^$')" "crlf: no stray blank lines"
assert_eq "$(wc -l <"$LOCAL" | tr -d ' ')" "$(grep -c $'\r$' "$LOCAL")" "crlf: every line ends CRLF"
assert_contains "$(cat "$LOCAL")" "[core, git, dev]  # c" "crlf: comment kept"
# no trailing newline: appended key starts on its own line
printf 'git_name: "A"' >"$LOCAL"
run remove fzf --no-apply
assert_eq 0 "$rc" "no_eol: exit 0 ($out)"
assert_eq '"A"' "$(val git_name)" "no_eol: git_name intact"
assert_eq '["fzf"]' "$(val tools_remove)" "no_eol: key appended"
# a block scalar with a blank line stays valid and untouched
printf '%s\n' 'msg: |' '  one' '' '  two' 'tool_groups: [core]' >"$LOCAL"
run add git --no-apply
assert_eq 0 "$rc" "block_scalar: exit 0 ($out)"
assert_eq "$(printf 'one\n\ntwo')" "$(yq -r .msg "$LOCAL")" "block_scalar: value intact"
assert_eq '["core","git"]' "$(val tool_groups)" "block_scalar: edit applied"
# unsupported shapes: exit 2, byte-identical
for body in 'tool_groups: &g [core, git]' $'tool_groups: [core,\n  git]' 'tool_groups:' '"tool_groups": [core, git]'; do
	printf '%s\n' "$body" >"$LOCAL"
	cp "$LOCAL" "$HOME/before.yml"
	run remove git --no-apply
	assert_eq 2 "$rc" "unsupported($body): exit 2 ($out)"
	assert_contains "$out" "can't safely edit tool_groups in $LOCAL; edit it by hand" "unsupported($body): message"
	cmp -s "$LOCAL" "$HOME/before.yml" || fail "unsupported($body): file byte-identical"
done
# mode preserved, no temp files left behind
nfiles() {
	set -- "$HOME"/local.yml*
	echo $#
}
printf 'git_name: "A"\n' >"$LOCAL"
chmod 640 "$LOCAL"
run remove fzf --no-apply
assert_eq "640" "$(stat -c %a "$LOCAL" 2>/dev/null || stat -f %Lp "$LOCAL")" "mode_kept" # GNU first: GNU `stat -f` succeeds with fs info
assert_eq 1 "$(nfiles)" "no_temp_left"
# a failing verify step leaves the original intact (exit 1)
mv "$HOME/bin/yq" "$HOME/bin/yq.real"
# shellcheck disable=SC2016 # the stub's $* and $$ expand when it runs
printf '#!/bin/sh\ncase "$*" in *"del("*) echo "{\\"x\\": $$}" ;; *) exec "$(dirname "$0")/yq.real" "$@" ;; esac\n' >"$HOME/bin/yq"
chmod +x "$HOME/bin/yq"
printf 'git_name: "A"\n' >"$LOCAL"
cp "$LOCAL" "$HOME/before.yml"
run remove fzf --no-apply
assert_eq 1 "$rc" "verify_fails: exit 1"
cmp -s "$LOCAL" "$HOME/before.yml" || fail "verify_fails: original intact"
assert_eq 1 "$(nfiles)" "verify_fails: no temp left"
mv "$HOME/bin/yq.real" "$HOME/bin/yq"
