#!/usr/bin/env bash
# scripts/claude-merge-settings.sh (additive settings.json merge), the baseline
# in claude.toml, and the run_onchange template that applies it per profile.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for t in jq yq; do
	command -v "$t" >/dev/null 2>&1 || {
		[ -z "${CI:-}" ] || fail "no $t on PATH (CI must not skip)"
		echo "SKIP: no $t on PATH" >&2
		exit 0
	}
done

script="$TESTS_REPO/scripts/claude-merge-settings.sh"
toml="$TESTS_REPO/home/.chezmoidata/claude.toml"
tmpl="$TESTS_REPO/home/.chezmoiscripts/run_onchange_after_30-claude-settings.sh.tmpl"
mk_home
# Away from the repo, so mise shims never read its (maybe untrusted) mise.toml.
cd "$HOME" || exit 1
w="$HOME/w"
mkdir -p "$w"

cat >"$w/baseline.json" <<'JSON'
{"statusLine":{"type":"command","command":"/h/.claude/statusline.sh"},
"enabledPlugins":{"superpowers@claude-plugins-official":true},
"permissions":{"allow":["Bash(ls *)","Bash(cat *)","Bash(wc *)"]}}
JSON

merge() { bash "$script" "$1" "$w/baseline.json"; }

# union_appends: existing order kept, new entries appended, no duplicates.
printf '{"permissions":{"allow":["Bash(zzz *)","Bash(cat *)"]}}\n' >"$w/u.json"
out="$(merge "$w/u.json")"
assert_eq updated "$out" "union_appends: prints updated"
assert_eq '["Bash(zzz *)","Bash(cat *)","Bash(ls *)","Bash(wc *)"]' \
	"$(jq -c .permissions.allow "$w/u.json")" "union_appends: order-preserving union"
assert_eq '{"type":"command","command":"/h/.claude/statusline.sh"}' \
	"$(jq -c .statusLine "$w/u.json")" "union_appends: statusLine set"

# idempotent: second run changes nothing, byte for byte.
cp "$w/u.json" "$w/u1.json"
out="$(merge "$w/u.json")"
assert_eq unchanged "$out" "idempotent: second run prints unchanged"
assert_eq "$(cksum <"$w/u1.json")" "$(cksum <"$w/u.json")" "idempotent: byte-identical"
# unchanged file keeps its own formatting (no rewrite)
printf '{"statusLine":{"type":"command","command":"/h/.claude/statusline.sh"},"enabledPlugins":{"superpowers@claude-plugins-official":true},"permissions":{"allow":["Bash(ls *)","Bash(cat *)","Bash(wc *)"]}}' >"$w/c.json"
cp "$w/c.json" "$w/c1.json"
merge "$w/c.json" >/dev/null
assert_eq "$(cksum <"$w/c1.json")" "$(cksum <"$w/c.json")" "idempotent: compact file not reformatted"

# preserves_other_keys: unrelated keys, their order, and other permissions.
cat >"$w/p.json" <<'JSON'
{"tui":"fullscreen","skipAutoPermissionPrompt":true,
"permissions":{"deny":["Bash(rm *)"],"defaultMode":"auto","allow":["X"]},
"statusLine":{"type":"command","command":"old"},
"enabledPlugins":{"other@m":true}}
JSON
merge "$w/p.json" >/dev/null
assert_eq '["tui","skipAutoPermissionPrompt","permissions","statusLine","enabledPlugins"]' \
	"$(jq -c 'keys_unsorted' "$w/p.json")" "preserves_other_keys: top-level order"
assert_eq '["deny","defaultMode","allow"]' "$(jq -c '.permissions|keys_unsorted' "$w/p.json")" \
	"preserves_other_keys: permissions order"
assert_eq '["Bash(rm *)"]' "$(jq -c .permissions.deny "$w/p.json")" "preserves_other_keys: deny"
assert_eq '"fullscreen"' "$(jq -c .tui "$w/p.json")" "preserves_other_keys: tui"
assert_eq '["other@m","superpowers@claude-plugins-official"]' \
	"$(jq -c '.enabledPlugins|keys_unsorted' "$w/p.json")" "preserves_other_keys: plugins appended"
assert_eq '["X","Bash(ls *)","Bash(cat *)","Bash(wc *)"]' "$(jq -c .permissions.allow "$w/p.json")" \
	"preserves_other_keys: allow order"

# respects_disabled_plugin: an explicit false is never flipped.
printf '{"enabledPlugins":{"superpowers@claude-plugins-official":false}}\n' >"$w/d.json"
merge "$w/d.json" >/dev/null
assert_eq false "$(jq -c '.enabledPlugins["superpowers@claude-plugins-official"]' "$w/d.json")" \
	"respects_disabled_plugin: stays false"

# new_profile: missing dir and file are created with only the baseline keys.
out="$(merge "$w/new/profile/settings.json")"
assert_eq updated "$out" "new_profile: prints updated"
assert_eq '["enabledPlugins","permissions","statusLine"]' \
	"$(jq -c 'keys' "$w/new/profile/settings.json")" "new_profile: only baseline keys"
