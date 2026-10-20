#!/usr/bin/env sh
# Assert every tool this machine selects resolves, runs, and passes its smoke test.
# Usage: .github/scripts/assert-tools.sh [--local LOCAL_YML] [--tools TOOLS_YAML]
#   --local  per-machine vars (default: ansible/local.yml)
#   --tools  tool catalog (default: home/.chezmoidata/tools.yaml; for tests)
#
# The tool set comes from scripts/select-tools.sh over the catalog (one source
# of truth with the playbook). Per source:
#   mise       `mise which --version <bin>` must be the exact tools.yaml version,
#              and `command -v <bin>` must point inside mise's data dir (a shim
#              or an install). Other copies further back on PATH get a WARN
#              (shadowed) with a removal hint; a copy AHEAD of mise's is a FAIL.
#   bundled    ships inside its provider (age-keygen in age): as above when the
#              provider comes from mise, at the provider's version.
#   bootstrap  (mise itself) must resolve and run.
#   native     must resolve: required on macOS (brew), best effort (SKIP) on Linux.
# `smoke` (tools.yaml) runs when set. Output lines: OK: / WARN: / SKIP: / FAIL:.
#
# The home pins are resolved from outside any project: mise runs as `mise -C /`
# with MISE_SYSTEM_CONFIG_DIR at the dotfiles pins and the user's global config
# masked (as the playbook's mise_install_env does), so neither the repo's own
# mise.toml (the lint toolchain) nor `mise use -g` answers for a home tool.
set -eu

repo="$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)"
local_yml="$repo/ansible/local.yml"
tools_yaml="$repo/home/.chezmoidata/tools.yaml"
usage() {
	echo "usage: assert-tools.sh [--local LOCAL_YML] [--tools TOOLS_YAML]" >&2
	exit 2
}
while [ $# -gt 0 ]; do
	[ $# -ge 2 ] || usage
	case "$1" in
	--local) local_yml="$2" ;;
	--tools) tools_yaml="$2" ;;
	*) usage ;;
	esac
	shift 2
done

# The dotfiles pins dir, the (per-arch under shared_home) data dir, and the
# masked global config: scripts/mise-env.sh sets sfx, user_global and MISE_*.
# shellcheck source=../../scripts/mise-env.sh
. "$repo/scripts/mise-env.sh"
mise_env "$local_yml"
# A shell that never read the dotfiles' .zshenv/.bashrc (a CI step, a fresh
# container) lacks the shims: put them in front, as those files do. The local
# bin (mise itself) is appended when missing, never moved ahead of anything.
# Entries already on PATH keep the caller's order: that order is what this
# check is about.
on_path() { case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac }
for d in "$HOME/.local/bin$sfx" "$HOME/.local/bin"; do
	on_path "$d" || PATH="$PATH:$d"
done
on_path "$MISE_DATA_DIR/shims" || PATH="$MISE_DATA_DIR/shims:$PATH"
export PATH
cd /

for t in yq jq; do
	command -v "$t" >/dev/null 2>&1 || {
		echo "FAIL: $t not on PATH (provision did not install the core tools)"
		exit 1
	}
done

case "$(uname -s)" in Darwin) os=darwin ;; *) os=linux ;; esac
sel="$("$repo/scripts/select-tools.sh" --os "$os" --local "$local_yml" --tools "$tools_yaml")"

