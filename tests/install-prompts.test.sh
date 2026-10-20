#!/usr/bin/env bash
# install.sh prompts: an existing local.yml is reused without --reconfigure.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mk_home
# Minimal checkout: install.sh, the version pins, stubbed ansible tools.
repo="$HOME/repo"
mkdir -p "$repo/ansible/group_vars" "$HOME/.local/bin"
cp "$TESTS_REPO/install.sh" "$repo/"
cp "$TESTS_REPO/ansible/group_vars/all.yml" "$repo/ansible/group_vars/"
: >"$repo/ansible/site.yml"
: >"$repo/ansible/requirements.yml"
core="$(sed -nE 's/^ansible_core_version:[[:space:]]*"([^"]*)".*/\1/p' "$repo/ansible/group_vars/all.yml")"
cat >"$HOME/.local/bin/ansible-playbook" <<STUB
#!/bin/sh
[ "\$1" = "--version" ] && echo "ansible-playbook [core $core]"
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/bin/ansible-galaxy"
chmod +x "$HOME/.local/bin/"*

# old_local_yml_no_prompt: no new prompt, local.yml untouched, signing off
old="---
git_name: 'Old'
git_email: 'old@example.com'
allow_sudo: false
shared_home: false"
printf '%s\n' "$old" >"$repo/ansible/local.yml"
out="$(cd / && env -i HOME="$HOME" PATH="$HOME/.local/bin:/usr/bin:/bin" sh "$repo/install.sh" 2>&1 </dev/null)"
assert_contains "$out" "Using existing ansible/local.yml" "old_local_yml_no_prompt: reused"
assert_not_contains "$out" "SSH public key" "old_local_yml_no_prompt: no signing prompt"
assert_eq "$old" "$(cat "$repo/ansible/local.yml")" "old_local_yml_no_prompt: file unchanged"
case "$(cat "$repo/ansible/local.yml")" in *signing_key*) fail "old_local_yml_no_prompt: signing_key appeared" ;; esac

# private_key_refused: with no tty a non-.pub answer is dropped, not written
# (ask falls back to its default, so drive ensure_local_vars directly)
rm "$repo/ansible/local.yml"
# shellcheck disable=SC2016  # the inner sh expands these
out="$(cd "$repo" && env -i HOME="$HOME" PATH="$HOME/.local/bin:/usr/bin:/bin" sh -c '
	. /dev/stdin <<SRC
$(sed -n "/^have() /p;/^have_tty()/p;/^ask() {/,/^}/p;/^yaml_quote()/p;/^ensure_local_vars() {/,/^}/p" install.sh)
SRC
	ask() { case "$1" in SSH*) printf "%s" "$HOME/.ssh/id_test" ;; *) printf x ;; esac; }
	reconfigure=0; SHARED_HOME=false
	ensure_local_vars' 2>&1 </dev/null)"
assert_contains "$out" "Not a .pub file" "private_key_refused: message"
case "$(cat "$repo/ansible/local.yml" 2>/dev/null)" in *signing_key*) fail "private_key_refused: key written" ;; esac
