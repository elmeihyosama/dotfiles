#!/bin/sh
# base16-to-theme.sh — convert base16 scheme YAML(s) into chezmoi theme TOML.
#
# Usage:
#   scripts/base16-to-theme.sh FILE.yaml [FILE2.yaml ...]
#   scripts/base16-to-theme.sh -d SRC_DIR     # convert every *.yaml/*.yml in SRC_DIR
#
# Output: home/.chezmoidata/themes/<slug>.toml  (slug = filename without extension).
# Dependency-free: POSIX sh + awk only. Idempotent.
set -eu

REPO_ROOT=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
OUT_DIR="$REPO_ROOT/home/.chezmoidata/themes"
mkdir -p "$OUT_DIR"

convert_one() {
	src=$1
	base=$(basename "$src")
	slug=${base%.yaml}
	slug=${slug%.yml}
	out="$OUT_DIR/$slug.toml"
	{
		printf '[themes.%s]\n' "$slug"
		awk '
/^[[:space:]]*base0[0-9A-Fa-f][[:space:]]*:/ {
key=$0; sub(/:.*/, "", key); gsub(/[[:space:]]/, "", key)
rest=$0; sub(/^[^:]*:/, "", rest)
if (match(rest, /[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/))
printf "%s = \"#%s\"\n", key, tolower(substr(rest, RSTART, RLENGTH))
}
' "$src"
	} >"$out"
	echo "wrote $out"
}

if [ "${1:-}" = "-d" ]; then
	[ $# -ge 2 ] || {
		echo "usage: $0 -d SRC_DIR" >&2
		exit 2
	}
	for f in "$2"/*.yaml "$2"/*.yml; do
		[ -f "$f" ] || continue
		convert_one "$f"
	done
else
	[ $# -ge 1 ] || {
		echo "usage: $0 FILE.yaml [...] | -d DIR" >&2
		exit 2
	}
	for f in "$@"; do
		convert_one "$f"
	done
fi
