#!/usr/bin/env sh
# dotfiles.sh: front end for this repo (the `dotfiles` shell function).
# Usage: dotfiles.sh <subcommand> [args]
#   list [--json]       catalog tools, selection and install state
#   add|remove <tool|group>... [--no-apply]
#                       edit ansible/local.yml, then apply; remove uninstalls
#                       mise tools and only prints how to remove native ones
#   update [--check]    pull, playbook, chezmoi, sheldon, nvim, then doctor
#   install             install the selected tools (the playbook's packages
#                       step only: chezmoi and its config are not touched)
#   doctor [args]       scripts/doctor.sh
#   look --json         active theme, glass, wallpaper, levels, every palette
#   look --fetch [--no-logo]
#                       the fastfetch start screen, coloured (for the preview)
#   theme SLUG | glass LEVEL | wallpaper on|off|toggle
#                       the zsh `theme`/`glass`/`wallpaper`, headless (TUI)
#   files --json        managed files changed here or waiting to apply
#   files diff|apply|keep PATH...
#                       chezmoi diff; apply (overwrites local edits); re-add
#   machine --json      this machine's local.yml answers
#   machine set KEY VALUE [--no-apply] | machine apply
#                       edit one answer, then rewrite chezmoi's config and
#                       apply without --force
#   tui                 the full-screen TUI (also bare `dotfiles` on a tty)
#   help
# Exit codes: 0 ok, 1 an operation failed, 2 usage or validation error
# (no subcommand, an invalid local.yml, an unsafe local.yml shape).
#
# add/remove line-edit only tool_groups/tools_add/tools_remove in local.yml, so
# every other byte (comments, CRLF) stays; an unsupported shape exits 2 with
# nothing written. A failed apply leaves local.yml edited; re-running is safe.
#
# update never stashes, resets or force-pulls (a dirty repo is refused), stops
# at the first failing step and never prompts: it runs from Raycast without a
# tty. --check writes nothing.
#
# Tests: DOTFILES_LOCAL_YML and DOTFILES_TOOLS_YAML override the default paths.
#
# `list --json` is a contract (the TUI parses it): an array, one object per
# catalog tool, sorted by tool_groups order then name:
#   name, group, bin  string
#   source            string, select-tools' enum (unselected: the one it would get)
#   selected          bool
#   installed         bool: mise tools, some version installed; others, bin on PATH
#   pinned            string|null, tools.yaml version (mise tools only)
#   actual            string|null, active version, else newest installed (mise only)
#   about, backend    string|null, from tools.yaml
# mise runs as `mise -C /` with the global config masked, as in assert-tools.sh,
# so the repo's own mise.toml never answers.
#
# `look --json` is a TUI contract too: an object
#   theme   string|null, active slug      glass   string|null, unset = null
#   levels  [string], glass levels, lightest first, "default" last
#   themes  [{slug, colors: {base00..base0F: "#rrggbb"}}], sorted by slug
#   wallpaper  "on"|"off"|null
#   wallpapers {slug: image path}, wallpaper_opacity number|null
#   glass_levels {level: {opacity, blur}} (strings, as glass.toml)
#
# `files --json`: an array of {path (relative to ~), local (changed here since
# chezmoi last wrote it), pending (the repo would change it), template}.
#
# `machine --json`: {path, exists, values: {KEY: value|null}, signing:
# {key, exists}}, KEY in MACHINE_KEYS plus the read-only shared_home and tool
# selection keys.
set -eu

repo_root="$(CDPATH='' cd "$(dirname "$0")/.." && pwd)"

