#!/usr/bin/env bash
# The bootstrap Python toolchain pins in group_vars (read by install.sh with
# sed and by tasks/python.yml) equal the repo mise.toml pins, and install.sh
# installs exactly those (pinned uv installer, ansible-core==<pin>).
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
for k in uv_version ansible_core_version pre_commit_version; do
	pin_of "$k" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "$k is an exact version"
done

inst="$(cat install.sh)"
# shellcheck disable=SC2016 # literal text in install.sh
assert_contains "$inst" 'https://astral.sh/uv/$_uv_version/install.sh' "install.sh uses the pinned uv installer"
# shellcheck disable=SC2016
assert_contains "$inst" 'ansible-core==$_ansible_version' "install.sh pins ansible-core"
assert_not_contains "$inst" "brew install ansible" "install.sh: no brew ansible"
assert_not_contains "$inst" "apt-get install -y ansible" "install.sh: no apt ansible"
assert_not_contains "$inst" "dnf install -y ansible" "install.sh: no dnf ansible"
assert_contains "$(cat ansible/tasks/python.yml)" 'pre-commit=={{ pre_commit_version }}' "python.yml pins pre-commit"

# install.sh's sed reader returns the pins (it runs before ansible exists).
# shellcheck disable=SC1090
eval "$(sed -n '/^gv_pin() {/,/^}/p' install.sh)"
declare -F gv_pin >/dev/null || fail "install.sh defines gv_pin()"
assert_eq "$(sed -nE 's/^uv_version:[[:space:]]*"([^"]*)".*/\1/p' "$gv")" "$(gv_pin uv_version "$gv")" "install.sh gv_pin reads uv_version"
