#!/usr/bin/env bash
# ci.yml + .github/scripts/ci-changes.sh: one PR workflow gates the rest.
source "$(dirname "$0")/lib.sh"
cd "$TESTS_REPO" || exit 1

filter=.github/scripts/ci-changes.sh
wf=.github/workflows

# gate PATH... -> "bootstrap=X" for that change set
gate() { printf '%s\n' "$@" | sh "$filter" | paste -sd' ' -; }

# path_cases
assert_eq "bootstrap=false" "$(gate README.md docs/mise.md docs/themes.md)" "docs only: nothing gated runs"
assert_eq "bootstrap=false" "$(gate tests/prompt.test.sh .github/scripts/lint.sh)" "lint-only paths: nothing gated runs"
for p in mise.toml mise.lock .mise/locks/pipx-ansible-core/x/uv.lock; do
	assert_eq "bootstrap=false" "$(gate "$p")" "repo toolchain $p: lint only"
done
for p in home/dot_zshrc.tmpl ansible/site.yml scripts/doctor.sh install.sh $wf/bootstrap.yml $wf/ci.yml "$filter"; do
	assert_eq "bootstrap=true" "$(gate README.md "$p")" "$p: bootstrap"
done
assert_eq "bootstrap=true" "$(sh "$filter" --full </dev/null)" "--full: everything"
assert_eq "bootstrap=false" "$(sh "$filter" </dev/null)" "no changes: nothing gated runs"

# filter_paths_exist: a renamed file must not silently drop out of the filter
n=0
while IFS= read -r p; do
	n=$((n + 1))
	[ -e "$p" ] || fail "filter names a missing path: $p"
done < <(grep -v '^[[:space:]]*#' "$filter" | grep -oE '(\.github/[a-z/-]+|[a-z]+)\.(sh|yml|toml|lock)|\.chezmoiroot')
# a reformat that hides every path from the grep must not pass vacuously
[ "$n" -ge 8 ] || fail "filter path check saw only $n paths (want >= 8)"

# closure ROOT...: repo scripts transitively referenced from ROOTs
closure() {
	local seen=$'\n' queue=("$@") f r refs
	while ((${#queue[@]})); do
		f="${queue[0]}"
		queue=("${queue[@]:1}")
		[[ $seen == *$'\n'"$f"$'\n'* ]] && continue
		seen+="$f"$'\n'
		[ -f "$f" ] || continue
		# a here-string, not < <(...): bash 3.2 leaks a pipe per process
		# substitution, and at the fd limit this loop spun forever
		refs="$(grep -ohE '(\.github/scripts|scripts)/[A-Za-z0-9_-]+\.sh' "$f" | sort -u)"
		while IFS= read -r r; do
			[ -f "$r" ] && queue+=("$r")
		done <<<"$refs"
	done
	printf '%s' "$seen" | grep -E '^(\.github/scripts|scripts)/.*\.sh$'
}

# filter_covers_closure: every script a gated workflow (or what it deploys)
# reaches must trigger that workflow.
deployed=()
while IFS= read -r f; do deployed+=("$f"); done < <(git ls-files ansible home)
for s in $(closure $wf/bootstrap.yml install.sh "${deployed[@]}"); do
	assert_contains "$(gate "$s")" "bootstrap=true" "$s (reached from bootstrap) triggers bootstrap"
done

# ci_yml_wiring: callees are reusable, only ci.yml runs on PRs, the gate
# needs every other job.
for w in lint bootstrap; do
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
