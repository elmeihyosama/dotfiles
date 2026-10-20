#!/usr/bin/env sh
# remove-hint.sh: sourced by assert-tools.sh and doctor.sh; how to remove a
# non-mise copy of a tool. The caller sets $os and $tools_yaml.
# shellcheck disable=SC2154 # os, tools_yaml: set by the sourcing script

# resolve PATH: the file a path finally points at (or the path itself)
resolve() { realpath "$1" 2>/dev/null || printf '%s\n' "$1"; }
# pkg_name TOOL MANAGER: tools.yaml native_pkg.<manager>, else the tool name
pkg_name() { yq ".tools.\"$1\".native_pkg.$2 // \"$1\"" "$tools_yaml"; }
# remove_hint TOOL PATH: prints nothing for a file macOS owns (SIP).
remove_hint() {
	_real="$(resolve "$2")"
	case "$_real" in */Cellar/*)
		_f="${_real#*/Cellar/}"
		echo "brew uninstall ${_f%%/*}"
		return
		;;
	esac
	for _p in ${HOMEBREW_PREFIX:-} /opt/homebrew /home/linuxbrew/.linuxbrew; do
		case "$2" in "$_p"/*)
			echo "brew uninstall $(pkg_name "$1" brew)"
			return
			;;
		esac
	done
	case "$2" in /usr/bin/* | /bin/* | /usr/sbin/* | /sbin/*)
		[ "$os" = darwin ] && return
		if command -v dpkg >/dev/null 2>&1; then
			_k="$(dpkg -S "$2" 2>/dev/null || dpkg -S "$_real" 2>/dev/null)" || _k=""
			_k="${_k%%:*}"
			echo "sudo apt remove ${_k:-$(pkg_name "$1" apt)}"
		elif command -v rpm >/dev/null 2>&1; then
			_k="$(rpm -qf --qf '%{NAME}\n' "$2" 2>/dev/null | head -n1)" || _k=""
			echo "sudo dnf remove ${_k:-$(pkg_name "$1" dnf)}"
		elif command -v pacman >/dev/null 2>&1; then
			_k="$(pacman -Qoq "$2" 2>/dev/null)" || _k=""
			echo "sudo pacman -R ${_k:-$(pkg_name "$1" pacman)}"
		else
			echo "your package manager"
		fi
		return
		;;
	esac
	echo "rm $2"
}
