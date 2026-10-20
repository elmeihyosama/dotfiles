#!/usr/bin/env bash
# The fresh-machine bootstrap pins Ansible writes before chezmoi exists
# (ansible/templates/mise-pins.toml.j2, core tools only) are byte-identical
# to what chezmoi renders from config.toml.tmpl for the same selection, so the
# first `chezmoi apply` changes nothing for the core set.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

j2="$TESTS_REPO/ansible/templates/mise-pins.toml.j2"
tmpl="$TESTS_REPO/home/dot_config/mise-dotfiles/config.toml.tmpl"
sel="$TESTS_REPO/scripts/select-tools.sh"
tools_yaml="$TESTS_REPO/home/.chezmoidata/tools.yaml"
d="$(mktemp -d)"
_tests_tmpdirs+=("$d")

[ -f "$j2" ] || fail "ansible/templates/mise-pins.toml.j2 exists"
command -v ansible >/dev/null 2>&1 || {
	fail "ansible not on PATH (repo toolchain: mise.toml pipx:ansible-core)"
	exit 1
}

# render_j2 OS PLAT OUT: what the playbook writes (core names, sorted)
render_j2() {
	local core
	core="$(yq -o=json '[.tools | to_entries | .[] | select(.value.group == "core") | .key] | sort' "$tools_yaml")"
	jq -n --argjson cat "$(yq -o=json '.' "$tools_yaml")" --argjson names "$core" \
		--arg os "$1" --arg plat "$2" \
		'{tool_catalog: $cat, mise_pin_names: $names, mise_pin_os: $os, mise_pin_plat: $plat}' >"$d/vars.json"
	(cd "$d" && ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_PYTHON_INTERPRETER=auto_silent \
		ansible localhost -c local -i localhost, -m ansible.builtin.template \
		-a "src=$j2 dest=$3" -e "@$d/vars.json" >"$d/ansible.log" 2>&1) || {
		fail "ansible template render ($1)"
		cat "$d/ansible.log" >&2
	}
}

for combo in darwin:arm64:arm64:macos-arm64 linux:amd64:x64:linux-x64; do
	IFS=: read -r os carch sarch plat <<<"$combo"
	core_sel="$("$sel" --os "$os" --arch "$sarch" --local /nonexistent |
		jq -c --argjson core "$(yq -o=json '[.tools | to_entries | .[] | select(.value.group == "core") | .key]' "$tools_yaml")" \
			'[.[] | select(.source == "mise" and (.name as $n | $core | index($n)))] | map(.name)')"
	TESTS_CHEZMOI_OS=$os TESTS_CHEZMOI_ARCH=$carch render_tmpl "$tmpl" "selected_tools=$core_sel" >"$d/chezmoi-$plat.toml" ||
		fail "chezmoi render ($plat)"
	render_j2 "$os" "$plat" "$d/ansible-$plat.toml"
	cmp "$d/chezmoi-$plat.toml" "$d/ansible-$plat.toml" >/dev/null || {
		fail "core pins: Ansible render equals chezmoi render ($plat)"
		diff "$d/chezmoi-$plat.toml" "$d/ansible-$plat.toml" >&2
	}
	assert_contains "$(cat "$d/ansible-$plat.toml")" '"aqua:jqlang/jq"' "core pins carry jq ($plat)"
	assert_not_contains "$(cat "$d/ansible-$plat.toml")" 'lazygit' "core pins: no non-core tool ($plat)"
done

# mise_options (rename_exe) render the same way in both templates.
jq -n --argjson cat "$(yq -o=json '.' "$tools_yaml")" \
	'{tool_catalog: $cat, mise_pin_names: ["editorconfig-checker", "fzf"], mise_pin_os: "linux", mise_pin_plat: "linux-x64"}' >"$d/vars.json"
(cd "$d" && ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_PYTHON_INTERPRETER=auto_silent \
	ansible localhost -c local -i localhost, -m ansible.builtin.template \
	-a "src=$j2 dest=$d/opts.toml" -e "@$d/vars.json" >/dev/null 2>&1) || fail "ansible render (options)"
TESTS_CHEZMOI_OS=linux TESTS_CHEZMOI_ARCH=amd64 render_tmpl "$tmpl" 'selected_tools=["editorconfig-checker","fzf"]' >"$d/opts-cz.toml"
cmp "$d/opts-cz.toml" "$d/opts.toml" >/dev/null || {
	fail "mise_options render identically"
	diff "$d/opts-cz.toml" "$d/opts.toml" >&2
}
