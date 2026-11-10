#!/usr/bin/env bash
# scripts/select-tools.sh: every catalog tool, and how it installs per platform.
source "$(dirname "$0")/lib.sh"

sel="$TESTS_REPO/scripts/select-tools.sh"
tools_yaml="$TESTS_REPO/home/.chezmoidata/tools.yaml"
d="$(mktemp -d)"
_tests_tmpdirs+=("$d")

run() { # run OS [ARGS...] -> stdout; stderr to $d/err; sets rc
	local os="$1"
	shift
	out="$("$sel" --os "$os" "$@" 2>"$d/err")"
	rc=$?
}
names() { jq -r '.[].name' <<<"$out" | paste -sd, -; }
field() { jq -r --arg n "$1" --arg f "$2" '.[] | select(.name == $n) | .[$f] // "null"' <<<"$out"; }

# every_tool: the whole catalog, sorted by name
all="$(yq '.tools | keys | .[]' "$tools_yaml" | sort | paste -sd, -)"
run linux
assert_eq 0 "$rc" "every_tool: exit 0"
assert_eq "$all" "$(names)" "every_tool: the whole catalog, sorted"

# native_on: native on that OS, mise elsewhere
run darwin --arch arm64
assert_eq native "$(field btop source)" "native_on: btop native on darwin"
assert_eq null "$(field btop version)" "native_on: no version when native"
assert_eq null "$(field btop backend)" "native_on: no backend when native"
run linux --arch arm64
assert_eq mise "$(field btop source)" "native_on: btop mise on linux"
assert_eq aqua:aristocratos/btop "$(field btop backend)" "native_on: backend on linux"

# bin defaults and overrides; bootstrap
run linux
assert_eq rg "$(field ripgrep bin)" "bin override"
assert_eq fzf "$(field fzf bin)" "bin defaults to name"
assert_eq bootstrap "$(field mise source)" "mise is bootstrap"

# native_only, missing_on and provided_by, on a small catalog (no real tool
# uses them now)
printf '%s\n' 'tools:' \
	'  nat: {native_only: true}' \
	'  gap: {backend: aqua:x/gap, version: "1.0.0", missing_on: [linux-arm64]}' \
	'  prov: {backend: aqua:x/prov, version: "1.0.0"}' \
	'  bund: {provided_by: prov}' >"$d/fixture.yaml"
fx() { # fx OS ARCH TOOL FIELD
	"$sel" --os "$1" --arch "$2" --tools "$d/fixture.yaml" |
		jq -r --arg n "$3" --arg f "$4" '.[] | select(.name == $n) | .[$f] // "null"'
}
for os in darwin linux; do
	assert_eq native "$(fx "$os" arm64 nat source)" "native_only: $os"
	assert_eq null "$(fx "$os" arm64 nat backend)" "native_only: $os no backend"
done
assert_eq native "$(fx linux arm64 gap source)" "missing_on: native on linux-arm64"
assert_eq mise "$(fx linux x64 gap source)" "missing_on: mise on linux-x64"
assert_eq bundled "$(fx linux x64 bund source)" "provided_by: bundled"
assert_eq prov "$(fx linux x64 bund provided_by)" "provided_by recorded"
assert_eq null "$(fx linux x64 bund version)" "provided_by has no version"
assert_eq null "$(fx linux x64 bund backend)" "provided_by has no backend"

# --platform <os>-<arch> is the same as --os/--arch; bad arguments exit 2
plat_src() { "$sel" --platform "$1" | jq -r --arg n "$2" '.[] | select(.name == $n) | .source'; }
assert_eq mise "$(plat_src linux-arm64 btop)" "--platform linux-arm64 maps to linux/arm64"
assert_eq native "$(plat_src macos-arm64 btop)" "--platform macos-arm64 maps to darwin/arm64"
for bad in "--os linux --arch riscv" "--platform windows-x64" "--os linux --local x.yml"; do
	# shellcheck disable=SC2086 # $bad is several arguments
	"$sel" $bad >/dev/null 2>&1
	assert_eq 2 "$?" "rejected: $bad"
done

# yaml_has_every_legacy_tool: the pre-mise group_vars `tools` list
for t in chezmoi atuin sheldon zellij starship zoxide eza bat fd ripgrep fzf \
	git-delta lazygit yazi jq yq gh dust duf btop neovim \
	fastfetch mise vivid; do
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
	run "$os"
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
