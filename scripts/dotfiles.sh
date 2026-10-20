#!/usr/bin/env sh
# dotfiles.sh — front end for managing this dotfiles repo (the `dotfiles` shell
# function and, later, a TUI call it).
# Usage: dotfiles.sh <subcommand> [args]
#   list [--json]   tools in the catalog, whether this machine selects them,
#                   and what is installed
#   add <tool|group>... [--no-apply]
#                   select tools/groups in ansible/local.yml, then apply
#   remove <tool|group>... [--no-apply]
#                   deselect them; mise tools are uninstalled after the apply,
#                   native ones get the command to run (never run for you)
#   doctor [args]   run scripts/doctor.sh (read-only health check)
#   help            print this usage
# Exit codes: 0 ok, 1 an operation failed, 2 usage or validation error.
#
# add/remove edit only tool_groups, tools_add and tools_remove in local.yml
# (yq -i: comments and other keys stay; flow style `[a, b]` is kept). An add of
# a selected tool or a remove of an unselected one changes nothing, judged
# against select-tools' computed selection. Every argument is validated before
# anything is written. Apply = ansible-playbook site.yml --tags
# mise,chezmoi,packages; if it fails local.yml stays edited and re-running the
# printed command is safe.
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
		echo "subcommands: list [--json] | add TOOL|GROUP... | remove TOOL|GROUP... | doctor [args] | help"
	} >&"${1:-2}"
}

# detect_platform: set os (darwin|linux), arch (x64|arm64|...) and plat
detect_platform() {
	case "$(uname -s)" in Darwin) os=darwin ;; *) os=linux ;; esac
	case "$(uname -m)" in
	x86_64 | amd64) arch=x64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) arch="$(uname -m)" ;;
	esac
	plat="$([ "$os" = darwin ] && echo macos || echo linux)-$arch"
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
	detect_platform

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

# suggest NAME: catalog names (tools and groups) near NAME, one per line
suggest() {
	printf '%s\n' "$catalog" | jq -r --arg n "$1" '
		($n | ascii_downcase) as $q
		| ((.tools | keys) + .tool_groups) as $all
		| ([$all[] | select(ascii_downcase as $a | ($a | contains($q)) or ($q | contains($a)))]) as $sub
		| (if ($sub | length) > 0 then $sub
			else [$all[] | select(.[0:1] == $q[0:1])] end)
		| .[0:5][]'
}

# write_key KEY JSON_LIST FILE: set FILE's KEY to the list, flow style when the
# key is new or already flow; an emptied tools_add/tools_remove is dropped
write_key() {
	_k="$1"
	_f="$3"
	if [ "$2" = '[]' ] && [ "$_k" != tool_groups ]; then
		yq -i "del(.$_k)" "$_f"
		return
	fi
	_flow=1
	if [ "$(yq ".$_k | tag" "$_f")" = '!!seq' ] && [ "$(yq ".$_k | style" "$_f")" != flow ]; then _flow=0; fi
	L="$2" yq -i ".$_k = (env(L) | .[] style=\"\" | . style=\"\")" "$_f"
	[ "$_flow" -eq 0 ] || yq -i ".$_k style=\"flow\"" "$_f"
}

