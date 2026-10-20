#!/usr/bin/env bash
# Live theme reload (_theme_live_reload in conf.d/45-theme.zsh): repaints a
# private headless nvim over RPC, skips stale/hung sockets within the 2s
# bound, and runs from theme/glass/wallpaper without exec'ing a shell. Only
# temp sockets (THEME_NVIM_GLOB) and stub cmux/chezmoi are used.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for t in nvim zsh chezmoi; do
	command -v "$t" >/dev/null 2>&1 || {
		[ -z "${CI:-}" ] || fail "no $t on PATH (CI must not skip: nvim/chezmoi are pinned in mise.toml)"
		echo "SKIP: no $t on PATH" >&2
		exit 0
	}
done

zsh_fn="$TESTS_REPO/home/dot_config/zsh/conf.d/45-theme.zsh"
nvim_src="$TESTS_REPO/home/dot_config/nvim"
real_chezmoi="$(command -v chezmoi)"
mk_home
# Short socket paths (macOS caps them at 104 bytes).
sockdir="$(mktemp -d /tmp/nvr.XXXXXX)"
_tests_tmpdirs+=("$sockdir")
pids=()
_stop_nvims() {
	local p
	for p in ${pids[@]+"${pids[@]}"}; do
		kill -CONT "$p" 2>/dev/null
		kill -9 "$p" 2>/dev/null
	done
	return 0
}
# Keep lib.sh's cleanup, and the exit status it reads.
_cleanup_all() {
	local rc=$?
	_stop_nvims
	(exit "$rc")
	_tests_cleanup
}
trap _cleanup_all EXIT

# Stubs: cmux logs its args; chezmoi renders from the repo, never applies.
mkdir -p "$HOME/bin"
export STUB_LOG="$HOME/stub.log"
cat >"$HOME/bin/cmux" <<'STUB'
#!/bin/sh
echo "cmux $*" >>"$STUB_LOG"
STUB
export REAL_CHEZMOI="$real_chezmoi" STUB_SRC="$TESTS_REPO" STUB_CFG="$TESTS_FIXTURE"
cat >"$HOME/bin/chezmoi" <<'STUB'
#!/bin/sh
case "$1" in
data) exec "$REAL_CHEZMOI" data --source "$STUB_SRC" --config "$STUB_CFG" --format json ;;
source-path) echo "$STUB_SRC/home" ;;
apply) echo apply >>"$STUB_LOG" ;;
esac
STUB
chmod +x "$HOME/bin/cmux" "$HOME/bin/chezmoi"
# Stubs only for the zsh side; render_tmpl needs the real chezmoi.
stubpath="$HOME/bin:$PATH"

# Rendered nvim config (only the theme modules) plus a base16 stub, since
# --clean has no plugins: the stub paints Normal from the palette it's given.
cfg="$HOME/nvim"
mkdir -p "$cfg/lua/config" "$cfg/lua/plugins"
cp "$nvim_src/lua/config/theme_reload.lua" "$cfg/lua/config/"
cat >"$cfg/lua/base16-colorscheme.lua" <<'LUA'
return {
	setup = function(c)
		vim.api.nvim_set_hl(0, "Normal", { fg = c.base05, bg = c.base00 })
		vim.g.colors_name = "base16-stub"
	end,
}
LUA
render_theme() {
	render_tmpl "$nvim_src/lua/plugins/colorscheme.lua.tmpl" theme="$1" >"$cfg/lua/plugins/colorscheme.lua"
	render_tmpl "$nvim_src/lua/config/design.lua.tmpl" theme="$1" >"$cfg/lua/config/design.lua"
}
base00() {
	sed -n 's/^base00 = "\(#[0-9a-fA-F]*\)"/\1/p' "$TESTS_REPO/home/.chezmoidata/themes/$1.toml" | tr 'A-F' 'a-f'
}

# start_nvim SOCK: headless nvim with the rendered config on rtp.
start_nvim() {
	nvim --headless --clean --listen "$1" -c "set rtp^=$cfg" >/dev/null 2>&1 </dev/null &
	pids+=($!)
	disown # no "Killed" job notices
	for _ in $(seq 50); do
		[ -S "$1" ] && return 0
		sleep 0.1
	done
	fail "nvim did not listen on $1"
}
normal_bg() {
	nvim --server "$1" --remote-expr \
		'luaeval("string.format(\"#%06x\", vim.api.nvim_get_hl(0, {name = \"Normal\"}).bg or 0)")' 2>&1
}

