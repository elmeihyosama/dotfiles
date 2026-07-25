#!/bin/sh
# theme-audit.sh — verify vendored themes against tinted-theming/schemes and
# report per-theme quirks. Sections:
#   DRIFT:        vendored TOML differs from freshly-converted upstream
#   COLLISION:    accent slots (base08–base0E) sharing one colour
#   LOWCONTRAST:  fg/bg contrast ratio < 3.0 for text or accent roles
# Usage: scripts/theme-audit.sh [--ref REF]   (default: upstream HEAD)
#
# Note: the COLLISION/LOWCONTRAST pass runs awk once per theme file (END,
# not ENDFILE) because macOS ships a one-true-awk without ENDFILE support;
# this keeps the script POSIX-portable without depending on gawk.
set -eu
REPO_ROOT=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
THEMES_DIR="$REPO_ROOT/home/.chezmoidata/themes"
REF=HEAD
[ "${1:-}" = "--ref" ] && REF=${2:?--ref needs a value}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

git clone --quiet --depth 1 https://github.com/tinted-theming/schemes "$tmp/schemes"
if [ "$REF" != "HEAD" ]; then
	git -C "$tmp/schemes" fetch --quiet --depth 1 origin "$REF"
	git -C "$tmp/schemes" checkout --quiet FETCH_HEAD
fi
printf 'upstream commit: %s\n' "$(git -C "$tmp/schemes" rev-parse HEAD)"

SCHEMES_SRC="$tmp/schemes/base16"
[ -d "$SCHEMES_SRC" ] || SCHEMES_SRC="$tmp/schemes/base16/schemes"

mkdir -p "$tmp/out"
OUT_DIR="$tmp/out" "$REPO_ROOT/scripts/base16-to-theme.sh" -d "$SCHEMES_SRC" >/dev/null

# --- DRIFT ---------------------------------------------------------------
for f in "$THEMES_DIR"/*.toml; do
	b=$(basename "$f")
	if [ ! -f "$tmp/out/$b" ]; then
		printf 'DRIFT %s: missing upstream (renamed or removed?)\n' "$b"
	elif ! cmp -s "$f" "$tmp/out/$b"; then
		printf 'DRIFT %s: differs from regenerated upstream\n' "$b"
	fi
done
for f in "$tmp/out"/*.toml; do
	[ -f "$THEMES_DIR/$(basename "$f")" ] || printf 'DRIFT %s: new upstream scheme not vendored\n' "$(basename "$f")"
done

# --- COLLISION + LOWCONTRAST --------------------------------------------
for f in "$THEMES_DIR"/*.toml; do
	slug=$(basename "$f")
	slug=${slug%.toml}
	awk -v slug="$slug" '
	function h2d(s,  i, c, v, n) {
		n = 0
		s = tolower(s)
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			v = index("0123456789abcdef", c) - 1
			if (v < 0) v = 0
			n = n * 16 + v
		}
		return n
	}
	function lin(c) { c /= 255; return (c <= 0.04045) ? c / 12.92 : ((c + 0.055) / 1.055) ^ 2.4 }
	function lum(h,  r, g, b) {
		r = h2d(substr(h, 2, 2)); g = h2d(substr(h, 4, 2)); b = h2d(substr(h, 6, 2))
		return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
	}
	function ratio(a, b,  la, lb, t) {
		la = lum(a); lb = lum(b)
		if (la < lb) { t = la; la = lb; lb = t }
		return (la + 0.05) / (lb + 0.05)
	}
	/^base0[0-9A-F] = / { gsub(/"/, "", $3); v[$1] = $3 }
	END {
		for (i in v) for (j in v)
			if (i < j && i ~ /base0[89ABCDE]/ && j ~ /base0[89ABCDE]/ && v[i] == v[j])
				printf "COLLISION %s: %s == %s (%s)\n", slug, i, j, v[i]
		if (ratio(v["base05"], v["base00"]) < 3.0)
			printf "LOWCONTRAST %s: text/bg %.2f\n", slug, ratio(v["base05"], v["base00"])
		if (ratio(v["base0B"], v["base00"]) < 3.0)
			printf "LOWCONTRAST %s: accent(base0B)/bg %.2f\n", slug, ratio(v["base0B"], v["base00"])
	}
	' "$f"
done
