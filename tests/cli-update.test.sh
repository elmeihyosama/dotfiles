#!/usr/bin/env bash
# scripts/dotfiles.sh update [--check]: dirty repo refused, steps in order,
# first failure stops it, sheldon --update only when plugins.toml changed,
# doctor's exit code wins, --check writes nothing and never prompts. A temp
# clone of a temp bare repo; the tools are logging stubs, git/yq/jq are real.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Under a git hook (pre-commit) GIT_DIR etc. point at the real repo; the temp
# repos must never see them.
for _v in $(git rev-parse --local-env-vars); do unset "$_v"; done
mk_home # also sets GIT_CEILING_DIRECTORIES: no repo discovery above $HOME
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
real_bin() {
	local d IFS=:
	for d in $PATH; do
		case "$d" in */shims | */shims/) continue ;; esac
		[ -x "$d/$1" ] && {
			echo "$d/$1"
			return 0
		}
	done
	return 1
}
mkdir -p "$HOME/bin"
for t in yq jq git; do
	real_bin "$t" >/dev/null || {
		echo "SKIP: no non-shim $t on PATH" >&2
		exit 0
	}
done
for t in yq jq; do ln -s "$(real_bin "$t")" "$HOME/bin/$t"; done
git_dir="$(dirname "$(real_bin git)")"

LOG="$HOME/calls.log"
export LOG
for s in ansible-playbook chezmoi sheldon nvim mise; do
	cat >"$HOME/bin/$s" <<'STUB'
#!/bin/sh
n="$(basename "$0")"
printf '%s %s\n' "$n" "$*" >>"$LOG"
case "$n $*" in
"ansible-playbook "*)
	printf 'env GIT_TERMINAL_PROMPT=%s\n' "${GIT_TERMINAL_PROMPT-unset}" >>"$LOG.env"
	printf 'env GIT_SSH_COMMAND=%s\n' "${GIT_SSH_COMMAND-unset}" >>"$LOG.env"
	printf 'env NO_COLOR=%s\n' "${NO_COLOR-unset}" >>"$LOG.env"
	printf 'cwd %s\n' "$(pwd -P)" >>"$LOG.env"
	;;
"chezmoi diff"*) echo "diff --git a/.zshrc b/.zshrc"; exit 0 ;;
"mise -C / ls --json") cat "$STUB_MISE_LS"; exit 0 ;;
esac
[ "${STUB_FAIL:-}" != "$n" ] || exit 1
[ "${STUB_FAIL_CMD:-}" != "$n $*" ] || exit 1
exit 0
STUB
	chmod +x "$HOME/bin/$s"
done
STUB_MISE_LS="$HOME/ls.json"
export STUB_MISE_LS
cat >"$STUB_MISE_LS" <<'J'
{"aqua:x/alpha": [{"version": "1.0.0", "installed": true, "active": true}],
"aqua:x/zed": [{"version": "1.5.0", "installed": true, "active": true}]}
J
printf '%s\n' '{tool_groups: [core, dev], tools: {' \
	'alpha: {group: core, backend: "aqua:x/alpha", version: "1.0.0"},' \
	'zed: {group: core, backend: "aqua:x/zed", version: "2.0.0"},' \
	'hx: {group: dev, backend: "aqua:x/hx", version: "3.0.0"}}}' >"$HOME/tools.yaml"
printf 'tool_groups: [core, dev]\n' >"$HOME/local.yml"

