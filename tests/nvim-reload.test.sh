#!/usr/bin/env bash
# Live theme reload (_theme_live_reload in conf.d/45-theme.zsh): repaints a
# private headless nvim (colorscheme + lualine) over RPC, skips stale/hung
# sockets within the 2s bound, finds sockets in the default macOS/Linux
# layouts, signals Ghostty, notes zellij, leaves no jobs, and runs from
# theme/glass/wallpaper without exec'ing a shell. Only temp sockets and stub
# cmux/zellij/pgrep/pkill/chezmoi are used.
# shellcheck disable=SC2016 # stub and zsh bodies expand later
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

# Stubs log to STUB_LOG. pgrep "finds" ghostty when GH_RUNNING=1; pkill exits
# GH_PKILL_RC; zellij list-sessions prints ZJ_LIST; chezmoi never applies.
mkdir -p "$HOME/bin"
export STUB_LOG="$HOME/stub.log"
stub() {
	printf '#!/bin/sh\n%s\n' "$2" >"$HOME/bin/$1"
	chmod +x "$HOME/bin/$1"
}
stub cmux 'echo "cmux $*" >>"$STUB_LOG"'
stub pgrep 'echo "pgrep $*" >>"$STUB_LOG"; [ "${GH_RUNNING:-0}" = 1 ]'
stub pkill 'echo "pkill $*" >>"$STUB_LOG"; exit "${GH_PKILL_RC:-0}"'
stub ghostty 'echo "Ghostty ${GH_VERSION:-1.2.3}"'
stub zellij '[ "$1" = list-sessions ] && printf "%s" "${ZJ_LIST:-}"; exit 0'
export REAL_CHEZMOI="$real_chezmoi" STUB_SRC="$TESTS_REPO" STUB_CFG="$TESTS_FIXTURE"
stub chezmoi 'case "$1" in
data) exec "$REAL_CHEZMOI" data --source "$STUB_SRC" --config "$STUB_CFG" --format json ;;
source-path) echo "$STUB_SRC/home" ;;
apply) echo apply >>"$STUB_LOG" ;;
esac'
# Stubs only for the zsh side; render_tmpl needs the real chezmoi.
stubpath="$HOME/bin:$PATH"

# Rendered theme modules plus plugins/ui.lua, with base16 and lualine stubs
# (--clean has no plugins): base16 paints Normal, lualine keeps its opts.
cfg="$HOME/nvim"
mkdir -p "$cfg/lua/config" "$cfg/lua/plugins"
cp "$nvim_src/lua/config/theme_reload.lua" "$cfg/lua/config/"
cp "$nvim_src/lua/plugins/ui.lua" "$cfg/lua/plugins/"
cat >"$cfg/lua/base16-colorscheme.lua" <<'LUA'
return {
	setup = function(c)
		vim.api.nvim_set_hl(0, "Normal", { fg = c.base05, bg = c.base00 })
		vim.g.colors_name = "base16-stub"
	end,
}
LUA
cat >"$cfg/lua/lualine.lua" <<'LUA'
local M = {}
M.get_config = function()
	return { options = {} }
end
M.setup = function(o)
	M.last = o
end
return M
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
remote() { nvim --server "$1" --remote-expr "luaeval('$2')" 2>&1; }
normal_bg() { remote "$1" 'string.format("#%06x", vim.api.nvim_get_hl(0, {name = "Normal"}).bg or 0)'; }

# reload GLOB [ENV=VAL ...]: the helper in zsh -f, socket glob = GLOB.
reload() {
	local g="$1"
	shift
	env PATH="$stubpath" THEME_NVIM_GLOB="$g" "$@" zsh -f -c '
		compdef() { :; }
		source "$1"; _theme_live_reload' _ "$zsh_fn" 2>&1 </dev/null
}

a=nord b=catppuccin-mocha
[ "$(base00 $a)" != "$(base00 $b)" ] || fail "themes $a and $b need distinct base00"

# live_reload: render A, reload; re-render B, reload; Normal and the lualine
# theme follow the disk.
live="$sockdir/live"
mkdir -p "$live/x"
render_theme "$a"
start_nvim "$live/x/nvim.1.0"
remote "$live/x/nvim.1.0" 'require("lualine") and 1' >/dev/null
: >"$STUB_LOG"
out="$(reload "$live/*/nvim.*.0")"
assert_eq "reloaded 1 nvim" "$out" "live_reload: counts 1 nvim, nothing else"
assert_eq "$(base00 $a)" "$(normal_bg "$live/x/nvim.1.0")" "live_reload: theme A applied"
render_theme "$b"
accent_b="$(sed -n 's/^  accent  = "\(#[0-9a-fA-F]*\)",/\1/p' "$cfg/lua/config/design.lua")"
out="$(reload "$live/*/nvim.*.0")"
assert_eq "reloaded 1 nvim" "$out" "live_reload: counts 1 nvim after re-render"
assert_eq "$(base00 $b)" "$(normal_bg "$live/x/nvim.1.0")" "live_reload: theme B applied"
assert_eq "$accent_b" "$(remote "$live/x/nvim.1.0" 'require("lualine").last.options.theme.normal.a.bg')" \
	"live_reload: lualine theme rebuilt"
assert_contains "$(cat "$STUB_LOG")" "cmux reload-config" "live_reload: cmux reloaded"

