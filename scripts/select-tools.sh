#!/usr/bin/env sh
# select-tools.sh: how each catalog tool installs on a platform (every
# machine gets every tool).
# Usage: select-tools.sh --os darwin|linux [--arch x64|arm64] [--tools TOOLS_YAML]
#        select-tools.sh --platform macos-arm64|linux-x64|linux-arm64 ... (instead of --os/--arch)
#
# Prints a JSON array sorted by name:
#   [{"name","bin","source","version","backend","provided_by"}]
# source (the output contract) is one of:
#   mise      from the dotfiles mise pins (backend and version set)
#   native    brew/apt/dnf/pacman, also a platform in missing_on (backend/version null)
#   bootstrap installed by Ansible before mise exists (mise itself; version set)
#   bundled   inside provided_by's install; version/backend null
#
# Bad arguments exit 2.
set -eu

repo_root="$(CDPATH='' cd "$(dirname "$0")/.." && pwd)"
os=""
arch=""
tools_yaml="$repo_root/home/.chezmoidata/tools.yaml"

usage() {
	echo "usage: select-tools.sh --os darwin|linux [--arch x64|arm64] | --platform <os>-<arch> [--tools TOOLS_YAML]" >&2
	exit 2
}
while [ $# -gt 0 ]; do
	case "$1" in
	--os)
		[ $# -ge 2 ] || usage
		os="$2"
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

yq -o=json '.' "$tools_yaml" | jq --arg os "$os" --arg plat "$plat" '
. as $c
| [$c.tools | keys[] | . as $n | $c.tools[$n] as $t
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
| sort_by(.name)'
