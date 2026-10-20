#!/usr/bin/env bash
# Git SSH signing templates: only GitHub-identity commits are signed.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

g="$TESTS_REPO/home/dot_config/git"
mk_home
pub="$HOME/.ssh/id_test.pub"
mkdir -p "$HOME/.ssh"
printf 'ssh-ed25519 AAAATESTKEY comment\n' >"$pub"

# render_nopersonal FILE: fixture minus personal_git_*, plus signing_key=$pub
render_nopersonal() {
	local d rc
	d="$(mktemp -d)"
	grep -v personal_git "$TESTS_FIXTURE" >"$d/f.toml"
	printf '    signing_key = "%s"\n' "$pub" >>"$d/f.toml"
	chezmoi execute-template --source "$TESTS_REPO" --config "$d/f.toml" <"$1"
	rc=$?
	rm -rf "$d"
	return "$rc"
}

personal="$(render_tmpl "$g/personal.tmpl" "signing_key=$pub")"
base="$(render_tmpl "$g/config.tmpl" "signing_key=$pub")"

# personal_gets_signing
for want in 'format = ssh' "signingkey = $pub" 'gpgsign = true' '[tag]'; do
	assert_contains "$personal" "$want" "personal_gets_signing: $want"
done
assert_contains "$base" "allowedSignersFile = ~/.config/git/allowed_signers" "personal_gets_signing: allowedSignersFile"

# default_identity_unsigned
assert_not_contains "$base" "gpgsign" "default_identity_unsigned: gpgsign"
assert_not_contains "$base" "signingkey" "default_identity_unsigned: signingkey"
assert_not_contains "$base" "format = ssh" "default_identity_unsigned: format"

# no_personal_global_signing
nop="$(render_nopersonal "$g/config.tmpl")"
assert_contains "$nop" "signingkey = $pub" "no_personal_global_signing: signingkey in config"
assert_contains "$nop" "gpgsign = true" "no_personal_global_signing: gpgsign in config"

# unset_renders_nothing (absent and empty)
for args in "" "signing_key="; do
	# shellcheck disable=SC2086
	a="$(render_tmpl "$g/config.tmpl" $args)"
	b="$(render_tmpl "$g/personal.tmpl" $args)"
	c="$(render_tmpl "$g/allowed_signers.tmpl" $args)"
	for out in "$a" "$b"; do
		assert_not_contains "$out" "gpgsign" "unset_renders_nothing($args): gpgsign"
		assert_not_contains "$out" "allowedSignersFile" "unset_renders_nothing($args): allowedSignersFile"
	done
	assert_eq "" "$c" "unset_renders_nothing($args): allowed_signers"
done

# tilde_expanded: git gets an absolute path
t="$(render_tmpl "$g/personal.tmpl" "signing_key=~/.ssh/id_test.pub")"
assert_contains "$t" "signingkey = $HOME/.ssh/id_test.pub" "tilde_expanded: absolute"
assert_not_contains "$t" "signingkey = ~" "tilde_expanded: no tilde"

# missing_pub_renders: no failure, empty file
if ! m="$(render_tmpl "$g/allowed_signers.tmpl" "signing_key=$HOME/.ssh/nope.pub")"; then
	fail "missing_pub_renders: render failed"
fi
assert_eq "" "$m" "missing_pub_renders: empty"

# allowed_signers_line: personal email wins over git_email
l="$(render_tmpl "$g/allowed_signers.tmpl" "signing_key=$pub")"
assert_eq "1+ci-personal@users.noreply.github.com ssh-ed25519 AAAATESTKEY comment" "$l" "allowed_signers_line: personal"
l="$(render_nopersonal "$g/allowed_signers.tmpl")"
assert_eq "ci@example.com ssh-ed25519 AAAATESTKEY comment" "$l" "allowed_signers_line: git_email fallback"