# no_jobs: an interactive shell's job table stays empty afterwards.
out="$(PATH="$stubpath" THEME_NVIM_GLOB="$live/*/nvim.*.0" zsh -f -i -c '
	compdef() { :; }
	source "$1"; _theme_live_reload >/dev/null; jobs; echo end' _ "$zsh_fn" 2>&1 </dev/null)"
assert_eq "end" "$out" "no_jobs: jobs empty"

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
assert_eq "reloaded 0 nvim" "$out" "stale_socket: nothing counted, no noise"
[ "$elapsed" -le 5 ] || fail "stale_socket: took ${elapsed}s (bound is 2s per socket)"

# sockets_only: a regular file never reaches nvim (stub nvim logs calls).
fake="$HOME/fakenvim"
mkdir -p "$fake"
printf '#!/bin/sh\necho "nvim $*" >>"$STUB_LOG"\n' >"$fake/nvim"
chmod +x "$fake/nvim"
: >"$STUB_LOG"
out="$(stubpath="$fake:$stubpath" reload "$stale/nvim.file.0")"
assert_eq "reloaded 0 nvim" "$out" "sockets_only: file not counted"
assert_not_contains "$(cat "$STUB_LOG")" "nvim --server" "sockets_only: file not contacted"

# no_nvim: nothing matches, nvim missing from PATH: still silent.
out="$(stubpath="$HOME/bin:/usr/bin:/bin" reload "$sockdir/none/*.0")"
assert_eq "reloaded 0 nvim" "$out" "no_nvim: silent"

# default_glob: THEME_NVIM_GLOB unset (opted in under DOTFILES_TEST). macOS
# layout $TMPDIR/nvim.$USER/*/nvim.N.0; Linux $XDG_RUNTIME_DIR/nvim.N.0.
mac="$sockdir/m" lnx="$sockdir/l" empty="$sockdir/e"
mkdir -p "$mac/nvim.$USER/ab" "$lnx" "$empty"
start_nvim "$mac/nvim.$USER/ab/nvim.1.0"
start_nvim "$lnx/nvim.2.0"
: >"$lnx/other.0"
dflt() {
	env -u THEME_NVIM_GLOB -u XDG_RUNTIME_DIR PATH="$stubpath" "$@" zsh -f -c '
		compdef() { :; }
		source "$1"; _theme_live_reload' _ "$zsh_fn" 2>&1 </dev/null
}
assert_eq "reloaded 1 nvim" "$(dflt THEME_TEST_DEFAULT_GLOB=1 TMPDIR="$mac/")" "default_glob: macOS layout"
assert_eq "reloaded 1 nvim" "$(dflt THEME_TEST_DEFAULT_GLOB=1 TMPDIR="$empty" XDG_RUNTIME_DIR="$lnx")" \
	"default_glob: Linux layout"
assert_eq "reloaded 2 nvim" "$(dflt THEME_TEST_DEFAULT_GLOB=1 TMPDIR="$mac" XDG_RUNTIME_DIR="$lnx")" \
	"default_glob: both roots"
# guard: under DOTFILES_TEST the default globs need the opt-in.
assert_eq "reloaded 0 nvim" "$(dflt TMPDIR="$mac/")" "guard: no default glob in tests"

# ghostty: SIGUSR2 to the user's own ghostty, only when one runs.
gh() { reload "$sockdir/none/*.0" THEME_TEST_SIGNAL=1 "$@"; }
: >"$STUB_LOG"
assert_eq "reloaded 0 nvim; ghostty: reloaded" "$(gh GH_RUNNING=1)" "ghostty: signalled"
assert_contains "$(cat "$STUB_LOG")" "pkill -USR2 -u $USER -x ghostty" "ghostty: pkill args"
: >"$STUB_LOG"
assert_eq "reloaded 0 nvim" "$(gh GH_RUNNING=0)" "ghostty: none running, nothing printed"
assert_not_contains "$(cat "$STUB_LOG")" "pkill" "ghostty: none running, no signal"
assert_eq "reloaded 0 nvim; ghostty: press ⌘⇧, (or ctrl+shift+, on Linux) to apply" \
	"$(gh GH_RUNNING=1 GH_PKILL_RC=1)" "ghostty: signal failed, key hint"
: >"$STUB_LOG"
assert_eq "reloaded 0 nvim; ghostty: press ⌘⇧, (or ctrl+shift+, on Linux) to apply" \
	"$(gh GH_RUNNING=1 GH_VERSION=1.1.3)" "ghostty: pre-1.2, key hint"
assert_not_contains "$(cat "$STUB_LOG")" "pkill" "ghostty: pre-1.2 never signalled"
: >"$STUB_LOG"
reload "$sockdir/none/*.0" GH_RUNNING=1 >/dev/null
assert_not_contains "$(cat "$STUB_LOG")" "pkill" "guard: no signal in tests without opt-in"

# zellij: noted only while a live session exists.
assert_eq "reloaded 0 nvim
zellij: applied" "$(reload "$sockdir/none/*.0" ZJ_LIST='main [Created 1m ago] (current)')" "zellij: live session"
assert_eq "reloaded 0 nvim" "$(reload "$sockdir/none/*.0" ZJ_LIST='old [Created 2d ago] (EXITED - attach to resurrect)')" \
	"zellij: exited only"

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
