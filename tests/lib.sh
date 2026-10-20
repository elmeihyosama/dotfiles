#!/usr/bin/env bash
# Shared helpers for tests/*.test.sh (source, don't execute). Assertions
# record failures and keep going; the EXIT trap cleans up and sets the exit
# status, so tests must not replace it.

TESTS_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_FIXTURE="$TESTS_REPO/.github/scripts/fixture.toml"
TESTS_FAILED=0
_tests_tmpdirs=()

_tests_cleanup() {
	local status=$? d
	for d in ${_tests_tmpdirs[@]+"${_tests_tmpdirs[@]}"}; do
		rm -rf "$d"
	done
	if [ "$TESTS_FAILED" -ne 0 ] && [ "$status" -eq 0 ]; then
		exit 1
	fi
}
trap _tests_cleanup EXIT

# fail MSG: record a failure.
fail() {
	TESTS_FAILED=1
	printf 'FAIL: %s\n' "$1" >&2
}

assert_eq() {
	if [ "$1" != "$2" ]; then
		fail "$3"
		printf '  expected: %s\n  actual:   %s\n' "$1" "$2" >&2
	fi
}

assert_contains() {
	case "$1" in
	*"$2"*) ;;
	*)
		fail "$3"
		printf '  needle:   %s\n  haystack: %s\n' "$2" "$1" >&2
		;;
	esac
}

assert_not_contains() {
	case "$1" in
	*"$2"*)
		fail "$3"
		printf '  unwanted: %s\n  haystack: %s\n' "$2" "$1" >&2
		;;
	esac
}

# render_tmpl FILE [KEY=VALUE ...]: render a chezmoi template with the CI
# fixture, each KEY=VALUE replacing that [data] key. Booleans, numbers and
# [..]/{..} values are raw TOML; anything else is a string.
# TESTS_CHEZMOI_OS=darwin|linux replaces `.chezmoi.os` in a temp copy of the
# top-level template (chezmoi has no way to override it).
render_tmpl() {
	local file="$1" cfg_dir cfg kv key val line extra="" num_re='^-?[0-9]+(\.[0-9]+)?$'
	shift
	cfg_dir="$(mktemp -d)"
	cfg="$cfg_dir/fixture.toml"
	for kv in "$@"; do
		key="${kv%%=*}"
		val="${kv#*=}"
		if [[ "$val" == true || "$val" == false || "$val" == \[* || "$val" == \{* || "$val" =~ $num_re ]]; then
			line="$key = $val"
		else
			line="$key = \"${val//\"/\\\"}\""
		fi
		extra+="$key"$'\t'"$line"$'\n'
	done
	# Drop fixture lines for overridden keys, then add ours right after [data].
	EXTRA="$extra" awk '
		BEGIN {
			n = split(ENVIRON["EXTRA"], rows, "\n")
			for (i = 1; i <= n; i++) if (rows[i] != "") {
				split(rows[i], p, "\t"); skip[p[1]] = 1; add = add "    " p[2] "\n"
			}
		}
		{
			k = $0; sub(/^[ \t]+/, "", k); sub(/[ \t]*=.*/, "", k)
			if (k in skip && $0 ~ /=/) next
			print
			if ($0 ~ /^\[data\][ \t]*$/) printf "%s", add
		}' "$TESTS_FIXTURE" >"$cfg"
	local src="$file"
	if [ -n "${TESTS_CHEZMOI_OS:-}" ]; then
		src="$cfg_dir/forced-os.tmpl"
		# Anchored: only when not followed by an identifier char (BSD+GNU sed).
		sed -e "s/\\.chezmoi\\.os\$/\"$TESTS_CHEZMOI_OS\"/" \
			-e "s/\\.chezmoi\\.os\\([^A-Za-z0-9_]\\)/\"$TESTS_CHEZMOI_OS\"\\1/g" "$file" >"$src"
	fi
	chezmoi execute-template --source "$TESTS_REPO" --config "$cfg" <"$src"
	local rc=$?
	rm -rf "$cfg_dir"
	return "$rc"
}

# mk_home: point HOME and the XDG dirs at a fresh temp dir.
mk_home() {
	local d
	d="$(mktemp -d)"
	_tests_tmpdirs+=("$d")
	export HOME="$d"
	export XDG_CONFIG_HOME="$d/.config"
	export XDG_DATA_HOME="$d/.local/share"
	export XDG_STATE_HOME="$d/.local/state"
	export XDG_CACHE_HOME="$d/.cache"
	mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
}

# run_zsh_env SCRIPT [ENV=VAL ...]: render SCRIPT (a template), source it in
# `zsh -f` (no user rc files) and print the resulting environment.
run_zsh_env() {
	local script="$1" rendered rc
	shift
	# Runs in $(...), so clean up here rather than via _tests_tmpdirs.
	rendered="$(mktemp)"
	if ! render_tmpl "$script" >"$rendered"; then
		rm -f "$rendered"
		return 1
	fi
	# shellcheck disable=SC2016  # $1 is expanded by zsh, not bash
	env "$@" zsh -f -c 'source "$1" && env' _ "$rendered"
	rc=$?
	rm -f "$rendered"
	return "$rc"
}
