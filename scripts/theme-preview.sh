#!/bin/sh
# theme-preview.sh — render a base16 theme as a mock terminal for the `theme`
# fzf picker preview (à la terminalcolors.com): background, prompt, ls, a code
# snippet, and the 16-color palette, all painted in the theme's colors.
# Usage: theme-preview.sh <path/to/theme.toml>
set -eu

f=${1:-}
[ -f "$f" ] || exit 0

awk -v name="$(basename "$f" .toml)" -v W="${FZF_PREVIEW_COLUMNS:-58}" '
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
	function fgc(k) { return sprintf("\033[38;2;%d;%d;%dm", R[k], G[k], B[k]) }
	function bgc(k) { return sprintf("\033[48;2;%d;%d;%dm", R[k], G[k], B[k]) }
	function add(s, w) { BUF = BUF s; VLEN += w }
	function raw(t) { add(t, length(t)) }
	function txt(k, t) { add(fgc(k) t, length(t)) }
	function sw(k) { add(bgc(k) "  " BG, 2) }
	function flush(  pad) {
		pad = W - VLEN
		if (pad < 0) pad = 0
		printf "%s%s%*s\033[0m\n", BG, BUF, pad, ""
		BUF = ""
		VLEN = 0
	}
	/^base0[0-9A-Fa-f]/ {
		hex = $3
		gsub(/[#"]/, "", hex)
		if (length(hex) < 6) next
		R[$1] = h2d(substr(hex, 1, 2))
		G[$1] = h2d(substr(hex, 3, 2))
		B[$1] = h2d(substr(hex, 5, 2))
	}
	END {
		BG = bgc("base00")
		flush()
		raw("  ")
		add("\033[1m" fgc("base05") name "\033[22m", length(name))
		flush()
		flush()
		raw("  "); txt("base0B", "user"); txt("base05", "@"); txt("base0C", "host")
		raw(" "); txt("base0D", "~/dev/dotfiles"); raw(" ")
		txt("base0E", "git:("); txt("base08", "main"); txt("base0E", ")"); flush()
		raw("  "); txt("base0B", "$"); raw(" "); txt("base05", "ls"); flush()
		raw("  "); txt("base0D", "src"); raw("  "); txt("base0D", "docs")
		raw("  "); txt("base05", "README.md"); raw("  "); txt("base0A", "Makefile")
		raw("  "); txt("base0B", "run.sh"); flush()
		raw("  "); txt("base0B", "$"); raw(" "); txt("base05", "cat hello.py"); flush()
		raw("  "); txt("base0E", "def "); txt("base0D", "greet"); txt("base05", "(name):"); flush()
		raw("      "); txt("base0C", "print"); txt("base05", "(")
		txt("base0B", "\"hi, \""); txt("base05", " + name)")
		raw("   "); txt("base03", "# base16"); flush()
		flush()
		raw("  ")
		for (i = 0; i < 16; i++) {
			d = (i < 10) ? i : substr("ABCDEF", i - 9, 1)
			sw("base0" d)
		}
		flush()
		flush()
	}
' "$f"
