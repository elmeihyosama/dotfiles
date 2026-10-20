#!/usr/bin/env bash
# .github/scripts/assert-tools.sh: mise tools resolve (via the dotfiles pins,
# from outside any repo) to the exact tools.yaml version and win on PATH;
# non-mise copies further back are reported as shadowed.
#
# Uses the real mise (offline) over a fake install tree: an
# installs/aqua-junegunn-fzf/<ver>/fzf script and a shim symlinked to mise, so
# `mise which`, the shim and config resolution are mise's own behaviour.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

real_mise="$(command -v mise 2>/dev/null)" || {
	echo "SKIP: no mise on PATH" >&2
	exit 0
}
script="$TESTS_REPO/.github/scripts/assert-tools.sh"

mk_home
data="$HOME/.local/share/mise"
mkdir -p "$HOME/.local/bin" "$HOME/tbin" "$data/shims" "$HOME/.config/mise-dotfiles"
ln -s "$real_mise" "$HOME/.local/bin/mise"
for t in yq jq; do ln -s "$(command -v "$t")" "$HOME/tbin/$t"; done
ln -s "$HOME/.local/bin/mise" "$data/shims/fzf"

fake() { # fake PATH OUTPUT
	mkdir -p "$(dirname "$1")"
	printf '#!/bin/sh\necho %s\n' "$2" >"$1"
	chmod +x "$1"
}
fake "$data/installs/aqua-junegunn-fzf/0.67.0/fzf" 0.67.0
fake "$data/installs/aqua-junegunn-fzf/0.66.0/fzf" 0.66.0

catalog() { # catalog FZF_VERSION
	printf '{"tool_groups": ["core"], "tools": {"mise": {"group": "core", "bootstrap": true, "version": "1.0.0"}, "fzf": {"group": "core", "backend": "aqua:junegunn/fzf", "version": "%s"}}}\n' "$1" >"$HOME/tools.yaml"
}
pins() { printf '[tools]\n"aqua:junegunn/fzf" = "%s"\n' "$1" >"$HOME/.config/mise-dotfiles/config.toml"; }

# run [CWD] [PATH]: assert-tools in a clean env; sets out, rc
run() {
	local cwd="${1:-$HOME}" p="${2:-$HOME/tbin:/usr/bin:/bin}"
	out="$(cd "$cwd" && env -i HOME="$HOME" PATH="$p" MISE_OFFLINE=1 \
		MISE_CACHE_DIR="$HOME/cache" MISE_STATE_DIR="$HOME/state" ${HB:+HOMEBREW_PREFIX="$HB"} \
		sh "$script" --local /nonexistent --tools "$HOME/tools.yaml" 2>&1)"
	rc=$?
}

# pinned_ok
catalog 0.67.0
pins 0.67.0
run
assert_eq 0 "$rc" "pinned_ok: exit 0 ($out)"
assert_contains "$out" "OK:   fzf -> fzf 0.67.0" "pinned_ok: fzf at the pinned version"
assert_not_contains "$out" "WARN" "pinned_ok: nothing shadowed"

# home pins are resolved outside the repo dir: a project mise.toml in the cwd
# (like the repo's own lint toolchain) and the user's global config pin 0.66.0
mkdir -p "$HOME/repo" "$HOME/.config/mise"
printf '[tools]\n"aqua:junegunn/fzf" = "0.66.0"\n' >"$HOME/repo/mise.toml"
printf '[tools]\n"aqua:junegunn/fzf" = "0.66.0"\n' >"$HOME/.config/mise/config.toml"
run "$HOME/repo"
assert_eq 0 "$rc" "repo_mise_toml_ignored: exit 0 ($out)"
assert_contains "$out" "OK:   fzf -> fzf 0.67.0" "repo_mise_toml_ignored: home pin wins"
rm -rf "$HOME/repo" "$HOME/.config/mise"

# wrong_version_fails: tools.yaml was bumped but the installed pins are older
catalog 0.68.0
run
assert_eq 1 "$rc" "wrong_version_fails: exit 1"
assert_contains "$out" "FAIL: fzf" "wrong_version_fails: names the tool"
assert_contains "$out" "0.67.0" "wrong_version_fails: shows the resolved version"
assert_contains "$out" "0.68.0" "wrong_version_fails: shows the pinned version"
# ... and a pin that is not installed at all
pins 0.68.0
run
assert_eq 1 "$rc" "pin_not_installed_fails: exit 1"
assert_contains "$out" "FAIL: fzf" "pin_not_installed_fails: names the tool"
catalog 0.67.0
pins 0.67.0

# stale_install_dir_fails: an old install dir (left on PATH by a stale
# activated shell) runs 0.66.0 though mise which reports the pin
run "$HOME" "$HOME/tbin:$data/installs/aqua-junegunn-fzf/0.66.0:$data/shims:/usr/bin:/bin"
assert_eq 1 "$rc" "stale_install_dir_fails: exit 1 ($out)"
assert_contains "$out" "FAIL: fzf -> 'fzf' resolves to $data/installs/aqua-junegunn-fzf/0.66.0/fzf" \
	"stale_install_dir_fails: names the stale install"

# a mise warning on stderr does not break the version comparison
mkdir -p "$HOME/noisy"
printf '#!/bin/sh\necho "mise WARN  a newer mise is available" >&2\nexec "%s" "$@"\n' "$real_mise" >"$HOME/noisy/mise"
chmod +x "$HOME/noisy/mise"
run "$HOME" "$HOME/noisy:$HOME/tbin:/usr/bin:/bin"
assert_eq 0 "$rc" "stderr_noise_ignored: exit 0 ($out)"

# shadowed_copy_warns: a Homebrew fzf behind mise's on PATH
mkdir -p "$HOME/brew/bin"
fake "$HOME/brew/Cellar/fzf/0.60.0/bin/fzf" 0.60.0
ln -s ../Cellar/fzf/0.60.0/bin/fzf "$HOME/brew/bin/fzf"
fake "$HOME/other/fzf" other
HB="$HOME/brew"
run "$HOME" "$HOME/tbin:$data/shims:$HOME/brew/bin:$HOME/other:/usr/bin:/bin"
assert_eq 0 "$rc" "shadowed_copy_warns: still passes ($out)"
assert_contains "$out" "WARN: fzf also installed at $HOME/brew/bin/fzf (shadowed); remove with: brew uninstall fzf" \
	"shadowed_copy_warns: brew copy named with its formula"
assert_contains "$out" "WARN: fzf also installed at $HOME/other/fzf (shadowed); remove with: rm $HOME/other/fzf" \
	"shadowed_copy_warns: other copy"

# shadowing_copy_fails: the Homebrew fzf comes first, so mise's never runs
run "$HOME" "$HOME/tbin:$HOME/brew/bin:$data/shims:/usr/bin:/bin"
assert_eq 1 "$rc" "shadowing_copy_fails: exit 1"
assert_contains "$out" "FAIL: fzf -> 'fzf' resolves to $HOME/brew/bin/fzf, not mise's" \
	"shadowing_copy_fails: names the winning copy"
assert_contains "$out" "brew uninstall fzf" "shadowing_copy_fails: removal hint"
unset HB

# the old positional LOCAL_YML usage is gone
out="$(sh "$script" /nonexistent 2>&1)"
assert_eq 2 "$?" "positional argument rejected (usage, exit 2)"
assert_contains "$out" "usage: " "positional argument: prints usage"