# chezmoi_repo: the checkout chezmoi applies from (its source dir's parent);
# fails when chezmoi is absent or answers with no absolute path
chezmoi_repo() {
	command -v chezmoi >/dev/null 2>&1 || return 1
	_s="$(cd / && chezmoi source-path 2>/dev/null)" || return 1
	case "$_s" in /*) dirname "$_s" ;; *) return 1 ;; esac
}

# machine_local_yml: this checkout's ansible/local.yml; in a second checkout
# or worktree without one, the machine's own, beside chezmoi's source
machine_local_yml() {
	if [ -n "${DOTFILES_LOCAL_YML:-}" ]; then
		echo "$DOTFILES_LOCAL_YML"
		return
	fi
	if [ ! -e "$repo_root/ansible/local.yml" ] && _cr="$(chezmoi_repo)" && [ -e "$_cr/ansible/local.yml" ]; then
		echo "$_cr/ansible/local.yml"
		return
	fi
	echo "$repo_root/ansible/local.yml"
}

# require_home_checkout WHAT: the playbook points chezmoi's sourceDir at the
# checkout it runs from, so it only runs from the one chezmoi already uses
require_home_checkout() {
	_cr="$(chezmoi_repo)" || return 0
	_a="$(CDPATH='' cd "$_cr" 2>/dev/null && pwd -P)" || return 0
	_b="$(CDPATH='' cd "$repo_root" && pwd -P)"
	[ "$_a" = "$_b" ] && return 0
	echo "dotfiles: $1 runs the playbook, which would point chezmoi at this checkout ($repo_root); run it from $_cr" >&2
	exit 1
}

usage() { # usage [FD]: to stderr by default, stdout with 1
	{
		echo "usage: dotfiles <subcommand> [args]"
		echo "subcommands: list [--json] | add TOOL|GROUP... | remove TOOL|GROUP... | update [--check] | install | doctor [args] | look --json | theme SLUG | glass LEVEL | wallpaper on|off|toggle | files ... | machine ... | tui | help"
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
	local_yml="$(machine_local_yml)"
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
	if ! catalog="$(yq -o=json '.' "$tools_yaml")"; then
		echo "dotfiles list: cannot read $tools_yaml" >&2
		exit 1
	fi
	if ! sel="$("$repo_root/scripts/select-tools.sh" "$@")"; then
		echo "dotfiles list: select-tools failed" >&2
		exit 2
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
				actual: ($hit.version | nz),
				about: ($t.about | nz), backend: ($t.backend | nz)}]
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

# cmd_update [--check]
cmd_update() {
	check=0
	for a in "$@"; do
		case "$a" in
		--check) check=1 ;;
		-h | --help)
			echo "usage: dotfiles update [--check]"
			return 0
			;;
		*)
			echo "dotfiles update: unknown option: $a" >&2
			usage
			exit 2
			;;
		esac
	done
	command -v git >/dev/null 2>&1 || {
		echo "dotfiles update: git not on PATH" >&2
		exit 1
	}
	# no tty (Raycast): nothing below may prompt
	export GIT_TERMINAL_PROMPT=0
	[ -n "${GIT_SSH_COMMAND:-}" ] || export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"
	export NO_COLOR=1
	# a bare environment lacks the pinned tools; mise's shims go ahead of
	# ~/.local/bin, as in the shell
	# shellcheck source=mise-env.sh
	. "$repo_root/scripts/mise-env.sh"
	_data="${MISE_DATA_DIR:-$HOME/.local/share$(mise_sfx "$(machine_local_yml)")/mise}"
	PATH="$PATH:$_data/shims:$HOME/.local/bin"
	export PATH
	cd / || exit 1

	if [ "$check" -eq 1 ]; then
		echo "==> git fetch"
		if ! git -C "$repo_root" fetch -q 2>/dev/null; then
			echo "dotfiles: warning: could not fetch (offline?); showing local state only" >&2
		fi
		echo "==> incoming commits"
		if _in="$(git -C "$repo_root" log --oneline 'HEAD..@{u}' 2>/dev/null)"; then
			[ -n "$_in" ] && printf '%s\n' "$_in" || echo "(none)"
		else
			echo "(no upstream branch to compare with)"
		fi
		echo "==> chezmoi diff"
		if command -v chezmoi >/dev/null 2>&1; then
			chezmoi diff --exclude scripts | head -200
		else
			echo "dotfiles: warning: chezmoi not on PATH; cannot show the diff" >&2
		fi
		echo "==> pending tool installs"
		if _rows="$(cmd_list --json)"; then
			_pend="$(printf '%s' "$_rows" | jq -r '.[]
				| select(.selected and .source == "mise" and (.installed == false or .actual != .pinned))
				| "  \(.name) \(.pinned) (" + (if .installed then "installed: \(.actual)" else "not installed" end) + ")"')"
			[ -z "$_pend" ] && echo "(none)" || printf '%s\n' "$_pend"
		else
			echo "dotfiles: warning: could not determine pending installs" >&2
		fi
		return 0
	fi

	require_home_checkout "dotfiles update"
	echo "==> check working tree"
	_st="$(git -C "$repo_root" status --porcelain)" || {
		echo "dotfiles: cannot read the repo status of $repo_root" >&2
		exit 1
	}
	if [ -n "$_st" ]; then
		_files="$(printf '%s\n' "$_st" | cut -c4- | paste -sd, - | sed 's/,/, /g')"
		echo "dotfiles: repo has local changes ($_files); commit or discard them, then re-run" >&2
		if [ "$_files" = "home/dot_config/nvim/.lazy-lock.json" ]; then
			echo "  to keep the plugin updates: git -C $repo_root commit -am \"nvim: update plugins\"" >&2
		fi
		exit 1
	fi

	upd_fail() {
		echo "dotfiles: update failed at: $1" >&2
		exit 1
	}
	echo "==> git pull --ff-only"
	_old="$(git -C "$repo_root" rev-parse HEAD)" || upd_fail "git pull --ff-only"
	# the user's git config autostashes (home/dot_config/git/config.tmpl); a
	# pull here must never stash or rebase, whatever the config says
	git -C "$repo_root" -c merge.autostash=false -c rebase.autostash=false \
		pull --no-rebase --ff-only || upd_fail "git pull --ff-only"
	echo "==> ansible-playbook site.yml"
	command -v ansible-playbook >/dev/null 2>&1 || upd_fail "ansible-playbook site.yml (ansible-playbook not on PATH)"
	(cd "$repo_root/ansible" && ansible-playbook site.yml) || upd_fail "ansible-playbook site.yml"
	echo "==> chezmoi apply"
	command -v chezmoi >/dev/null 2>&1 || upd_fail "chezmoi apply (chezmoi not on PATH)"
	# never --force: it would silently overwrite a managed file edited since.
	if ! chezmoi apply; then
		if [ ! -t 0 ]; then
			echo "dotfiles: if chezmoi says a file has changed since it last wrote it (or \"could not open a new TTY\"), run \`chezmoi diff\`, then \`chezmoi apply\` in a terminal to choose, and re-run" >&2
		fi
		upd_fail "chezmoi apply"
	fi
	if git -C "$repo_root" diff --quiet "$_old" HEAD -- home/dot_config/sheldon/plugins.toml; then
		_sh="sheldon lock"
	else
		_sh="sheldon lock --update"
	fi
	echo "==> $_sh"
	if command -v sheldon >/dev/null 2>&1; then
		# A plain lock fails when a pull outside update moved a pin to a rev
		# sheldon has not fetched: retry once with --update.
		# shellcheck disable=SC2086 # _sh is a fixed command line
		if ! $_sh; then
			[ "$_sh" = "sheldon lock" ] || upd_fail "$_sh"
			echo "  (sheldon lock failed; retrying with --update)"
			sheldon lock --update || upd_fail "sheldon lock --update"
		fi
	else
		echo "  (sheldon not installed; skipped)"
	fi
	# nvim exits 0 even when Lazy's restore fails; only nvim itself can fail this
	echo "==> nvim Lazy! restore"
	if command -v nvim >/dev/null 2>&1; then
		nvim --headless "+Lazy! restore" +qa || upd_fail "nvim Lazy! restore"
	else
		echo "  (nvim not installed; skipped)"
	fi
	echo "==> dotfiles doctor"
	_rc=0
	sh "$repo_root/scripts/doctor.sh" || _rc=$?
	return "$_rc"
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

# edit_key KEY JSON_LIST SRC DST REQUIRED: copy SRC to DST with only KEY's own
# lines changed (awk, column-0 `KEY:` only; yq is never used to write):
#   flow `KEY: [..]` on one line: just the bracket span, inline comment kept
#   block `KEY:` + `- item` lines: only the item lines, first item's indent
#   absent: `KEY: [a, b]` appended (REQUIRED=1 means it must exist: exit 4)
# An emptied list is written as `KEY: []`. CR line endings are kept.
# Exit 3: a shape we do not edit (scalar, anchor, multi-line flow, duplicate,
# a blank line or comment inside a block list).
edit_key() {
	KEY="$1" REQUIRE="$5" EMPTY="$([ "$2" = '[]' ] && echo 1 || echo 0)" \
	ITEMS="$(printf '%s' "$2" | jq -r 'map(if test("^[A-Za-z0-9][A-Za-z0-9._-]*$") then . else tojson end) | join("\n")')" \
		awk '
		function emit_items(   i, nl) {
			nl = (hcr ? "\r" : "")
			if (!seen) { rc = 3; print hdr nl; mode = 0; return }
			if (n == 0) {
				print key ": []" (hv ~ /^#/ ? " " hv : "") nl
			} else {
				print hdr nl
				for (i = 1; i <= n; i++) print indent "- " it[i] (icr ? "\r" : "")
			}
			mode = 0; ended = 1
		}
		BEGIN {
			key = ENVIRON["KEY"]
			n = (ENVIRON["EMPTY"] == "1") ? 0 : split(ENVIRON["ITEMS"], it, "\n")
			flow = ""
			for (i = 1; i <= n; i++) flow = flow (i > 1 ? ", " : "") it[i]
		}
		{
			line = $0; cr = 0
			if (sub(/\r$/, "", line)) cr = 1
			lastcr = cr
			if (ended) {
				if (line ~ /^[ ]*-([ ]|$)/) rc = 3
				else if (line ~ /^[^ \t#]/) ended = 0
			}
			if (mode == 2) {
				if (line ~ /^[ ]*-([ ]|$)/) {
					if (!seen) { indent = line; sub(/-.*/, "", indent); icr = cr; seen = 1 }
					next
				}
				emit_items()
				if (line ~ /^[^ \t#]/) ended = 0
			}
			if (line ~ ("^" key ":([ \t]|$)")) {
				if (found) rc = 3
				found = 1
				rest = line; sub("^" key ":", "", rest)
				ws = rest; sub(/[^ \t].*$/, "", ws)
				v = substr(rest, length(ws) + 1)
				if (v ~ /^\[/) {
					p = index(v, "]")
					after = substr(v, p + 1)
					if (p > 0 && after ~ /^[ \t]*(#.*)?$/) {
						print key ":" ws "[" flow "]" after (cr ? "\r" : "")
						next
					}
					rc = 3
				} else if (v == "" || v ~ /^#/) {
					hdr = line; hv = v; hcr = cr; mode = 2; seen = 0
					next
				} else rc = 3
			}
			print $0
		}
		END {
			if (mode == 2) emit_items()
			if (!found) {
				if (ENVIRON["REQUIRE"] == "1") exit 4
				print key ": [" flow "]" (lastcr ? "\r" : "")
			}
			exit rc
		}' "$3" >"$4"
}

# cmd_edit add|remove ARGS...
# shellcheck disable=SC2016 # jq filters: $n is a jq variable, not shell
cmd_edit() {
	verb="$1"
	shift
	set -f # names are used unquoted below; never glob them
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
	local_yml="$(machine_local_yml)"
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
	# Edit a symlinked local.yml's target in place, so the link survives.
	_n=0
	while [ -L "$local_yml" ]; do
		_n=$((_n + 1))
		_t="$(readlink "$local_yml")"
		case "$_t" in /*) ;; *) _t="$(dirname "$local_yml")/$_t" ;; esac
		if [ "$_n" -gt 40 ] || { [ ! -e "$_t" ] && [ ! -L "$_t" ]; }; then
			echo "dotfiles: $local_yml is a dangling or looping symlink; fix the link first" >&2
			exit 2
		fi
		local_yml="$_t"
	done
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

	for a in $names; do
		if ! printf '%s\n' "$catalog" | jq -e --arg n "$a" '(.tools[$n] != null) or (.tool_groups | index($n)) != null' >/dev/null; then
			echo "dotfiles: unknown tool: $a" >&2
			near="$(suggest "$a")"
			[ -z "$near" ] || echo "  did you mean: $(echo "$near" | tr '\n' ' ')" >&2
			exit 2
		fi
	done

	# tmp/tmpn sit next to local.yml so the final mv is atomic.
	scratch="$(mktemp -d)" || exit 1
	tmp="$(mktemp "$local_yml.XXXXXX")" || exit 1
	tmpn="$tmp.n"
	trap 'rm -rf "$scratch" "$tmp" "$tmpn"' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP

	sel_args="--os $os --arch $arch --tools $tools_yaml"
	# sel_run FILE: select-tools JSON for that local file; invalid input exits 2
	sel_run() {
		# shellcheck disable=SC2086 # sel_args: no spaces in the values we pass
		"$repo_root/scripts/select-tools.sh" $sel_args --local "$1" || return 2
	}
	# sel_has STATE_JSON NAME: is NAME selected? (the rules live in select-tools)
	sel_has() {
		printf '%s' "$1" >"$scratch/s.json" || exit 1
		_o="$(sel_run "$scratch/s.json")" || exit 2
		printf '%s' "$_o" | jq -e --arg n "$2" 'any(.[]; .name == $n)' >/dev/null
	}
	# st_jq STATE FILTER: edit the state JSON; $n is the current name
	st_jq() { printf '%s' "$1" | jq -c --arg n "$n" "$2" || exit 1; }

	before="$(sel_run "$local_yml")" || {
		echo "dotfiles: $local_yml has an invalid selection (above); fix it first" >&2
		exit 2
	}
	st="$(printf '%s' "$local_json" | jq -c --argjson c "$catalog" \
		'{tool_groups: (.tool_groups // $c.tool_groups), tools_add: (.tools_add // []), tools_remove: (.tools_remove // [])}')" || exit 1
	msgs=""
	for n in $names; do
		if printf '%s\n' "$catalog" | jq -e --arg n "$n" '.tool_groups | index($n) != null' >/dev/null; then
			case "$verb:$n" in
			remove:core)
				echo "dotfiles: core is in core and can't be removed" >&2
				exit 2
				;;
			add:core) msgs="$msgs
dotfiles: group core is already selected (always on)" ;;
			add:*)
				if [ "$(st_jq "$st" '.tool_groups | index($n) != null')" = true ]; then
					msgs="$msgs
dotfiles: group $n is already selected"
				else
					st="$(st_jq "$st" '.tool_groups += [$n]')"
					msgs="$msgs
dotfiles: selected group $n"
				fi
				;;
			remove:*)
				if [ "$(st_jq "$st" '.tool_groups | index($n) != null')" = false ]; then
					msgs="$msgs
dotfiles: group $n is not selected"
				else
					st="$(st_jq "$st" '.tool_groups -= [$n]')"
					msgs="$msgs
dotfiles: deselected group $n"
				fi
				;;
			esac
			continue
		fi
		if [ "$verb" = remove ] && [ "$(printf '%s\n' "$catalog" | jq -r --arg n "$n" '.tools[$n].group')" = core ]; then
			echo "dotfiles: $n is in core and can't be removed" >&2
			exit 2
		fi
		if [ "$verb" = add ]; then
			if sel_has "$st" "$n"; then
				msgs="$msgs
dotfiles: $n is already selected"
				continue
			fi
			cand="$(st_jq "$st" '.tools_remove -= [$n]')"
			sel_has "$cand" "$n" || cand="$(st_jq "$cand" '.tools_add += [$n]')"
			sel_has "$cand" "$n" >/dev/null || true # exits 2 with select-tools' message if invalid
			st="$cand"
			msgs="$msgs
dotfiles: selected $n"
		else
			if ! sel_has "$st" "$n"; then
				msgs="$msgs
dotfiles: $n is not selected"
				continue
			fi
			cand="$(st_jq "$st" '.tools_add -= [$n]')"
			if sel_has "$cand" "$n"; then cand="$(st_jq "$cand" '.tools_remove += [$n]')"; fi
			st="$cand"
			msgs="$msgs
dotfiles: deselected $n"
		fi
	done
	printf '%s\n' "${msgs#
}"

	# Keys whose value differs from what the file effectively says (an absent
	# tool_groups means every group); nothing differs -> nothing is written.
	cp -p "$local_yml" "$tmp" || exit 1
	[ -z "$(tail -c1 "$tmp")" ] || printf '\n' >>"$tmp" || exit 1
	changed=""
	for key in tool_groups tools_add tools_remove; do
		new="$(printf '%s' "$st" | jq -c ".$key")" || exit 1
		old="$(printf '%s' "$local_json" | jq -c --argjson c "$catalog" --arg k "$key" '.[$k] // (if $k == "tool_groups" then $c.tool_groups else [] end)')" || exit 1
		[ "$new" != "$old" ] || continue
		req=0
		[ "$(printf '%s' "$local_json" | jq -r --arg k "$key" 'has($k)')" = true ] && req=1
		rc=0
		edit_key "$key" "$new" "$tmp" "$tmpn" "$req" || rc=$?
		if [ "$rc" -ne 0 ]; then
			echo "dotfiles: can't safely edit $key in $local_yml; edit it by hand" >&2
			exit 2
		fi
		cat "$tmpn" >"$tmp" || exit 1
		changed="$changed $key"
	done
	[ -n "$changed" ] || return 0

	# Verify before committing the write: keys we did not touch are identical,
	# the edited ones hold the plan, and select-tools accepts the file.
	_other='(. // {}) | del(.tool_groups, .tools_add, .tools_remove)'
	_o1="$(yq -o=json -I0 "$_other" "$local_yml" | jq -cS .)" || _o1=x1
	_o2="$(yq -o=json -I0 "$_other" "$tmp" | jq -cS .)" || _o2=x2
	ok=1
	[ "$_o1" = "$_o2" ] || ok=0
	for key in $changed; do
		_want="$(printf '%s' "$st" | jq -c ".$key")"
		_got="$(yq -o=json -I0 "(. // {}) | .$key" "$tmp" | jq -c . 2>/dev/null)" || _got=x
		[ "$_want" = "$_got" ] || ok=0
	done
	if [ "$ok" -ne 1 ] || ! after="$(sel_run "$tmp")"; then
		echo "dotfiles: internal check failed after editing; $local_yml left unchanged" >&2
		exit 1
	fi
	mv -f "$tmp" "$local_yml" || exit 1

	gone="$(jq -n --argjson b "$before" --argjson a "$after" \
		'$b | map(select(.name as $n | ($a | map(.name) | index($n)) == null))')" || exit 1
	if [ "$verb" = remove ]; then
		# shellcheck source=remove-hint.sh
		. "$repo_root/scripts/remove-hint.sh"
		for t in $(printf '%s' "$gone" | jq -r '.[] | select(.source == "native") | .name'); do
			native_hint "$t"
		done
	fi
	[ "$apply" -eq 1 ] || return 0

	require_home_checkout "applying the selection"
	if ! command -v ansible-playbook >/dev/null 2>&1; then
		echo "dotfiles: ansible-playbook not on PATH; $local_yml is edited, apply later with: dotfiles add (or remove) again" >&2
		exit 1
	fi
	# Never the playbook's forced chezmoi apply (it would overwrite files edited
	# here): rewrite chezmoi's config (selected_tools), apply only the pins file
	# that uses it, then install.
	if ! (cd "$repo_root/ansible" && ansible-playbook site.yml --tags chezmoi --skip-tags packages,chezmoi_apply) ||
		! cz apply "$HOME/.config/mise-dotfiles/config.toml" ||
		! (cd "$repo_root/ansible" && ansible-playbook site.yml --tags packages); then
		echo "dotfiles: apply failed; $local_yml stays edited. Re-running is safe." >&2
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
	_on=1
	if _p="$(command -v "$_bin" 2>/dev/null)" && [ "${_p#/}" != "$_p" ]; then
		_h="$(remove_hint "$1" "$_p")"
		if [ -z "$_h" ] && [ "$os" = darwin ]; then
			echo "dotfiles: $1: provided by macOS; nothing to remove"
			return 0
		fi
	else
		_on=0
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
	if [ "$_on" -eq 1 ]; then
		echo "dotfiles: $1: installed natively; remove with: $_h"
	else
		echo "dotfiles: $1: if installed natively, remove with: $_h"
	fi
}

# cmd_look --json
cmd_look() {
	if [ "${1:-}" = --fetch ]; then
		# the shell's splash (50-aliases.zsh), forced to colour; nothing if absent
		command -v fastfetch >/dev/null 2>&1 || return 0
		cfg="$HOME/.config/fastfetch/config.jsonc"
		[ -f "$cfg" ] || return 0
		logo=""
		[ "${2:-}" = --no-logo ] && logo="--logo none"
		# under zsh (the trailing : keeps it from exec'ing), so the shell
		# module reports zsh, as at a real prompt
		if command -v zsh >/dev/null 2>&1; then
			# shellcheck disable=SC2016 # expanded by zsh
			exec zsh -fc 'fastfetch --config "$1" --pipe false ${=2}; :' zsh "$cfg" "$logo"
		fi
		# shellcheck disable=SC2086 # logo: an option pair, split on purpose
		exec fastfetch --config "$cfg" --pipe false $logo
	fi
	[ "${1:-}" = --json ] && [ $# -eq 1 ] || {
		echo "usage: dotfiles look --json | --fetch [--no-logo]" >&2
		exit 2
	}
	for t in chezmoi jq; do
		command -v "$t" >/dev/null 2>&1 || {
			echo "dotfiles look: $t not on PATH" >&2
			exit 1
		}
	done
	data="$(cd / && chezmoi data --format json)" || {
		echo "dotfiles look: chezmoi data failed" >&2
		exit 1
	}
	printf '%s\n' "$data" | jq --arg wdir "$repo_root/home/dot_config/wallpapers" '
		def nz: if . == null or . == "" then null else . end;
		["clear", "frosted", "tinted", "solid"] as $known
		| (.glass_levels // {} | keys) as $have
		| {theme: (.theme | nz), glass: (.glass | nz), wallpaper: (.wallpaper_mode | nz),
			wallpapers: (.wallpaper.map // {} | map_values($wdir + "/" + .)),
			wallpaper_opacity: (.wallpaper.opacity // null),
			glass_levels: (.glass_levels // {}),
			levels: ([$known[] | select(IN($have[]))]
				+ [$have[] | select(. != "default" and (IN($known[]) | not))]
				+ [$have[] | select(. == "default")]),
			themes: [.themes // {} | to_entries[]
				| {slug: .key, colors: (.value | with_entries(select(.key | test("^base0[0-9A-F]$"))))}]
				| sort_by(.slug)}'
}

# cmd_zsh FUNC ARG: the zsh FUNC (theme, glass or wallpaper) from the repo's 45-theme.zsh,
# without rc files and with stdin closed, so `theme` never execs a new shell.
cmd_zsh() {
	[ $# -eq 2 ] || {
		case "$1" in theme) _a=SLUG ;; glass) _a=LEVEL ;; *) _a="on|off|toggle" ;; esac
		echo "usage: dotfiles $1 $_a" >&2
		exit 2
	}
	command -v zsh >/dev/null 2>&1 || {
		echo "dotfiles $1: zsh not on PATH" >&2
		exit 1
	}
	# shellcheck disable=SC2016 # expanded by zsh
	exec zsh -fc '
		compdef() { :; }
		source "$1" || exit 1; shift; "$@"' zsh \
		"$repo_root/home/dot_config/zsh/conf.d/45-theme.zsh" "$@" </dev/null
}

# --- files: chezmoi drift --------------------------------------------------

# cz ARGS...: chezmoi from / (no repo mise.toml), never paging or prompting
cz() { (cd / && chezmoi --no-pager --no-tty "$@"); }

cmd_files() {
	command -v chezmoi >/dev/null 2>&1 || {
		echo "dotfiles files: chezmoi not on PATH" >&2
		exit 1
	}
	sub="${1:-}"
	[ $# -gt 0 ] && shift
	case "$sub" in
	--json)
		command -v jq >/dev/null 2>&1 || {
			echo "dotfiles files: jq not on PATH" >&2
			exit 1
		}
		st="$(cz status --exclude scripts)" || {
			echo "dotfiles files: chezmoi status failed" >&2
			exit 1
		}
		tmpl="$(cz managed --include templates)" || tmpl=""
		# status columns: 1 = changed here since chezmoi wrote it, 2 = the repo
		# would change it; the path starts at column 4
		printf '%s\n' "$st" | jq -R -s --arg tmpl "$tmpl" '
			($tmpl | split("\n") | map(select(length > 0))) as $t
			| split("\n") | map(select(length > 3))
			| map({path: .[3:], local: (.[0:1] != " "), pending: (.[1:2] != " ")}
				| .template = (.path as $p | $t | index($p) != null))'
		;;
	diff | apply | keep)
		[ $# -gt 0 ] || {
			echo "usage: dotfiles files $sub PATH..." >&2
			exit 2
		}
		# relative paths -> absolute, in place (paths may hold spaces)
		_n=$#
		while [ "$_n" -gt 0 ]; do
			case "$1" in /* | ../* | */../* | ..)
				echo "dotfiles files: give paths relative to ~ without ..: $1" >&2
				exit 2
				;;
			esac
			if [ "$sub" = keep ] && cz managed --include templates | grep -qxF "$1"; then
				echo "dotfiles files: $1 comes from a template; edit $(cz source-path "$HOME/$1") instead" >&2
				exit 2
			fi
			set -- "$@" "$HOME/$1"
			shift
			_n=$((_n - 1))
		done
		case "$sub" in
		diff) cz diff "$@" ;;
		# --force: the TUI confirms first that local edits are overwritten
		# not recursive: a directory entry must not drag the files under it
		apply) cz apply --force --recursive=false "$@" ;;
		keep) cz re-add "$@" ;;
		esac
		;;
	*)
		echo "usage: dotfiles files --json | diff|apply|keep PATH..." >&2
		exit 2
		;;
	esac
}

# --- machine: local.yml answers --------------------------------------------

# Scalars `machine set` edits; personal_git_dirs is a list (comma-separated).
MACHINE_KEYS="git_name git_email personal_git_name personal_git_email personal_git_dirs signing_key allow_sudo shared_home"

# resolve_local_yml: set local_yml to the real file (a symlink's target)
resolve_local_yml() {
	local_yml="$(machine_local_yml)"
	_n=0
	while [ -L "$local_yml" ]; do
		_n=$((_n + 1))
		_t="$(readlink "$local_yml")"
		case "$_t" in /*) ;; *) _t="$(dirname "$local_yml")/$_t" ;; esac
		if [ "$_n" -gt 40 ] || { [ ! -e "$_t" ] && [ ! -L "$_t" ]; }; then
			echo "dotfiles: $local_yml is a dangling or looping symlink; fix the link first" >&2
			exit 2
		fi
		local_yml="$_t"
	done
}

# yaml_quote: single-quoted YAML, as install.sh writes it
yaml_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

# set_scalar KEY LINE SRC DST: SRC with the column-0 `KEY:` line replaced by
# LINE (empty LINE deletes it), or LINE appended when absent. Exit 3 when KEY
# is not a one-line scalar (a block value follows it, or it is duplicated).
set_scalar() {
	KEY="$1" LINE="$2" awk '
		BEGIN { key = ENVIRON["KEY"]; line = ENVIRON["LINE"] }
		skip && /^[ \t]+[^ \t#]/ { rc = 3 }
		{ skip = 0 }
		$0 ~ ("^" key ":([ \t]|$)") {
			if (found) rc = 3
			found = 1
			rest = $0; sub("^" key ":[ \t]*", "", rest)
			if (rest == "" || rest ~ /^#/ || rest ~ /^[|>&*]/) { rc = 3; skip = 1 }
			if (line != "") print line
			next
		}
		{ print }
		END { if (!found && line != "") print line; exit rc }' "$3" >"$4"
}

cmd_machine() {
	for t in yq jq; do
		command -v "$t" >/dev/null 2>&1 || {
			echo "dotfiles machine: $t not on PATH" >&2
			exit 1
		}
	done
	resolve_local_yml
	sub="${1:-}"
	[ $# -gt 0 ] && shift
	case "$sub" in
	--json)
		if [ -f "$local_yml" ]; then
			vals="$(yq -o=json -I0 '. // {}' "$local_yml")" || {
				echo "dotfiles machine: cannot read $local_yml" >&2
				exit 1
			}
			exists=true
		else
			vals='{}' exists=false
		fi
		key="$(printf '%s' "$vals" | jq -r '.signing_key // ""')"
		kexists=false
		# shellcheck disable=SC2088 # a literal ~/ prefix, as stored in local.yml
		case "$key" in "~/"*) kpath="$HOME/${key#\~/}" ;; *) kpath="$key" ;; esac
		[ -n "$key" ] && [ -f "$kpath" ] && kexists=true
		printf '%s' "$vals" | jq --arg path "$local_yml" --argjson exists "$exists" \
			--arg keys "$MACHINE_KEYS tool_groups tools_add tools_remove" \
			--argjson kexists "$kexists" '
			. as $v
			| {path: $path, exists: $exists,
				values: ($keys | split(" ") | map({key: ., value: $v[.]}) | from_entries),
				signing: {key: ($v.signing_key // null), exists: $kexists}}'
		;;
	set)
		[ $# -ge 2 ] || {
			echo "usage: dotfiles machine set KEY VALUE [--no-apply]" >&2
			exit 2
		}
		key="$1" val="$2"
		shift 2
		apply=1
		[ "${1:-}" = --no-apply ] && apply=0
		case " $MACHINE_KEYS " in *" $key "*) ;; *)
			echo "dotfiles machine: $key can't be set here (settable: $MACHINE_KEYS)" >&2
			exit 2
			;;
		esac
		[ -f "$local_yml" ] || {
			echo "dotfiles: $local_yml not found; run install.sh first" >&2
			exit 2
		}
		case "$key" in
		git_name | git_email)
			[ -n "$val" ] || {
				echo "dotfiles machine: $key can't be empty" >&2
				exit 2
			}
			;;
		allow_sudo | shared_home)
			case "$val" in true | false) ;; *)
				echo "dotfiles machine: $key is true or false" >&2
				exit 2
				;;
			esac
			;;
		signing_key)
			# a private key path would be read into allowed_signers
			case "$val" in "" | *.pub) ;; *)
				echo "dotfiles machine: signing_key must be a .pub (public key) path" >&2
				exit 2
				;;
			esac
			;;
		esac
		case "$key" in
		allow_sudo | shared_home) line="$key: $val" want="$val" ;;
		personal_git_dirs)
			want="$(printf '%s' "$val" | jq -R -c 'split(",") | map(gsub("^ +| +$"; "")) | map(select(length > 0))')"
			line="$key: $want"
			[ "$want" = "[]" ] && line="" want="null"
			;;
		*)
			line="$key: $(yaml_quote "$val")" want="$(jq -n -c --arg v "$val" '$v')"
			[ -z "$val" ] && line="" want="null"
			;;
		esac
		tmp="$(mktemp "${local_yml}.XXXXXX")" || exit 1
		tmpn="$tmp.new"
		trap 'rm -f "$tmp" "$tmpn"' EXIT
		cp -p "$local_yml" "$tmp" || exit 1
		[ -z "$(tail -c1 "$tmp")" ] || printf '\n' >>"$tmp" || exit 1
		if ! set_scalar "$key" "$line" "$tmp" "$tmpn"; then
			echo "dotfiles: can't safely edit $key in $local_yml; edit it by hand" >&2
			exit 2
		fi
		cat "$tmpn" >"$tmp" || exit 1
		# verify: every other key is identical and KEY holds the new value
		_o1="$(yq -o=json -I0 "(. // {}) | del(.$key)" "$local_yml" | jq -cS .)" || _o1=x1
		_o2="$(yq -o=json -I0 "(. // {}) | del(.$key)" "$tmp" | jq -cS .)" || _o2=x2
		_got="$(yq -o=json -I0 "(. // {}) | .$key" "$tmp" | jq -c .)" || _got=x
		if [ "$_o1" != "$_o2" ] || [ "$_got" != "$want" ]; then
			echo "dotfiles: internal check failed after editing; $local_yml left unchanged" >&2
			exit 1
		fi
		mv -f "$tmp" "$local_yml" || exit 1
		echo "dotfiles: $key updated in $local_yml"
		[ "$apply" -eq 1 ] || return 0
		cmd_machine apply
		;;
	apply)
		command -v ansible-playbook >/dev/null 2>&1 || {
			echo "dotfiles machine: ansible-playbook not on PATH" >&2
			exit 1
		}
		require_home_checkout "dotfiles machine apply"
		echo "==> rewrite chezmoi's config from local.yml"
		# chezmoi_apply is skipped: the playbook applies with --force, which
		# would overwrite files changed here
		(cd "$repo_root/ansible" && ansible-playbook site.yml --tags chezmoi --skip-tags packages,chezmoi_apply) || exit 1
		echo "==> chezmoi apply"
		cz apply || {
			echo "dotfiles: chezmoi apply stopped; a file changed here needs a decision (dotfiles files, or the TUI's Files tab)" >&2
			exit 1
		}
		;;
	*)
		echo "usage: dotfiles machine --json | set KEY VALUE [--no-apply] | apply" >&2
		exit 2
		;;
	esac
}

# cmd_install: the selected tools at their pins (mise, native packages and the
# locked full selection), without the playbook's chezmoi step, which applies
# with --force and rewrites chezmoi's config
cmd_install() {
	command -v ansible-playbook >/dev/null 2>&1 || {
		echo "dotfiles install: ansible-playbook not on PATH" >&2
		exit 1
	}
	[ -f "$repo_root/ansible/local.yml" ] || {
		echo "dotfiles install: $repo_root/ansible/local.yml not found; run install.sh (or run this from $(chezmoi_repo 2>/dev/null || echo the checkout chezmoi uses))" >&2
		exit 1
	}
	echo "==> ansible-playbook site.yml --tags packages"
	(cd "$repo_root/ansible" && ansible-playbook site.yml --tags packages)
}

# cmd_tui [args]: the Textual app, run by uv from its locked script env
cmd_tui() {
	command -v uv >/dev/null 2>&1 || {
		echo "dotfiles tui: uv not on PATH" >&2
		exit 1
	}
	exec uv run --quiet --locked --script "$repo_root/scripts/tui/dotfiles_tui.py" "$@"
}

# Bare `dotfiles` opens the TUI on a terminal; scripts keep usage + exit 2.
if [ $# -eq 0 ]; then
	if [ -t 0 ] && [ -t 1 ]; then
		set -- tui
	else
		usage
		exit 2
	fi
fi
sub="$1"
shift
case "$sub" in
help | -h | --help) usage 1 ;;
list) cmd_list "$@" ;;
add | remove) cmd_edit "$sub" "$@" ;;
update) cmd_update "$@" ;;
install) cmd_install "$@" ;;
doctor) exec sh "$repo_root/scripts/doctor.sh" "$@" ;;
look) cmd_look "$@" ;;
theme | glass | wallpaper) cmd_zsh "$sub" "$@" ;;
files) cmd_files "$@" ;;
machine) cmd_machine "$@" ;;
tui) cmd_tui "$@" ;;
*)
	echo "dotfiles: unknown subcommand: $sub" >&2
	usage
	exit 2
	;;
esac
