#!/usr/bin/env bash
# group_vars' bootstrap Python pins equal the repo mise.toml's, and install.sh
# and CI's provision matrix install exactly those.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$TESTS_REPO" || exit 1
gv=ansible/group_vars/all.yml
pin_of() { sed -nE "s/^$1:[[:space:]]*\"([^\"]*)\".*/\\1/p" "$gv"; }
toml_pin() { yq -p toml -o json '.tools' mise.toml | jq -r --arg k "$1" '.[$k] | if type == "object" then .version else . end'; }

assert_eq "$(toml_pin aqua:astral-sh/uv)" "$(pin_of uv_version)" "uv_version equals mise.toml"
assert_eq "$(toml_pin pipx:ansible-core)" "$(pin_of ansible_core_version)" "ansible_core_version equals mise.toml"
assert_eq "$(toml_pin pipx:pre-commit)" "$(pin_of pre_commit_version)" "pre_commit_version equals mise.toml"
assert_eq "$(toml_pin python)" "$(pin_of python_version)" "python_version equals mise.toml python (exact patch)"
for k in uv_version ansible_core_version pre_commit_version python_version; do
	pin_of "$k" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "$k is an exact version"
done

inst="$(cat install.sh)"
# shellcheck disable=SC2016 # literal text in install.sh
assert_contains "$inst" 'https://github.com/astral-sh/uv/releases/download/$_uv_version/uv-installer.sh' "install.sh uses the pinned uv installer"
pin_of uv_installer_sha256 | grep -Eq '^[0-9a-f]{64}$' || fail "uv_installer_sha256 is 64 hex"
# shellcheck disable=SC2016
assert_contains "$inst" '"$(sha256_of "$_uv_inst")" != "$_uv_sha"' "install.sh checks the uv installer's sha256"
assert_eq "" "$(grep -vE '^[[:space:]]*#' install.sh | grep -E 'curl[[:space:]]+-[^#]*[|]' || true)" "install.sh pipes no download into sh (it checks the file first)"
# shellcheck disable=SC2016
assert_contains "$inst" '--python "$_python_version"' "install.sh installs ansible-core on the pinned Python"
# shellcheck disable=SC2016
assert_contains "$inst" 'ansible-core==$_ansible_version' "install.sh pins ansible-core"
assert_not_contains "$inst" "brew install ansible" "install.sh: no brew ansible"
assert_not_contains "$inst" "apt-get install -y ansible" "install.sh: no apt ansible"
assert_not_contains "$inst" "dnf install -y ansible" "install.sh: no dnf ansible"
assert_contains "$(cat ansible/tasks/python.yml)" 'pre-commit=={{ pre_commit_version }}' "python.yml pins pre-commit"

# install.sh's sed reader returns the pins.
# shellcheck disable=SC1090
eval "$(sed -n '/^gv_pin() {/,/^}/p' install.sh)"
declare -F gv_pin >/dev/null || fail "install.sh defines gv_pin()"
assert_eq "$(sed -nE 's/^uv_version:[[:space:]]*"([^"]*)".*/\1/p' "$gv")" "$(gv_pin uv_version "$gv")" "install.sh gv_pin reads uv_version"

# CI's provision matrix pins the same ansible-core (Arch: pacman's).
ci="$(cat .github/scripts/provision-ci.sh)"
# shellcheck disable=SC2016
assert_contains "$ci" 'ANSIBLE_CORE="$(gv_pin ansible_core_version)"' "provision-ci.sh reads ansible_core_version"
unpinned="$(grep -vE '^[[:space:]]*#' .github/scripts/provision-ci.sh | grep -E 'install[^#]*ansible-core([^=]|$)' | grep -v pacman || true)"
assert_eq "" "$unpinned" "provision-ci.sh installs no unpinned ansible-core outside pacman"
