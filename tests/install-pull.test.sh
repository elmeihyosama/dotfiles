#!/usr/bin/env bash
# install.sh reusing an existing clone: a dirty clone is never pulled (so never
# stashed, even with merge/rebase.autostash = true in the user's git config,
# which this repo's own git config sets) and the run goes on; a clean clone
# fast-forwards; a failed pull is non-fatal.
# install.sh is fed on stdin (the `curl | sh` path), DOTFILES_DIR is a temp
# clone of a temp bare repo, and the clone's own install.sh, which the real one
# execs, is a stub that logs and exits.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# run from a git hook, GIT_DIR / GIT_INDEX_FILE point at the real repo
for _v in $(git rev-parse --local-env-vars); do unset "$_v"; done
mk_home # also sets GIT_CEILING_DIRECTORIES: no repo discovery above $HOME
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# the user's config autostashes (home/dot_config/git/config.tmpl)
printf '[merge]\n\tautostash = true\n[rebase]\n\tautostash = true\n' >"$HOME/.gitconfig"
git_dir="$(dirname "$(command -v git)")"
LOG="$HOME/calls.log"

die() {
	echo "FATAL: $1" >&2
	exit 1
}
# own_repo DIR: DIR is a repo in its own right (not found by discovery above it)
own_repo() {
	[ "$(git -C "$1" rev-parse --show-toplevel)" = "$(cd "$1" && pwd -P)" ] || die "$1 is not its own repo"
}
# fresh: bare repo with a stub install.sh and a.txt, cloned to $dest
fresh() {
	rm -rf "$HOME/bare.git" "$HOME/seed" "$HOME/dest"
	git init -q --bare "$HOME/bare.git" || die "git init --bare"
	git -C "$HOME/bare.git" symbolic-ref HEAD refs/heads/main || die "bare HEAD"
	git init -q "$HOME/seed" || die "git init seed"
	own_repo "$HOME/seed"
	git -C "$HOME/seed" symbolic-ref HEAD refs/heads/main || die "seed branch"
	# shellcheck disable=SC2016 # the stub expands $LOG itself
	printf '#!/bin/sh\necho "stub install.sh $*" >>"$LOG"\n' >"$HOME/seed/install.sh"
	printf 'one\n' >"$HOME/seed/a.txt"
	git -C "$HOME/seed" add -A || die "seed add"
	git -C "$HOME/seed" commit -q -m init || die "seed commit"
	git -C "$HOME/seed" push -q "$HOME/bare.git" HEAD:main || die "seed push"
	git clone -q "$HOME/bare.git" "$HOME/dest" 2>/dev/null || die "git clone"
	dest="$HOME/dest"
	own_repo "$dest"
	: >"$LOG"
}
# upstream FILE CONTENT MSG: a new commit on the bare repo's main
upstream() {
	printf '%s\n' "$2" >"$HOME/seed/$1"
	git -C "$HOME/seed" add -A || die "upstream add"
	git -C "$HOME/seed" commit -q -m "$3" || die "upstream commit"
	git -C "$HOME/seed" push -q "$HOME/bare.git" HEAD:main || die "upstream push"
}
run_install() { # sets out, rc
	out="$(cd / && env -i HOME="$HOME" PATH="/usr/bin:/bin:$git_dir" LOG="$LOG" \
		GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
		DOTFILES_DIR="$dest" DOTFILES_REPO="$HOME/bare.git" \
		sh <"$TESTS_REPO/install.sh" 2>&1)"
	rc=$?
}

# dirty_conflicting: the local edit and the incoming commit touch the same file
fresh
upstream a.txt upstream-two "upstream edit"
printf 'mine\n' >"$dest/a.txt"
printf 'new\n' >"$dest/new.txt"
head_before="$(git -C "$dest" rev-parse HEAD)"
diff_before="$(git -C "$dest" diff)"
run_install
assert_eq 0 "$rc" "dirty_conflicting: exit 0 ($out)"
assert_contains "$out" "local changes in: a.txt, new.txt" "dirty_conflicting: names the dirty files"
assert_contains "$out" "dotfiles update" "dirty_conflicting: points to dotfiles update"
assert_eq "$head_before" "$(git -C "$dest" rev-parse HEAD)" "dirty_conflicting: not pulled"
assert_eq "" "$(git -C "$dest" stash list)" "dirty_conflicting: no stash"
assert_eq "$diff_before" "$(git -C "$dest" diff)" "dirty_conflicting: edit untouched"
assert_eq "mine" "$(cat "$dest/a.txt")" "dirty_conflicting: no conflict markers"
assert_eq "new" "$(cat "$dest/new.txt")" "dirty_conflicting: untracked file untouched"
assert_eq "stub install.sh " "$(cat "$LOG")" "dirty_conflicting: install goes on"

# dirty_disjoint: an edit the pull would not touch; still no pull, no stash
fresh
upstream b.txt b "upstream add"
printf 'mine\n' >"$dest/a.txt"
head_before="$(git -C "$dest" rev-parse HEAD)"
run_install
assert_eq 0 "$rc" "dirty_disjoint: exit 0 ($out)"
assert_eq "$head_before" "$(git -C "$dest" rev-parse HEAD)" "dirty_disjoint: not pulled"
assert_eq "" "$(git -C "$dest" stash list)" "dirty_disjoint: no stash"
assert_eq " M a.txt" "$(git -C "$dest" status --porcelain)" "dirty_disjoint: tree unchanged"

# clean_ff: a clean clone fast-forwards
fresh
upstream b.txt b "upstream add"
run_install
assert_eq 0 "$rc" "clean_ff: exit 0 ($out)"
assert_eq "upstream add" "$(git -C "$dest" log -1 --format=%s)" "clean_ff: fast-forwarded"
assert_eq "" "$(git -C "$dest" status --porcelain)" "clean_ff: tree clean"
assert_not_contains "$out" "skipping update" "clean_ff: no skip message"
assert_eq "stub install.sh " "$(cat "$LOG")" "clean_ff: install goes on"

# diverged: a local commit and an upstream one; ff-only fails, non-fatal
fresh
upstream b.txt b "upstream add"
printf 'local\n' >"$dest/c.txt"
git -C "$dest" add -A || die "local add"
git -C "$dest" commit -q -m local || die "local commit"
run_install
assert_eq 0 "$rc" "diverged: exit 0 ($out)"
assert_contains "$out" "the pull failed" "diverged: says the pull failed"
assert_eq "local" "$(git -C "$dest" log -1 --format=%s)" "diverged: local commit kept"
assert_eq "stub install.sh " "$(cat "$LOG")" "diverged: install goes on"
