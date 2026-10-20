#!/usr/bin/env sh
# select-tools.sh — resolve which tools this machine installs, and how.
# Usage: select-tools.sh --os darwin|linux --local LOCAL_YML [--tools TOOLS_YAML]
#
# Reads the catalog (default home/.chezmoidata/tools.yaml) and the per-machine
# ansible/local.yml, prints a JSON array sorted by name:
#   [{"name","bin","source","version","backend","provided_by"}]
# source is "mise" (installed by mise), "native" (brew/apt/dnf/pacman) or
# "bootstrap" (mise itself, installed by Ansible); version/backend are null
# unless source is "mise" (bootstrap keeps its version). provided_by names the
# tool whose package ships this bin (age-keygen -> age), else null.
#
# Selection = core U tools in tool_groups (default: every group) U tools_add
#             - tools_remove. Removing a core tool is an error. A provided_by
# tool follows its provider. Nothing here ever uninstalls anything.
# Exit 2 with a message on stderr for unknown groups/tools or a core removal.
set -eu

repo_root="$(CDPATH='' cd "$(dirname "$0")/.." && pwd)"
os=""
local_yml=""
tools_yaml="$repo_root/home/.chezmoidata/tools.yaml"

usage() {
	echo "usage: select-tools.sh --os darwin|linux --local LOCAL_YML [--tools TOOLS_YAML]" >&2
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
	--tools)
		[ $# -ge 2 ] || usage
		tools_yaml="$2"
		shift 2
		;;
	*) usage ;;
	esac
done
case "$os" in darwin | linux) ;; *) usage ;; esac
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

printf '%s\n' "$catalog" | jq --arg os "$os" --argjson l "$local_json" '
def die($m): ($m + "\n") | halt_error(2);
. as $c
| $c.tool_groups as $groups
| ($c.tools | keys) as $names
| ($l.tool_groups // $groups) as $sel
| ($l.tools_add // []) as $add
| ($l.tools_remove // []) as $rm
| ($sel[] | select(. as $g | ($groups | index($g)) == null)
		| die("unknown group: \(.) (valid: \($groups | join(", ")))")),
	(($add + $rm)[] | select(. as $t | ($names | index($t)) == null)
		| die("unknown tool: \(.)")),
	($rm[] | select($c.tools[.].group == "core")
		| die("cannot remove core tool: \(.)")),
	( ([$names[] | . as $n | select($c.tools[$n].provided_by == null)
				| select(($c.tools[$n].group == "core") or ($sel | index($c.tools[$n].group)) != null
								or ($add | index($n)) != null)
				| select(($rm | index($n)) == null)]) as $base
		| [$names[] | . as $n | $c.tools[$n] as $t
				| select(($base | index($n)) != null
								or ($t.provided_by != null and ($base | index($t.provided_by)) != null
										and ($rm | index($n)) == null))
				| ($t.provided_by // null) as $p
				| ($c.tools[$p // $n]) as $src
				| (if $src.bootstrap == true then "bootstrap"
					elif $src.native_only == true or (($src.native_on // []) | index($os)) != null then "native"
					else "mise" end) as $s
				| {name: $n,
					bin: ($t.bin // $n),
					source: $s,
					version: (if $p != null then null
										elif $s == "mise" or $s == "bootstrap" then $t.version else null end),
					backend: (if $p == null and $s == "mise" then $t.backend else null end),
					provided_by: $p}]
		| sort_by(.name) )'
