#!/usr/bin/env sh
# Assert every tool this machine selects resolves, runs, and passes its smoke test.
# Usage: .github/scripts/assert-tools.sh [LOCAL_YML]   (default: ansible/local.yml)
# The tool set comes from scripts/select-tools.sh over home/.chezmoidata/tools.yaml
# (one source of truth with the playbook). mise / bootstrap / bundled tools are
# required; native tools (brew/distro packages, best effort) are checked only
# when present. Runs from / so no repo mise.toml shadows the dotfiles pins.
set -eu

repo="$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)"
local_yml="${1:-$repo/ansible/local.yml}"

# Same layout as ansible/group_vars/all.yml (mise_env): the dotfiles pins dir
# and the (per-arch under shared_home) shims first, then the local bin.
shared_home=false
if [ -f "$local_yml" ] && grep -Eq '^[[:space:]]*shared_home:[[:space:]]*true' "$local_yml"; then
	shared_home=true
fi
if [ "$shared_home" = true ]; then
	sfx="-$(uname -m)"
else
	sfx=""
fi
export MISE_SYSTEM_CONFIG_DIR="${MISE_SYSTEM_CONFIG_DIR:-$HOME/.config/mise-dotfiles}"
export MISE_DATA_DIR="${MISE_DATA_DIR:-$HOME/.local/share$sfx/mise}"
export PATH="$MISE_DATA_DIR/shims:$HOME/.local/bin$sfx:$HOME/.local/bin:$PATH"
cd /

for t in yq jq; do
	command -v "$t" >/dev/null 2>&1 || {
		echo "FAIL: $t not on PATH (provision did not install the core tools)"
		exit 1
	}
done

case "$(uname -s)" in Darwin) os=darwin ;; *) os=linux ;; esac
sel="$("$repo/scripts/select-tools.sh" --os "$os" --local "$local_yml")"
tools_yaml="$repo/home/.chezmoidata/tools.yaml"

fail=0
for row in $(printf '%s\n' "$sel" | jq -r '.[] | "\(.name):\(.bin):\(.source)"'); do
	tool="${row%%:*}"
	rest="${row#*:}"
	bin="${rest%%:*}"
	source="${rest#*:}"

	if ! command -v "$bin" >/dev/null 2>&1; then
		if [ "$source" = native ]; then
			echo "SKIP: $tool -> '$bin' (native, best effort: not installed here)"
		else
			echo "FAIL: $tool -> '$bin' not found on PATH"
			fail=1
		fi
		continue
	fi
	if ! out="$("$bin" --version 2>&1)"; then
		echo "FAIL: $tool -> '$bin' did not run '--version': $(printf '%s' "$out" | head -n1)"
		fail=1
		continue
	fi

	# `--version` is answered by the binary alone, so it cannot see a missing
	# install tree (a neovim without share/nvim/runtime passes it and is still
	# unusable). Tools with a smoke test must also exit 0 AND stay silent —
	# nvim prints E484 on a broken runtime but still exits 0, so check output.
	smoke="$(yq ".tools.\"$tool\".smoke // \"\"" "$tools_yaml")"
	if [ -n "$smoke" ]; then
		if ! sout="$(sh -c "$smoke" 2>&1)" || [ -n "$sout" ]; then
			echo "FAIL: $tool -> smoke test failed: $(printf '%s' "$sout" | head -n1)"
			fail=1
			continue
		fi
	fi
	echo "OK:   $tool -> $bin ($source: $(command -v "$bin"))"
done

[ "$fail" -eq 0 ] && echo "All tool assertions passed." || echo "Tool assertions FAILED."
exit "$fail"
