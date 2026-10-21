#!/usr/bin/env bash
# Prompt options (.chezmoidata/prompt.toml): the starship and ghostty templates
# for the defaults, for every choice of every option (valid TOML that starship
# loads without a warning) and for the layouts that differ.
# shellcheck disable=SC2016 # starship's $variables are literal text here
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for t in chezmoi jq python3 starship; do
	command -v "$t" >/dev/null 2>&1 || {
		[ -z "${CI:-}" ] || fail "no $t on PATH (CI must not skip; the repo mise.toml pins it)"
		echo "SKIP: no $t on PATH" >&2
		exit 0
	}
done

starship_tmpl="$TESTS_REPO/home/dot_config/starship.toml.tmpl"
ghostty_tmpl="$TESTS_REPO/home/dot_config/ghostty/config.tmpl"
data="$TESTS_REPO/home/.chezmoidata/prompt.toml"
mk_home
scratch="$(mktemp -d)"
_tests_tmpdirs+=("$scratch")

# get FILE KEY...: a value from rendered TOML, by a dotted path (JSON).
get() {
	python3 -I -c 'import json, sys, tomllib
v = tomllib.load(open(sys.argv[1], "rb"))
for k in sys.argv[2].split("."):
	v = v.get(k) if isinstance(v, dict) else None
print(json.dumps(v, ensure_ascii=False))' "$@"
}
# render NAME [KEY=VAL...]: the starship config at $scratch/NAME.toml
render() {
	local name="$1"
	shift
	render_tmpl "$starship_tmpl" "$@" >"$scratch/$name.toml" || fail "$name: renders"
}
# loads NAME: starship draws a prompt from it and says nothing on stderr
loads() {
	local err
	err="$(cd "$scratch" && STARSHIP_CONFIG="$scratch/$1.toml" STARSHIP_CACHE="$scratch/cache" \
		starship prompt -w 100 -p "$scratch" -s 1 -d 3000 -j 1 2>&1 >/dev/null)"
	assert_eq "" "$err" "$1: starship loads it without warnings"
}

# defaults: the prompt as it was before the options existed
render default
loads default
assert_eq '"[╭─](rail)$hostname$directory$git_branch$git_status$jobs$nodejs$python$rust$golang$docker_context$kubernetes$fill$cmd_duration$time\n[╰─](rail)$character"' \
	"$(get "$scratch/default.toml" format)" "default: two lines, framed, split"
assert_eq true "$(get "$scratch/default.toml" add_newline)" "default: sparse"
assert_eq null "$(get "$scratch/default.toml" right_format)" "default: no right prompt"
assert_eq '"bold accent2"' "$(get "$scratch/default.toml" directory.style)" "default: directory colour"
assert_eq '"[❯](bold accent)"' "$(get "$scratch/default.toml" character.success_symbol)" "default: chevron"
assert_eq '" "' "$(get "$scratch/default.toml" fill.symbol)" "default: fill is space"
assert_eq '"%R"' "$(get "$scratch/default.toml" time.time_format)" "default: 24h clock"

# every_choice: each option's choices, one at a time, from prompt.toml
options="$(python3 -I -c 'import json, sys, tomllib
for o in tomllib.load(open(sys.argv[1], "rb"))["prompt_options"]:
	for c in o["choices"]:
		print(o["key"], c)' "$data")"
[ -n "$options" ] || fail "prompt.toml lists options"
while read -r key choice; do
	render "$key-$choice" "prompt_$key=$choice"
	loads "$key-$choice"
done <<<"$options"
# ...and the rainbow block ends and the bar's ends with each, on one and two lines
for sep in round angled slanted flat; do
	for lines in one two; do
		render "rb-$sep-$lines" prompt_style=rainbow "prompt_separator=$sep" "prompt_lines=$lines"
		loads "rb-$sep-$lines"
		for t in 24h off; do
			render "bar-$sep-$lines-$t" prompt_style=bar "prompt_separator=$sep" "prompt_lines=$lines" "prompt_time=$t"
			loads "bar-$sep-$lines-$t"
		done
	done
done

