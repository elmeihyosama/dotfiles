#!/usr/bin/env bash
# Ghostty glass levels: template output per level/OS, and the `glass` command
# (conf.d/45-theme.zsh) against a temp chezmoi config and a stub chezmoi.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v zsh >/dev/null 2>&1 || {
	echo "SKIP: no zsh" >&2
	exit 0
}
command -v jq >/dev/null 2>&1 || {
	echo "SKIP: no jq" >&2
	exit 0
}
tmpl="$TESTS_REPO/home/dot_config/ghostty/config.tmpl"

# glass_lines [KEY=VAL ...]: the two glass lines, joined.
glass_lines() {
	render_tmpl "$tmpl" "$@" | grep -E '^background-(opacity|blur) ' | paste -sd'|' -
}

# Template: exact lines per level on macOS.
export TESTS_CHEZMOI_OS=darwin
assert_eq "background-opacity = 0.50|background-blur = macos-glass-clear" "$(glass_lines glass=clear)" "darwin clear"
assert_eq "background-opacity = 0.66|background-blur = macos-glass-regular" "$(glass_lines glass=frosted)" "darwin frosted"
assert_eq "background-opacity = 0.82|background-blur = macos-glass-regular" "$(glass_lines glass=tinted)" "darwin tinted"
assert_eq "background-opacity = 1.0|background-blur = false" "$(glass_lines glass=solid)" "darwin solid"
assert_eq "background-opacity = 0.8|background-blur = 20" "$(glass_lines glass=default)" "darwin default"
assert_eq "background-opacity = 0.8|background-blur = 20" "$(glass_lines)" "darwin unset = default"
assert_eq "background-opacity = 0.8|background-blur = 20" "$(glass_lines glass=bogus)" "darwin unknown = default"

# Same values on every OS (Ghostty macos-glass-* to blur 20 off macOS).
export TESTS_CHEZMOI_OS=linux
assert_eq "background-opacity = 0.50|background-blur = macos-glass-clear" "$(glass_lines glass=clear)" "linux clear"
assert_eq "background-opacity = 1.0|background-blur = false" "$(glass_lines glass=solid)" "linux solid"
assert_eq "background-opacity = 0.8|background-blur = 20" "$(glass_lines)" "linux unset"

# with_wallpaper: one background-opacity line, image lines kept.
export TESTS_CHEZMOI_OS=darwin
out="$(render_tmpl "$tmpl" glass=clear wallpaper_mode=on)"
assert_contains "$out" "background-image = " "wallpaper present"
assert_eq "1" "$(grep -c '^background-opacity ' <<<"$out")" "one background-opacity with wallpaper"
assert_eq "1" "$(grep -c '^background-blur ' <<<"$out")" "one background-blur with wallpaper"
assert_contains "$out" "background-opacity = 0.50" "level opacity with wallpaper"
unset TESTS_CHEZMOI_OS

# Function tests: temp config, stub chezmoi (data from the real repo data).
real_chezmoi="$(command -v chezmoi)" || {
	echo "SKIP: no chezmoi" >&2
	exit 0
}
mk_home
mkdir -p "$HOME/bin"
export STUB_LOG="$HOME/stub.log"
export REAL_CHEZMOI="$real_chezmoi" STUB_SRC="$TESTS_REPO" STUB_CFG="$TESTS_FIXTURE"
cat >"$HOME/bin/chezmoi" <<'STUB'
#!/bin/sh
case "$1" in
data) exec "$REAL_CHEZMOI" data --source "$STUB_SRC" --config "$STUB_CFG" --format json ;;
source-path) echo "$STUB_SRC/home" ;;
status) ;;
target-path)
	shift
	for f in "$@"; do echo "$HOME/t/$(basename "$f" .tmpl)"; done
	;;
apply)
	shift
	echo "apply $*" >>"$STUB_LOG"
	;;
esac
STUB
chmod +x "$HOME/bin/chezmoi"
cfg="$HOME/chezmoi.toml"

# run_glass ARGS...: run `glass ARGS` in zsh -f with stdin not a tty; prints
# stdout+stderr, then "rc=N".
run_glass() {
	: >"$STUB_LOG"
	PATH="$HOME/bin:$PATH" CHEZMOI_CONFIG="$cfg" zsh -f -c '
		compdef() { :; }
		source "$1"; shift
		glass "$@"; echo "rc=$?"' _ "$TESTS_REPO/home/dot_config/zsh/conf.d/45-theme.zsh" "$@" 2>&1 </dev/null
}

printf '[data]\n    theme = "nord"\n' >"$cfg"

# Valid level: written, applied, reported; no exec (shell continues).
out="$(run_glass tinted)"
assert_contains "$out" "glass → tinted" "reports level"
assert_contains "$out" "rc=0" "valid level exits 0"
assert_contains "$(cat "$cfg")" 'glass = "tinted"' "level written"
assert_eq 1 "$(grep -c '^apply ' "$STUB_LOG")" "chezmoi apply ran once"
assert_contains "$(cat "$STUB_LOG")" "$HOME/t/config " "apply covers the theme templates (ghostty's config)"
assert_not_contains "$(cat "$STUB_LOG")" "$HOME/t/dot_gitconfig" "apply skips files that don't use the theme"

# off is an alias for default (a real value; keys can't be deleted).
out="$(run_glass off)"
assert_contains "$out" "glass → default" "off reports default"
assert_contains "$(cat "$cfg")" 'glass = "default"' "off writes default"

# headless_no_exec: the function returns to the caller, never exec's a shell.
out="$(PATH="$HOME/bin:$PATH" CHEZMOI_CONFIG="$cfg" zsh -f -c '
	compdef() { :; }
	source "$1"; glass clear; echo still-here' _ "$TESTS_REPO/home/dot_config/zsh/conf.d/45-theme.zsh" 2>&1 </dev/null)"
assert_contains "$out" "still-here" "headless_no_exec"

# invalid_level: usage + valid levels, exit 1, nothing written or applied.
before="$(cat "$cfg")"
out="$(run_glass nonsense)"
assert_contains "$out" "usage: glass" "invalid_level usage"
for l in clear frosted tinted solid default off; do
	assert_contains "$out" "$l" "invalid_level lists $l"
done
assert_contains "$out" "rc=1" "invalid_level exits 1"
assert_eq "$before" "$(cat "$cfg")" "invalid_level leaves config untouched"
assert_eq "" "$(cat "$STUB_LOG")" "invalid_level does not apply"

# No arg, no fzf: usage, exit 1. PATH drops dirs with fzf; jq/mise are linked in.
nofzf="$HOME/bin"
for t in jq mise sh env; do
	p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$HOME/bin/$t"
done
IFS=: read -ra _dirs <<<"$PATH"
for d in "${_dirs[@]}"; do
	[ -x "$d/fzf" ] || nofzf+=":$d"
done
out="$(PATH="$nofzf" CHEZMOI_CONFIG="$cfg" zsh -f -c '
	compdef() { :; }
	source "$1"; glass; echo "rc=$?"' _ "$TESTS_REPO/home/dot_config/zsh/conf.d/45-theme.zsh" 2>&1 </dev/null)"
assert_contains "$out" "usage: glass" "no-arg usage"
assert_contains "$out" "rc=1" "no-arg exits 1"
