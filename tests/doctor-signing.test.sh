#!/usr/bin/env bash
# scripts/doctor.sh signing section, with stubbed chezmoi and gh.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

doctor="$TESTS_REPO/scripts/doctor.sh"
mk_home
mkdir -p "$HOME/tbin" "$HOME/sysbin" "$HOME/.ssh"
# Hermetic PATH: every system tool except gh (CI runners ship a real one).
for f in /usr/bin/* /bin/*; do
	b="${f##*/}"
	[ "$b" = gh ] || ln -s "$f" "$HOME/sysbin/$b" 2>/dev/null
done
body="AAAAC3NzaC1lZDI1NTE5AAAAITESTBODY"
pub="$HOME/.ssh/id_test.pub"

# chezmoi stub: execute-template prints $HOME/signing_key; anything else is empty.
cat >"$HOME/tbin/chezmoi" <<'STUB'
#!/bin/sh
[ "$1" = execute-template ] && cat "$HOME/signing_key"
exit 0
STUB
# gh stub: GH_AUTH is the `auth` exit code. `api` prints GH_KEYS, fails with
# GH_API_ERR on stderr if set, or hangs if GH_HANG.
cat >"$HOME/tbin/gh" <<'STUB'
#!/bin/sh
case "$1" in
auth) exit "${GH_AUTH:-0}" ;;
api)
	[ -z "${GH_HANG:-}" ] || exec sleep 30
	[ -z "${GH_API_ERR:-}" ] || { echo "$GH_API_ERR" >&2; exit 1; }
	printf '%s\n' "${GH_KEYS:-}" ;;
*) exit 9 ;;
esac
STUB
chmod +x "$HOME/tbin/chezmoi" "$HOME/tbin/gh"

run() { # run [ENV=VAL ...]
	out="$(cd "$HOME" && env -i HOME="$HOME" DOCTOR_GH_TIMEOUT=1 "$@" PATH="$HOME/tbin:$HOME/sysbin" \
		sh "$doctor" --local /nonexistent 2>&1)"
}
set_key() { printf '%s' "$1" >"$HOME/signing_key"; }

# unset: no signing section at all
set_key ""
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

# empty_pub_fails / malformed_pub_fails: never a false OK
: >"$pub"
set_key "$pub"
run GH_KEYS=""
assert_contains "$out" "FAIL  signing key $pub is not a valid public key" "empty_pub_fails"
assert_not_contains "$out" "registered on GitHub" "empty_pub_fails: no false OK"
printf 'ssh-ed25519\n' >"$pub"
run GH_KEYS="x"
assert_contains "$out" "FAIL  signing key $pub is not a valid public key" "malformed_pub_fails"

printf 'ssh-ed25519 %s comment\n' "$body" >"$pub"

# tilde_expands: install.sh's default value is ~/.ssh/id_ed25519.pub
# shellcheck disable=SC2088  # literal ~, as install.sh writes it
set_key "~/.ssh/id_test.pub"
run GH_KEYS="ssh-ed25519 $body"
assert_contains "$out" "OK    signing key $pub present" "tilde_expands"
set_key "$pub"

# registered_ok
run GH_KEYS="ssh-ed25519 $body"
assert_contains "$out" "OK    signing key $pub present" "registered_ok: present"
assert_contains "$out" "OK    signing key registered on GitHub" "registered_ok: registered"

# crlf_pub_ok: a CRLF .pub still matches
printf 'ssh-ed25519 %s\r\n' "$body" >"$pub"
run GH_KEYS="ssh-ed25519 $body"
assert_contains "$out" "OK    signing key registered on GitHub" "crlf_pub_ok"
printf 'ssh-ed25519 %s comment\n' "$body" >"$pub"

# unregistered_warns
run GH_KEYS="ssh-ed25519 AAAAOTHER"
assert_contains "$out" "WARN  signing key not registered on GitHub; run: gh ssh-key add $pub --type signing" "unregistered_warns"
assert_not_contains "$out" "FAIL  signing" "unregistered_warns: not a FAIL"

# scope_missing_warns: the 404 that names the scope is not "offline"
run GH_API_ERR='gh: This API operation needs the "admin:ssh_signing_key" scope. (HTTP 404)'
assert_contains "$out" "WARN  signing key registration not checked (token lacks a scope; run: gh auth refresh -h github.com -s admin:ssh_signing_key)" "scope_missing_warns"

# offline_warns
run GH_API_ERR='error connecting to api.github.com'
assert_contains "$out" "WARN  signing key registration not checked (offline)" "offline_warns"

# hang_is_bounded: a gh that never answers is cut off at DOCTOR_GH_TIMEOUT
SECONDS=0
run GH_HANG=1
assert_contains "$out" "WARN  signing key registration not checked (offline)" "hang_is_bounded"
[ "$SECONDS" -lt 15 ] || fail "hang_is_bounded: took ${SECONDS}s"

# unauthenticated_warns: checked locally, no API call
run GH_AUTH=1 GH_HANG=1
assert_contains "$out" "WARN  signing key registration not checked (gh not authenticated)" "unauthenticated_warns"

# no_gh_warns: sysbin has no gh, tbin loses its stub
rm "$HOME/tbin/gh"
run
assert_contains "$out" "WARN  signing key registration not checked (gh not installed)" "no_gh_warns"
