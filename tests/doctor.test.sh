#!/usr/bin/env bash
# scripts/doctor.sh: the pinned mise (~/.local/bin/mise) must be the group_vars
# mise_version and must be the one on PATH (another mise ahead of it: FAIL, or
# WARN when it happens to match the pin), and assert-tools' shadowed-copy
# warnings surface as doctor WARN lines. --local /nonexistent keeps a repo
# ansible/local.yml (shared_home) out of the tests.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

doctor="$TESTS_REPO/scripts/doctor.sh"
want="$(sed -nE 's/^mise_version: *"([^"]+)".*/\1/p' "$TESTS_REPO/ansible/group_vars/all.yml")"
[ -n "$want" ] || fail "group_vars has a mise_version"

mk_home
mkdir -p "$HOME/.local/bin" "$HOME/tbin"
for t in yq jq; do ln -s "$(command -v "$t")" "$HOME/tbin/$t"; done
stub_mise() { # stub_mise VERSION [FILE]: a mise that only reports its version
	local f="${2:-$HOME/.local/bin/mise}"
	mkdir -p "$(dirname "$f")"
	printf '#!/bin/sh\necho "%s macos-arm64 (2026-01-01)"\n' "$1" >"$f"
	chmod +x "$f"
}
run() { # run [PATH-PREFIX]
	out="$(cd "$HOME" && env -i HOME="$HOME" HOMEBREW_PREFIX="$HOME/brew" \
		PATH="${1:+$1:}$HOME/.local/bin:$HOME/tbin:/usr/bin:/bin" \
		sh "$doctor" --local /nonexistent 2>&1)"
}

stub_mise "$want"
run
assert_contains "$out" "OK    mise $want at $HOME/.local/bin/mise (ansible/group_vars mise_version)" "mise_version_ok"
assert_not_contains "$out" "shadows" "mise_version_ok: nothing shadows it"

# A Homebrew mise ahead of the pinned one: the playbook cannot fix that, so
# doctor names both binaries and the removal command.
stub_mise 2000.1.1 "$HOME/brew/Cellar/mise/2000.1.1/bin/mise"
mkdir -p "$HOME/brew/bin"
ln -s ../Cellar/mise/2000.1.1/bin/mise "$HOME/brew/bin/mise"
run "$HOME/brew/bin"
assert_contains "$out" "OK    mise $want at $HOME/.local/bin/mise" "shadowing_mise: the pinned one is still checked"
assert_contains "$out" "FAIL  mise 2000.1.1 at $HOME/brew/bin/mise shadows the pinned $HOME/.local/bin/mise (mise_version $want); remove it with: brew uninstall mise" \
	"shadowing_mise_wrong_version_fails: both paths and the brew remedy"
assert_not_contains "$out" "--tags mise" "shadowing_mise_wrong_version_fails: no playbook remedy"
# ... and one that matches the pin is still a WARN, never a silent OK
rm "$HOME/brew/bin/mise"
stub_mise "$want" "$HOME/brew/Cellar/mise/$want/bin/mise"
ln -s "../Cellar/mise/$want/bin/mise" "$HOME/brew/bin/mise"
run "$HOME/brew/bin"
assert_contains "$out" "WARN  mise $want at $HOME/brew/bin/mise shadows the pinned $HOME/.local/bin/mise; remove it with: brew uninstall mise" \
	"shadowing_mise_same_version_warns"
assert_not_contains "$out" "FAIL  mise" "shadowing_mise_same_version_warns: not a FAIL"
rm -rf "$HOME/brew"

stub_mise 2000.1.1
run
assert_contains "$out" "FAIL  mise 2000.1.1 at $HOME/.local/bin/mise, but ansible/group_vars pins mise_version $want (rerun the playbook: --tags mise)" \
	"mise_version_mismatch_fails"

rm "$HOME/.local/bin/mise"
run
assert_contains "$out" "FAIL  pinned mise missing at $HOME/.local/bin/mise" "mise_missing_fails: names the pinned path"
assert_contains "$out" "FAIL  mise not on PATH" "mise_missing_fails: none on PATH"

# pinned_missing_brew_mise: an existing Mac after chezmoi apply, before the
# playbook: only the Homebrew mise. One FAIL for the missing pin; no
# "shadows the pinned <nonexistent>" line on top.
stub_mise 2000.1.1 "$HOME/brew/Cellar/mise/2000.1.1/bin/mise"
mkdir -p "$HOME/brew/bin"
ln -s ../Cellar/mise/2000.1.1/bin/mise "$HOME/brew/bin/mise"
run "$HOME/brew/bin"
assert_contains "$out" "FAIL  pinned mise missing at $HOME/.local/bin/mise" "pinned_missing_brew_mise: names the missing pin"
assert_not_contains "$out" "shadows the pinned" "pinned_missing_brew_mise: no shadow line for a missing pin"
rm -rf "$HOME/brew"

# relative_local_and_tools: --local / --tools relative to the caller's cwd
# still resolve after doctor's cd / (a lost --local means "all groups").
stub_mise "$want"
printf -- '---\nshared_home: true\n' >"$HOME/rel-local.yml"
stub_mise "$want" "$HOME/.local/bin-$(uname -m)/mise"
out="$(cd "$HOME" && env -i HOME="$HOME" PATH="$HOME/.local/bin-$(uname -m):$HOME/tbin:/usr/bin:/bin" \
	sh "$doctor" --local rel-local.yml 2>&1)"
assert_contains "$out" "OK    mise $want at $HOME/.local/bin-$(uname -m)/mise" "relative_local: shared_home read from a relative --local"
printf 'tool_groups: [core]\ntools:\n  nosuchtool: {group: core, native_only: true, bin: nosuchtool-bin}\n' >"$HOME/rel-tools.yaml"
out="$(cd "$HOME" && env -i HOME="$HOME" PATH="$HOME/.local/bin:$HOME/tbin:/usr/bin:/bin" \
	sh "$doctor" --local /nonexistent --tools rel-tools.yaml 2>&1)"
assert_contains "$out" "nosuchtool-bin" "relative_tools: the relative --tools catalog is the one checked"
rm -rf "$HOME/.local/bin-$(uname -m)" "$HOME/rel-local.yml" "$HOME/rel-tools.yaml" "$HOME/.local/bin/mise"

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
	sh "$doctor" --local /nonexistent --tools "$HOME/tools.yaml" 2>&1)"
assert_contains "$out" "OK    selected tools all present and runnable" "shadow case: tools pass"
assert_contains "$out" "WARN  fzf also installed at $HOME/other/fzf (shadowed); remove with: rm $HOME/other/fzf" \
	"shadowed copy surfaces as a doctor WARN"
