#!/usr/bin/env bash
# The Pages site (site/index.html) is hand-written; this keeps it in step with
# the repo: every installable tool in tools.yaml has a chip under its group,
# and the tool and theme counts match.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v yq >/dev/null 2>&1 || {
	[ -z "${CI:-}" ] || fail "no yq on PATH (CI must not skip)"
	echo "SKIP: no yq on PATH" >&2
	exit 0
}

page="$TESTS_REPO/site/index.html"
tools_yaml="$TESTS_REPO/home/.chezmoidata/tools.yaml"
html="$(cat "$page")"

# provided_by tools (age-keygen) ship inside another tool and get no chip.
installable="$(yq '.tools | to_entries[] | select(.value.provided_by == null) | .key' "$tools_yaml")"
n_tools="$(printf '%s\n' "$installable" | grep -c .)"
n_themes="$(find "$TESTS_REPO/home/.chezmoidata/themes" -name '*.toml' | wc -l | tr -d ' ')"

while IFS= read -r t; do
	g="$(yq ".tools.\"$t\".group" "$tools_yaml")"
	row="$(printf '%s\n' "$html" | grep "<div class=\"gname\">$g</div>")"
	assert_contains "$row" ">$t</span>" "chip for $t in the $g row"
done <<<"$installable"

chips="$(printf '%s\n' "$html" | grep -o 'class="chip"' | grep -c .)"
assert_eq "$n_tools" "$chips" "one chip per installable tool"

while IFS= read -r v; do
	assert_eq "$n_tools" "$v" "data-count=tools"
done < <(printf '%s\n' "$html" | sed -n 's/.*data-count="tools">\([0-9]*\)<.*/\1/p')
while IFS= read -r v; do
	assert_eq "$n_themes" "$v" "data-count=themes"
done < <(printf '%s\n' "$html" | grep -o 'data-count="themes">[0-9]*<' | grep -o '[0-9]*')

# The picker's themes must exist in the repo.
for th in $(printf '%s\n' "$html" | grep -o '<button class="opt[^"]*" data-theme="[^"]*"' | cut -d'"' -f4); do
	[ -f "$TESTS_REPO/home/.chezmoidata/themes/$th.toml" ] || fail "picker theme $th exists"
done
