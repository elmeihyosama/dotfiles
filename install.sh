#!/bin/sh
# One-command bootstrap for a fresh machine:
#
#   sh -c "$(curl -fsSL https://elmeihyosama.github.io/dotfiles/install.sh)"
#
# Clones (or reuses) the repo, installs Ansible, prompts once for per-machine
# values, then runs the playbook. Idempotent: an existing clone is
# fast-forwarded (never clobbered), a saved ansible/local.yml is reused unless
# --reconfigure is passed, and the playbook only changes what has drifted.
#
# Run from anywhere (it self-clones) or from inside a checkout (./install.sh).
# Override the source repo with DOTFILES_REPO and the destination with
# DOTFILES_DIR.
set -eu

REPO_URL="${DOTFILES_REPO:-https://github.com/elmeihyosama/dotfiles.git}"
DEST="${DOTFILES_DIR:-$HOME/dotfiles}"

# Set to "true" on hosts that share one $HOME across CPU arches (e.g. a mounted
# home reachable from both x86_64 and aarch64 login nodes). ensure_local_vars
# resolves the real value from the prompt or an existing local.yml; kept in
# sync with ansible/group_vars/all.yml's shared_home logic.
SHARED_HOME=false

have() { command -v "$1" >/dev/null 2>&1; }

# User-local bin/share dirs, arch-suffixed under a shared $HOME so ARM and x86
# binaries don't collide. Mirror ansible/group_vars/all.yml exactly.
local_bin_dir() {
	if [ "$SHARED_HOME" = "true" ]; then
		printf '%s' "$HOME/.local/bin-$(uname -m)"
	else
		printf '%s' "$HOME/.local/bin"
	fi
}
local_share_dir() {
	if [ "$SHARED_HOME" = "true" ]; then
		printf '%s' "$HOME/.local/share-$(uname -m)"
	else
		printf '%s' "$HOME/.local/share"
	fi
}

# Install Ansible: native where sudo is available, else user-local via uv.
ensure_ansible() {
	if have ansible-playbook; then return; fi
	case "$(uname -s)" in
	Darwin)
		if ! have brew; then
			echo "Homebrew required on macOS; install from https://brew.sh first." >&2
			exit 1
		fi
		brew install ansible
		;;
	Linux)
		if sudo -n true >/dev/null 2>&1 && have apt-get; then
			sudo apt-get update && sudo apt-get install -y ansible
		elif sudo -n true >/dev/null 2>&1 && have pacman; then
			sudo pacman -Sy --noconfirm ansible
		else
			# no-sudo fallback: uv → ansible-core (uv also provides Python if missing).
			# Redirect uv's outputs to the (possibly arch-suffixed) local dirs so a
			# shared $HOME keeps each arch's binaries and venvs separate — matches the
			# XDG_BIN_HOME/UV_* env in ansible/tasks/python.yml.
			_lbin="$(local_bin_dir)"
			_lshare="$(local_share_dir)"
			# In shared-home mode a `uv` already on PATH may be the OTHER arch's
			# binary (exec-format error on `uv tool install`), so require the
			# arch-local $_lbin/uv explicitly; single-arch hosts accept any uv.
			if [ "$SHARED_HOME" = "true" ]; then
				_uv="$_lbin/uv"
				[ -x "$_uv" ] || _need_uv=1
			else
				_uv="uv"
				have uv || _need_uv=1
			fi
			if [ "${_need_uv:-0}" = 1 ]; then
				curl -LsSf https://astral.sh/uv/install.sh | XDG_BIN_HOME="$_lbin" sh
				export PATH="$_lbin:$HOME/.local/bin:$PATH"
				_uv="$_lbin/uv"
			fi
			XDG_BIN_HOME="$_lbin" \
				UV_PYTHON_INSTALL_DIR="$_lshare/uv/python" \
				UV_TOOL_DIR="$_lshare/uv/tools" \
				"$_uv" tool install ansible-core
			export PATH="$_lbin:$HOME/.local/bin:$PATH"
		fi
		;;
	*)
		echo "Unsupported OS: $(uname -s)" >&2
		exit 1
		;;
	esac
}

# ask "Question" "default" -> echoes the chosen value (prompt goes to the tty,
# so it works under `sh -c "$(curl ...)"` where stdin isn't the keyboard).
# True only when the controlling terminal can actually be opened. `[ -r /dev/tty ]`
# is not enough: the device node can pass that test yet fail to open in CI/cron/
# piped contexts ("Device not configured").
have_tty() { (exec >/dev/tty) 2>/dev/null; }

