#!/usr/bin/env bash
# Vendored iglass themes: 16 hex keys, MIT attribution, on_colors entry,
# and theme-audit.sh stays clean for them (needs network for schemes).
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dir="$TESTS_REPO/home/.chezmoidata/themes"
for slug in iglass-dark iglass-light; do
	f="$dir/$slug.toml"
	[ -f "$f" ] || {
		fail "$slug: missing"
		continue
	}
	head -3 "$f" | grep -q 'github.com/vukkt/iglass' || fail "$slug: no iglass attribution"
	head -3 "$f" | grep -q 'v1.5.0' || fail "$slug: no tag in attribution"
	head -3 "$f" | grep -q 'MIT' || fail "$slug: no MIT in attribution"
	grep -q "^\[themes\.$slug\]\$" "$f" || fail "$slug: bad table header"
	for k in 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F; do
		grep -Eq "^base$k = \"#[0-9a-f]{6}\"\$" "$f" || fail "$slug: base$k not #rrggbb"
	done
	grep -q "^\[on_colors\.$slug\]\$" "$TESTS_REPO/home/.chezmoidata/on_colors.toml" || fail "$slug: no on_colors"
done

# iglass-light keeps base16 light semantics: base00-03 lighter than base05.
lum() { # #rrggbb -> r+g+b
	local h=${1#\#}
	echo $((16#${h:0:2} + 16#${h:2:2} + 16#${h:4:2}))
}
light="$dir/iglass-light.toml"
fg=$(lum "$(sed -n 's/^base05 = "\(.*\)"/\1/p' "$light")")
for k in 00 01 02 03; do
	v=$(lum "$(sed -n "s/^base$k = \"\(.*\)\"/\1/p" "$light")")
	[ "$v" -gt "$fg" ] || fail "iglass-light: base$k not lighter than base05"
done

# The audit must not flag marked themes. Needs network: SKIP the audit when
# schemes are unreachable (the file checks above still ran).
export GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=10
if git ls-remote https://github.com/tinted-theming/schemes HEAD >/dev/null 2>&1; then
	cache=$(mktemp -d)
	out=$(XDG_CACHE_HOME="$cache" sh "$TESTS_REPO/scripts/theme-audit.sh" 2>&1)
	rc=$?
	rm -rf "$cache"
	assert_eq 0 "$rc" "theme-audit exit"
	assert_not_contains "$out" "iglass" "theme-audit flags iglass"
else
	echo "SKIP: theme-audit (no network)" >&2
fi