assert_eq '{"allow":["Bash(ls *)","Bash(cat *)","Bash(wc *)"]}' \
	"$(jq -c .permissions "$w/new/profile/settings.json")" "new_profile: allow list"

# invalid_json_untouched: warn, leave the file alone, exit 0.
printf '{"tui": ' >"$w/bad.json"
cp "$w/bad.json" "$w/bad1.json"
out="$(merge "$w/bad.json" 2>/dev/null)"
rc=$?
assert_eq 0 "$rc" "invalid_json_untouched: exit 0"
assert_eq "skipped: invalid JSON: $w/bad.json" "$out" "invalid_json_untouched: message names the file"
assert_eq "$(cksum <"$w/bad1.json")" "$(cksum <"$w/bad.json")" "invalid_json_untouched: unchanged"
printf '[]\n' >"$w/arr.json"
assert_eq "skipped: invalid JSON: $w/arr.json" "$(merge "$w/arr.json" 2>/dev/null)" "non-object JSON skipped"
assert_eq '[]' "$(cat "$w/arr.json")" "non-object JSON untouched"

# mode kept, symlink target edited, no temp files left behind.
printf '{}\n' >"$w/m.json"
chmod 640 "$w/m.json"
merge "$w/m.json" >/dev/null
mode="$(stat -c %a "$w/m.json" 2>/dev/null || stat -f %Lp "$w/m.json")"
assert_eq 640 "$mode" "mode preserved"
mkdir -p "$w/real"
printf '{"tui":"x"}\n' >"$w/real/s.json"
ln -s real/s.json "$w/link.json"
merge "$w/link.json" >/dev/null
[ -L "$w/link.json" ] || fail "symlink replaced by a regular file"
assert_eq '"x"' "$(jq -c .tui "$w/real/s.json")" "symlink: target kept its keys"
assert_eq '["Bash(ls *)","Bash(cat *)","Bash(wc *)"]' "$(jq -c .permissions.allow "$w/real/s.json")" \
	"symlink: target edited"
assert_eq "" "$(find "$w" -name '.settings.json.*' | head -1)" "no temp files left"

# symlink chain: the final target is edited, links stay links.
ln -s real/s.json "$w/l1.json"
ln -s l1.json "$w/l2.json"
printf '{}\n' >"$w/real/s.json"
merge "$w/l2.json" >/dev/null
[ -L "$w/l1.json" ] && [ -L "$w/l2.json" ] || fail "symlink chain replaced"
assert_eq '["Bash(ls *)","Bash(cat *)","Bash(wc *)"]' "$(jq -c .permissions.allow "$w/real/s.json")" "symlink chain: target edited"
# a bad baseline is an error, not a silent skip
printf 'x' >"$w/badbase.json"
bash "$script" "$w/nb.json" "$w/badbase.json" 2>/dev/null
assert_eq 2 "$?" "bad baseline: exit 2"
[ ! -e "$w/nb.json" ] || fail "bad baseline: no file created"

# symlink loop: give up, exit 0, leave things alone.
ln -s lb.json "$w/la.json"
ln -s la.json "$w/lb.json"
out="$(merge "$w/la.json" 2>/dev/null)"
assert_eq 0 "$?" "symlink loop: exit 0"
assert_eq "skipped: symlink loop: $w/la.json" "$out" "symlink loop: message"

# template end to end: a broken profile does not stop the next one.
mkdir -p "$HOME/.claude" "$HOME/.claude-work"
printf '{ nope' >"$HOME/.claude/settings.json"
printf '{"tui":"y"}\n' >"$HOME/.claude-work/settings.json"
render_tmpl "$tmpl" >"$w/apply.sh" || fail "template renders"
bash "$w/apply.sh" >/dev/null 2>&1
assert_eq 0 "$?" "template: exit 0 with an invalid profile"
assert_eq '{ nope' "$(cat "$HOME/.claude/settings.json")" "template: invalid profile untouched"
assert_eq true "$(jq -c '.enabledPlugins["superpowers@claude-plugins-official"]' "$HOME/.claude-work/settings.json")" \
	"template: next profile merged"
assert_eq "\"$HOME/.claude/statusline.sh\"" "$(jq -c .statusLine.command "$HOME/.claude-work/settings.json")" \
	"template: statusLine command"
# entries with quotes, $ and backticks survive the template
# shellcheck disable=SC2016  # literal $ and backtick are the point
render_tmpl "$tmpl" 'claude_baseline_allow=["Bash(echo '"'"'x y'"'"' $HOME `id`)"]' >"$w/apply2.sh" || fail "template renders (quotes)"
mkdir -p "$HOME/.claude-work"
printf '{}\n' >"$HOME/.claude-work/settings.json"
bash "$w/apply2.sh" >/dev/null 2>&1
assert_eq "Bash(echo 'x y' \$HOME \`id\`)" "$(jq -r '.permissions.allow[0]' "$HOME/.claude-work/settings.json")" \
	"template: quotes, \$ and backticks pass through"
