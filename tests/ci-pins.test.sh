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

# workflows_in DIR: every *.yml and *.yaml workflow directly under DIR.
workflows_in() {
	local d="$1" f
	for f in "$d"/*.yml "$d"/*.yaml; do
		[ -e "$f" ] && printf '%s\n' "$f"
	done
}

# missing_permissions DIR: workflows under DIR with no top-level permissions:.
missing_permissions() {
	local f
	while IFS= read -r f; do
		grep -qE '^permissions:' "$f" || printf '%s\n' "$f"
	done < <(workflows_in "$1")
}

# every_workflow_has_top_level_permissions (.yml and .yaml)
assert_eq "" "$(missing_permissions .github/workflows)" "every workflow declares top-level permissions:"

# the check also catches a .yaml workflow lacking permissions: (fixture dir)
fx="$(mktemp -d)"
_tests_tmpdirs+=("$fx")
printf 'name: x\non: push\njobs: {}\n' >"$fx/nope.yaml"
printf 'name: y\non: push\npermissions:\n  contents: read\njobs: {}\n' >"$fx/ok.yaml"
assert_eq "$fx/nope.yaml" "$(missing_permissions "$fx")" "a .yaml workflow without permissions: is caught"

# setup_lint_cache_keyed_on_mise_lock_and_mise_version: the cache also holds
# the mise binary, so the key must change when the pinned mise version does.
key="$(grep -E '^[[:space:]]*key:' .github/actions/setup-lint/action.yml)"
assert_contains "$key" "hashFiles('mise.lock'" "setup-lint cache key mentions mise.lock"
assert_contains "$key" ".github/actions/setup-lint/action.yml" "setup-lint cache key covers the pinned mise version"

# scheduled_and_dispatchable: weekly refresh catches upstream drift
for w in lint provision bootstrap; do
	wf="$(cat ".github/workflows/$w.yml")"
	assert_contains "$wf" '- cron: "17 5 * * 1"' "$w.yml has the weekly schedule"
	assert_contains "$wf" "workflow_dispatch:" "$w.yml has workflow_dispatch"
done

# dependabot_groups_actions
dep="$(cat .github/dependabot.yml 2>/dev/null || true)"
assert_contains "$dep" "package-ecosystem: github-actions" "dependabot covers github-actions"
assert_contains "$dep" "interval: weekly" "dependabot runs weekly"
assert_contains "$dep" "day: monday" "dependabot runs on Monday"
assert_contains "$dep" "actions:" "dependabot has the actions group"
assert_contains "$dep" 'patterns: ["*"]' "dependabot actions group matches everything"
assert_contains "$dep" "prefix: ci" "dependabot commit prefix is ci"

# no_latest: comments excepted (runner labels and container tags included)
latest="$(grep -nE '\blatest\b' "${gh_files[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | sed -E 's/[[:space:]]+#.*$//' | grep -E '\blatest\b' || true)"
assert_eq "" "$latest" "no 'latest' under .github/ outside comments"