# die MSG: stop the test rather than run git against the wrong repo.
die() {
	echo "FATAL: $1" >&2
	exit 1
}
# fresh_repo: bare + clone ("$clone") with scripts/ committed; pushes name the
# bare repo by path, never `origin`.
fresh_repo() {
	rm -rf "$HOME/bare.git" "$HOME/clone" "$HOME/other"
	git init -q --bare "$HOME/bare.git" || die "git init --bare"
	git -C "$HOME/bare.git" symbolic-ref HEAD refs/heads/main || die "bare HEAD"
	git clone -q "$HOME/bare.git" "$HOME/clone" 2>/dev/null || die "git clone"
	clone="$HOME/clone"
	[ "$(git -C "$clone" rev-parse --show-toplevel)" = "$(cd "$clone" && pwd -P)" ] ||
		die "the clone is not its own repo"
	cp -R "$TESTS_REPO/scripts" "$clone/scripts" || die "copy scripts/"
	# shellcheck disable=SC2016 # the stub expands $LOG itself
	printf '#!/bin/sh\necho "doctor.sh $*" >>"$LOG"\nexit "${STUB_DOCTOR_RC:-0}"\n' >"$clone/scripts/doctor.sh"
	mkdir -p "$clone/ansible" "$clone/home/dot_config/sheldon" "$clone/home/dot_config/nvim"
	echo 'v1' >"$clone/home/dot_config/sheldon/plugins.toml"
	echo '{}' >"$clone/home/dot_config/nvim/.lazy-lock.json"
	touch "$clone/ansible/site.yml"
	git -C "$clone" symbolic-ref HEAD refs/heads/main || die "branch main"
	git -C "$clone" add -A || die "git add"
	git -C "$clone" commit -q -m init || die "git commit"
	git -C "$clone" push -q "$HOME/bare.git" HEAD:main || die "git push"
	git -C "$clone" fetch -q origin || die "git fetch"
	git -C "$clone" branch -q -u origin/main || die "set upstream"
	: >"$LOG"
	: >"$LOG.env"
}
# upstream_commit FILE CONTENT MSG: push a commit from a second clone
upstream_commit() {
	if [ ! -d "$HOME/other" ]; then
		git clone -q "$HOME/bare.git" "$HOME/other" 2>/dev/null || die "upstream_commit: git clone"
		[ "$(git -C "$HOME/other" rev-parse --show-toplevel)" = "$(cd "$HOME/other" && pwd -P)" ] ||
			die "upstream_commit: the clone is not its own repo"
	fi
	mkdir -p "$(dirname "$HOME/other/$1")"
	printf '%s\n' "$2" >"$HOME/other/$1"
	git -C "$HOME/other" add -A || die "upstream_commit: git add"
	git -C "$HOME/other" commit -q -m "$3" || die "upstream_commit: git commit"
	git -C "$HOME/other" push -q "$HOME/bare.git" HEAD:main || die "upstream_commit: git push"
}
run() { # run ARGS...: sets out, rc, in a no-tty env
	out="$(cd / && env -i HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin:$git_dir" LOG="$LOG" STUB_MISE_LS="$STUB_MISE_LS" \
		${STUB_FAIL:+STUB_FAIL="$STUB_FAIL"} ${STUB_DOCTOR_RC:+STUB_DOCTOR_RC="$STUB_DOCTOR_RC"} \
		DOTFILES_LOCAL_YML="$HOME/local.yml" DOTFILES_TOOLS_YAML="$HOME/tools.yaml" \
		GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" ${STUB_FAIL_CMD:+STUB_FAIL_CMD="$STUB_FAIL_CMD"} \
		sh "$clone/scripts/dotfiles.sh" "$@" </dev/null 2>&1)"
	rc=$?
}
steps_only() { grep -v '^mise ' "$LOG"; }

# dirty_refuses: modified tracked file and an untracked one; nothing changes
fresh_repo
echo changed >>"$clone/home/dot_config/sheldon/plugins.toml"
echo x >"$clone/stray.txt"
upstream_commit f.txt hi "upstream"
run update
assert_eq 1 "$rc" "dirty_refuses: exit 1"
assert_contains "$out" "dotfiles: repo has local changes (" "dirty_refuses: message"
assert_contains "$out" "home/dot_config/sheldon/plugins.toml" "dirty_refuses: names the tracked file"
assert_contains "$out" "stray.txt" "dirty_refuses: names the untracked file"
assert_contains "$out" "); commit or discard them, then re-run" "dirty_refuses: message tail"
assert_not_contains "$out" "nvim: update plugins" "dirty_refuses: no lazy-lock hint for other files"
assert_eq "" "$(cat "$LOG")" "dirty_refuses: nothing ran"
assert_eq "" "$(git -C "$clone" stash list)" "dirty_refuses: no stash"
assert_contains "$(git -C "$clone" status --porcelain)" "plugins.toml" "dirty_refuses: changes untouched"
assert_eq "init" "$(git -C "$clone" log -1 --format=%s)" "dirty_refuses: no pull"

