#!/usr/bin/env bash
# The dotfiles mise pins template (home/dot_config/mise-dotfiles/config.toml.tmpl):
# renders [tools] for selected_tools, falls back to "every mise-capable tool on
# this OS" when selected_tools is absent, and that fallback matches
# scripts/select-tools.sh's default selection.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmpl="$TESTS_REPO/home/dot_config/mise-dotfiles/config.toml.tmpl"
sel="$TESTS_REPO/scripts/select-tools.sh"
tools_yaml="$TESTS_REPO/home/.chezmoidata/tools.yaml"

render() { render_tmpl "$tmpl" "$@"; }

# selected_tools: only those, as "<backend>" = "<version>"; native_on is skipped.
out="$(TESTS_CHEZMOI_OS=darwin render 'selected_tools=["fzf","btop"]')"
assert_contains "$out" '"aqua:junegunn/fzf" = "0.67.0"' "selected: fzf line"
assert_not_contains "$out" 'btop' "selected: btop (native on darwin) has no line"
assert_not_contains "$out" 'ripgrep' "selected: unselected tool absent"
out="$(TESTS_CHEZMOI_OS=linux render 'selected_tools=["fzf","btop"]')"
assert_contains "$out" '"aqua:aristocratos/btop" = "1.4.7"' "selected: btop rendered on linux"

# mise_options render as mise's inline-table form
out="$(TESTS_CHEZMOI_OS=linux render 'selected_tools=["editorconfig-checker"]')"
assert_contains "$out" '"github:editorconfig-checker/editorconfig-checker" = { version = "4.0.2", rename_exe = "ec" }' "options: inline table"

# core-only selection (bootstrap order): renders, valid TOML, no non-core tool
core="$(yq '.tools | to_entries | .[] | select(.value.group == "core") | .key' "$tools_yaml" | paste -sd, - | sed 's/\([^,]*\)/"\1"/g')"
out="$(TESTS_CHEZMOI_OS=linux render "selected_tools=[$core]")"
assert_contains "$out" '"aqua:rossmacarthur/sheldon"' "core-only: core tool present"
assert_not_contains "$out" 'lazygit' "core-only: git tool absent"
assert_not_contains "$out" 'mise' "core-only: bootstrap mise itself is not pinned"
printf '%s\n' "$out" | yq -p toml -o json '.tools | length' >/dev/null || fail "core-only: output is valid TOML"

# empty selection still renders an (empty) valid [tools] table
out="$(TESTS_CHEZMOI_OS=linux render 'selected_tools=[]')"
assert_contains "$out" '[tools]' "empty selection: [tools] present"
assert_eq "0" "$(printf '%s\n' "$out" | yq -p toml '.tools | length')" "empty selection: no tools"

# mise_pins_all (used by relock.sh): every backend tool, ignores native_on
out="$(TESTS_CHEZMOI_OS=darwin render 'mise_pins_all=true')"
assert_contains "$out" '"aqua:aristocratos/btop" = "1.4.7"' "pins_all: btop present on darwin"

# fallback (no selected_tools) == select-tools.sh default, mise source, both OSes
for os in darwin linux; do
	want="$("$sel" --os "$os" --local /nonexistent | jq -r '.[] | select(.source == "mise") | .backend' | sort | paste -sd, -)"
	got="$(TESTS_CHEZMOI_OS=$os render | yq -p toml -o json '.tools | keys | .[]' | tr -d '"' | sort | paste -sd, -)"
	assert_eq "$want" "$got" "fallback tool set equals select-tools default ($os)"
	[ -n "$got" ] || fail "fallback renders tools ($os)"
done

# MISE_SYSTEM_CONFIG_DIR is exported everywhere a mise shim can run
# shellcheck disable=SC2016  # literal $HOME is what the files contain
for f in home/dot_zshenv.tmpl home/dot_bashrc.tmpl home/dot_bash_profile.tmpl home/dot_config/raycast/scripts/executable_*.sh; do
	assert_contains "$(cat "$TESTS_REPO/$f")" 'export MISE_SYSTEM_CONFIG_DIR="$HOME/.config/mise-dotfiles"' "env var set in $f"
done
