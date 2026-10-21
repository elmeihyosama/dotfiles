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

# choose_tools: scripted answers (ask/say stubbed); the lines it would write
# shellcheck disable=SC2016  # the inner sh expands these
choose() { # choose ANSWER...: run choose_tools with these answers, in order
	printf '%s\n' "$@" >"$HOME/answers"
	(cd "$TESTS_REPO" && env -i HOME="$HOME" PATH="/usr/bin:/bin" sh -c '
		. /dev/stdin <<SRC
$(sed -n "/^catalog_groups()/,/^}/p;/^catalog_tools()/,/^}/p;/^choose_tools() {/,/^}/p" install.sh)
SRC
		say() { :; }
		ask() { _a="$(head -1 "$HOME/answers")"; sed -i.bak 1d "$HOME/answers"; printf "%s" "${_a:-$2}"; }
		choose_tools' 2>&1)
}
assert_eq "" "$(choose a)" "choose_tools all: no keys (every group)"
assert_eq "" "$(choose "")" "choose_tools default (enter): every group"
assert_eq "tool_groups: []" "$(choose c)" "choose_tools core only: an empty group list"
# pick: git and dev yes, the rest no, no per-tool tweaks
assert_eq "tool_groups: [git, dev]" "$(choose p yes no no no no yes no)" "choose_tools pick groups"
# pick git only, then toggle tool 1 (git-delta, off) and the first files tool (on)
out="$(choose p yes no no no no no yes "1 7" "")"
assert_contains "$out" "tool_groups: [git]" "choose_tools tweak: groups"
assert_contains "$out" "tools_add: [yazi]" "choose_tools tweak: a tool from an unpicked group"
assert_contains "$out" "tools_remove: [git-delta]" "choose_tools tweak: a tool from a picked group"
assert_not_contains "$(choose p yes yes yes yes yes yes yes "1" "")" "age-keygen" "choose_tools: bundled tools are not offered"