assert_contains "$(bash "$w/apply.sh" 2>&1)" "$HOME/.claude-work: " "template: output names the profile"
assert_contains "$(cat "$w/apply.sh")" "Bash(chezmoi diff)" "template: content carries the baseline"
assert_contains "$(cat "$w/apply.sh")" "merge-settings sha256: $(shasum -a 256 "$script" | cut -d" " -f1)" "template: hashes the merge script"

# baseline_has_no_forbidden: the shipped allow list is read-only only.
# allow_violation ENTRY: print why ENTRY is not allowed, nothing if fine.
allow_violation() {
	local e="$1" inner cmd
	case "$e" in
	"Bash("*")") inner="${e#Bash(}" inner="${inner%)}" ;;
	*)
		echo "not a Bash(...) entry"
		return
		;;
	esac
	cmd="${inner%% *}"
	case "$cmd" in
	'*' | '') echo "bare wildcard" ;;
	rm | security | keyring | python | python3 | curl | wget | uv | sudo | chmod | chown | ssh | scp | eval | sh | bash | zsh | npm | npx | pip | brew | apt | dnf | pacman)
		echo "forbidden command $cmd"
		;;
	find | fd | yq | rg | env | xargs | node | perl | ruby | make | awk | sed | tee | dd | mv | cp | ln | install | touch | mkdir | rmdir | tar | unzip | patch | open | kill | pkill)
		echo "write/exec-capable command $cmd"
		;;
	esac
	case "$inner" in
	"mise exec"* | "mise run"* | "mise x"* | "mise r"*) echo "mise exec/run" ;;
	esac
	case "$inner" in
	*--force* | *--hard* | *--delete* | *" -D"* | *" -d "* | *" -d" | *" -f"* | *" -exec"* | *" --exec"*)
		echo "destructive/exec flag"
		;;
	esac
	# Wildcards need a per-flag audit (global/negation flags too: --yes, --no-list).
	# A wildcard over a command with pager/output/exec/pre/in-place flags.
	case "$inner" in
	"git log "* | "git diff "* | "git show "* | "chezmoi "*" *" | less\ * | man\ * | sort\ * | tree\ * | rg\ * | find\ * | fd\ * | yq\ *)
		case "$inner" in
		*" *") echo "wildcard over a command with --pager/--output/--exec/--pre/-i flags" ;;
		esac
		;;
	esac
	# Only these reviewed forms; everything else needs a new review.
	case "$inner" in
	"git branch --show-current") ;;
	"gh pr view *" | "gh pr list *" | "gh pr checks *" | "gh issue view *" | "gh run view *") ;;
	"mise ls" | "chezmoi diff" | "chezmoi status") ;;
	*) echo "not in the reviewed read-only set" ;;
	esac
}

# The checker itself must reject these.
for bad in 'Bash(rm *)' 'Bash(find *)' 'Bash(fd *)' 'Bash(yq *)' 'Bash(rg *)' 'Bash(git branch *)' \
	'Bash(git branch -D *)' 'Bash(git branch -d *)' 'Bash(git branch --delete *)' 'Bash(git push --force *)' \
	'Bash(git reset --hard *)' 'Bash(git clean *)' 'Bash(git push *)' 'Bash(git *)' 'Bash(mise exec *)' \
	'Bash(mise run *)' 'Bash(curl *)' 'Bash(sed *)' 'Bash(tee *)' 'Bash(xargs *)' 'Bash(cp *)' 'Bash(sudo ls)' \
	'Bash(python3 *)' 'Bash(bash *)' 'Bash(*)' 'Bash(gh pr merge *)' 'Bash(gh api *)' 'Read(*)' \
	'Bash(chezmoi diff *)' 'Bash(chezmoi status *)' 'Bash(chezmoi apply *)' 'Bash(chezmoi *)' \
	'Bash(git log *)' 'Bash(git diff *)' 'Bash(git show *)' 'Bash(less *)' 'Bash(sort *)' 'Bash(/bin/rm *)' \
	'Bash(FOO=1 rm *)' 'Bash(mise install *)' 'Bash(git branch --list *)' 'Bash(git branch --list --no-l *)' \
	'Bash(mise ls *)' 'Bash(jq *)' 'Bash(jq -n env)'; do
	[ -n "$(allow_violation "$bad")" ] || fail "forbidden-check misses: $bad"
done
# ...and accept these.
for ok in 'Bash(git branch --show-current)' 'Bash(gh pr view *)' 'Bash(mise ls)' \
	'Bash(chezmoi diff)' 'Bash(chezmoi status)'; do
	[ -z "$(allow_violation "$ok")" ] || fail "forbidden-check rejects fine entry: $ok"
done

entries="$(yq -p toml -o json '.claude_baseline_allow' "$toml" 2>/dev/null | jq -r '.[]?')"
[ -n "$entries" ] || fail "baseline_has_no_forbidden: claude_baseline_allow empty or missing"
while IFS= read -r e; do
	[ -n "$e" ] || continue
	v="$(allow_violation "$e")"
	[ -z "$v" ] || fail "baseline_has_no_forbidden: $e ($v)"
done <<<"$entries"
assert_eq '["superpowers@claude-plugins-official"]' \
	"$(yq -p toml -o json -I0 '.claude_baseline_plugins' "$toml")" "baseline plugins"