# the choices change what they say
render one-split prompt_lines=one
assert_eq '"$hostname$directory$git_branch$git_status$jobs$nodejs$python$rust$golang$docker_context$kubernetes$character"' \
	"$(get "$scratch/one-split.toml" format)" "one line: left only, then the symbol"
assert_eq '"$cmd_duration$time"' "$(get "$scratch/one-split.toml" right_format)" "one line split: duration and time on the right"
assert_eq '"[$time]($style)"' "$(get "$scratch/one-split.toml" time.format)" "split: the clock ends the line"
render one-left prompt_lines=one prompt_layout=left
assert_eq null "$(get "$scratch/one-left.toml" right_format)" "one line left: no right prompt"
assert_contains "$(get "$scratch/one-left.toml" format)" '$cmd_duration$time$character' "one line left: duration and time before the symbol"
assert_eq '"[$time]($style) "' "$(get "$scratch/one-left.toml" time.format)" "left: a space after the clock"
assert_not_contains "$(get "$scratch/frame-off.toml" format)" "╭─" "frame off: no rail"
assert_not_contains "$(get "$scratch/layout-left.toml" format)" '$fill' "two lines left: no fill"
render dots prompt_fill=dots
assert_eq '"·"' "$(get "$scratch/dots.toml" fill.symbol)" "fill dots"
assert_contains "$(get "$scratch/dots.toml" format)" '$fill $cmd_duration' "fill dots: a space before the right side"
assert_eq '"rail"' "$(get "$scratch/dots.toml" fill.style)" "fill takes the frame colour"
render dots-left prompt_fill=dots prompt_layout=left
assert_eq '" "' "$(get "$scratch/dots-left.toml" fill.symbol)" "fill only in split"
render dots-one prompt_fill=dots prompt_lines=one
assert_eq '" "' "$(get "$scratch/dots-one.toml" fill.symbol)" "fill only on two lines"
assert_contains "$(get "$scratch/rb-angled-two.toml" directory.format)" $'[](fg:accent2)[ ' "rainbow: angled block start"
assert_contains "$(get "$scratch/rb-angled-two.toml" directory.format)" $'[](fg:accent2)' "rainbow: angled block end"
assert_eq '"bold fg:bg bg:accent2"' "$(get "$scratch/rb-angled-two.toml" directory.style)" "rainbow: text on the colour"
# bar: one strip, capped once at each end, thin dividers inside
bar_fmt="$(get "$scratch/bar-round-two-24h.toml" format)"
assert_contains "$bar_fmt" '[](fg:surface)$hostname$directory' "bar: one cap before the left side"
assert_contains "$bar_fmt" '$kubernetes[](fg:surface) $fill' "bar: one cap after it"
assert_contains "$bar_fmt" '[](fg:surface)$cmd_duration$time[](fg:surface)' "bar: the right side is a bar too"
assert_eq '"bold fg:accent2 bg:surface"' "$(get "$scratch/bar-round-two-24h.toml" directory.style)" "bar: segment colour on the bar"
assert_eq '"[](fg:muted bg:surface)[ $symbol$branch ]($style)"' \
	"$(get "$scratch/bar-round-two-24h.toml" git_branch.format)" "bar: a thin divider before the branch"
