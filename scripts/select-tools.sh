#!/usr/bin/env sh
# select-tools.sh: which tools this machine installs, and how.
# Usage: select-tools.sh --os darwin|linux [--arch x64|arm64] --local LOCAL_YML [--tools TOOLS_YAML]
#        select-tools.sh --platform macos-arm64|linux-x64|linux-arm64 ... (instead of --os/--arch)
#
# Prints a JSON array sorted by name:
#   [{"name","bin","source","version","backend","provided_by"}]
# source (the output contract) is one of:
#   mise      from the dotfiles mise pins (backend and version set)
#   native    brew/apt/dnf/pacman, also a platform in missing_on (backend/version null)
#   bootstrap installed by Ansible before mise exists (mise itself; version set)
#   bundled   inside provided_by's install (age-keygen -> age); version/backend null
#
# Selection = core + tool_groups (default: all) + tools_add - tools_remove; a
# provided_by tool follows its provider. Never uninstalls anything. Bad input
# (unknown names, removing core, a non-list, a provided_by tool without its
# provider) exits 2.
set -eu

repo_root="$(CDPATH='' cd "$(dirname "$0")/.." && pwd)"
os=""
arch=""
local_yml=""
tools_yaml="$repo_root/home/.chezmoidata/tools.yaml"

usage() {
	echo "usage: select-tools.sh --os darwin|linux [--arch x64|arm64] | --platform <os>-<arch> --local LOCAL_YML [--tools TOOLS_YAML]" >&2
	exit 2
}
while [ $# -gt 0 ]; do
	case "$1" in
	--os)
		[ $# -ge 2 ] || usage
		os="$2"
		shift 2
		;;
	--local)
		[ $# -ge 2 ] || usage
		local_yml="$2"
		shift 2
		;;
	--arch)
		[ $# -ge 2 ] || usage
		arch="$2"
		shift 2
		;;
	--platform)
		[ $# -ge 2 ] || usage
		case "$2" in macos-*) os=darwin ;; linux-*) os=linux ;; *) usage ;; esac
		arch="${2#*-}"
		shift 2
		;;
	--tools)
		[ $# -ge 2 ] || usage
		tools_yaml="$2"
		shift 2
		;;
	*) usage ;;
	esac
done
case "$os" in darwin | linux) ;; *) usage ;; esac
if [ -z "$arch" ]; then
	case "$(uname -m)" in
	x86_64 | amd64) arch=x64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) arch="$(uname -m)" ;;
	esac
fi
case "$arch" in x64 | arm64) ;; *) usage ;; esac
plat="$([ "$os" = darwin ] && echo macos || echo linux)-$arch"
[ -f "$tools_yaml" ] || {
	echo "tools file not found: $tools_yaml" >&2
	exit 2
}

catalog="$(yq -o=json '.' "$tools_yaml")"
if [ -n "$local_yml" ] && [ -f "$local_yml" ]; then
	local_json="$(yq -o=json '. // {}' "$local_yml")"
else
	local_json='{}'
fi

printf '%s\n' "$catalog" | jq --arg os "$os" --arg plat "$plat" --argjson l "$local_json" '
def die($m): ($m + "\n") | halt_error(2);
. as $c
| $c.tool_groups as $groups
| ($c.tools | keys) as $names
| ($l.tool_groups // $groups) as $sel
| ($l.tools_add // []) as $add
| ($l.tools_remove // []) as $rm
| (["tool_groups", "tools_add", "tools_remove"][] | . as $k
		| select($l[$k] != null and ($l[$k] | type) != "array")
		| die("\($k) must be a list, e.g. \($k): [x] (got \($l[$k] | type))")),
	($sel[] | select(. as $g | ($groups | index($g)) == null)
		| die("unknown group: \(.) (valid: \($groups | join(", ")))")),
	(($add + $rm)[] | select(. as $t | ($names | index($t)) == null)
		| die("unknown tool: \(.)")),
	($rm[] | select($c.tools[.].group == "core")
		| die("cannot remove core tool: \(.)")),
	( ([$names[] | . as $n | select($c.tools[$n].provided_by == null)
				| select(($c.tools[$n].group == "core") or ($sel | index($c.tools[$n].group)) != null
								or ($add | index($n)) != null)
				| select(($rm | index($n)) == null)]) as $base
		| ($add[] | select($c.tools[.].provided_by != null)
				| . as $n | $c.tools[$n].provided_by as $p
				| select(($base | index($p)) == null)
				| die("\($n) comes with \($p); add \($p) instead")),
		[$names[] | . as $n | $c.tools[$n] as $t
				| select(($base | index($n)) != null
								or ($t.provided_by != null and ($base | index($t.provided_by)) != null
										and ($rm | index($n)) == null))
				| ($t.provided_by // null) as $p
				| ($c.tools[$p // $n]) as $src
				| (if $p != null then "bundled"
					elif $src.bootstrap == true then "bootstrap"
					elif $src.native_only == true or (($src.native_on // []) | index($os)) != null
											or (($src.missing_on // []) | index($plat)) != null then "native"
					else "mise" end) as $s
				| {name: $n,
					bin: ($t.bin // $n),
					source: $s,
					version: (if $p != null then null
										elif $s == "mise" or $s == "bootstrap" then $t.version else null end),
					backend: (if $p == null and $s == "mise" then $t.backend else null end),
					provided_by: $p}]
		| sort_by(.name) )'
