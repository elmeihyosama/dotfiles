#!/usr/bin/env sh
# cleanup-ubi.sh — one-time removal of what the old ubi install path left
# behind, now that CLI tools come from mise.
# Usage: cleanup-ubi.sh LOCAL_BIN LOCAL_OPT TOOLS_YAML SELECTION_JSON   (needs jq)
#   SELECTION_JSON: scripts/select-tools.sh output for this host (the JSON
#   text itself, not a path).
#
# One-shot: it runs only while a legacy marker exists — LOCAL_BIN/ubi (every
# old install path bootstrapped ubi: the no-sudo path, macOS for gh-dash and
# sudo Linux for the force_ubi tools) or the LOCAL_OPT/neovim tree. It deletes
# both markers last, so later runs are no-ops and a binary the user puts in
# LOCAL_BIN afterwards is never touched. A marker instead of a stamp file: no
# extra state to keep, and a host that never had ubi is never scanned.
#
# Scope: only bins of tools that select-tools reports with source "mise" on
# this host (or "bundled" with a mise provider, e.g. age-keygen) — the locked
# mise install replaces exactly those. Native, deselected and bootstrap tools
# (mise itself) are never touched, nor uv (install.sh puts its own pinned uv
# in LOCAL_BIN; ubi never installed it). For each such name in LOCAL_BIN it deletes:
#   - a regular file, unless it is a mise shim (mentions `mise`);
#   - a legacy rename symlink: target named batcat/fdfind (apt) or
#     editorconfig-checker (brew), or into LOCAL_OPT/neovim.
# Foreign symlinks and every other file stay. TOOLS_YAML is accepted for the
# interface's sake (the selection already carries each bin).
# Prints one `removed: PATH` line per deletion; nothing when clean. Exit 0.
set -eu

[ $# -eq 4 ] || {
	echo "usage: cleanup-ubi.sh LOCAL_BIN LOCAL_OPT TOOLS_YAML SELECTION_JSON" >&2
	exit 2
}
bin_dir="$1"
opt_dir="$2"
selection="$4"

if [ ! -e "$bin_dir/ubi" ] && [ ! -d "$opt_dir/neovim" ]; then
	exit 0
fi

names="$(printf '%s\n' "$selection" | jq -r '
	(map({key: .name, value: .source}) | from_entries) as $src
	| .[] | select(.source == "mise" or (.source == "bundled" and $src[.provided_by] == "mise"))
	| select(.name != "uv")
	| .bin')"

removed=""
for n in $names; do
	f="$bin_dir/$n"
	if [ -L "$f" ]; then
		target="$(readlink "$f")"
		case "$target" in
		*/batcat | */fdfind | */editorconfig-checker | batcat | fdfind | editorconfig-checker | "$opt_dir"/neovim/*) ;;
		*) continue ;;
		esac
	elif [ -f "$f" ]; then
		# A mise shim written as a script (`exec mise x -- ...`).
		if head -c 4096 "$f" 2>/dev/null | grep -aq 'mise'; then continue; fi
	else
		continue
	fi
	rm -f "$f"
	removed="$removed$f
"
done
# The markers last: once they are gone this script never runs again.
if [ -d "$opt_dir/neovim" ]; then
	rm -rf "$opt_dir/neovim"
	removed="$removed$opt_dir/neovim
"
fi
if [ -f "$bin_dir/ubi" ] && ! [ -L "$bin_dir/ubi" ]; then
	rm -f "$bin_dir/ubi"
	removed="$removed$bin_dir/ubi
"
fi
printf '%s' "$removed" | sed 's/^/removed: /'
