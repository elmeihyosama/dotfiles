#!/usr/bin/env sh
# dotfiles.sh — front end for managing this dotfiles repo (the `dotfiles` shell
# function and, later, a TUI call it).
# Usage: dotfiles.sh <subcommand> [args]
#   list [--json]   tools in the catalog, whether this machine selects them,
#                   and what is installed
#   doctor [args]   run scripts/doctor.sh (read-only health check)
#   help            print this usage
# Exit codes: 0 ok, 1 an operation failed, 2 usage or validation error.
#
# Environment (tests): DOTFILES_LOCAL_YML overrides ansible/local.yml (when the
# file is missing, select-tools' defaults apply: every group); DOTFILES_TOOLS_YAML
# overrides home/.chezmoidata/tools.yaml.
#
# `list --json` is a stable contract (the TUI parses it). One array element per
# catalog tool, sorted by group order in tools.yaml `tool_groups`, then by name:
#   name      string       tool name (catalog key)
#   group     string       tools.yaml group
#   bin       string       command name (default: name)
#   source    string       "mise" | "native" | "bootstrap" | "bundled"; the
#                          select-tools.sh enum, unchanged. A tool that is not
#                          selected gets the source it would have here.
#   selected  boolean      true when select-tools picks it for this host; false
#                          for a tool outside the selection (still listed)
#   installed boolean      mise tools: some version is installed (mise -C / ls);
#                          all others: `bin` resolves on PATH
#   pinned    string|null  tools.yaml version for mise tools, else null
#   actual    string|null  installed version for mise tools (the active one,
#                          else the newest installed), else null
# The mise lookup runs as `mise -C /` with the dotfiles pins and the user's
# global config masked, exactly as .github/scripts/assert-tools.sh does, so the
# repo's own mise.toml can never answer.
set -eu

repo_root="$(CDPATH='' cd "$(dirname "$0")/.." && pwd)"

usage() { # usage [FD]: to stderr by default, stdout with 1
	{
		echo "usage: dotfiles <subcommand> [args]"
		echo "subcommands: list [--json] | doctor [args] | help"
	} >&"${1:-2}"
}

cmd_list() {
	json=0
	while [ $# -gt 0 ]; do
		case "$1" in
		--json) json=1 ;;
		-h | --help)
			echo "usage: dotfiles list [--json]"
			return 0
			;;
		*)
			echo "dotfiles list: unknown option: $1" >&2
			usage
			exit 2
			;;
		esac
		shift
	done

	tools_yaml="${DOTFILES_TOOLS_YAML:-$repo_root/home/.chezmoidata/tools.yaml}"
	local_yml="${DOTFILES_LOCAL_YML:-$repo_root/ansible/local.yml}"
	case "$(uname -s)" in Darwin) os=darwin ;; *) os=linux ;; esac
	case "$(uname -m)" in
	x86_64 | amd64) arch=x64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) arch="$(uname -m)" ;;
	esac
	plat="$([ "$os" = darwin ] && echo macos || echo linux)-$arch"

	# The dotfiles pins with the global config masked (scripts/mise-env.sh).
	# shellcheck source=mise-env.sh
	. "$repo_root/scripts/mise-env.sh"
	mise_env "$local_yml"

	for t in yq jq; do
		command -v "$t" >/dev/null 2>&1 || {
			echo "dotfiles list: $t not on PATH" >&2
			exit 1
		}
	done
	[ -f "$tools_yaml" ] || {
		echo "dotfiles list: tools file not found: $tools_yaml" >&2
		exit 1
	}

	set -- --os "$os" --arch "$arch" --tools "$tools_yaml"
	[ -f "$local_yml" ] && set -- "$@" --local "$local_yml"
	if ! sel="$("$repo_root/scripts/select-tools.sh" "$@")"; then
		echo "dotfiles list: select-tools failed" >&2
		exit 1
	fi
	if ! catalog="$(yq -o=json '.' "$tools_yaml")"; then
		echo "dotfiles list: cannot read $tools_yaml" >&2
		exit 1
	fi
	mise_ls='{}'
	if command -v mise >/dev/null 2>&1; then
		mise_ls="$(cd / && mise -C / ls --json 2>/dev/null)" || mise_ls='{}'
	fi
	# anything but a JSON object (empty, garbage, an array) counts as no answer
	printf '%s' "$mise_ls" | jq -e 'type == "object"' >/dev/null 2>&1 || mise_ls='{}'
	# bins that resolve on PATH (native/bootstrap/bundled "installed")
	onpath="$(printf '%s\n' "$catalog" | jq -r '.tools | to_entries[] | .value.bin // .key' |
		while IFS= read -r b; do
			command -v "$b" >/dev/null 2>&1 && printf '%s\n' "$b"
		done | jq -R . | jq -s .)"

	if ! rows="$(jq -n --argjson c "$catalog" --argjson sel "$sel" --argjson ls "$mise_ls" \
		--argjson onpath "$onpath" --arg os "$os" --arg plat "$plat" '
		def nz: if . == null or . == "" then null else . end;
		($sel | map({key: .name, value: .source}) | from_entries) as $selsrc
		| ($ls | to_entries | map({key: (.key | sub("\\[.*$"; "")), value: .value}) | from_entries) as $mls
		| $c.tool_groups as $groups
		| [$c.tools | to_entries[] | .key as $n | .value as $t
			| (if $selsrc[$n] != null then $selsrc[$n]
				elif $t.provided_by != null then "bundled"
				elif $t.bootstrap == true then "bootstrap"
				elif $t.native_only == true or (($t.native_on // []) | index($os)) != null
					or (($t.missing_on // []) | index($plat)) != null then "native"
				else "mise" end) as $src
			| ($t.bin // $n) as $bin
			| (if $src == "mise" then
					(($mls[$t.backend // ""] // []) | map(select(.installed == true))) as $inst
					| (($inst | map(select(.active == true)) | last) // ($inst | last))
				else null end) as $hit
			| {name: $n, group: $t.group, bin: $bin, source: $src,
				selected: ($selsrc[$n] != null),
				installed: (if $src == "mise" then $hit != null else ($onpath | index($bin)) != null end),
				pinned: (if $src == "mise" then ($t.version | nz) else null end),
				actual: ($hit.version | nz)}]
		| sort_by(.group as $g | [($groups | index($g)), .name])')"; then
		echo "dotfiles list: could not build the tool list" >&2
		exit 1
	fi

	if [ "$json" -eq 1 ]; then
		printf '%s\n' "$rows" | jq .
		return 0
	fi
	printf '%s\n' "$rows" | jq -r '
		def pad($n): . + (" " * ([$n - length, 0] | max));
		(map(.name | length) | max // 0) as $w
		| (reduce .[] as $r ([]; if index($r.group) == null then . + [$r.group] else . end)) as $order
		| $order[] as $g
		| "\($g)",
			(.[] | select(.group == $g)
				| "  \(if .selected then "✓" else "·" end) \(.name | pad($w))  \(.source | pad(9))  "
					+ (if .installed then "installed" else "missing  " end)
					+ (if .source == "mise" then
							"  " + (if .actual != null and .actual != .pinned then "\(.actual)≠\(.pinned)"
								else (.actual // .pinned) end)
						else "" end))'
}

[ $# -gt 0 ] || {
	usage
	exit 0
}
sub="$1"
shift
case "$sub" in
help | -h | --help) usage 1 ;;
list) cmd_list "$@" ;;
doctor) exec sh "$repo_root/scripts/doctor.sh" "$@" ;;
*)
	echo "dotfiles: unknown subcommand: $sub" >&2
	usage
	exit 2
	;;
esac
