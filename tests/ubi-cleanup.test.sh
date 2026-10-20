#!/usr/bin/env bash
# scripts/cleanup-ubi.sh: a one-time removal of what the old ubi install path
# left in the local bin/opt dirs. Only bins of tools this host gets from mise
# (select-tools source "mise"/"bundled"); never user scripts, mise shims, the
# pinned mise binary, foreign symlinks, native or deselected tools; and
# nothing at all once the legacy markers (ubi, the neovim tree) are gone.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$TESTS_REPO/scripts/cleanup-ubi.sh"
sel="$TESTS_REPO/scripts/select-tools.sh"
tools_yaml="$TESTS_REPO/home/.chezmoidata/tools.yaml"
d="$(mktemp -d)"
_tests_tmpdirs+=("$d")
bin="$d/bin"
opt="$d/opt"
mkdir -p "$bin" "$opt/neovim/bin" "$d/brew"

# This host: Linux x64 without lazydocker (deselected); jless is native there.
printf 'tools_remove: [lazydocker]\n' >"$d/local.yml"
selection="$("$sel" --os linux --arch x64 --local "$d/local.yml")" || fail "select-tools runs"

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
# a script shim), uv's own install, a foreign symlink with a tool name, a
# native tool (jless on Linux) and a deselected one (lazydocker).
exe "$bin/my-tool" "echo mine"
exe "$bin/mise" "echo mise"
ln -s "$bin/mise" "$bin/jq"
exe "$bin/yq" 'exec mise x -- yq "$@"'
exe "$bin/uv" "echo uv"
exe "$d/brew/gh"
ln -s "$d/brew/gh" "$bin/gh"
exe "$bin/jless" "echo user-jless"
exe "$bin/lazydocker" "echo user-lazydocker"

out="$("$script" "$bin" "$opt" "$tools_yaml" "$selection")" || fail "cleanup exits 0"

for f in ubi rg delta fzf age-keygen nvim ec bat fd; do
	[ -e "$bin/$f" ] || [ -L "$bin/$f" ] && fail "removed: $f"
	assert_contains "$out" "$bin/$f" "reports $f"
done
[ -e "$opt/neovim" ] && fail "removed: $opt/neovim"
assert_contains "$out" "$opt/neovim" "reports the neovim tree"
for f in my-tool mise jq yq uv gh jless lazydocker; do
	[ -e "$bin/$f" ] || fail "kept: $f"
	assert_not_contains "$out" "$bin/$f"$'\n' "does not report $f"
done
[ -e "$d/brew/batcat" ] || fail "symlink target outside the bin dir is untouched"

# One-shot: the markers are gone, so a later run touches nothing — not even a
# legacy-looking binary the user drops in afterwards.
exe "$bin/rg" "echo user-rg"
out="$("$script" "$bin" "$opt" "$tools_yaml" "$selection")" || fail "second run exits 0"
assert_eq "" "$out" "second run removes nothing"
[ -e "$bin/rg" ] || fail "second run: a later rg is kept"

# A host that never had ubi is never scanned.
mkdir -p "$d/fresh"
exe "$d/fresh/fzf"
out="$("$script" "$d/fresh" "$d/nope-opt" "$tools_yaml" "$selection")" || fail "no marker exits 0"
assert_eq "" "$out" "no marker: nothing removed"
[ -e "$d/fresh/fzf" ] || fail "no marker: fzf kept"

# Missing dirs are fine (fresh machine).
out="$("$script" "$d/nope-bin" "$d/nope-opt" "$tools_yaml" "$selection")" || fail "missing dirs exit 0"
assert_eq "" "$out" "missing dirs: nothing removed"
