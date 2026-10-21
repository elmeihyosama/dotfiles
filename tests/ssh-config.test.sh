#!/usr/bin/env bash
# private_dot_ssh/config.tmpl: Colima's Include (which Colima adds itself) is
# rendered only when Colima is set up, first, so the file doesn't drift.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmpl="$TESTS_REPO/home/private_dot_ssh/config.tmpl"
mk_home
out="$(render_tmpl "$tmpl")" || fail "renders without Colima"
assert_not_contains "$out" "colima" "no Colima: no Include for it"
assert_eq "# Generic client defaults only; private hosts go in ~/.ssh/config.local. The" "$(head -1 <<<"$out")" \
	"no Colima: starts with the header"

mkdir -p "$HOME/.config/colima"
: >"$HOME/.config/colima/ssh_config"
out="$(render_tmpl "$tmpl")" || fail "renders with Colima"
assert_eq "Include $HOME/.config/colima/ssh_config" "$(head -1 <<<"$out")" "Colima: its Include comes first, as Colima writes it"
assert_eq "" "$(sed -n 2p <<<"$out")" "Colima: then a blank line"
assert_contains "$out" "Include config.local" "the local Include stays"
