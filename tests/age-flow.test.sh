#!/usr/bin/env bash
# age encryption end to end in a temp HOME: the chezmoi.toml block the
# playbook writes, chezmoi add --encrypt, chezmoi cat. Every chezmoi call
# uses temp --source/--config/--destination.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# CI's lint toolchain has no age, so this SKIPs there; local runs exercise it.
for t in age age-keygen chezmoi; do
	command -v "$t" >/dev/null 2>&1 || {
		echo "SKIP: no $t on PATH" >&2
		exit 0
	}
done

mk_home
key="$HOME/key.txt"
age-keygen -o "$key" 2>/dev/null
recipient="$(age-keygen -y "$key")"
src="$HOME/src" cfg="$HOME/cfg/cz.toml" dst="$HOME/dst"
mkdir -p "$src" "$dst" "$HOME/cfg"

# The block ansible/tasks/chezmoi.yml writes, with the temp identity.
tmpl="$TESTS_REPO/ansible/tasks/chezmoi.yml"
grep -q 'encryption = "age"' "$tmpl" || fail "chezmoi.yml writes encryption = \"age\""
grep -q 'recipient = "{{ age_recipient }}"' "$tmpl" || fail "chezmoi.yml writes the age recipient"
printf 'encryption = "age"\n[age]\nidentity = "%s"\nrecipient = "%s"\n' "$key" "$recipient" >"$cfg"

cz() { chezmoi --source "$src" --config "$cfg" --destination "$dst" "$@"; }

printf 'hunter2\n' >"$dst/secret.txt"
cz add --encrypt "$dst/secret.txt" 2>&1 || fail "chezmoi add --encrypt"
enc="$(find "$src" -name 'encrypted_*' | head -n1)"
[ -n "$enc" ] || fail "an encrypted_ source file exists"
if [ -n "$enc" ]; then
	assert_not_contains "$(cat "$enc")" "hunter2" "source file is ciphertext"
fi
assert_eq "hunter2" "$(cz cat "$dst/secret.txt")" "chezmoi cat decrypts"
