#!/usr/bin/env bash
# scripts/cleanup-ubi.sh: removes what the old ubi install path left in the
# local bin/opt dirs, and nothing else (user scripts, mise shims, the pinned
# mise binary, foreign symlinks stay).
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$TESTS_REPO/scripts/cleanup-ubi.sh"
tools_yaml="$TESTS_REPO/home/.chezmoidata/tools.yaml"
d="$(mktemp -d)"
_tests_tmpdirs+=("$d")
bin="$d/bin"
opt="$d/opt"
mkdir -p "$bin" "$opt/neovim/bin" "$d/mise-data/shims" "$d/brew"

exe() { # exe PATH [BODY]: an executable regular file
	printf '#!/bin/sh\n%s\n' "${2:-echo legacy}" >"$1"
	chmod +x "$1"
}
exe "$bin/ubi"
exe "$bin/rg"
exe "$bin/delta"
exe "$bin/fzf"
exe "$bin/age-keygen"
exe "$opt/neovim/bin/nvim"
ln -s "$opt/neovim/bin/nvim" "$bin/nvim"
exe "$d/brew/editorconfig-checker"
ln -s "$d/brew/editorconfig-checker" "$bin/ec"
exe "$d/brew/batcat"
ln -s "$d/brew/batcat" "$bin/bat"
exe "$d/brew/fdfind"
ln -s "$d/brew/fdfind" "$bin/fd"
# Kept: user script, the pinned mise binary, mise shims (a symlink to mise and
# a script shim), uv's own install, a foreign symlink with a tool name.
exe "$bin/my-tool" "echo mine"
exe "$bin/mise" "echo mise"
ln -s "$bin/mise" "$bin/jq"
exe "$bin/yq" 'exec mise x -- yq "$@"'
exe "$bin/uv" "echo uv"
exe "$d/brew/gh"
ln -s "$d/brew/gh" "$bin/gh"

out="$("$script" "$bin" "$opt" "$tools_yaml")" || fail "cleanup exits 0"

for f in ubi rg delta fzf age-keygen nvim ec bat fd; do
	[ -e "$bin/$f" ] || [ -L "$bin/$f" ] && fail "removed: $f"
	assert_contains "$out" "$bin/$f" "reports $f"
done
[ -e "$opt/neovim" ] && fail "removed: $opt/neovim"
assert_contains "$out" "$opt/neovim" "reports the neovim tree"
for f in my-tool mise jq yq uv gh; do
	[ -e "$bin/$f" ] || fail "kept: $f"
	assert_not_contains "$out" "$bin/$f"$'\n' "does not report $f"
done
[ -e "$d/brew/batcat" ] || fail "symlink target outside the bin dir is untouched"

# Second run: nothing left to do, no output.
out="$("$script" "$bin" "$opt" "$tools_yaml")" || fail "second run exits 0"
assert_eq "" "$out" "second run removes nothing"

# Missing dirs are fine (fresh machine).
out="$("$script" "$d/nope-bin" "$d/nope-opt" "$tools_yaml")" || fail "missing dirs exit 0"
assert_eq "" "$out" "missing dirs: nothing removed"
