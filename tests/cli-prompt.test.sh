#!/usr/bin/env bash
# `dotfiles prompt`: --json and --preview against real chezmoi, this repo's
# data and the CI fixture config; setting options through the repo's zsh
# prompt_set against a stub chezmoi and a temp config.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for t in chezmoi jq starship zsh; do
	command -v "$t" >/dev/null 2>&1 || {
		[ -z "${CI:-}" ] || fail "no $t on PATH (CI must not skip)"
		echo "SKIP: no $t on PATH" >&2
		exit 0
	}
done
script="$TESTS_REPO/scripts/dotfiles.sh"
real_chezmoi="$(command -v chezmoi)"
mk_home
mkdir -p "$XDG_CONFIG_HOME/chezmoi" "$HOME/bin"
# the fixture plus two prompt choices, one of them not a choice
awk '{ print } /^\[data\][ \t]*$/ { print "    prompt_lines = \"one\""; print "    prompt_style = \"neon\"" }' \
	"$TESTS_FIXTURE" >"$XDG_CONFIG_HOME/chezmoi/chezmoi.toml"
n_options="$(grep -c '^\[\[prompt_options\]\]' "$TESTS_REPO/home/.chezmoidata/prompt.toml")"

run() { # run ARGS...: sets out, rc
	out="$(sh "$script" "$@" 2>&1 </dev/null)"
	rc=$?
}

# json: the contract the TUI parses
run prompt --json
assert_eq 0 "$rc" "json: exit 0 ($out)"
assert_eq '["options","palette","values"]' "$(jq -c keys <<<"$out")" "json: keys"
assert_eq "$n_options" "$(jq '.options | length' <<<"$out")" "json: every option, in prompt.toml order"
assert_eq "style" "$(jq -r '.options[0].key' <<<"$out")" "json: style first"
assert_eq '["about","choices","default","key","label"]' "$(jq -c '.options[0] | keys' <<<"$out")" "json: option fields"
assert_eq "one" "$(jq -r .values.lines <<<"$out")" "json: the machine's choice"
assert_eq "lean" "$(jq -r .values.style <<<"$out")" "json: an unknown value reads as the default"
assert_eq "chevron" "$(jq -r .values.char <<<"$out")" "json: unset reads as the default"
assert_eq "$n_options" "$(jq '.values | length' <<<"$out")" "json: a value per option"
want="$("$real_chezmoi" data --source "$TESTS_REPO" --format json | jq -r '.themes[.theme][.design.accent]')"
assert_eq "$want" "$(jq -r .palette.accent <<<"$out")" "json: palette resolves design roles in the active theme"
assert_eq "" "$(jq -r '[.options[] | .choices[]] as $c | .options[] | select(.key | endswith("_color")) | .choices[] | select(. as $x | ($c | index($x)) == null)' <<<"$out")" "json: colour choices exist"
assert_eq "" "$(jq -r '.palette as $p | .options[] | select(.key | endswith("_color")) | .choices[] | select($p[.] == null)' <<<"$out")" "json: every colour choice has a swatch"

# preview: real starship output for the options asked for
run prompt --preview --width 70 lines=two layout=split
assert_eq 0 "$rc" "preview: exit 0 ($out)"
assert_eq '{"err":["left","right"],"ok":["left","right"]}' "$(jq -cS 'map_values(keys)' <<<"$out")" "preview: ok and err, left and right"
assert_contains "$(jq -r .ok.left <<<"$out")" "╭─" "preview: two lines, framed"
assert_contains "$(jq -r .ok.left <<<"$out")" $'\e[' "preview: coloured"
assert_eq "" "$(jq -r .ok.right <<<"$out")" "preview: two lines has no right prompt"
assert_contains "$(jq -r .err.left <<<"$out")" "3s" "preview: the slow command's duration"
run prompt --preview --width 70
assert_not_contains "$(jq -r .ok.left <<<"$out")" "╭─" "preview: the machine's own choices (one line)"
assert_contains "$(jq -r .err.right <<<"$out")" "3s" "preview: one line split puts the duration on the right"
NO_COLOR=1 run prompt --preview lines=two
assert_contains "$(jq -r .ok.left <<<"$out")" $'\e[' "preview: coloured even under NO_COLOR (the TUI sets it)"
run prompt --preview oops
assert_eq 2 "$rc" "preview: a bare word is a usage error"
run prompt --preview --width wide
assert_eq 2 "$rc" "preview: --width needs a number"
run prompt
assert_eq 2 "$rc" "prompt: needs arguments"

