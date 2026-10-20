#!/usr/bin/env bash
# scripts/select-tools.sh: group/add/remove selection and per-OS source.
source "$(dirname "$0")/lib.sh"

sel="$TESTS_REPO/scripts/select-tools.sh"
tools_yaml="$TESTS_REPO/home/.chezmoidata/tools.yaml"
d="$(mktemp -d)"
_tests_tmpdirs+=("$d")

run() { # run OS LOCAL_CONTENT -> stdout; stderr to $d/err; sets rc
	local os="$1"
	printf '%s' "$2" >"$d/local.yml"
	out="$("$sel" --os "$os" --local "$d/local.yml" 2>"$d/err")"
	rc=$?
}
names() { jq -r '.[].name' <<<"$out" | paste -sd, -; }
field() { jq -r --arg n "$1" --arg f "$2" '.[] | select(.name == $n) | .[$f] // "null"' <<<"$out"; }

# default_all: no selection keys -> every tool in the catalog
run linux ''
all="$(yq '.tools | keys | .[]' "$tools_yaml" | sort | paste -sd, -)"
assert_eq 0 "$rc" "default_all: exit 0"
assert_eq "$all" "$(names)" "default_all: every tool selected"
assert_eq "$(names)" "$(jq -r '[.[].name] | sort | join(",")' <<<"$out")" "default_all: sorted by name"

# groups_subset: core + named groups only
run linux 'tool_groups: [git]'
assert_eq 0 "$rc" "groups_subset: exit 0"
assert_contains "$(names)" "lazygit" "groups_subset: git tool present"
assert_contains "$(names)" "ripgrep" "groups_subset: core present"
assert_not_contains "$(names)" "lazydocker" "groups_subset: containers absent"
assert_not_contains "$(names)" "cava" "groups_subset: media absent"
run linux 'tool_groups: []'
assert_not_contains "$(names)" "lazygit" "groups_subset: empty list is core only"
assert_contains "$(names)" "jq" "groups_subset: empty list keeps core"

# add_remove
run linux $'tool_groups: [git]\ntools_add: [lazydocker]\ntools_remove: [gh-dash]'
assert_eq 0 "$rc" "add_remove: exit 0"
assert_contains "$(names)" "lazydocker" "add_remove: added"
assert_not_contains "$(names)" "gh-dash" "add_remove: removed"
run linux $'tool_groups: [files]\ntools_remove: [age]'
assert_not_contains "$(names)" "age" "add_remove: removing provider drops age-keygen too"

# age-keygen follows age and is never installed on its own
run linux ''
assert_eq age "$(field age-keygen provided_by)" "provided_by recorded"
assert_eq null "$(field age-keygen version)" "provided_by has no version"
assert_eq null "$(field age-keygen backend)" "provided_by has no backend"
assert_eq bundled "$(field age-keygen source)" "age-keygen is bundled"

# core_cannot_be_removed
run linux 'tools_remove: [fzf]'
assert_eq 2 "$rc" "core_cannot_be_removed: exit 2"
assert_contains "$(cat "$d/err")" "fzf" "core_cannot_be_removed: names tool"

# unknown_group_fails / unknown tool
run linux 'tool_groups: [nope]'
assert_eq 2 "$rc" "unknown_group_fails: exit 2"
assert_contains "$(cat "$d/err")" "unknown group: nope (valid: core, git," "unknown_group_fails: message"
run linux 'tools_add: [nope]'
assert_eq 2 "$rc" "unknown_tool: exit 2"
assert_contains "$(cat "$d/err")" "unknown tool: nope" "unknown_tool: message"

# btop_darwin_native
run darwin ''
assert_eq native "$(field btop source)" "btop_darwin_native: darwin native"
assert_eq null "$(field btop version)" "btop_darwin_native: no version"
assert_eq null "$(field btop backend)" "btop_darwin_native: no backend"
run linux ''
assert_eq mise "$(field btop source)" "btop linux: mise"
assert_eq aqua:aristocratos/btop "$(field btop backend)" "btop linux: backend"

# cava_native_only
for os in darwin linux; do
	run "$os" ''
	assert_eq native "$(field cava source)" "cava_native_only: $os"
	assert_eq null "$(field cava backend)" "cava_native_only: $os no backend"
done

# bin defaults and overrides; bootstrap
run linux ''
assert_eq rg "$(field ripgrep bin)" "bin override"
assert_eq fzf "$(field fzf bin)" "bin defaults to name"
assert_eq ec "$(field editorconfig-checker bin)" "ec bin"
assert_eq bootstrap "$(field mise source)" "mise is bootstrap"

# missing local file is the default selection
out="$("$sel" --os linux --local "$d/absent.yml")"
assert_eq "$all" "$(names)" "missing local.yml: default selection"

