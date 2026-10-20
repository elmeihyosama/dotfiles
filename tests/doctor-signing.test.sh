#!/usr/bin/env bash
# scripts/doctor.sh signing section, with stubbed chezmoi and gh.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

doctor="$TESTS_REPO/scripts/doctor.sh"
mk_home
mkdir -p "$HOME/tbin" "$HOME/.ssh"
# doctor runs with PATH=tbin:/usr/bin:/bin, so jq must be there (mise shims won't work).
if [ ! -x /usr/bin/jq ] && [ ! -x /bin/jq ]; then
	[ -z "${CI:-}" ] || fail "no jq in /usr/bin (CI must not skip)"
	echo "SKIP: no jq in /usr/bin" >&2
	exit 0
fi
body="AAAAC3NzaC1lZDI1NTE5AAAAITESTBODY"
pub="$HOME/.ssh/id_test.pub"

# chezmoi stub: `data` prints $HOME/data.json, anything else is empty.
cat >"$HOME/tbin/chezmoi" <<'STUB'
#!/bin/sh
[ "$1" = data ] && cat "$HOME/data.json"
exit 0
STUB
# gh stub: GH_AUTH is the `auth status` exit code; `api` prints GH_KEYS, or fails if GH_API_FAIL.
cat >"$HOME/tbin/gh" <<'STUB'
#!/bin/sh
case "$1" in
auth) exit "${GH_AUTH:-0}" ;;
api) [ -z "${GH_API_FAIL:-}" ] || exit 1; printf '%s\n' "${GH_KEYS:-}" ;;
*) exit 9 ;;
esac
STUB
chmod +x "$HOME/tbin/chezmoi" "$HOME/tbin/gh"

run() { # run [ENV=VAL ...]
	out="$(cd "$HOME" && env -i HOME="$HOME" "$@" PATH="$HOME/tbin:/usr/bin:/bin" \
		sh "$doctor" --local /nonexistent 2>&1)"
}
set_key() { printf '{"signing_key": "%s"}\n' "$1" >"$HOME/data.json"; }

# unset: no signing section at all
printf '{}\n' >"$HOME/data.json"
run
assert_not_contains "$out" "signing" "unset_skips_section"

# missing_key_fails
set_key "$pub"
run
assert_contains "$out" "FAIL  signing key $pub is missing" "missing_key_fails"

# non_pub_fails: a private key path is never read, and the message says why
set_key "$HOME/.ssh/id_ed25519"
run
assert_contains "$out" "FAIL  signing_key $HOME/.ssh/id_ed25519 must be the public key (a .pub file)" "non_pub_fails"

printf 'ssh-ed25519 %s comment\n' "$body" >"$pub"
set_key "$pub"

# registered_ok
run GH_KEYS="ssh-ed25519 $body"
assert_contains "$out" "OK    signing key $pub present" "registered_ok: present"
assert_contains "$out" "OK    signing key registered on GitHub" "registered_ok: registered"

# unregistered_warns
run GH_KEYS="ssh-ed25519 AAAAOTHER"
assert_contains "$out" "WARN  signing key not registered on GitHub; run: gh ssh-key add $pub --type signing" "unregistered_warns"
assert_not_contains "$out" "FAIL  signing" "unregistered_warns: not a FAIL"

# offline_warns: signed in but the API call fails
run GH_API_FAIL=1
assert_contains "$out" "WARN  signing key registration not checked (offline)" "offline_warns"

# unauthenticated_warns
run GH_AUTH=1
assert_contains "$out" "WARN  signing key registration not checked (gh not authenticated)" "unauthenticated_warns"

# no gh at all
rm "$HOME/tbin/gh"
run
assert_contains "$out" "WARN  signing key registration not checked (gh not installed)" "no_gh_warns"
