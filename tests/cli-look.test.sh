#!/usr/bin/env bash
# scripts/dotfiles.sh: look --json, theme/glass/tui dispatch, bare `dotfiles`.
# chezmoi, zsh and uv are stubs; jq is real.
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
stub() { # stub NAME BODY: a /bin/sh stub in $HOME/bin
	printf '#!/bin/sh\n%s\n' "$2" >"$HOME/bin/$1"
	chmod +x "$HOME/bin/$1"
}
export STUB_DATA="$HOME/data.json" STUB_CALL="$HOME/call.txt"
stub chezmoi '[ "$*" = "data --format json" ] || exit 9; [ -z "${STUB_FAIL:-}" ] || exit 1; cat "$STUB_DATA"'
# records argv and whatever arrives on stdin
stub zsh 'printf "%s\n" "$@" >"$STUB_CALL"; printf "stdin=[%s]\n" "$(cat)" >>"$STUB_CALL"'
stub uv 'printf "%s\n" "$@" >"$STUB_CALL"'

cat >"$STUB_DATA" <<'J'
{"theme": "zeta", "glass": "", "wallpaper_mode": "on", "wallpaper": {"opacity": 0.15, "map": {"zeta": "z.png"}},
	"glass_levels": {"default": {}, "clear": {}, "solid": {}, "frosted": {}, "tinted": {}, "extra": {}},
	"themes": {
		"zeta": {"base00": "#000000", "base0F": "#ffffff", "name": "not a colour"},
		"alpha": {"base00": "#111111", "base05": "#eeeeee"}}}
J

run() { # run ARGS...: sets out, rc (stdin closed)
	out="$(env -i HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" STUB_DATA="$STUB_DATA" STUB_CALL="$STUB_CALL" \
		${STUB_FAIL:+STUB_FAIL="$STUB_FAIL"} sh "$script" "$@" 2>&1 </dev/null)"
	rc=$?
}

# look_json: the contract the TUI parses
run look --json
assert_eq 0 "$rc" "look: exit 0 ($out)"
assert_eq '["glass","glass_levels","levels","theme","themes","wallpaper","wallpaper_opacity","wallpapers"]' "$(jq -c 'keys' <<<"$out")" "look: keys"
assert_eq "$TESTS_REPO/home/dot_config/wallpapers/z.png" "$(jq -r .wallpapers.zeta <<<"$out")" "look: wallpaper image paths"
assert_eq 0.15 "$(jq -r .wallpaper_opacity <<<"$out")" "look: wallpaper opacity"
assert_eq on "$(jq -r .wallpaper <<<"$out")" "look: wallpaper mode"
assert_eq zeta "$(jq -r .theme <<<"$out")" "look: active theme"
assert_eq null "$(jq -r .glass <<<"$out")" "look: empty glass is null"
assert_eq "clear,frosted,tinted,solid,extra,default" "$(jq -r '.levels | join(",")' <<<"$out")" "look: levels lightest first, unknown before default, default last"
assert_eq "alpha,zeta" "$(jq -r '[.themes[].slug] | join(",")' <<<"$out")" "look: themes sorted by slug"
assert_eq '["base00","base0F"]' "$(jq -c '.themes[1].colors | keys' <<<"$out")" "look: only base00..base0F colours"

STUB_FAIL=1 run look --json
assert_eq 1 "$rc" "look: chezmoi failure exits 1"
assert_contains "$out" "chezmoi data failed" "look: says why"
run look
assert_eq 2 "$rc" "look: --json is required"
run look --fetch
assert_eq 0 "$rc" "look --fetch: no fastfetch, no output, exit 0"
assert_eq "" "$out" "look --fetch: silent without fastfetch"

# theme_glass_dispatch: the repo's 45-theme.zsh in zsh -f, stdin closed
run theme rose-pine
assert_eq 0 "$rc" "theme: exit 0 ($out)"
call="$(cat "$STUB_CALL")"
assert_contains "$call" "-fc" "theme: zsh -f (no rc files)"
assert_contains "$call" "$TESTS_REPO/home/dot_config/zsh/conf.d/45-theme.zsh" "theme: sources the repo's 45-theme.zsh"
assert_contains "$call" $'theme\nrose-pine\nstdin=[]' "theme: calls theme SLUG with nothing on stdin"
out="$(printf 'y\n' | env -i HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" STUB_CALL="$STUB_CALL" sh "$script" glass frosted 2>&1)"
assert_contains "$(cat "$STUB_CALL")" $'glass\nfrosted\nstdin=[]' "glass: piped stdin never reaches zsh"
run wallpaper toggle
assert_contains "$(cat "$STUB_CALL")" $'wallpaper\ntoggle\nstdin=[]' "wallpaper: dispatched like theme"
run theme
assert_eq 2 "$rc" "theme: a slug is required"
run glass a b
assert_eq 2 "$rc" "glass: one level only"

