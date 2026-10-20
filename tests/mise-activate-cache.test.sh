#!/usr/bin/env bash
# conf.d/49-mise.zsh caches `mise activate zsh`. The raw output embeds the
# generating shell's PATH (`export PATH='...'`, `export __MISE_ORIG_PATH='...'`),
# so a cached copy would reset every later shell to that snapshot and drop
# its own entries (per-session dirs, a venv, ...). The cache must not carry
# PATH, and must be regenerated when the mise binary changes.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

real_mise="$(command -v mise 2>/dev/null)" || {
	echo "SKIP: no mise on PATH" >&2
	exit 0
}
command -v zsh >/dev/null 2>&1 || {
	echo "SKIP: no zsh" >&2
	exit 0
}

mk_home
mkdir -p "$HOME/misebin" "$HOME/misebin2"
ln -s "$real_mise" "$HOME/misebin/mise"
cp "$TESTS_REPO/home/dot_config/zsh/conf.d/49-mise.zsh" "$HOME/49-mise.zsh"
cache="$HOME/cache/mise/activate.zsh"

# shell PATH: source 49-mise in a clean zsh, print the resulting PATH
shell() {
	# shellcheck disable=SC2016 # expanded by zsh
	(cd "$HOME" && env -i HOME="$HOME" PATH="$1" TERM=dumb ZSH_CACHE_DIR="$HOME/cache" MISE_OFFLINE=1 \
		MISE_DATA_DIR="$HOME/data" MISE_CACHE_DIR="$HOME/mcache" MISE_STATE_DIR="$HOME/state" \
		zsh -f -c 'compdef() { :; }; source "$HOME/49-mise.zsh"
			(( $+functions[_mise_hook] )) && [[ $MISE_SHELL == zsh ]] && print -r -- ACTIVATED
			print -r -- "$PATH"' 2>&1)
}

shell "/stale/session-A:$HOME/misebin:/usr/bin:/bin" >/dev/null
[ -s "$cache" ] || fail "first shell writes the activate cache"
assert_not_contains "$(cat "$cache")" "/stale/session-A" "cache holds no PATH snapshot"

got="$(shell "/fresh/session-B:$HOME/misebin:/usr/bin:/bin")"
assert_contains "$got" "ACTIVATED" "cached activation still defines the mise hooks"
assert_contains "$got" "/fresh/session-B" "cached activation keeps this shell's PATH entries"
assert_not_contains "$got" "/stale/session-A" "cached activation does not replay the generating shell's PATH"

# A cache from before this fix (raw output with a PATH snapshot, newer than
# the binary) is regenerated, not replayed.
printf "export PATH='/stale/legacy:/usr/bin:/bin'\n" >"$cache"
got="$(shell "/fresh/session-C:$HOME/misebin:/usr/bin:/bin")"
assert_contains "$got" "/fresh/session-C" "legacy cache: PATH kept"
assert_not_contains "$got" "/stale/legacy" "legacy cache: regenerated"

# A failed generation (mise activate exits non-zero or prints nothing) leaves
# no cache: otherwise the key line alone would match, and every later shell
# would source it and silently stay unactivated until the binary changed.
rm -f "$cache"
mkdir -p "$HOME/flaky"
printf '#!/bin/sh\nexit 1\n' >"$HOME/flaky/mise"
chmod +x "$HOME/flaky/mise"
shell "$HOME/flaky:/usr/bin:/bin" >/dev/null
[ -e "$cache" ] && fail "failed generation: no cache written"
rm "$HOME/flaky/mise"
ln -s "$real_mise" "$HOME/flaky/mise" # same path, now working (and older)
got="$(shell "$HOME/flaky:/usr/bin:/bin")"
assert_contains "$got" "ACTIVATED" "after a failed generation the next shell activates"

# A different mise binary (e.g. Homebrew's vs the dotfiles' one) regenerates
# the cache: it embeds the binary's absolute path.
cp "$real_mise" "$HOME/misebin2/mise"
touch -t 200001010000 "$HOME/misebin2/mise" # older than the cache
shell "$HOME/misebin2:/usr/bin:/bin" >/dev/null
assert_contains "$(cat "$cache")" "$HOME/misebin2/mise" "cache follows the mise binary in use"
