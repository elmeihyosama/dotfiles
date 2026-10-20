#!/usr/bin/env bash
# ci.yml + .github/scripts/ci-changes.sh: one PR workflow gates the rest.
source "$(dirname "$0")/lib.sh"
cd "$TESTS_REPO" || exit 1

filter=.github/scripts/ci-changes.sh
wf=.github/workflows

# gate PATH... -> "provision=X bootstrap=Y" for that change set
gate() { printf '%s\n' "$@" | sh "$filter" | paste -sd' ' -; }

# path_cases
assert_eq "provision=false bootstrap=false" "$(gate README.md docs/mise.md site/index.html)" "docs only: nothing gated runs"
assert_eq "provision=false bootstrap=false" "$(gate tests/glass.test.sh .github/scripts/lint.sh)" "lint-only paths: nothing gated runs"
assert_eq "provision=true bootstrap=true" "$(gate home/dot_zshrc.tmpl)" "home/: both"
assert_eq "provision=true bootstrap=true" "$(gate ansible/site.yml)" "ansible/: both"
assert_eq "provision=true bootstrap=true" "$(gate scripts/doctor.sh)" "scripts/: both"
assert_eq "provision=true bootstrap=false" "$(gate mise.lock)" "repo toolchain: provision (macOS job)"
assert_eq "provision=true bootstrap=false" "$(gate $wf/provision.yml)" "provision.yml: provision only"
assert_eq "provision=false bootstrap=true" "$(gate install.sh)" "install.sh: bootstrap only"
assert_eq "provision=false bootstrap=true" "$(gate $wf/bootstrap.yml)" "bootstrap.yml: bootstrap only"
assert_eq "provision=true bootstrap=true" "$(gate README.md $wf/ci.yml)" "ci.yml: everything"
assert_eq "provision=true bootstrap=true" "$(gate $filter)" "the filter itself: everything"
assert_eq "provision=true bootstrap=true" "$(sh "$filter" --full </dev/null | paste -sd' ' -)" "--full: everything"
assert_eq "provision=false bootstrap=false" "$(sh "$filter" </dev/null | paste -sd' ' -)" "no changes: nothing gated runs"

# filter_paths_exist: a renamed file must not silently drop out of the filter
while IFS= read -r p; do
	[ -e "$p" ] || fail "filter names a missing path: $p"
done < <(grep -v '^[[:space:]]*#' "$filter" | grep -oE '(\.github/[a-z/-]+|[a-z]+)\.(sh|yml|toml|lock)|\.chezmoiroot')

# closure ROOT...: repo scripts transitively referenced from ROOTs
closure() {
	local seen=$'\n' queue=("$@") f r
	while ((${#queue[@]})); do
		f="${queue[0]}"
		queue=("${queue[@]:1}")
		[[ $seen == *$'\n'"$f"$'\n'* ]] && continue
		seen+="$f"$'\n'
		[ -f "$f" ] || continue
		while IFS= read -r r; do
			[ -f "$r" ] && queue+=("$r")
		done < <(grep -ohE '(\.github/scripts|scripts)/[A-Za-z0-9_-]+\.sh' "$f" | sort -u)
	done
	printf '%s' "$seen" | grep -E '^(\.github/scripts|scripts)/.*\.sh$'
}

# filter_covers_closure: every script a gated workflow (or what it deploys)
# reaches must trigger that workflow.
deployed=()
while IFS= read -r f; do deployed+=("$f"); done < <(git ls-files ansible home)
for s in $(closure $wf/provision.yml "${deployed[@]}"); do
	assert_contains "$(gate "$s")" "provision=true" "$s (reached from provision) triggers provision"
done
for s in $(closure $wf/bootstrap.yml install.sh "${deployed[@]}"); do
	assert_contains "$(gate "$s")" "bootstrap=true" "$s (reached from bootstrap) triggers bootstrap"
done

# ci_yml_wiring: callees are reusable, only ci.yml runs on PRs, the gate
# needs every other job.
for w in lint provision bootstrap; do
	assert_eq "true" "$(yq '.on | has("workflow_call")' "$wf/$w.yml")" "$w.yml is reusable"
	assert_eq "./$wf/$w.yml" "$(yq ".jobs.$w.uses" "$wf/ci.yml")" "ci.yml calls $w.yml"
done
for f in "$wf"/*.yml; do
	[ "$f" = "$wf/ci.yml" ] && continue
	assert_eq "false" "$(yq '.on | has("pull_request")' "$f")" "$f does not run on pull_request"
done
assert_eq "true" "$(yq '.on | has("pull_request")' "$wf/ci.yml")" "ci.yml runs on pull_request"
assert_eq "$(yq '.jobs | keys | .[] | select(. != "ci-gate")' "$wf/ci.yml" | sort | paste -sd, -)" \
	"$(yq '.jobs.ci-gate.needs[]' "$wf/ci.yml" | sort | paste -sd, -)" "ci-gate needs every other job"
assert_eq "always()" "$(yq '.jobs.ci-gate.if' "$wf/ci.yml")" "ci-gate runs even when a need failed"