# lazy_lock_hint: the only change is the nvim lockfile
fresh_repo
echo '{"a":1}' >"$clone/home/dot_config/nvim/.lazy-lock.json"
run update
assert_eq 1 "$rc" "lazy_lock_hint: exit 1"
assert_contains "$out" "repo has local changes (home/dot_config/nvim/.lazy-lock.json); commit or discard them, then re-run" "lazy_lock_hint: message"
assert_contains "$out" "git -C $clone commit -am \"nvim: update plugins\"" "lazy_lock_hint: commit hint"

# happy_path_order: seven steps, in order, with headers; sheldon lock (no --update)
fresh_repo
upstream_commit f.txt hi "upstream"
run update
assert_eq 0 "$rc" "happy_path_order: exit 0 ($out)"
assert_eq "ansible-playbook site.yml
chezmoi apply
sheldon lock
nvim --headless +Lazy! restore +qa
doctor.sh " "$(steps_only)" "happy_path_order: calls in order"
hdr="$(printf '%s\n' "$out" | grep '^==> ' | tr '\n' '|')"
assert_eq "==> check working tree|==> git pull --ff-only|==> ansible-playbook site.yml|==> chezmoi apply|==> sheldon lock|==> nvim Lazy! restore|==> dotfiles doctor|" "$hdr" "happy_path_order: headers"
assert_eq "upstream" "$(git -C "$clone" log -1 --format=%s)" "happy_path_order: pulled"
assert_eq "" "$(git -C "$clone" status --porcelain)" "happy_path_order: repo clean"
assert_eq "cwd $(cd "$clone/ansible" && pwd -P)" "$(grep '^cwd ' "$LOG.env")" "happy_path_order: playbook runs in ansible/"

# pins changed upstream: sheldon lock --update
fresh_repo
upstream_commit home/dot_config/sheldon/plugins.toml v2 "bump pins"
run update
assert_eq 0 "$rc" "sheldon_update: exit 0"
assert_contains "$(steps_only)" "sheldon lock --update" "sheldon_update: pins changed"
# plugins.toml untouched or no new commits: plain lock too
fresh_repo
run update
assert_contains "$(steps_only)" "sheldon lock" "up_to_date: runs"
assert_not_contains "$(steps_only)" "--update" "up_to_date: plain sheldon lock"

# plain lock fails (pin moved, rev not fetched): one retry with --update
fresh_repo
STUB_FAIL_CMD="sheldon lock" run update
assert_eq 0 "$rc" "sheldon_retry: exit 0 ($out)"
assert_eq "sheldon lock
sheldon lock --update" "$(steps_only | grep '^sheldon')" "sheldon_retry: retried with --update"
assert_contains "$(steps_only)" "doctor.sh" "sheldon_retry: later steps run"
# --update itself failing stops the run
fresh_repo
upstream_commit home/dot_config/sheldon/plugins.toml v2 "bump pins"
STUB_FAIL_CMD="sheldon lock --update" run update
assert_eq 1 "$rc" "sheldon_update_fails: exit 1"
assert_eq "sheldon lock --update" "$(steps_only | grep '^sheldon')" "sheldon_update_fails: no retry"
assert_not_contains "$(steps_only)" "doctor.sh" "sheldon_update_fails: doctor skipped"

# chezmoi apply fails with no tty: hint to run it in a terminal
fresh_repo
STUB_FAIL=chezmoi run update
assert_contains "$out" "chezmoi apply\` in a terminal" "chezmoi_no_tty: hint"

# first failure stops the run, exit 1
for failing in ansible-playbook chezmoi; do
	fresh_repo
	STUB_FAIL="$failing" run update
	assert_eq 1 "$rc" "stop_at_failure($failing): exit 1"
	assert_not_contains "$(steps_only)" "sheldon" "stop_at_failure($failing): later steps skipped"
	assert_not_contains "$(steps_only)" "doctor.sh" "stop_at_failure($failing): doctor skipped"
	assert_contains "$out" "dotfiles: update failed at" "stop_at_failure($failing): says where"
