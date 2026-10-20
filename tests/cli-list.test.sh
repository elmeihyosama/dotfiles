#!/usr/bin/env bash
# scripts/dotfiles.sh: list --json shape and sort, selected/installed/actual
# fields, the mismatch marker in the table, and doctor delegation.
# mise is a stub printing fixed `ls --json`; yq/jq are the real ones.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$TESTS_REPO/scripts/dotfiles.sh"
mk_home
mkdir -p "$HOME/bin" "$HOME/nbin"
# real binaries, not mise shims (the test env has no mise to resolve them)
for t in yq jq; do
	ln -s "$(mise which "$t" 2>/dev/null || command -v "$t")" "$HOME/bin/$t"
done
cat >"$HOME/bin/mise" <<'STUB'
#!/bin/sh
# only `-C / ls --json` is expected
[ "$3" = ls ] || exit 1
cat "$STUB_MISE_LS"
STUB
chmod +x "$HOME/bin/mise"
# a native tool that "resolves on PATH"
printf '#!/bin/sh\n' >"$HOME/nbin/natbin"
chmod +x "$HOME/nbin/natbin"

printf '%s\n' '{tool_groups: [core, dev], tools: {' \
	'mise: {group: core, bootstrap: true, version: "1.0.0"},' \
	'zed: {group: core, backend: "aqua:x/zed", version: "2.0.0"},' \
	'alpha: {group: core, backend: "aqua:x/alpha", version: "1.0.0"},' \
	'hx: {group: dev, backend: "aqua:x/hx", version: "3.0.0"},' \
	'nat: {group: dev, bin: natbin, native_only: true}}}' >"$HOME/tools.yaml"
printf 'tool_groups: [core]\n' >"$HOME/local.yml"
STUB_MISE_LS="$HOME/ls.json"
export STUB_MISE_LS
cat >"$STUB_MISE_LS" <<'J'
{"aqua:x/alpha": [{"version": "1.0.0", "installed": true, "active": true}],
"aqua:x/zed": [{"version": "1.5.0", "installed": true, "active": false}, {"version": "2.0.0", "installed": false, "active": true}]}
J

run() { # run ARGS...: sets out, rc
	out="$(env -i HOME="$HOME" PATH="$HOME/bin:$HOME/nbin:/usr/bin:/bin" STUB_MISE_LS="$STUB_MISE_LS" \
		DOTFILES_LOCAL_YML="$HOME/local.yml" DOTFILES_TOOLS_YAML="$HOME/tools.yaml" sh "$script" "$@" 2>&1)"
	rc=$?
}

# json_shape
run list --json
assert_eq 0 "$rc" "json_shape: exit 0 ($out)"
keys="$(printf '%s' "$out" | jq -c '.[0] | keys')"
assert_eq '["actual","bin","group","installed","name","pinned","selected","source"]' "$keys" "json_shape: keys"
assert_eq "alpha,mise,zed,hx,nat" "$(printf '%s' "$out" | jq -r 'map(.name) | join(",")')" "json_shape: sorted by group order then name"
assert_eq "false" "$(printf '%s' "$out" | jq -r '.[] | select(.name == "hx") | .selected')" "json_shape: deselected group tool not selected"
assert_eq "true" "$(printf '%s' "$out" | jq -r '.[] | select(.name == "alpha") | .selected')" "json_shape: selected tool"
assert_eq "mise" "$(printf '%s' "$out" | jq -r '.[] | select(.name == "hx") | .source')" "json_shape: unselected keeps its source"
assert_eq "bootstrap" "$(printf '%s' "$out" | jq -r '.[] | select(.name == "mise") | .source')" "json_shape: select-tools enum passes through"
assert_eq "1.0.0 1.0.0 true" "$(printf '%s' "$out" | jq -r '.[] | select(.name == "alpha") | "\(.pinned) \(.actual) \(.installed)"')" "json_shape: installed mise tool"
assert_eq "2.0.0 1.5.0 true" "$(printf '%s' "$out" | jq -r '.[] | select(.name == "zed") | "\(.pinned) \(.actual) \(.installed)"')" "json_shape: actual is the installed version"
assert_eq "3.0.0 null false" "$(printf '%s' "$out" | jq -r '.[] | select(.name == "hx") | "\(.pinned) \(.actual) \(.installed)"')" "json_shape: not installed"
assert_eq "null null true" "$(printf '%s' "$out" | jq -r '.[] | select(.name == "nat") | "\(.pinned) \(.actual) \(.installed)"')" "json_shape: native installed = bin on PATH"

# missing local.yml: select-tools defaults (every group) apply
out="$(env -i HOME="$HOME" PATH="$HOME/bin:$HOME/nbin:/usr/bin:/bin" STUB_MISE_LS="$STUB_MISE_LS" \
	DOTFILES_LOCAL_YML=/nonexistent DOTFILES_TOOLS_YAML="$HOME/tools.yaml" sh "$script" list --json 2>&1)"
assert_eq "true" "$(printf '%s' "$out" | jq -r '.[] | select(.name == "hx") | .selected')" "no_local_yml: all groups selected"

# mismatch_shown
run list
assert_eq 0 "$rc" "mismatch_shown: exit 0 ($out)"
assert_contains "$out" "1.5.0≠2.0.0" "mismatch_shown: actual≠pinned in the table"
assert_contains "$out" "✓ alpha" "mismatch_shown: selected mark"
assert_contains "$out" "· hx" "mismatch_shown: unselected mark"

# usage errors exit 2
run bogus
assert_eq 2 "$rc" "unknown_subcommand: exit 2"
run list --nope
assert_eq 2 "$rc" "unknown_list_flag: exit 2"
run help
assert_eq 0 "$rc" "help: exit 0"
assert_contains "$out" "usage: dotfiles" "help: prints usage"

# doctor_delegates: doctor.sh's own usage error proves it was exec'd with the args
run doctor --bogus
assert_eq 2 "$rc" "doctor_delegates: exit status of doctor.sh"
assert_contains "$out" "usage: doctor.sh" "doctor_delegates: doctor.sh ran"
