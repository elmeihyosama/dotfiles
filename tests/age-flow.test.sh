#!/usr/bin/env bash
# age encryption end to end in a temp HOME: the chezmoi.toml block from
# ansible/tasks/chezmoi.yml, chezmoi add --encrypt, chezmoi cat. Every chezmoi
# call uses temp --source/--config/--destination.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for t in age age-keygen chezmoi; do
	command -v "$t" >/dev/null 2>&1 || {
		[ -z "${CI:-}" ] || fail "no $t on PATH (CI must not skip; age is pinned in mise.toml)"
		echo "SKIP: no $t on PATH" >&2
		exit 0
	}
done

mk_home
mkdir -p "$HOME/.config/chezmoi" "$HOME/src" "$HOME/dst" "$HOME/cfg"
key="$HOME/.config/chezmoi/key.txt"
age-keygen -o "$key" 2>/dev/null
recipient="$(age-keygen -y "$key")"
src="$HOME/src" cfg="$HOME/cfg/cz.toml" dst="$HOME/dst"

# The playbook's own age block (lines between the age_recipient if/endif), with
# the Jinja tags dropped and the recipient filled in. The ~ identity path
# resolves under the temp HOME. (Rendering the Jinja itself needs ansible.)
awk '/age_recipient is defined/ { on = 1; next } on && /{% endif %}/ { exit } on' \
	"$TESTS_REPO/ansible/tasks/chezmoi.yml" |
	sed -e 's/^ *//' -e "s/{{ age_recipient }}/$recipient/" >"$cfg"
assert_contains "$(cat "$cfg")" 'encryption = "age"' "block: encryption = age"
assert_contains "$(cat "$cfg")" "recipient = \"$recipient\"" "block: recipient"
assert_not_contains "$(cat "$cfg")" "{{" "block: no Jinja left"

cz() { chezmoi --source "$src" --config "$cfg" --destination "$dst" "$@"; }

printf 'hunter2\n' >"$dst/secret.txt"
cz add --encrypt "$dst/secret.txt" 2>&1 || fail "chezmoi add --encrypt"
enc="$(find "$src" -name 'encrypted_*' | head -n1)"
[ -n "$enc" ] || fail "an encrypted_ source file exists"
if [ -n "$enc" ]; then
	assert_not_contains "$(cat "$enc")" "hunter2" "source file is ciphertext"
fi
assert_eq "hunter2" "$(cz cat "$dst/secret.txt")" "chezmoi cat decrypts"