done
fresh_repo
STUB_FAIL=nvim run update
assert_eq 1 "$rc" "nvim_failure: exit 1"
assert_not_contains "$(steps_only)" "doctor.sh" "nvim_failure: doctor skipped"

# diverged branch: ff-only pull fails, nothing later runs, nothing is reset
fresh_repo
echo l >"$clone/local.txt"
git -C "$clone" add -A
git -C "$clone" commit -q -m local
upstream_commit f.txt hi "upstream"
run update
assert_eq 1 "$rc" "pull_fails: exit 1"
assert_eq "" "$(cat "$LOG")" "pull_fails: nothing after the pull"
assert_eq "local" "$(git -C "$clone" log -1 --format=%s)" "pull_fails: local commit kept"

# doctor's exit code is update's
fresh_repo
STUB_DOCTOR_RC=7 run update
assert_eq 7 "$rc" "doctor_rc: exit code propagates"

# usage
fresh_repo
run update --bogus
assert_eq 2 "$rc" "update_usage: unknown flag exits 2"

# check_changes_nothing: incoming commits, the diff, pending installs; no writes
fresh_repo
upstream_commit f.txt hi "incoming change"
before="$(git -C "$clone" rev-parse HEAD)"
echo dirty >>"$clone/home/dot_config/sheldon/plugins.toml" # --check needs no clean tree
run update --check
assert_eq 0 "$rc" "check_changes_nothing: exit 0 ($out)"
assert_contains "$out" "incoming change" "check_changes_nothing: incoming commits"
assert_contains "$out" "diff --git a/.zshrc b/.zshrc" "check_changes_nothing: chezmoi diff"
assert_contains "$out" "hx" "check_changes_nothing: pending install (not installed)"
assert_contains "$out" "zed" "check_changes_nothing: pending install (version differs)"
assert_not_contains "$out" "alpha" "check_changes_nothing: installed tool is not pending"
assert_eq "chezmoi diff --exclude scripts" "$(grep -v '^mise ' "$LOG")" "check_changes_nothing: only chezmoi diff called"
assert_eq "mise -C / ls --json" "$(grep '^mise ' "$LOG" | sort -u)" "check_changes_nothing: mise only reads"
assert_eq "$before" "$(git -C "$clone" rev-parse HEAD)" "check_changes_nothing: HEAD unchanged"
assert_eq "" "$(git -C "$clone" stash list)" "check_changes_nothing: no stash"
git -C "$clone" checkout -q -- . 2>/dev/null

# check_offline: fetch fails -> warning, still the diff and pending installs
fresh_repo
git -C "$clone" remote set-url origin "$HOME/does-not-exist.git"
run update --check
assert_eq 0 "$rc" "check_offline: exit 0 ($out)"
assert_contains "$out" "could not fetch" "check_offline: warning"
assert_contains "$out" "diff --git a/.zshrc b/.zshrc" "check_offline: still shows the diff"
assert_contains "$out" "hx" "check_offline: still shows pending installs"

# no_tty: no prompts, no colour, no carriage-return progress, nvim headless
fresh_repo
upstream_commit f.txt hi "x"
run update
assert_eq 0 "$rc" "no_tty: exit 0"
assert_contains "$(cat "$LOG.env")" "env GIT_TERMINAL_PROMPT=0" "no_tty: git never prompts"
assert_contains "$(cat "$LOG.env")" "env GIT_SSH_COMMAND=ssh -o BatchMode=yes -o ConnectTimeout=10" "no_tty: ssh never prompts or hangs"
assert_contains "$(cat "$LOG.env")" "env NO_COLOR=1" "no_tty: NO_COLOR reaches children"
case "$out" in *$'\r'* | *$'\033'*) fail "no_tty: output has CR or ANSI escapes" ;; esac
assert_contains "$(cat "$LOG")" "nvim --headless" "no_tty: nvim headless"
