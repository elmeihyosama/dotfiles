#!/usr/bin/env bash
# scripts/dotfiles.sh update [--check]: refuses a dirty repo, runs the seven
# steps in order and stops at the first failure, sheldon lock --update only when
# plugins.toml changed, doctor's exit code is update's, and --check changes
# nothing, survives a failed fetch, and never prompts (no tty, no colour).
# The repo is a temp clone of a temp bare repo with scripts/ committed into it,
# so the script finds its repo from its own path exactly as in real use.
# ansible-playbook, chezmoi, sheldon, nvim, mise and doctor.sh are stubs that
# log their calls; git, yq and jq are the real ones.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# run from a git hook (pre-commit) GIT_DIR / GIT_INDEX_FILE point at the real
# repo; the temp repos below must never see them
for _v in $(git rev-parse --local-env-vars); do unset "$_v"; done
mk_home
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
"ansible-playbook "*) printf 'env GIT_TERMINAL_PROMPT=%s\n' "${GIT_TERMINAL_PROMPT-unset}" >>"$LOG.env" ;;
"chezmoi diff"*) echo "diff --git a/.zshrc b/.zshrc"; exit 0 ;;
"mise -C / ls --json") cat "$STUB_MISE_LS"; exit 0 ;;
esac
[ "${STUB_FAIL:-}" != "$n" ] || exit 1
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

# fresh_repo: new bare + clone ("$clone") with scripts/ committed and pushed,
# a stub doctor.sh, and plugins.toml / .lazy-lock.json tracked.
fresh_repo() {
	rm -rf "$HOME/bare.git" "$HOME/clone" "$HOME/other"
	git init -q --bare -b main "$HOME/bare.git"
	git clone -q "$HOME/bare.git" "$HOME/clone" 2>/dev/null
	clone="$HOME/clone"
	cp -R "$TESTS_REPO/scripts" "$clone/scripts"
	# shellcheck disable=SC2016 # the stub expands $LOG itself
	printf '#!/bin/sh\necho "doctor.sh $*" >>"$LOG"\nexit "${STUB_DOCTOR_RC:-0}"\n' >"$clone/scripts/doctor.sh"
	mkdir -p "$clone/ansible" "$clone/home/dot_config/sheldon" "$clone/home/dot_config/nvim"
	echo 'v1' >"$clone/home/dot_config/sheldon/plugins.toml"
	echo '{}' >"$clone/home/dot_config/nvim/.lazy-lock.json"
	touch "$clone/ansible/site.yml"
	git -C "$clone" add -A
	git -C "$clone" commit -q -m init
	git -C "$clone" push -q -u origin HEAD:main 2>/dev/null
	git -C "$clone" branch -q -u origin/main 2>/dev/null
	: >"$LOG"
	: >"$LOG.env"
}
# upstream_commit FILE CONTENT MSG: push a commit from a second clone
upstream_commit() {
	[ -d "$HOME/other" ] || git clone -q "$HOME/bare.git" "$HOME/other" 2>/dev/null || {
		fail "upstream_commit: cannot clone the bare repo"
		return 1
	}
	mkdir -p "$(dirname "$HOME/other/$1")"
	printf '%s\n' "$2" >"$HOME/other/$1"
	git -C "$HOME/other" add -A
	git -C "$HOME/other" commit -q -m "$3"
	git -C "$HOME/other" push -q origin HEAD:main 2>/dev/null
}
run() { # run ARGS...: sets out, rc, in a no-tty env
	out="$(cd / && env -i HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin:$git_dir" LOG="$LOG" STUB_MISE_LS="$STUB_MISE_LS" \
		${STUB_FAIL:+STUB_FAIL="$STUB_FAIL"} ${STUB_DOCTOR_RC:+STUB_DOCTOR_RC="$STUB_DOCTOR_RC"} \
		DOTFILES_LOCAL_YML="$HOME/local.yml" DOTFILES_TOOLS_YAML="$HOME/tools.yaml" \
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
assert_eq "==> git pull --ff-only|==> ansible-playbook site.yml|==> chezmoi apply|==> sheldon lock|==> nvim Lazy! restore|==> dotfiles doctor|" "$hdr" "happy_path_order: headers"
assert_eq "upstream" "$(git -C "$clone" log -1 --format=%s)" "happy_path_order: pulled"
assert_eq "" "$(git -C "$clone" status --porcelain)" "happy_path_order: repo clean"

# pins changed upstream: sheldon lock --update
fresh_repo
upstream_commit home/dot_config/sheldon/plugins.toml v2 "bump pins"
run update
assert_eq 0 "$rc" "sheldon_update: exit 0"
assert_contains "$(steps_only)" "sheldon lock --update" "sheldon_update: pins changed"
# unrelated commit, then plugins.toml untouched: plain lock (covered above); and
# already up to date with no new commits: plain lock too
fresh_repo
run update
assert_contains "$(steps_only)" "sheldon lock" "up_to_date: runs"
assert_not_contains "$(steps_only)" "--update" "up_to_date: plain sheldon lock"

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
assert_eq 0 "$rc" "check: exit 0 ($out)"
assert_contains "$out" "incoming change" "check: incoming commits"
assert_contains "$out" "diff --git a/.zshrc b/.zshrc" "check: chezmoi diff"
assert_contains "$out" "hx" "check: pending install (not installed)"
assert_contains "$out" "zed" "check: pending install (version differs)"
assert_not_contains "$out" "alpha" "check: installed tool is not pending"
assert_eq "chezmoi diff --exclude scripts" "$(grep -v '^mise ' "$LOG")" "check: only chezmoi diff called"
assert_eq "mise -C / ls --json" "$(grep '^mise ' "$LOG" | sort -u)" "check: mise only reads"
assert_eq "$before" "$(git -C "$clone" rev-parse HEAD)" "check: HEAD unchanged"
assert_eq "" "$(git -C "$clone" stash list)" "check: no stash"
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
assert_eq "env GIT_TERMINAL_PROMPT=0" "$(head -1 "$LOG.env")" "no_tty: git never prompts"
case "$out" in *$'\r'* | *$'\033'*) fail "no_tty: output has CR or ANSI escapes" ;; esac
assert_contains "$(cat "$LOG")" "nvim --headless" "no_tty: nvim headless"
