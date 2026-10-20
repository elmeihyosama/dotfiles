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
#   update [--check]
#                   git pull --ff-only, ansible-playbook, chezmoi apply,
#                   sheldon lock, nvim plugin restore, then doctor; --check
#                   only reports what an update would do
#   doctor [args]   run scripts/doctor.sh (read-only health check)
#   help            print this usage
# Exit codes: 0 ok, 1 an operation failed, 2 usage or validation error.
#
# add/remove edit only tool_groups, tools_add and tools_remove in local.yml
# as a line edit of just those keys' own lines (yq only reads; every other byte,
# comment and CRLF stays; an unsupported shape exits 2 with nothing written; the
# result is verified, then moved into place atomically). An add of
# a selected tool or a remove of an unselected one changes nothing, judged
# against select-tools' computed selection. Every argument is validated before
# anything is written. Apply = ansible-playbook site.yml --tags
# mise,chezmoi,packages; if it fails local.yml stays edited and re-running the
# printed command is safe.
#
# update: each step prints `==> <step>`; the first failure stops it (exit 1).
# It never stashes, resets or force-pulls: a dirty repo is refused. Step order:
# git pull --ff-only; (cd ansible && ansible-playbook site.yml); chezmoi apply;
# sheldon lock --update when home/dot_config/sheldon/plugins.toml differs between
# the pre- and post-pull HEAD (plugins are pinned by rev, so --update only moves
# them to the pinned revs), else sheldon lock; nvim --headless "+Lazy! restore"
# +qa; dotfiles doctor (its exit code is update's). sheldon and nvim are skipped
# with a notice when not installed. Nothing may prompt (it runs from Raycast
# without a tty): GIT_TERMINAL_PROMPT=0, ssh BatchMode, no colour, no progress.
# The playbook only uses sudo when allow_sudo is true (local.yml, else the
# `sudo -n true` probe in site.yml); a password-needing sudo fails the task, it
# does not wait. --check: git fetch (a failure is a warning), incoming commits,
# `chezmoi diff --exclude scripts` (first 200 lines), and selected mise tools
# whose pinned version is not installed (from `list --json`). It writes nothing.
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
		echo "subcommands: list [--json] | add TOOL|GROUP... | remove TOOL|GROUP... | update [--check] | doctor [args] | help"
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
	# no tty may be present (Raycast): nothing below may prompt
	export GIT_TERMINAL_PROMPT=0
	[ -n "${GIT_SSH_COMMAND:-}" ] || export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"
	export NO_COLOR=1
	# a bare environment lacks the pinned tools; look in the usual places last,
	# mise's shims ahead of ~/.local/bin (mise tools outrank it, as in the shell)
	# shellcheck source=mise-env.sh
	. "$repo_root/scripts/mise-env.sh"
	_data="${MISE_DATA_DIR:-$HOME/.local/share$(mise_sfx "${DOTFILES_LOCAL_YML:-$repo_root/ansible/local.yml}")/mise}"
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
	# never --force: a managed file edited since chezmoi last wrote it would be
	# overwritten silently. With no tty chezmoi cannot ask and fails instead.
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
		# sheldon reads ~/.config/sheldon/plugins.toml (chezmoi, just applied);
		# no SHELDON_* variables are set anywhere, so no zsh is needed
		# A plain lock fails when a pin moved by a pull outside update (a
		# manual pull, install.sh, or an update that failed after its pull)
		# names a rev sheldon has not fetched: retry once with --update.
		# shellcheck disable=SC2086 # _sh is a fixed command line
		if ! $_sh; then
			[ "$_sh" = "sheldon lock" ] || upd_fail "$_sh"
			echo "  (sheldon lock failed; retrying with --update)"
			sheldon lock --update || upd_fail "sheldon lock --update"
		fi
	else
		echo "  (sheldon not installed; skipped)"
	fi
	# nvim exits 0 even when Lazy reports a failed restore, so this step only
	# fails when nvim itself cannot run
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
# Exit 3: a shape we do not edit (scalar, anchor, multi-line flow, duplicate).
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
			mode = 0
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
			if (mode == 2) {
				if (line ~ /^[ ]*-([ ]|$)/) {
					if (!seen) { indent = line; sub(/-.*/, "", indent); icr = cr; seen = 1 }
					next
				}
				emit_items()
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

	# Temp files: scratch holds select-tools probes (no user content); tmp/tmpn
	# live next to local.yml so the final mv is atomic. All removed on any exit.
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
	# sel_has STATE_JSON NAME: is NAME in select-tools' selection for that state?
	# (select-tools is the only place the selection rules live.)
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
	_other='del(.tool_groups, .tools_add, .tools_remove)'
	_o1="$(yq -o=json -I0 "$_other" "$local_yml" | jq -cS .)" || _o1=x1
	_o2="$(yq -o=json -I0 "$_other" "$tmp" | jq -cS .)" || _o2=x2
	ok=1
	[ "$_o1" = "$_o2" ] || ok=0
	for key in $changed; do
		_want="$(printf '%s' "$st" | jq -c ".$key")"
		_got="$(yq -o=json -I0 ".$key" "$tmp" | jq -c . 2>/dev/null)" || _got=x
		[ "$_want" = "$_got" ] || ok=0
	done
	if [ "$ok" -ne 1 ] || ! after="$(sel_run "$tmp")"; then
		echo "dotfiles: internal check failed after editing; $local_yml left unchanged" >&2
		exit 1
	fi
	mv -f "$tmp" "$local_yml" || exit 1

	# tools that stop being installed: native ones get a hint, mise ones are
	# uninstalled after the apply
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
update) cmd_update "$@" ;;
doctor) exec sh "$repo_root/scripts/doctor.sh" "$@" ;;
*)
	echo "dotfiles: unknown subcommand: $sub" >&2
	usage
	exit 2
	;;
esac
