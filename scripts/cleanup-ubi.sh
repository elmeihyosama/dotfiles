#!/usr/bin/env sh
# cleanup-ubi.sh: one-time removal of the old ubi install's leftovers.
# Usage: cleanup-ubi.sh LOCAL_BIN LOCAL_OPT TOOLS_YAML SELECTION_JSON   (needs jq)
#   SELECTION_JSON: select-tools.sh output (the JSON text, not a path).
#
# Runs only while a legacy marker exists (LOCAL_BIN/ubi or LOCAL_OPT/neovim)
# and deletes the markers last, so later runs never touch a binary the user
# adds. Only bins of tools select-tools sources from mise (or bundled with a
# mise provider), never uv: a regular file unless it is a mise shim, or a
# legacy rename symlink (batcat/fdfind, editorconfig-checker, into
# LOCAL_OPT/neovim). TOOLS_YAML is unused (kept for the interface).
# Prints one `removed: PATH` line per deletion. Exit 0.
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