# reload GLOB: run the helper in zsh -f with the socket glob pointed at GLOB.
reload() {
	PATH="${PATH_OVERRIDE:-$stubpath}" THEME_NVIM_GLOB="$1" zsh -f -c '
		compdef() { :; }
		source "$1"; _theme_live_reload' _ "$zsh_fn" 2>&1 </dev/null
}

ghostty="ghostty: press ⌘⇧, (or ctrl+shift+, on Linux) to apply"
a=nord b=catppuccin-mocha
[ "$(base00 $a)" != "$(base00 $b)" ] || fail "themes $a and $b need distinct base00"

# live_reload: render A, reload; re-render B, reload; Normal follows the disk.
live="$sockdir/live"
mkdir -p "$live/x"
render_theme "$a"
start_nvim "$live/x/nvim.1.0"
out="$(reload "$live/*/nvim.*.0")"
assert_contains "$out" "reloaded 1 nvim; $ghostty" "live_reload: counts 1 nvim"
assert_eq "$(base00 $a)" "$(normal_bg "$live/x/nvim.1.0")" "live_reload: theme A applied"
render_theme "$b"
out="$(reload "$live/*/nvim.*.0")"
assert_contains "$out" "reloaded 1 nvim" "live_reload: counts 1 nvim after re-render"
assert_eq "$(base00 $b)" "$(normal_bg "$live/x/nvim.1.0")" "live_reload: theme B applied"
assert_eq "cmux reload-config" "$(tail -n1 "$STUB_LOG" 2>/dev/null)" "live_reload: cmux reloaded"

# stale_socket: a regular file, a dead socket (nvim killed -9) and a hung nvim
# (SIGSTOP) are each skipped silently; the hung one costs at most ~2s.
stale="$sockdir/stale"
mkdir -p "$stale"
: >"$stale/nvim.file.0"
start_nvim "$stale/nvim.dead.0"
kill -9 "${pids[${#pids[@]} - 1]}"
start_nvim "$stale/nvim.hung.0"
kill -STOP "${pids[${#pids[@]} - 1]}"
[ -S "$stale/nvim.dead.0" ] || fail "stale_socket: setup left no dead socket"
start=$SECONDS
out="$(reload "$stale/nvim.*.0")"
elapsed=$((SECONDS - start))
assert_eq "reloaded 0 nvim; $ghostty" "$(grep -v "^zellij: applied$" <<<"$out")" "stale_socket: nothing counted, no noise"
[ "$elapsed" -le 5 ] || fail "stale_socket: took ${elapsed}s (bound is 2s per socket)"

# no_nvim: nothing matches, nvim missing from PATH: still silent.
out="$(PATH_OVERRIDE="$HOME/bin:/usr/bin:/bin" reload "$sockdir/none/*.0")"
assert_eq "reloaded 0 nvim; $ghostty" "$(grep -v "^zellij: applied$" <<<"$out")" "no_nvim: silent"

# callers: theme, glass and wallpaper reload live and return (headless: no
# exec zsh); the old restart message is gone.
ccfg="$HOME/chezmoi.toml"
printf '[data]\n    theme = "nord"\n' >"$ccfg"
calls=("theme $b" "wallpaper on")
command -v jq >/dev/null 2>&1 && calls+=("glass clear")
for call in "${calls[@]}"; do
	: >"$STUB_LOG"
	# shellcheck disable=SC2086  # $call is "fn arg"
	out="$(PATH="$stubpath" THEME_NVIM_GLOB="$live/*/nvim.*.0" CHEZMOI_CONFIG="$ccfg" zsh -f -c '
		compdef() { :; }
		source "$1"; shift; "$@"; echo "rc=$? still-here"' _ "$zsh_fn" $call 2>&1 </dev/null)"
	assert_contains "$out" "reloaded 1 nvim" "$call: live reload"
	assert_contains "$out" "rc=0 still-here" "$call: returns, no exec"
	assert_not_contains "$out" "need a restart" "$call: no restart message"
	assert_contains "$(cat "$STUB_LOG")" "cmux reload-config" "$call: cmux reloaded"
done
