#!/usr/bin/env sh
# Smoke-test the fresh-machine bootstrap: run install.sh end-to-end in a clean
# Ubuntu container — the surface the provision matrix does not cover. This
# exercises the self-clone (curl | sh) path, promptless local.yml generation,
# ensure_ansible (native apt under sudo, uv -> ansible-core without), the FULL
# playbook (every tag, not just packages), and second-run idempotence.
# MODE=sudo|nosudo, same contract as provision-ci.sh.
set -eu

MODE="${MODE:?set MODE=sudo|nosudo}"

# Base deps a stock cloud image ships; deliberately NOT python or ansible —
# install.sh must provide those itself.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl ca-certificates sudo >/dev/null

# ubi reads GITHUB_TOKEN to raise its API rate limit; empty is fine.
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# In CI the mounted checkout sits at a detached HEAD; cloning that yields no
# checkout. Pin a branch and point HEAD at it so install.sh's plain
# `git clone` of /repo gets this exact tree. Skip when HEAD is already on a
# branch (retry attempts reuse the same checkout, local runs mount a clone).
# Both paths: git resolves a non-bare source repo to its .git dir when cloning
# from a local path, and on CI runners /repo belongs to the runner uid, not
# container root (Docker Desktop's uid mapping masks this locally).
git config --global --add safe.directory /repo
git config --global --add safe.directory /repo/.git
if ! git -C /repo symbolic-ref -q HEAD >/dev/null; then
	git -C /repo branch -f _bootstrap-smoke HEAD
	git -C /repo symbolic-ref HEAD refs/heads/_bootstrap-smoke
fi

# Run a COPY of install.sh from outside any checkout so it takes the
# self-clone + exec path, exactly like `sh -c "$(curl ...)"` on a fresh box.
cp /repo/install.sh /tmp/install.sh

assert_idempotent() { # $1 = log file
	# A run that never reached ansible must not pass vacuously.
	if ! grep -q '^PLAY RECAP' "$1"; then
		echo "IDEMPOTENCE FAIL: second install.sh run produced no ansible recap:"
		cat "$1"
		exit 1
	fi
	if grep -qE 'changed=[1-9]' "$1"; then
		echo "IDEMPOTENCE FAIL: second install.sh run reported changes:"
		grep -E 'PLAY RECAP|changed=' "$1"
		exit 1
	fi
	echo "IDEMPOTENT: second run reported changed=0"
}

if [ "$MODE" = "sudo" ]; then
	# Root with working sudo -> install.sh's apt path for ansible itself.
	git config --global user.name ci-smoke
	git config --global user.email ci-smoke@example.com
	DOTFILES_REPO=/repo DOTFILES_DIR="$HOME/dotfiles" sh /tmp/install.sh
	export PATH="$HOME/.local/bin:$PATH"
	# Distro btop packages may carry cap_perfmon, which a container's bounding
	# set can't grant — exec fails with EPERM. Container-only artifact; strip it
	# so --version runs (same workaround as provision-ci.sh).
	if command -v setcap >/dev/null 2>&1 && command -v btop >/dev/null 2>&1; then
		setcap -r "$(command -v btop)" 2>/dev/null || true
	fi
	(cd "$HOME/dotfiles" && ./.github/scripts/assert-tools.sh ansible/group_vars/all.yml)
	test -f "$HOME/.zshrc" || {
		echo "FAIL: chezmoi did not apply (~/.zshrc missing)"
		exit 1
	}
	find "$HOME/.local/share/fonts" -name '*NerdFont*' | grep -q . || {
		echo "FAIL: Nerd Font not installed"
		exit 1
	}
	sh "$HOME/dotfiles/install.sh" >/tmp/run2.log 2>&1 || {
		cat /tmp/run2.log
		exit 1
	}
	cat /tmp/run2.log
	assert_idempotent /tmp/run2.log
else
	# Genuine unprivileged user, no sudoers entry -> install.sh's uv fallback.
	useradd -m tester
	# Both paths: git's dubious-ownership check resolves a non-bare source
	# repo to its .git dir when cloning from a local path.
	su tester -c "git config --global --add safe.directory /repo"
	su tester -c "git config --global --add safe.directory /repo/.git"
	su tester -c "git config --global user.name ci-smoke"
	su tester -c "git config --global user.email ci-smoke@example.com"
	su tester -c "GITHUB_TOKEN='$GITHUB_TOKEN' DOTFILES_REPO=/repo DOTFILES_DIR=\$HOME/dotfiles sh /tmp/install.sh"
	su tester -c "cd \$HOME/dotfiles && PATH=\$HOME/.local/bin:\$PATH ./.github/scripts/assert-tools.sh ansible/group_vars/all.yml"
	su tester -c "test -f \$HOME/.zshrc" || {
		echo "FAIL: chezmoi did not apply (~/.zshrc missing)"
		exit 1
	}
	su tester -c "find \$HOME/.local/share/fonts -name '*NerdFont*' | grep -q ." || {
		echo "FAIL: Nerd Font not installed"
		exit 1
	}
	su tester -c "GITHUB_TOKEN='$GITHUB_TOKEN' sh \$HOME/dotfiles/install.sh" >/tmp/run2.log 2>&1 || {
		cat /tmp/run2.log
		exit 1
	}
	cat /tmp/run2.log
	assert_idempotent /tmp/run2.log
fi