# cmd_edit add|remove ARGS...
cmd_edit() {
	verb="$1"
	shift
	apply=1
	names=""
	for a in "$@"; do
		case "$a" in
		--no-apply) apply=0 ;;
		-h | --help)
			echo "usage: dotfiles $verb <tool|group>... [--no-apply]"
			return 0
			;;
		-*)
			echo "dotfiles $verb: unknown option: $a" >&2
			usage
			exit 2
			;;
		*) names="$names $a" ;;
		esac
	done
	[ -n "$names" ] || {
		echo "usage: dotfiles $verb <tool|group>... [--no-apply]" >&2
		exit 2
	}

	tools_yaml="${DOTFILES_TOOLS_YAML:-$repo_root/home/.chezmoidata/tools.yaml}"
	local_yml="${DOTFILES_LOCAL_YML:-$repo_root/ansible/local.yml}"
	detect_platform
	for t in yq jq; do
		command -v "$t" >/dev/null 2>&1 || {
			echo "dotfiles $verb: $t not on PATH" >&2
			exit 1
		}
	done
	[ -f "$tools_yaml" ] || {
		echo "dotfiles $verb: tools file not found: $tools_yaml" >&2
		exit 1
	}
	[ -f "$local_yml" ] || {
		echo "dotfiles: $local_yml not found; run install.sh or copy ansible/local.yml.example" >&2
		exit 2
	}
	catalog="$(yq -o=json '.' "$tools_yaml")" || {
		echo "dotfiles $verb: cannot read $tools_yaml" >&2
		exit 1
	}
	local_json="$(yq -o=json '. // {}' "$local_yml")" || {
		echo "dotfiles $verb: cannot read $local_yml" >&2
		exit 2
	}

	# every name must be a tool or a group (nothing is written otherwise)
	for a in $names; do
		if ! printf '%s\n' "$catalog" | jq -e --arg n "$a" '(.tools[$n] != null) or (.tool_groups | index($n)) != null' >/dev/null; then
			echo "dotfiles: unknown tool: $a" >&2
			near="$(suggest "$a")"
			[ -z "$near" ] || echo "  did you mean: $(echo "$near" | tr '\n' ' ')" >&2
			exit 2
		fi
	done

	# shellcheck disable=SC2086 # sel_args: no spaces in the values we pass
	sel_args="--os $os --arch $arch --tools $tools_yaml"
	# shellcheck disable=SC2086
	if ! before="$("$repo_root/scripts/select-tools.sh" $sel_args --local "$local_yml")"; then
		echo "dotfiles: $local_yml has an invalid selection (above); fix it first" >&2
		exit 2
	fi

	# The pure part: fold the arguments, in order, over the three selection keys.
	if ! plan="$(jq -n --arg verb "$verb" --arg names "$names" --argjson c "$catalog" --argjson l "$local_json" '
		def die($m): ($m + "\n") | halt_error(2);
		def own($s; $t): $c.tools[$t].group == "core" or ($s.g | index($c.tools[$t].group)) != null
			or ($s.a | index($t)) != null;
		def base($s; $t): own($s; $t) and ($s.r | index($t)) == null;
		def sel($s; $t): ($c.tools[$t].provided_by) as $p
			| if $p != null then base($s; $p) and ($s.r | index($t)) == null else base($s; $t) end;
		def drop($l; $x): $l - [$x];
		def put($l; $x): if ($l | index($x)) != null then $l else $l + [$x] end;
		{g: ($l.tool_groups // $c.tool_groups), a: ($l.tools_add // []), r: ($l.tools_remove // []), msgs: []}
		| reduce ($names | split(" ") | map(select(. != ""))[]) as $n (.;
			. as $s
			| if ($c.tool_groups | index($n)) != null then
				(if $n == "core" then
					(if $verb == "remove" then die("dotfiles: core is in core and can'\''t be removed")
					else .msgs += ["dotfiles: group core is already selected (always on)"] end)
				elif $verb == "add" then
					(if ($s.g | index($n)) != null then .msgs += ["dotfiles: group \($n) is already selected"]
					else .g = put($s.g; $n) | .msgs += ["dotfiles: selected group \($n)"] end)
				else
					(if ($s.g | index($n)) == null then .msgs += ["dotfiles: group \($n) is not selected"]
					else .g = drop($s.g; $n) | .msgs += ["dotfiles: deselected group \($n)"] end)
				end)
			else
				(if $verb == "remove" and $c.tools[$n].group == "core" then
					die("dotfiles: \($n) is in core and can'\''t be removed")
				elif $verb == "add" then
					(if sel($s; $n) then .msgs += ["dotfiles: \($n) is already selected"]
					elif $c.tools[$n].provided_by != null and (base($s; $c.tools[$n].provided_by) | not) then
						die("dotfiles: \($n) comes with \($c.tools[$n].provided_by); add \($c.tools[$n].provided_by) instead")
					else
						.r = drop($s.r; $n)
						| (if sel(.; $n) then . else .a = put(.a; $n) end)
						| .msgs += ["dotfiles: selected \($n)"]
					end)
				else
					(if (sel($s; $n) | not) then .msgs += ["dotfiles: \($n) is not selected"]
					else
						.a = drop($s.a; $n)
						| (if sel(.; $n) then .r = put(.r; $n) else . end)
						| .msgs += ["dotfiles: deselected \($n)"]
					end)
				end)
			end)')"; then
		exit 2
	fi

	tmp="$(mktemp)"
	trap 'rm -f "$tmp" "$tmp.2"' EXIT
	# yq (4.54) drops blank lines on rewrite; park them as marker comments
	sed 's/^[[:space:]]*$/#__dotfiles_blank__/' "$local_yml" >"$tmp"
	changed=0
	# Each key is written only when it differs from what the file effectively
	# says (an absent tool_groups means every group), so a no-op writes nothing.
	for spec in tool_groups:g tools_add:a tools_remove:r; do
		key="${spec%%:*}"
		f="${spec#*:}"
		new="$(printf '%s' "$plan" | jq -c ".$f")"
		old="$(printf '%s' "$local_json" | jq -c --argjson c "$catalog" --arg k "$key" '.[$k] // (if $k == "tool_groups" then $c.tool_groups else [] end)')"
		[ "$new" != "$old" ] || continue
		write_key "$key" "$new" "$tmp"
		changed=1
	done
	sed 's/^#__dotfiles_blank__$//' "$tmp" >"$tmp.2" && mv "$tmp.2" "$tmp"
	printf '%s' "$plan" | jq -r '.msgs[]'
	[ "$changed" -eq 1 ] || return 0

	# shellcheck disable=SC2086
	if ! after="$("$repo_root/scripts/select-tools.sh" $sel_args --local "$tmp")"; then
		echo "dotfiles: that selection is invalid (above); $local_yml unchanged" >&2
		exit 2
	fi
	cat "$tmp" >"$local_yml"

	# tools that stop being installed: native ones get a hint, mise ones are
	# uninstalled after the apply
	gone="$(jq -n --argjson b "$before" --argjson a "$after" \
		'$b | map(select(.name as $n | ($a | map(.name) | index($n)) == null))')"
	if [ "$verb" = remove ]; then
		# shellcheck source=remove-hint.sh
		. "$repo_root/scripts/remove-hint.sh"
		for t in $(printf '%s' "$gone" | jq -r '.[] | select(.source == "native") | .name'); do
			native_hint "$t"
		done
	fi
	[ "$apply" -eq 1 ] || return 0

	if ! command -v ansible-playbook >/dev/null 2>&1; then
		echo "dotfiles: ansible-playbook not on PATH; $local_yml is edited, apply later with:" >&2
		echo "  (cd $repo_root/ansible && ansible-playbook site.yml --tags mise,chezmoi,packages)" >&2
		exit 1
	fi
	if ! (cd "$repo_root/ansible" && ansible-playbook site.yml --tags mise,chezmoi,packages); then
		echo "dotfiles: apply failed; $local_yml stays edited. Re-running is safe:" >&2
		echo "  (cd $repo_root/ansible && ansible-playbook site.yml --tags mise,chezmoi,packages)" >&2
		exit 1
	fi

	[ "$verb" = remove ] || return 0
	# shellcheck source=mise-env.sh
	. "$repo_root/scripts/mise-env.sh"
	mise_env "$local_yml"
	for spec in $(printf '%s' "$gone" | jq -r '.[] | select(.source == "mise" and .version != null) | "\(.name)=\(.backend)@\(.version)"'); do
		if (cd / && mise -C / uninstall "${spec#*=}"); then
			echo "dotfiles: uninstalled ${spec%%=*} (${spec#*=})"
		else
			echo "dotfiles: warning: could not uninstall ${spec%%=*}; run: mise uninstall ${spec#*=}" >&2
		fi
	done
	return 0
}

# native_hint TOOL: print how to remove the natively installed TOOL (never runs it)
native_hint() {
	_bin="$(printf '%s\n' "$catalog" | jq -r --arg t "$1" '.tools[$t].bin // $t')"
	_h=""
	if _p="$(command -v "$_bin" 2>/dev/null)" && [ "${_p#/}" != "$_p" ]; then
		_h="$(remove_hint "$1" "$_p")"
	fi
	if [ -z "$_h" ]; then
		if [ "$os" = darwin ]; then
			_h="brew uninstall $(pkg_name "$1" brew)"
		elif command -v apt-get >/dev/null 2>&1; then
			_h="sudo apt remove $(pkg_name "$1" apt)"
		elif command -v dnf >/dev/null 2>&1; then
			_h="sudo dnf remove $(pkg_name "$1" dnf)"
		elif command -v pacman >/dev/null 2>&1; then
			_h="sudo pacman -R $(pkg_name "$1" pacman)"
		else
			_h="brew uninstall $(pkg_name "$1" brew)"
		fi
	fi
	echo "dotfiles: $1: installed natively; remove with: $_h"
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
add | remove) cmd_edit "$sub" "$@" ;;
doctor) exec sh "$repo_root/scripts/doctor.sh" "$@" ;;
*)
	echo "dotfiles: unknown subcommand: $sub" >&2
	usage
	exit 2
	;;
esac