assert_contains "$(get "$scratch/bar-round-two-off.toml" cmd_duration.format)" '[](fg:surface)[ ' "bar, no clock: the duration caps itself"
assert_contains "$(get "$scratch/bar-round-two-off.toml" format)" ' $fill$cmd_duration$time' "bar, no clock: no empty right bar"
render bar-blue prompt_style=bar prompt_bar_color=blue
assert_eq '"bold fg:bg bg:blue"' "$(get "$scratch/bar-blue.toml" directory.style)" "bright bar: dark text"
assert_eq false "$(get "$scratch/spacing-compact.toml" add_newline)" "compact: no blank line"
assert_eq true "$(get "$scratch/time-off.toml" time.disabled)" "clock off"
assert_eq '"%I:%M %p"' "$(get "$scratch/time-12h.toml" time.time_format)" "clock 12h"
assert_eq '"[λ](bold accent)"' "$(get "$scratch/char-lambda.toml" character.success_symbol)" "lambda symbol"
assert_eq '"[λ](bold err)"' "$(get "$scratch/char-lambda.toml" character.error_symbol)" "error keeps the symbol, in red"
assert_eq '"bold magenta"' "$(get "$scratch/dir_color-magenta.toml" directory.style)" "directory colour"
assert_eq '"magenta"' "$(get "$scratch/git_color-magenta.toml" git_branch.style)" "branch colour"
assert_eq '"[❯](bold green)"' "$(get "$scratch/char_color-green.toml" character.success_symbol)" "symbol colour"
assert_contains "$(get "$scratch/frame_color-blue.toml" format)" "[╭─](blue)" "frame colour"
assert_not_contains "$(get "$scratch/langs-off.toml" format)" '$python' "languages off"
# plain icons: no private-use (Nerd Font) characters anywhere
pua="$(python3 -I -c 'import sys
t = open(sys.argv[1], encoding="utf-8").read()
print(sum(1 for ch in t if 0xE000 <= ord(ch) <= 0xF8FF or ord(ch) >= 0xF0000))' "$scratch/icons-plain.toml")"
assert_eq 0 "$pua" "plain icons: no Nerd Font glyphs"
assert_eq '"took $duration"' "$(get "$scratch/icons-plain.toml" cmd_duration.format | jq -r . | sed 's/^\[\(.*\)\](.*/"\1"/')" "plain icons: duration label"

# unknown values fall back to the defaults
render bogus prompt_lines=three prompt_style=neon
cmp -s "$scratch/default.toml" "$scratch/bogus.toml" || fail "unknown values render the defaults"

# ghostty: the cursor lines only when picked; any choice but its own
# blinking bar turns off shell integration's cursor (it would draw that bar)
gh_lines() { render_tmpl "$ghostty_tmpl" "$@" | grep -E '^(cursor-style|shell-integration-features)' | paste -sd'|' -; }
assert_eq "" "$(gh_lines)" "ghostty default: no cursor lines"
assert_eq "cursor-style = block|cursor-style-blink = true|shell-integration-features = no-cursor" \
	"$(gh_lines prompt_cursor=block)" "ghostty block cursor"
assert_eq "cursor-style = bar|cursor-style-blink = false|shell-integration-features = no-cursor" \
	"$(gh_lines prompt_blink=off)" "ghostty: blink off alone also takes the cursor from the integration"

# the cursor code 70-prompt.zsh draws (none: Ghostty's own)
cursor_tmpl="$TESTS_REPO/home/dot_config/zsh/cursor.tmpl"
assert_eq "" "$(render_tmpl "$cursor_tmpl")" "cursor default: no file"
assert_eq "1" "$(render_tmpl "$cursor_tmpl" prompt_cursor=block)" "cursor: blinking block"
assert_eq "4" "$(render_tmpl "$cursor_tmpl" prompt_cursor=underline prompt_blink=off)" "cursor: steady underline"
assert_eq "6" "$(render_tmpl "$cursor_tmpl" prompt_blink=off)" "cursor: steady bar"

# 70-prompt.zsh's hooks (starship absent: its init is skipped)
draw() { # draw CODE|- KEYMAP: what _cursor_draw prints, as visible text
	if [ "$1" = - ]; then rm -f "$HOME/.config/zsh/cursor"; else
		mkdir -p "$HOME/.config/zsh" && printf '%s\n' "$1" >"$HOME/.config/zsh/cursor"
	fi
	PATH=/usr/bin:/bin zsh -fc 'source "$1"; KEYMAP=$2; _cursor_draw; _cursor_reset' _ \
		"$TESTS_REPO/home/dot_config/zsh/conf.d/70-prompt.zsh" "$2" 2>&1 | cat -v
}
assert_eq "^[[2 q^[[0 q" "$(draw 2 main)" "hook: draws the code, resets for commands"
assert_eq "^[[1 q^[[0 q" "$(draw 3 vicmd)" "hook: vi command mode is a block, blinking like the choice"
assert_eq "^[[2 q^[[0 q" "$(draw 6 vicmd)" "hook: a steady choice gives a steady block"
assert_eq "" "$(draw - main)" "hook: no file, nothing drawn (Ghostty's integration does it)"
assert_eq "" "$(draw 9 main | sed 's/\^\[\[0 q//')" "hook: an unknown code draws nothing"