# resolve, remove_hint (needs $os and $tools_yaml)
# shellcheck source=../../scripts/remove-hint.sh
. "$repo/scripts/remove-hint.sh"
data_real="$(resolve "$MISE_DATA_DIR")"
in_mise() { # in_mise PATH: a shim or install under mise's data dir
	case "$1" in "$MISE_DATA_DIR"/*) return 0 ;; esac
	case "$(resolve "$1")" in "$data_real"/*) return 0 ;; esac
	return 1
}
# copies BIN: every executable BIN on PATH, in PATH order, once per real dir
copies() {
	_seen=":"
	_ifs="$IFS"
	IFS=:
	for _d in $PATH; do
		[ -n "$_d" ] && [ -x "$_d/$1" ] && [ ! -d "$_d/$1" ] || continue
		_r="$(CDPATH='' cd -P "$_d" 2>/dev/null && pwd -P)" || continue
		case "$_seen" in *":$_r:"*) continue ;; esac
		_seen="$_seen$_r:"
		printf '%s\n' "$_d/$1"
	done
	IFS="$_ifs"
}
fail=0
# name|bin|source|version|mise-managed (yes/no). A bundled tool takes its
# provider's version and is mise-managed when its provider is.
rows="$(printf '%s\n' "$sel" | jq -r '
	(map({key: .name, value: .}) | from_entries) as $by
	| .[]
	| (if .source == "bundled" then $by[.provided_by] else . end) as $src
	| [.name, .bin, .source, ($src.version // ""),
		(if $src.source == "mise" then "yes" else "no" end)]
	| join("|")')"
while IFS='|' read -r tool bin source want managed; do
	[ -n "$tool" ] || continue
	if ! where="$(command -v "$bin" 2>/dev/null)"; then
		# Native tools are best effort on Linux (the distro may lack the
		# package, no-sudo hosts skip them) but required on macOS, where brew
		# is always there and every native tool has a formula.
		if [ "$source" = native ] && [ "$os" != darwin ]; then
			echo "SKIP: $tool -> '$bin' (native, best effort: not installed here)"
		else
			echo "FAIL: $tool -> '$bin' not found on PATH"
			fail=1
		fi
		continue
	fi

	if [ "$managed" = yes ]; then
		# stdout only: a mise WARN on stderr must not spoil the comparison.
		if ! got="$(mise -C / which --version "$bin" 2>/dev/null)"; then
			err="$(mise -C / which --version "$bin" 2>&1 >/dev/null | head -n1)" || true
			echo "FAIL: $tool -> mise does not provide '$bin' from the dotfiles pins (want $want): $err"
			fail=1
			continue
		fi
		if [ "$got" != "$want" ]; then
			echo "FAIL: $tool -> mise resolves '$bin' to $got, tools.yaml pins $want (run the playbook, or: mise -C / install --locked)"
			fail=1
			continue
		fi
		# An install dir on PATH (mise activate) must be the pinned one, not
		# an old version left there by a stale shell. One that the user's
		# global config selects (`mise use -g`) is their choice: WARN.
		case "$where" in "$MISE_DATA_DIR"/installs/*)
			pinned="$(mise -C / which "$bin" 2>/dev/null)" || pinned=""
			if [ "$(resolve "$where")" != "$(resolve "$pinned")" ]; then
				if [ -f "$user_global" ] &&
					[ "$(resolve "$(MISE_GLOBAL_CONFIG_FILE="$user_global" mise -C / which "$bin" 2>/dev/null)")" = "$(resolve "$where")" ]; then
					ver="$(MISE_GLOBAL_CONFIG_FILE="$user_global" mise -C / which --version "$bin" 2>/dev/null)" || ver="?"
					echo "WARN: $tool -> '$bin' is $ver from your global mise config ($user_global), not the pinned $want; remove it there to use the pin"
					continue
				fi
				echo "FAIL: $tool -> '$bin' resolves to $where, not the pinned $want install ($pinned): restart the shell, or run: mise -C / install --locked"
				fail=1
				continue
			fi
			;;
		esac
		if ! in_mise "$where"; then
			hint="$(remove_hint "$tool" "$where")"
			echo "FAIL: $tool -> '$bin' resolves to $where, not mise's (under $MISE_DATA_DIR)${hint:+; remove with: $hint}"
			fail=1
			continue
		fi
		while IFS= read -r c; do
			[ -n "$c" ] || continue
			in_mise "$c" && continue
			# install.sh's own pinned uv (it bootstraps ansible-core before
			# mise exists, and reinstalls it when missing): expected, not stray.
			[ "$c" = "$HOME/.local/bin$sfx/uv" ] && continue
			hint="$(remove_hint "$tool" "$c")"
			[ -n "$hint" ] || continue
			echo "WARN: $bin also installed at $c (shadowed); remove with: $hint"
		done <<C
$(copies "$bin")
C
	fi

	# Native packages are best effort and not all take --version (cava -v).
	if [ "$source" != native ] && ! out="$("$bin" --version 2>&1)"; then
		echo "FAIL: $tool -> '$bin' did not run '--version': $(printf '%s' "$out" | head -n1)"
		fail=1
		continue
	fi

	# `--version` is answered by the binary alone, so it cannot see a missing
	# install tree (a neovim without share/nvim/runtime passes it and is still
	# unusable). Tools with a smoke test must also exit 0 AND stay silent —
	# nvim prints E484 on a broken runtime but still exits 0, so check output.
	smoke="$(yq ".tools.\"$tool\".smoke // \"\"" "$tools_yaml")"
	if [ -n "$smoke" ]; then
		if ! sout="$(sh -c "$smoke" 2>&1)" || [ -n "$sout" ]; then
			echo "FAIL: $tool -> smoke test failed: $(printf '%s' "$sout" | head -n1)"
			fail=1
			continue
		fi
	fi
	if [ "$managed" = yes ]; then
		echo "OK:   $tool -> $bin $want ($source: $where)"
	else
		echo "OK:   $tool -> $bin ($source, present: $where)"
	fi
done <<EOF
$rows
EOF

[ "$fail" -eq 0 ] && echo "All tool assertions passed." || echo "Tool assertions FAILED."
exit "$fail"