# theme_real_zsh: the real `zsh -fc` snippet and 45-theme.zsh, against a stub
# chezmoi and a temp config: sets the key, applies, never execs a new shell.
zsh_bin=""
for d in /bin /usr/bin; do [ -x "$d/zsh" ] && zsh_bin="$d/zsh" && break; done
if [ -n "$zsh_bin" ]; then
	src="$HOME/src/home"
	mkdir -p "$src/.chezmoidata/themes" "$HOME/rbin"
	: >"$src/.chezmoidata/themes/rose-pine.toml"
	printf '[data]\n    theme = "old"\n' >"$HOME/chezmoi.toml"
	ln -s "$zsh_bin" "$HOME/rbin/zsh"
	# two templates use the theme (one edited here: kept), one doesn't (never applied)
	mkdir -p "$src/dot_config"
	printf '{{ .theme }}\n' >"$src/dot_config/ghostty.tmpl"
	printf '{{ .theme }}\n' >"$src/dot_config/edited.tmpl"
	printf 'plain {{ .chezmoi.os }}\n' >"$src/dot_config/other.tmpl"
	cat >"$HOME/rbin/chezmoi" <<STUB
#!/bin/sh
case "\$1" in
source-path) echo "$src" ;;
status) printf "MM .config/edited\\n M .config/other\\n M .config/ghostty\\n" ;;
target-path) shift; for f in "\$@"; do n=\$(basename "\$f" .tmpl); echo "$HOME/.config/\$n"; done ;;
apply) echo "\$*" >>"$STUB_CALL" ;;
esac
STUB
	for t in cmux zellij pgrep pkill nvim; do printf '#!/bin/sh\nexit 0\n' >"$HOME/rbin/$t"; done
	chmod +x "$HOME/rbin/"*
	rm -f "$STUB_CALL"
	out="$(env -i HOME="$HOME" PATH="$HOME/rbin:/usr/bin:/bin" CHEZMOI_CONFIG="$HOME/chezmoi.toml" \
		DOTFILES_TEST=1 THEME_NVIM_GLOB="$HOME/none*" sh "$script" theme rose-pine 2>&1 </dev/null)"
	rc=$?
	assert_eq 0 "$rc" "real zsh: theme exits 0 ($out)"
	assert_contains "$out" "theme → rose-pine" "real zsh: theme ran"
	assert_contains "$(cat "$HOME/chezmoi.toml")" 'theme = "rose-pine"' "real zsh: theme key written"
	assert_eq "apply $HOME/.config/ghostty" "$(cat "$STUB_CALL" 2>/dev/null)" "real zsh: applies only theme templates, never unrelated pending ones"
	assert_contains "$out" "kept your edits, not applied: .config/edited" "real zsh: names the edited theme file it left alone"
	out="$(env -i HOME="$HOME" PATH="$HOME/rbin:/usr/bin:/bin" CHEZMOI_CONFIG="$HOME/chezmoi.toml" \
		DOTFILES_TEST=1 sh "$script" theme no-such 2>&1 </dev/null)"
	assert_eq 1 "$?" "real zsh: unknown theme exits 1"
	assert_contains "$out" "unknown theme" "real zsh: unknown theme says so"
elif [ -n "${CI:-}" ]; then
	fail "no zsh in /bin or /usr/bin (CI must not skip)"
fi

# tui_dispatch: uv runs the locked script; no uv is a clear error
rm -f "$STUB_CALL"
run tui
assert_eq "run,--quiet,--locked,--script,$TESTS_REPO/scripts/tui/dotfiles_tui.py" "$(paste -sd, "$STUB_CALL")" "tui: uv run --locked --script"
rm "$HOME/bin/uv"
run tui
assert_eq 1 "$rc" "tui: no uv exits 1"
assert_contains "$out" "uv not on PATH" "tui: says uv is missing"

# bare_non_tty: scripts keep the usage + exit 2 contract
run
assert_eq 2 "$rc" "bare dotfiles without a tty: exit 2"
assert_contains "$out" "usage: dotfiles" "bare dotfiles without a tty: usage"

# dotfiles_command: ~/.local/bin/dotfiles runs this checkout's script (bare
# `dotfiles` then opens the TUI on a terminal); the zsh function is gone
w="$(render_tmpl "$TESTS_REPO/home/dot_local/bin/executable_dotfiles.tmpl")"
assert_contains "$w" '/scripts/dotfiles.sh" "$@"' "dotfiles command: execs the repo script with all args"
assert_contains "$w" "exec sh \"" "dotfiles command: exec, so exit codes pass through"
assert_eq "" "$(grep -E '^dotfiles\(\)' "$TESTS_REPO/home/dot_config/zsh/conf.d/80-tools.zsh")" "no zsh function shadows the command"