# set: the repo's prompt_set in zsh -f, a stub chezmoi, a temp config
export STUB_LOG="$HOME/stub.log" REAL_CHEZMOI="$real_chezmoi" STUB_SRC="$TESTS_REPO" STUB_CFG="$TESTS_FIXTURE"
cat >"$HOME/bin/chezmoi" <<'STUB'
#!/bin/sh
case "$1" in
data) exec "$REAL_CHEZMOI" data --source "$STUB_SRC" --config "$STUB_CFG" --format json ;;
source-path) echo "$STUB_SRC/home" ;;
status) ;;
managed) for f in $(find "$STUB_SRC/home" -name '*.tmpl'); do f="${f#"$STUB_SRC/home/"}"; echo "$HOME/t/${f%.tmpl}"; done ;;
target-path) shift; for f in "$@"; do f="${f#"$STUB_SRC/home/"}"; echo "$HOME/t/${f%.tmpl}"; done ;;
apply) shift; echo "apply $*" >>"$STUB_LOG" ;;
esac
STUB
chmod +x "$HOME/bin/chezmoi"
cfg="$HOME/chezmoi.toml"
printf '[data]\n    theme = "nord"\n' >"$cfg"
set_run() { # set_run ARGS...: `dotfiles prompt ARGS` with the stub; sets out, rc
	rm -f "$STUB_LOG"
	out="$(PATH="$HOME/bin:$PATH" CHEZMOI_CONFIG="$cfg" sh "$script" prompt "$@" 2>&1 </dev/null)"
	rc=$?
}

set_run lines=one fill=dots
assert_eq 0 "$rc" "set: exit 0 ($out)"
assert_contains "$(cat "$cfg")" 'prompt_lines = "one"' "set: writes prompt_lines"
assert_contains "$(cat "$cfg")" 'prompt_fill = "dots"' "set: writes prompt_fill"
assert_contains "$(cat "$cfg")" 'theme = "nord"' "set: keeps the other data"
assert_contains "$out" "prompt → lines=one, fill=dots" "set: says what it set"
assert_contains "$(cat "$STUB_LOG" 2>/dev/null)" "$HOME/t/dot_config/starship.toml" "set: applies the starship config"
assert_contains "$(cat "$STUB_LOG" 2>/dev/null)" "$HOME/t/dot_config/ghostty/config" "set: applies ghostty (the cursor)"
assert_not_contains "$(cat "$STUB_LOG" 2>/dev/null)" "$HOME/t/dot_config/git/config" "set: never unrelated templates"

before="$(cat "$cfg")"
set_run lines=one fill=stars
assert_eq 2 "$rc" "set: a bad choice exits 2"
assert_contains "$out" "fill must be space|dots|line|dashed" "set: names the choices"
assert_eq "$before" "$(cat "$cfg")" "set: a bad pair writes nothing, not even the good one"
set_run colour=red
assert_eq 2 "$rc" "set: an unknown option exits 2"
assert_contains "$out" "unknown option 'colour'" "set: says which"
set_run lines
assert_eq 2 "$rc" "set: KEY without =VALUE exits 2"

set_run lines=two
assert_eq 0 "$rc" "set default: exit 0 ($out)"
assert_not_contains "$(cat "$cfg")" "prompt_lines" "set default: the key goes (a later default change reaches this machine)"
assert_contains "$(cat "$cfg")" 'prompt_fill = "dots"' "set default: other keys stay"
set_run ""
assert_eq 2 "$rc" "set: an empty argument exits 2"
set_run reset
assert_eq 0 "$rc" "reset: exit 0 ($out)"
assert_eq 0 "$(grep -c 'prompt_' "$cfg")" "reset: no prompt keys left"
assert_contains "$(cat "$cfg")" 'theme = "nord"' "reset: keeps the other data"

# from a checkout chezmoi doesn't apply from: refused, nothing written
# shellcheck disable=SC2016 # matches the stub's own text
sed -i.bak 's|^source-path) echo "$STUB_SRC/home" ;;|source-path) echo "/elsewhere/home" ;;|' "$HOME/bin/chezmoi"
set_run lines=one
assert_eq 1 "$rc" "other checkout: refused"
assert_contains "$out" "chezmoi applies from /elsewhere" "other checkout: says where to run it"
assert_eq 0 "$(grep -c 'prompt_' "$cfg")" "other checkout: nothing written"
mv "$HOME/bin/chezmoi.bak" "$HOME/bin/chezmoi"

# a starship failure fails the preview (the TUI shows why)
printf '#!/bin/sh\nexit 3\n' >"$HOME/bin/starship"
chmod +x "$HOME/bin/starship"
out="$(PATH="$HOME/bin:$PATH" sh "$script" prompt --preview 2>&1 </dev/null)"
assert_eq 1 "$?" "preview: starship failing exits 1"
assert_contains "$out" "starship failed" "preview: says so"
