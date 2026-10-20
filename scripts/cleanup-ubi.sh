#!/usr/bin/env sh
# cleanup-ubi.sh — remove what the old ubi install path left behind, now that
# CLI tools come from mise.
# Usage: cleanup-ubi.sh LOCAL_BIN LOCAL_OPT TOOLS_YAML   (needs yq)
#
# In LOCAL_BIN it deletes, by name (`ubi`, every tool `bin` in TOOLS_YAML,
# plus the legacy names delta/rg/nvim/ec):
#   - regular files, unless they are mise shims (mention `mise`);
#   - the legacy rename symlinks: targets named batcat/fdfind (apt) or
#     editorconfig-checker (brew), or anything into LOCAL_OPT/neovim.
# Never touched: the pinned mise binary and uv (installed by mise.yml and
# uv's own installer, not ubi), source-only tools (never ubi-installed),
# symlinks into mise or anywhere else, and every other file. Then it deletes
# LOCAL_OPT/neovim (the ubi --extract-all tree).
# Prints one `removed: PATH` line per deletion; nothing when clean. Exit 0.
set -eu

[ $# -eq 3 ] || {
	echo "usage: cleanup-ubi.sh LOCAL_BIN LOCAL_OPT TOOLS_YAML" >&2
	exit 2
}
bin_dir="$1"
opt_dir="$2"
tools_yaml="$3"

names="$(yq '.tools | to_entries | .[]
	| select(.value.bootstrap != true and .value.native_only != true and .key != "uv")
	| (.value.bin // .key)' "$tools_yaml")"
names="ubi delta rg nvim ec $names"

removed=""
# shellcheck disable=SC2086 # word-split the name list on purpose
for n in $(printf '%s\n' $names | sort -u); do
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
if [ -d "$opt_dir/neovim" ]; then
	rm -rf "$opt_dir/neovim"
	removed="$removed$opt_dir/neovim
"
fi
printf '%s' "$removed" | sed 's/^/removed: /'
