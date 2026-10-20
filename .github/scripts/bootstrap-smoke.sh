#!/usr/bin/env sh
# Smoke-test install.sh end-to-end in a clean Ubuntu or Fedora container: the
# curl | sh self-clone, promptless local.yml, the full playbook, idempotence.
# MODE=sudo|nosudo, as in provision-ci.sh.
set -eu

MODE="${MODE:?set MODE=sudo|nosudo}"

# The first full apply must not hit a tool before it is installed. bash/zsh
# say "command not found"; dash says "sh: 1: x: not found".
assert_no_command_not_found() {
	if grep -iE 'command not found|: [0-9]+: [^:]+: not found' "$1"; then
		echo "FAIL: the first run logged 'command not found' (above)"
		exit 1
	fi
}

# Deliberately no python or ansible: install.sh must provide them.
if command -v apt-get >/dev/null 2>&1; then
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq git curl ca-certificates sudo >/dev/null
elif command -v dnf >/dev/null 2>&1; then
	dnf install -y -q git curl ca-certificates sudo >/dev/null
else
	echo "no supported package manager (need apt-get or dnf)"
	exit 1
fi

# Raises mise's API rate limit; empty is fine.
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# A detached HEAD clones to no checkout: point HEAD at a branch so install.sh's
# `git clone` of /repo gets this tree. Both safe.directory paths: git resolves
# a local non-bare source to its .git dir, and /repo belongs to the runner uid.
git config --global --add safe.directory /repo
git config --global --add safe.directory /repo/.git
if ! git -C /repo symbolic-ref -q HEAD >/dev/null; then
	git -C /repo branch -f _bootstrap-smoke HEAD
	git -C /repo symbolic-ref HEAD refs/heads/_bootstrap-smoke
fi

# A copy run from outside any checkout takes the self-clone path, as curl | sh.
cp /repo/install.sh /tmp/install.sh

if [ "$MODE" = "sudo" ]; then
	# Root with working sudo -> native essentials; ansible itself still via uv.
	git config --global user.name ci-smoke
	git config --global user.email ci-smoke@example.com
	DOTFILES_REPO=/repo DOTFILES_DIR="$HOME/workspace/dotfiles" sh /tmp/install.sh >/tmp/run1.log 2>&1 || {
		cat /tmp/run1.log
		exit 1
	}
	cat /tmp/run1.log
	assert_no_command_not_found /tmp/run1.log
	export PATH="$HOME/.local/bin:$PATH"
	# Strip btop's cap_perfmon (container-only EPERM), as in provision-ci.sh.
	if command -v setcap >/dev/null 2>&1 && command -v btop >/dev/null 2>&1; then
		setcap -r "$(command -v btop)" 2>/dev/null || true
	fi
	(cd "$HOME/workspace/dotfiles" && ./.github/scripts/assert-tools.sh)
	test -f "$HOME/.zshrc" || {
		echo "FAIL: chezmoi did not apply (~/.zshrc missing)"
		exit 1
	}
	find "$HOME/.local/share/fonts" -name '*NerdFont*' | grep -q . || {
		echo "FAIL: Nerd Font not installed"
		exit 1
	}
	sh "$HOME/workspace/dotfiles/install.sh" >/tmp/run2.log 2>&1 || {
		cat /tmp/run2.log
		exit 1
	}
	cat /tmp/run2.log
	sh /repo/.github/scripts/assert-idempotent.sh /tmp/run2.log
else
	# Unprivileged, no sudoers entry -> install.sh's uv fallback.
	useradd -m tester
	# Both paths: git resolves a local non-bare source to its .git dir.
	su tester -c "git config --global --add safe.directory /repo"
	su tester -c "git config --global --add safe.directory /repo/.git"
	su tester -c "git config --global user.name ci-smoke"
	su tester -c "git config --global user.email ci-smoke@example.com"
	su tester -c "GITHUB_TOKEN='$GITHUB_TOKEN' DOTFILES_REPO=/repo DOTFILES_DIR=\$HOME/workspace/dotfiles sh /tmp/install.sh" >/tmp/run1.log 2>&1 || {
		cat /tmp/run1.log
		exit 1
	}
	cat /tmp/run1.log
	assert_no_command_not_found /tmp/run1.log
	su tester -c "cd \$HOME/workspace/dotfiles && ./.github/scripts/assert-tools.sh"
	su tester -c "test -f \$HOME/.zshrc" || {
		echo "FAIL: chezmoi did not apply (~/.zshrc missing)"
		exit 1
	}
	su tester -c "find \$HOME/.local/share/fonts -name '*NerdFont*' | grep -q ." || {
		echo "FAIL: Nerd Font not installed"
		exit 1
	}
	su tester -c "GITHUB_TOKEN='$GITHUB_TOKEN' sh \$HOME/workspace/dotfiles/install.sh" >/tmp/run2.log 2>&1 || {
		cat /tmp/run2.log
		exit 1
	}
	cat /tmp/run2.log
	sh /repo/.github/scripts/assert-idempotent.sh /tmp/run2.log
fi
