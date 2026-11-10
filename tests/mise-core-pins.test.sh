#!/usr/bin/env bash
# Ansible's bootstrap pins (mise-pins.toml.j2) are byte-identical to chezmoi's
# render, so the first apply changes nothing.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

j2="$TESTS_REPO/ansible/templates/mise-pins.toml.j2"
tmpl="$TESTS_REPO/home/dot_config/mise-dotfiles/config.toml.tmpl"
tools_yaml="$TESTS_REPO/home/.chezmoidata/tools.yaml"
d="$(mktemp -d)"
_tests_tmpdirs+=("$d")

[ -f "$j2" ] || fail "ansible/templates/mise-pins.toml.j2 exists"
command -v ansible >/dev/null 2>&1 || {
	fail "ansible not on PATH (repo toolchain: mise.toml pipx:ansible-core)"
	exit 1
}

# render_j2 OS PLAT OUT: what the playbook writes (every tool name, sorted)
render_j2() {
	local names
	names="$(yq -o=json '[.tools | keys | .[]] | sort' "$tools_yaml")"
	jq -n --argjson cat "$(yq -o=json '.' "$tools_yaml")" --argjson names "$names" \
		--arg os "$1" --arg plat "$2" \
		'{tool_catalog: $cat, mise_pin_names: $names, mise_pin_os: $os, mise_pin_plat: $plat}' >"$d/vars.json"
	(cd "$d" && ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_PYTHON_INTERPRETER=auto_silent \
		ansible localhost -c local -i localhost, -m ansible.builtin.template \
		-a "src=$j2 dest=$3" -e "@$d/vars.json" >"$d/ansible.log" 2>&1) || {
		fail "ansible template render ($1)"
		cat "$d/ansible.log" >&2
	}
}

for combo in darwin:arm64:macos-arm64 linux:amd64:linux-x64; do
	IFS=: read -r os carch plat <<<"$combo"
	TESTS_CHEZMOI_OS=$os TESTS_CHEZMOI_ARCH=$carch render_tmpl "$tmpl" >"$d/chezmoi-$plat.toml" ||
		fail "chezmoi render ($plat)"
	render_j2 "$os" "$plat" "$d/ansible-$plat.toml"
	cmp "$d/chezmoi-$plat.toml" "$d/ansible-$plat.toml" >/dev/null || {
		fail "pins: Ansible render equals chezmoi render ($plat)"
		diff "$d/chezmoi-$plat.toml" "$d/ansible-$plat.toml" >&2
	}
	assert_contains "$(cat "$d/ansible-$plat.toml")" '"aqua:jqlang/jq"' "pins carry jq ($plat)"
	assert_contains "$(cat "$d/ansible-$plat.toml")" 'lazygit' "pins carry every tool ($plat)"
done

# mise_options (atuin's matching_regex) are part of the full render above.
assert_contains "$(cat "$d/ansible-linux-x64.toml")" 'matching_regex = ' "mise_options render in both templates"
