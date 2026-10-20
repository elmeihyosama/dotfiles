#!/usr/bin/env sh
# Assert a captured second ansible-playbook run changed nothing (idempotence).
# Usage: .github/scripts/assert-idempotent.sh LOGFILE
# `changed=N` appears only in the PLAY RECAP (tasks print `changed: [host]`).
set -eu

log="${1:?usage: assert-idempotent.sh LOGFILE}"

# A run that never reached ansible must not pass vacuously.
if ! grep -q '^PLAY RECAP' "$log"; then
	echo "IDEMPOTENCE FAIL: second run produced no ansible recap:"
	cat "$log"
	exit 1
fi
if grep -qE 'changed=[1-9]' "$log"; then
	echo "IDEMPOTENCE FAIL: second run reported changes:"
	grep -E 'PLAY RECAP|changed=' "$log"
	exit 1
fi
echo "IDEMPOTENT: second run reported changed=0"
