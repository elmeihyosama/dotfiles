#!/usr/bin/env bash
# Self-test for the harness: if these fail, every other test is suspect.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_eq a a "assert_eq passes on equal values"
assert_contains "hello world" "lo wo" "assert_contains finds needle"
assert_not_contains "hello" "xyz" "assert_not_contains misses needle"

tmpl="$(mktemp)"
printf '%s' '{{ .git_email }}' >"$tmpl"
assert_eq "ci@example.com" "$(render_tmpl "$tmpl")" "render_tmpl uses fixture data"
assert_eq "x@y" "$(render_tmpl "$tmpl" git_email=x@y)" "render_tmpl overrides a string key"

printf '%s' '{{ if .flag }}on{{ else }}off{{ end }}' >"$tmpl"
assert_eq "on" "$(render_tmpl "$tmpl" flag=true)" "render_tmpl keeps true as a bool"
assert_eq "off" "$(render_tmpl "$tmpl" flag=false)" "render_tmpl keeps false as a bool"
rm -f "$tmpl"

mk_home
assert_contains "$XDG_CONFIG_HOME" "$HOME" "XDG_CONFIG_HOME is under the temp HOME"
assert_contains "$XDG_DATA_HOME" "$HOME" "XDG_DATA_HOME is under the temp HOME"

if command -v zsh >/dev/null 2>&1; then
	printf '%s' 'export HARNESS_PROBE={{ .git_name }}' >"$HOME/probe.zsh.tmpl"
	out="$(run_zsh_env "$HOME/probe.zsh.tmpl" FOO=bar)"
	assert_contains "$out" "HARNESS_PROBE=CI" "run_zsh_env sources the rendered script"
	assert_contains "$out" "FOO=bar" "run_zsh_env passes extra env"
fi

# run.sh selects by test NAME as an extended regex (fake dir: no recursion).
fake="$(mktemp -d)"
for n in alpha beta gamma; do
	printf '#!/usr/bin/env bash\necho ran-%s\n' "$n" >"$fake/$n.test.sh"
done
out="$(TESTS_DIR="$fake" bash "$TESTS_REPO/tests/run.sh" alpha 2>&1)"
assert_contains "$out" "PASS alpha.test.sh" "run.sh selects by name"
assert_not_contains "$out" "beta" "run.sh skips non-matching names"
out="$(TESTS_DIR="$fake" bash "$TESTS_REPO/tests/run.sh" 'alpha|gamma' 2>&1)"
assert_contains "$out" "PASS gamma.test.sh" "run.sh accepts alternation"
assert_not_contains "$out" "beta" "alternation skips others"
out="$(TESTS_DIR="$fake" bash "$TESTS_REPO/tests/run.sh" 2>&1)"
assert_contains "$out" "PASS beta.test.sh" "run.sh with no arg runs all"
TESTS_DIR="$fake" bash "$TESTS_REPO/tests/run.sh" nomatch >/dev/null 2>&1
assert_eq 1 "$?" "run.sh exits 1 when nothing matches"
rm -rf "$fake"
