#!/usr/bin/env bash
# The mise pins template (home/dot_config/mise-dotfiles/config.toml.tmpl):
# every catalog tool for the platform, as select-tools.sh sources them.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmpl="$TESTS_REPO/home/dot_config/mise-dotfiles/config.toml.tmpl"
sel="$TESTS_REPO/scripts/select-tools.sh"

render() { render_tmpl "$tmpl" "$@"; }

# every tool, as "<backend>" = "<version>"; native_on is skipped per OS.
out="$(TESTS_CHEZMOI_OS=darwin render)"
assert_contains "$out" '"aqua:junegunn/fzf" = "0.67.0"' "fzf line"
assert_not_contains "$out" 'btop' "btop (native on darwin) has no line"
assert_not_contains "$out" 'jdx/mise' "bootstrap mise itself is not pinned"
printf '%s\n' "$out" | yq -p toml -o json '.tools | length' >/dev/null || fail "output is valid TOML"
out="$(TESTS_CHEZMOI_OS=linux render)"
assert_contains "$out" '"aqua:aristocratos/btop" = "1.4.7"' "btop rendered on linux"

# mise_options render as mise's inline-table form
assert_contains "$out" '"github:atuinsh/atuin" = { version = "18.17.1", matching_regex = ' "options: inline table"

# a stale selected_tools key (old machines) is ignored, not an error
out="$(TESTS_CHEZMOI_OS=linux render 'selected_tools=["fzf","nosuchtool"]')" || fail "stale selected_tools renders"
assert_contains "$out" 'aqua:sharkdp/bat' "stale selected_tools: every tool still pinned"

# mise_pins_all (used by relock.sh): every backend tool, ignores native_on
out="$(TESTS_CHEZMOI_OS=darwin render 'mise_pins_all=true')"
assert_contains "$out" '"aqua:aristocratos/btop" = "1.4.7"' "pins_all: btop present on darwin"

# the rendered set == select-tools.sh's mise tools, for every locked platform
# (os, chezmoi arch, select-tools arch)
for combo in darwin:arm64:arm64 linux:amd64:x64 linux:arm64:arm64; do
	IFS=: read -r os carch sarch <<<"$combo"
	want="$("$sel" --os "$os" --arch "$sarch" | jq -r '.[] | select(.source == "mise") | .backend' | sort | paste -sd, -)"
	got="$(TESTS_CHEZMOI_OS=$os TESTS_CHEZMOI_ARCH=$carch render | yq -p toml -o json '.tools | keys | .[]' | tr -d '"' | sort | paste -sd, -)"
	assert_eq "$want" "$got" "tool set equals select-tools ($os-$sarch)"
	[ -n "$got" ] || fail "renders tools ($os-$sarch)"
done

# native_on per platform
out="$(TESTS_CHEZMOI_OS=linux TESTS_CHEZMOI_ARCH=amd64 render)"
assert_contains "$out" "aristocratos/btop" "btop pinned on linux"
out="$(TESTS_CHEZMOI_OS=darwin TESTS_CHEZMOI_ARCH=arm64 render)"
assert_not_contains "$out" "aristocratos/btop" "btop (native on darwin) not pinned on darwin"

# no blank line after [tools]
out="$(TESTS_CHEZMOI_OS=linux render)"
assert_eq "[tools]" "$(printf '%s\n' "$out" | sed -n 1p)" "pins start with [tools]"
assert_contains "$(printf '%s\n' "$out" | sed -n 2p)" ' = ' "no blank line after [tools]"

# MISE_SYSTEM_CONFIG_DIR is exported everywhere a mise shim can run
# shellcheck disable=SC2016  # literal $HOME is what the files contain
for f in home/dot_zshenv.tmpl home/dot_bashrc.tmpl home/dot_bash_profile.tmpl; do
	assert_contains "$(cat "$TESTS_REPO/$f")" 'export MISE_SYSTEM_CONFIG_DIR="$HOME/.config/mise-dotfiles"' "env var set in $f"
done
