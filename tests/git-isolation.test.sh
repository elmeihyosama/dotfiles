#!/usr/bin/env bash
# Tests run from a git hook inherit GIT_DIR etc. pointing at the real repo.
# With those aimed at a decoy, the decoy and its origin must stay untouched:
# run.sh drops them centrally, and cli-update.test.sh (which once pushed to
# the real main) drops them itself when run standalone.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for _v in $(git rev-parse --local-env-vars); do unset "$_v"; done
mk_home
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

die() {
	echo "FATAL: $1" >&2
	exit 1
}
decoy="$HOME/decoy"
git init -q --bare "$HOME/decoy-origin.git" || die "init decoy origin"
git init -q "$decoy" || die "init decoy"
[ "$(git -C "$decoy" rev-parse --show-toplevel)" = "$(cd "$decoy" && pwd -P)" ] || die "decoy is not its own repo"
git -C "$decoy" symbolic-ref HEAD refs/heads/main || die "decoy branch"
echo real >"$decoy/f.txt"
git -C "$decoy" add -A || die "decoy add"
git -C "$decoy" commit -q -m real || die "decoy commit"
git -C "$decoy" remote add origin "$HOME/decoy-origin.git" || die "decoy remote"
git -C "$decoy" push -q origin HEAD:main || die "decoy push"
echo staged >"$decoy/g.txt"
git -C "$decoy" add g.txt || die "decoy stage"

snapshot() {
	git -C "$decoy" rev-parse HEAD
	git -C "$decoy" for-each-ref
	git -C "$decoy" status --porcelain
	git -C "$decoy" stash list
	git -C "$decoy" config --local --list
	cksum <"$decoy/.git/index"
	git -C "$HOME/decoy-origin.git" for-each-ref
}
before="$(snapshot)"
# as a pre-commit hook would see it
leak=(GIT_DIR="$decoy/.git" GIT_INDEX_FILE="$decoy/.git/index" GIT_WORK_TREE="$decoy")

# run.sh, central guard: a probe test with no guard of its own
probe_dir="$HOME/probe-tests"
mkdir -p "$probe_dir"
cat >"$probe_dir/probe.test.sh" <<'PROBE'
#!/usr/bin/env bash
# deliberately unguarded: any inherited GIT_DIR would take these
mkdir -p "$HOME/probe-cwd" && cd "$HOME/probe-cwd" || exit 1
echo leak >leak.txt
git add -A 2>/dev/null
git commit -q -m leak 2>/dev/null
git push -q origin HEAD:main 2>/dev/null
git config user.name leaked 2>/dev/null
exit 0
PROBE
env "${leak[@]}" TESTS_DIR="$probe_dir" bash "$TESTS_REPO/tests/run.sh" probe >/dev/null 2>&1
assert_eq "$before" "$(snapshot)" "run_sh_guard: decoy untouched by an unguarded test"

# cli-update.test.sh standalone: its own guard
env "${leak[@]}" bash "$TESTS_REPO/tests/cli-update.test.sh" >"$HOME/cli-update.out" 2>&1 ||
	fail "cli_update_guard: cli-update.test.sh failed under a leaked GIT_DIR: $(cat "$HOME/cli-update.out")"
assert_eq "$before" "$(snapshot)" "cli_update_guard: decoy untouched"