# yaml_has_every_legacy_tool: the pre-mise group_vars `tools` list (removed
# from group_vars; tools.yaml is now the only catalog)
for t in chezmoi atuin sheldon zellij navi starship zoxide eza bat fd ripgrep fzf \
	git-delta lazygit lazydocker yazi jq yq gh dust duf btop neovim gitleaks \
	editorconfig-checker fastfetch git-absorb gh-dash mise cava vivid hyperfine xh \
	jless watchexec age age-keygen; do
	if [ "$(yq ".tools | has(\"$t\")" "$tools_yaml")" != true ]; then
		fail "yaml_has_every_legacy_tool: $t missing from tools.yaml"
	fi
done
# legacy_keys_gone: group_vars no longer carries the ubi/brew/native install keys
for k in tools ubi_tool_repos ubi_exe_overrides ubi_extract_all ubi_archive_exe_overrides \
	ubi_match_overrides ubi_matching_regex_overrides ubi_unavailable force_ubi min_versions \
	brew_formula_overrides brew_bin_renames brew_unavailable native_pkg_overrides \
	native_bin_renames tool_smoke_tests; do
	assert_eq false "$(yq "has(\"$k\")" "$TESTS_REPO/ansible/group_vars/all.yml")" "legacy group_vars key removed: $k"
done

# no tool may pin "latest"
bad="$(yq -o=json '.' "$tools_yaml" | jq -r '.tools | to_entries[] | select((.value.version // "") == "latest") | .key')"
assert_eq "" "$bad" "no latest pins"

# source enum, and mise entries are fully pinned (both OSes)
for os in darwin linux; do
	run "$os" ''
	bad="$(jq -r '.[] | select([.source] | inside(["mise", "native", "bootstrap", "bundled"]) | not) | .name' <<<"$out")"
	assert_eq "" "$bad" "source enum ($os)"
	bad="$(jq -r '.[] | select(.source == "mise" and (.backend == null or .version == null)) | .name' <<<"$out")"
	assert_eq "" "$bad" "mise entries have backend and version ($os)"
done

# versions shared with the repo mise.toml must agree (matched on backend)
yq -o=json '.' "$tools_yaml" | jq -r '.tools | to_entries[] | select(.value.backend) | "\(.value.backend)\t\(.key)\t\(.value.version)"' >"$d/cat.tsv"
yq -p toml -o json '.tools' "$TESTS_REPO/mise.toml" |
	jq -r 'to_entries[] | "\(.key)\t\(.value | if type == "object" then .version else . end)"' >"$d/pins.tsv"
overlap=0
while IFS=$'\t' read -r backend name ver; do
	pin="$(awk -F'\t' -v b="$backend" '$1 == b { print $2 }' "$d/pins.tsv")"
	[ -n "$pin" ] || continue
	overlap=$((overlap + 1))
	assert_eq "$pin" "$ver" "tools.yaml pin for $name matches mise.toml"
done <"$d/cat.tsv"
[ "$overlap" -ge 4 ] || fail "expected >=4 overlapping tools with mise.toml, found $overlap"

# scalar instead of list -> friendly exit 2
for k in tool_groups tools_add tools_remove; do
	run linux "$k: git"
	assert_eq 2 "$rc" "scalar $k: exit 2"
	assert_contains "$(cat "$d/err")" "$k must be a list" "scalar $k: message"
	assert_not_contains "$(cat "$d/err")" "jq: error" "scalar $k: no raw jq error"
done

# provided_by tool added without its provider
run linux $'tool_groups: [git]\ntools_add: [age-keygen]'
assert_eq 2 "$rc" "age-keygen without age: exit 2"
assert_contains "$(cat "$d/err")" "age-keygen comes with age; add age instead" "age-keygen without age: message"
run linux $'tool_groups: [git]\ntools_add: [age, age-keygen]'
assert_eq 0 "$rc" "age-keygen with age: ok"

# missing_on: a tool with no asset for <os>-<arch> is native there, mise elsewhere
src_of() { "$sel" --os "$1" --arch "$2" --local /nonexistent | jq -r --arg n "$3" '.[] | select(.name == $n) | .source'; }
assert_eq native "$(src_of linux arm64 git-absorb)" "missing_on: git-absorb native on linux-arm64"
assert_eq mise "$(src_of linux x64 git-absorb)" "missing_on: git-absorb mise on linux-x64"
assert_eq native "$(src_of linux x64 jless)" "native_on: jless native on linux"
assert_eq mise "$(src_of darwin arm64 jless)" "native_on: jless mise on macos-arm64"
assert_eq native "$(src_of darwin arm64 navi)" "native_on: navi native on darwin"
assert_eq mise "$(src_of linux arm64 navi)" "native_on: navi mise on linux"
if "$sel" --os linux --arch riscv --local /nonexistent >/dev/null 2>&1; then fail "bad --arch is rejected"; fi
# --platform <os>-<arch> is the same as --os/--arch
plat_src() { "$sel" --platform "$1" --local /nonexistent | jq -r --arg n "$2" '.[] | select(.name == $n) | .source'; }
assert_eq native "$(plat_src linux-arm64 git-absorb)" "--platform linux-arm64 maps to linux/arm64"
assert_eq mise "$(plat_src macos-arm64 jless)" "--platform macos-arm64 maps to darwin/arm64"
if "$sel" --platform windows-x64 --local /nonexistent >/dev/null 2>&1; then fail "bad --platform is rejected"; fi