ask() {
	_q="$1"
	_def="${2:-}"
	_ans=""
	if have_tty; then
		if [ -n "$_def" ]; then
			printf '%s [%s]: ' "$_q" "$_def" >/dev/tty
		else
			printf '%s: ' "$_q" >/dev/tty
		fi
		IFS= read -r _ans </dev/tty || true
	fi
	printf '%s' "${_ans:-$_def}"
}

ensure_local_vars() {
	if [ -f ansible/local.yml ] && [ "$reconfigure" -eq 0 ]; then
		echo "Using existing ansible/local.yml (pass --reconfigure to change)."
		# Recover shared_home so ensure_ansible's uv output paths match what the
		# playbook will use (absent key → default false).
		if grep -Eq '^[[:space:]]*shared_home:[[:space:]]*true([[:space:]]|$)' ansible/local.yml; then
			SHARED_HOME=true
		fi
		return
	fi

	echo "Configuring ansible/local.yml (per-machine values)…"
	_name="$(ask "Git user name" "$(git config --global user.name 2>/dev/null || true)")"
	if [ -z "$_name" ] && have_tty; then
		_name="$(ask "Git user name (required)" "")"
	fi
	_email="$(ask "Git email" "$(git config --global user.email 2>/dev/null || true)")"
	if [ -z "$_email" ] && have_tty; then
		_email="$(ask "Git email (required)" "")"
	fi

	if sudo -n true >/dev/null 2>&1; then _sudo_default="yes"; else _sudo_default="no"; fi
	_sudo_answer="$(ask "Allow sudo for native package installs? (yes/no)" "$_sudo_default")"
	case "$_sudo_answer" in [Yy]*) _allow_sudo="true" ;; *) _allow_sudo="false" ;; esac

	# Only relevant on the rare shared-$HOME multi-arch host; default no.
	_shared_answer="$(ask "Is this \$HOME shared across CPU arches (arm+x86)? (yes/no)" "no")"
	case "$_shared_answer" in [Yy]*) SHARED_HOME="true" ;; *) SHARED_HOME="false" ;; esac

	cat >ansible/local.yml <<EOF
---
# Generated by install.sh. Edit freely or re-run with --reconfigure.
git_name: "$_name"
git_email: "$_email"
allow_sudo: $_allow_sudo
shared_home: $SHARED_HOME
EOF
	echo "Wrote ansible/local.yml."
}

# --- Acquire the repo (skipped when already running from inside a checkout) ---
self_dir="$(CDPATH='' cd "$(dirname "$0")" && pwd)"
if [ ! -f "$self_dir/ansible/site.yml" ]; then
	have git || {
		echo "git is required to clone the repository; install it and re-run." >&2
		exit 1
	}
	if [ -d "$DEST/.git" ]; then
		echo "Reusing existing clone at $DEST"
		git -C "$DEST" pull --ff-only || echo "  (skipping update; resolve local changes by hand)"
	elif [ -e "$DEST" ]; then
		echo "$DEST exists but is not a git clone; move it aside or set DOTFILES_DIR." >&2
		exit 1
	else
		echo "Cloning $REPO_URL -> $DEST"
		git clone "$REPO_URL" "$DEST"
	fi
	exec sh "$DEST/install.sh" "$@"
fi
cd "$self_dir"

# --- Provision (running from inside the repo) ---
# Filter out our own flags, leaving any extra args for ansible-playbook.
reconfigure=0
n=$#
while [ "$n" -gt 0 ]; do
	arg="$1"
	shift
	case "$arg" in
	--reconfigure) reconfigure=1 ;;
	*) set -- "$@" "$arg" ;;
	esac
	n=$((n - 1))
done

# local_vars first: it resolves SHARED_HOME, which ensure_ansible needs to place
# uv's binaries/venvs in the correct (possibly arch-suffixed) local dirs.
ensure_local_vars
ensure_ansible
_lbin="$(local_bin_dir)"
export PATH="$_lbin:$HOME/.local/bin:$PATH"

# Run from ansible/ so its ansible.cfg is loaded (ansible reads it from cwd).
(cd "$self_dir/ansible" && ansible-playbook site.yml "$@")

# Wire up the repo's pre-commit hook (binary installed by the playbook). Non-fatal.
if have pre-commit; then
	(cd "$self_dir" && pre-commit install) ||
		echo "warning: 'pre-commit install' failed — run it manually in the repo later" >&2
fi
