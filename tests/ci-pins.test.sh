#!/usr/bin/env bash
# CI supply-chain pins: every action/runner is pinned, every workflow declares
# permissions, the lint tool cache is keyed on mise.lock, and nothing under
# .github/ floats on "latest".
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$TESTS_REPO" || exit 1
gh_files=()
while IFS= read -r f; do gh_files+=("$f"); done < <(find .github -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)

# every_uses_is_sha_pinned: remote `uses:` must be OWNER/REPO[/path]@<40 hex>
# followed by a "# vX.Y.Z" comment; local (./) actions are exempt.
bad="$(grep -nE '^[[:space:]]*-?[[:space:]]*uses:' "${gh_files[@]}" |
	grep -vE 'uses:[[:space:]]*(\./|\$/)' |
	grep -vE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]+\.[0-9]+\.[0-9]+' || true)"
assert_eq "" "$bad" "every uses: is pinned to a 40-hex SHA with a # vX.Y.Z comment"

# every_workflow_has_top_level_permissions
for f in .github/workflows/*.yml; do
	grep -qE '^permissions:' "$f" || fail "$f has no top-level permissions:"
done

# setup_lint_cache_keyed_on_mise_lock
assert_contains "$(cat .github/actions/setup-lint/action.yml)" "hashFiles('mise.lock')" \
	"setup-lint cache key mentions mise.lock"

# no_latest: comments excepted (runner labels and container tags included)
latest="$(grep -nE '\blatest\b' "${gh_files[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | sed -E 's/[[:space:]]+#.*$//' | grep -E '\blatest\b' || true)"
assert_eq "" "$latest" "no 'latest' under .github/ outside comments"
