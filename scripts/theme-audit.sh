#!/bin/sh
# theme-audit.sh — verify vendored themes against tinted-theming/schemes and
# report per-theme quirks. Sections:
#   DRIFT:        vendored TOML differs from freshly-converted upstream
#   COLLISION:    accent slots (base08–base0E) sharing one colour
#   LOWCONTRAST:  text/bg < 3.0, or a chip (text ON an accent slot) whose best
#                 on-color (base00/base05, see gen-on-colors.sh) still can't reach 3.0
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

# Cache the upstream clone under $XDG_CACHE_HOME so re-runs reuse it and an
# offline run still works (fetch is best-effort). The rest of the script keeps
# using "$tmp/schemes" via a symlink into the cache.
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/tinted-schemes"
if [ -d "$CACHE/.git" ]; then
	if git -C "$CACHE" fetch --quiet --depth 1 origin "$REF" 2>/dev/null; then
		git -C "$CACHE" checkout --quiet -f FETCH_HEAD 2>/dev/null || true
	else
		printf 'note: could not fetch upstream (offline?) — using cached schemes\n' >&2
	fi
else
	git clone --quiet --depth 1 https://github.com/tinted-theming/schemes "$CACHE"
	if [ "$REF" != "HEAD" ]; then
		git -C "$CACHE" fetch --quiet --depth 1 origin "$REF"
		git -C "$CACHE" checkout --quiet -f FETCH_HEAD
	fi
fi
ln -s "$CACHE" "$tmp/schemes"
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
		# Chrome chips put text ON an accent slot (zellij pills, lualine block,
		# delta emph, yazi hover). The foreground is on-color = base00 or base05,
		# whichever contrasts more (scripts/gen-on-colors.sh). Report slots where
		# even the best on-color stays < 3.0 — inherently marginal, unfixable by
		# token choice. This is the guardrail for the fg-on-accent bug class.
		split("base08 base0A base0B base0C base0D base0E", chips, " ")
		for (c = 1; c <= 6; c++) {
			s = chips[c]
			best = ratio(v["base00"], v[s])
			if (ratio(v["base05"], v[s]) > best) best = ratio(v["base05"], v[s])
			if (best < 3.0)
				printf "LOWCONTRAST %s: chip-on-%s best %.2f\n", slug, s, best
		}
	}
	' "$f"
done
