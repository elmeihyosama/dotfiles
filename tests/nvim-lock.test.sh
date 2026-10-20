#!/usr/bin/env bash
# lazy-lock.json lives in the repo, symlinked to ~/.config/nvim/lazy-lock.json,
# so LazyVim's rewrites show up in `git status`.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

nvim_src="$TESTS_REPO/home/dot_config/nvim"
tmpl="$nvim_src/symlink_lazy-lock.json.tmpl"
data="$nvim_src/.lazy-lock.json"

# Template renders an absolute path into the repo's source dir.
if [ -f "$tmpl" ]; then
	out="$(render_tmpl "$tmpl")"
else
	out=""
	fail "symlink template missing: $tmpl"
fi
assert_contains "$out" "/dot_config/nvim/.lazy-lock.json" "template points at the dotfile data"
case "$out" in
*/dot_config/nvim/.lazy-lock.json) ;;
*) fail "template output must end with /dot_config/nvim/.lazy-lock.json (got: $out)" ;;
esac
case "$out" in
/*) ;;
*) fail "template output must be an absolute path (got: $out)" ;;
esac

# Data file is valid JSON with the lazy.nvim entry.
if [ -f "$data" ] && command -v jq >/dev/null 2>&1; then
	jq -e 'has("lazy.nvim")' "$data" >/dev/null 2>&1 || fail "data file must be JSON with a \"lazy.nvim\" key"
else
	fail "data file missing or jq not installed: $data"
fi

# Sandboxed apply: never the real $HOME or chezmoi config/state.
mk_home
dest="$HOME/dest"
mkdir -p "$dest"
cfg="$HOME/chezmoi.toml"
cp "$TESTS_FIXTURE" "$cfg"
cz=(chezmoi --source "$TESTS_REPO/home" --destination "$dest" --config "$cfg"
	--persistent-state "$HOME/state.boltdb" --cache "$HOME/cache" --no-tty)
target="$dest/.config/nvim/lazy-lock.json"

managed="$("${cz[@]}" managed --include symlinks 2>&1)"
assert_eq "1" "$(printf '%s\n' "$managed" | grep -c '^\.config/nvim/lazy-lock\.json$')" "lazy-lock.json managed exactly once as a symlink"
assert_not_contains "$managed" ".lazy-lock.json" "dotfile data is not itself managed"

# A pre-existing regular file (what LazyVim wrote before) is replaced by the symlink.
mkdir -p "$dest/.config/nvim"
echo '{"stale":{}}' >"$target"
"${cz[@]}" apply --force "$target" >/dev/null 2>&1 || fail "chezmoi apply --force failed"
if [ -L "$target" ]; then
	want="$(cd "$nvim_src" && pwd -P)/.lazy-lock.json"
	got="$(cd "$(dirname "$target")" && cd "$(dirname "$(readlink "$target")")" 2>/dev/null && pwd -P)/$(basename "$(readlink "$target")")"
	assert_eq "$want" "$got" "symlink resolves to the repo's .lazy-lock.json"
else
	fail "apply --force did not replace the regular file with a symlink"
fi
