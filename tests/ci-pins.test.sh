#!/usr/bin/env bash
# CI supply-chain pins: actions and images pinned, permissions declared, the
# lint cache keyed on mise.lock, nothing under .github/ on "latest".
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

# scheduled_and_dispatchable: ci.yml's weekly full run catches upstream
# drift; each called workflow stays dispatchable on its own.
assert_contains "$(cat .github/workflows/ci.yml)" '- cron: "17 5 * * 1"' "ci.yml has the weekly schedule"
for w in ci lint provision bootstrap; do
	assert_contains "$(cat ".github/workflows/$w.yml")" "workflow_dispatch:" "$w.yml has workflow_dispatch"
done

# dependabot_groups_actions
dep="$(cat .github/dependabot.yml 2>/dev/null || true)"
assert_contains "$dep" "package-ecosystem: github-actions" "dependabot covers github-actions"
assert_contains "$dep" "interval: weekly" "dependabot runs weekly"
assert_contains "$dep" "day: monday" "dependabot runs on Monday"
assert_contains "$dep" "actions:" "dependabot has the actions group"
assert_contains "$dep" 'patterns: ["*"]' "dependabot actions group matches everything"
assert_contains "$dep" "prefix: ci" "dependabot commit prefix is ci"
# The composite action (actions/cache, jdx/mise-action) lives outside
# /.github/workflows, so dependabot must be told to scan it.
assert_contains "$dep" 'directories: ["/", "/.github/actions/*"]' "dependabot scans / and the composite actions dir"
assert_not_contains "$dep" "directory: /" "dependabot uses directories:, not a single directory"

# no_latest: comments excepted (runner labels and container tags included)
latest="$(grep -nE '\blatest\b' "${gh_files[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | sed -E 's/[[:space:]]+#.*$//' | grep -E '\blatest\b' || true)"
assert_eq "" "$latest" "no 'latest' under .github/ outside comments"

# images_pinned_by_digest: every image a workflow pulls is name:tag@sha256:<64 hex>.
imgs="$(grep -hnE '(^[[:space:]]*-?[[:space:]]*image:|(mirror\.gcr\.io|quay\.io|docker\.io)/)' .github/workflows/*.yml)"
assert_contains "$imgs" "image:" "workflows declare container images"
unpinned="$(printf '%s\n' "$imgs" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE '[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}' || true)"
assert_eq "" "$unpinned" "every container image is pinned by tag@sha256 digest"

# image_pins_agree: bootstrap.yml's ubuntu/fedora images (tag@digest) are
# copies of provision.yml's; a one-sided bump must fail here.
img_of() { # FILE DISTRO -> the image: reference (no trailing comment)
	awk -v d="$2" '$0 ~ "distro: "d"$" {f=1; next} f && /image:/ {sub(/^[^:]*image:[ ]*/, ""); sub(/[ ]+#.*$/, ""); print; exit}' "$1"
}
for d in ubuntu fedora; do
	p_img="$(img_of .github/workflows/provision.yml "$d")"
	b_img="$(img_of .github/workflows/bootstrap.yml "$d")"
	assert_contains "$p_img" "@sha256:" "provision.yml has a pinned $d image"
	assert_eq "$p_img" "$b_img" "$d image is identical in provision.yml and bootstrap.yml"
done

# mise_versions_agree: the CI mise binary pin in setup-lint and the macOS job.
mise_ver() { grep -E '^[[:space:]]*version:[[:space:]]*[0-9]' "$1" | head -1 | sed -E 's/.*version:[[:space:]]*//'; }
sl_ver="$(mise_ver .github/actions/setup-lint/action.yml)"
mac_ver="$(mise_ver .github/workflows/provision.yml)"
assert_contains "$sl_ver" "20" "setup-lint pins a mise version"
assert_eq "$sl_ver" "$mac_ver" "setup-lint and the macOS job pin the same mise version"

# bootstrap_covers_fedora: the bootstrap matrix exercises install.sh's dnf path.
boot="$(cat .github/workflows/bootstrap.yml)"
# shellcheck disable=SC2016 # literal GitHub expression, not shell
assert_contains "$boot" 'name: bootstrap ${{ matrix.distro }} (${{ matrix.mode }})' "bootstrap job name is prefixed (no clash with provision checks)"
assert_contains "$boot" "distro: [ubuntu, fedora]" "bootstrap matrix covers ubuntu and fedora"

# macos_job: real playbook on a macOS runner, casks skipped, idempotence shared.
prov="$(cat .github/workflows/provision.yml)"
assert_contains "$prov" "runs-on: macos-26" "provision has a macOS job on a versioned runner"
assert_contains "$prov" "ansible-playbook site.yml --skip-tags casks" "macOS job skips casks"
assert_contains "$prov" "mise install --locked" "macOS job installs ansible from the locked repo toolchain"
assert_contains "$prov" ".github/scripts/assert-idempotent.sh" "macOS job checks second-run idempotence"
assert_contains "$prov" "scripts/doctor.sh" "macOS job runs the doctor health check"
assert_contains "$prov" "timeout-minutes: 30" "macOS job has a timeout"

# concurrency_cancels_superseded_runs: ci.yml only (a callee group would
# collide with its caller's, both being named after ci.yml).
assert_contains "$(cat .github/workflows/ci.yml)" "cancel-in-progress: true" "ci.yml cancels superseded runs"
for w in lint provision bootstrap; do
	assert_not_contains "$(cat ".github/workflows/$w.yml")" "concurrency:" "$w.yml leaves concurrency to ci.yml"
done

# pages_dispatchable, zizmor hook and online audits
assert_contains "$(cat .github/workflows/pages.yml)" "workflow_dispatch:" "pages.yml has workflow_dispatch"
assert_contains "$(grep -A6 'id: lint-zizmor' .pre-commit-config.yaml)" "files: '^\\.github/'" "zizmor hook covers all of .github/"
assert_contains "$(cat .github/workflows/lint.yml)" "ZIZMOR_ONLINE" "lint.yml runs zizmor online"
assert_contains "$(cat .github/scripts/bootstrap-smoke.sh)" "assert-idempotent.sh" "bootstrap-smoke uses the shared idempotence check"

# assert_idempotent_script: passes a converged recap, fails changes or no recap.
ai=.github/scripts/assert-idempotent.sh
log="$fx/run2.log"
printf 'PLAY RECAP ***\nlocalhost : ok=5 changed=0 unreachable=0 failed=0\n' >"$log"
sh "$ai" "$log" >/dev/null 2>&1
assert_eq "0" "$?" "assert-idempotent passes a changed=0 recap"
printf 'PLAY RECAP ***\nlocalhost : ok=5 changed=2 unreachable=0 failed=0\n' >"$log"
sh "$ai" "$log" >/dev/null 2>&1
assert_eq "1" "$?" "assert-idempotent fails a changed=2 recap"
printf 'no ansible here\n' >"$log"
sh "$ai" "$log" >/dev/null 2>&1
assert_eq "1" "$?" "assert-idempotent fails a log with no PLAY RECAP"
