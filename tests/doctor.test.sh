#!/usr/bin/env bash
# scripts/doctor.sh: the mise binary must be the group_vars mise_version, and
# assert-tools' shadowed-copy warnings surface as doctor WARN lines.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

doctor="$TESTS_REPO/scripts/doctor.sh"
want="$(sed -nE 's/^mise_version: *"([^"]+)".*/\1/p' "$TESTS_REPO/ansible/group_vars/all.yml")"
[ -n "$want" ] || fail "group_vars has a mise_version"

mk_home
mkdir -p "$HOME/.local/bin" "$HOME/tbin"
for t in yq jq; do ln -s "$(command -v "$t")" "$HOME/tbin/$t"; done
stub_mise() { # stub_mise VERSION: a mise that only reports its version
	printf '#!/bin/sh\necho "%s macos-arm64 (2026-01-01)"\n' "$1" >"$HOME/.local/bin/mise"
	chmod +x "$HOME/.local/bin/mise"
}
run() {
	out="$(cd "$HOME" && env -i HOME="$HOME" PATH="$HOME/.local/bin:$HOME/tbin:/usr/bin:/bin" \
		sh "$doctor" 2>&1)"
}

stub_mise "$want"
run
assert_contains "$out" "OK    mise $want (ansible/group_vars mise_version)" "mise_version_ok"

stub_mise 2000.1.1
run
assert_contains "$out" "FAIL  mise 2000.1.1 at $HOME/.local/bin/mise, but ansible/group_vars pins mise_version $want" \
	"mise_version_mismatch_fails"

rm "$HOME/.local/bin/mise"
run
assert_contains "$out" "FAIL  mise not on PATH" "mise_missing_fails"

# Shadowed copies: with a real mise and the assert-tools fixture layout.
real_mise="$(command -v mise 2>/dev/null)" || {
	echo "SKIP: no mise on PATH (shadow case)" >&2
	exit 0
}
data="$HOME/.local/share/mise"
mkdir -p "$data/shims" "$HOME/.config/mise-dotfiles" "$HOME/other"
ln -s "$real_mise" "$HOME/.local/bin/mise"
ln -s "$HOME/.local/bin/mise" "$data/shims/fzf"
mkdir -p "$data/installs/aqua-junegunn-fzf/0.67.0"
printf '#!/bin/sh\necho 0.67.0\n' >"$data/installs/aqua-junegunn-fzf/0.67.0/fzf"
printf '#!/bin/sh\necho other\n' >"$HOME/other/fzf"
chmod +x "$data/installs/aqua-junegunn-fzf/0.67.0/fzf" "$HOME/other/fzf"
printf '[tools]\n"aqua:junegunn/fzf" = "0.67.0"\n' >"$HOME/.config/mise-dotfiles/config.toml"
printf 'tool_groups: [core]\ntools:\n  fzf: {group: core, backend: "aqua:junegunn/fzf", version: "0.67.0"}\n' >"$HOME/tools.yaml"
out="$(cd "$HOME" && env -i HOME="$HOME" MISE_OFFLINE=1 MISE_CACHE_DIR="$HOME/cache" MISE_STATE_DIR="$HOME/state" \
	PATH="$HOME/.local/bin:$HOME/tbin:$data/shims:$HOME/other:/usr/bin:/bin" \
	sh "$doctor" --tools "$HOME/tools.yaml" 2>&1)"
assert_contains "$out" "OK    selected tools all present and runnable" "shadow case: tools pass"
assert_contains "$out" "WARN  fzf also installed at $HOME/other/fzf (shadowed); remove with: rm $HOME/other/fzf" \
	"shadowed copy surfaces as a doctor WARN"
