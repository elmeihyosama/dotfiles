#!/bin/sh
# One-command bootstrap for a fresh machine:
#
#   curl -fsSL https://elmeihyosama.github.io/dotfiles/install.sh | sh
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
DEST="${DOTFILES_DIR:-$HOME/workspace/dotfiles}"

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

# gv_pin KEY FILE: the quoted value of a top-level `KEY: "X.Y.Z"` line in
# group_vars (read with sed: this runs before Ansible exists).
gv_pin() { sed -nE "s/^$1:[[:space:]]*\"([^\"]*)\".*/\\1/p" "$2"; }

# Install Ansible, the same way on every OS: a pinned uv (astral's versioned
# installer) into the local bin dir, then `uv tool install` of the pinned
# ansible-core (uv also provides the Python). Versions come from
# ansible/group_vars/all.yml (uv_version, ansible_core_version), which equal
# the repo mise.toml pins. Dirs match ansible/tasks/python.yml.
ensure_ansible() {
	_gv=ansible/group_vars/all.yml
	_uv_version="$(gv_pin uv_version "$_gv")"
	_ansible_version="$(gv_pin ansible_core_version "$_gv")"
	if [ -z "$_uv_version" ] || [ -z "$_ansible_version" ]; then
		echo "uv_version / ansible_core_version not found in $_gv" >&2
		exit 1
	fi
	_lbin="$(local_bin_dir)"
	_lshare="$(local_share_dir)"
	if "$_lbin/ansible-playbook" --version 2>/dev/null | head -n1 | grep -qF "[core $_ansible_version]"; then
		return
	fi
	# Under a shared $HOME a `uv` on PATH may be the other arch's binary (or
	# another version), so use the arch-local pinned one.
	_uv="$_lbin/uv"
	if ! "$_uv" --version 2>/dev/null | grep -qF "uv $_uv_version"; then
		have curl || {
			echo "curl is required to install uv; install it and re-run." >&2
			exit 1
		}
		# UV_NO_MODIFY_PATH: chezmoi owns the shell rc files; uv's PATH edits
		# would be drift that every apply reverts.
		curl -LsSf "https://astral.sh/uv/$_uv_version/install.sh" |
			env XDG_BIN_HOME="$_lbin" UV_NO_MODIFY_PATH=1 sh
	fi
	XDG_BIN_HOME="$_lbin" \
		UV_PYTHON_INSTALL_DIR="$_lshare/uv/python" \
		UV_TOOL_DIR="$_lshare/uv/tools" \
		"$_uv" tool install --force --python 3.13 "ansible-core==$_ansible_version"
	export PATH="$_lbin:$HOME/.local/bin:$PATH"
}

# True only when the terminal can actually be opened: `[ -r /dev/tty ]` passes in
# CI/cron yet the open fails ("Device not configured").
have_tty() { (exec >/dev/tty) 2>/dev/null; }

# ask "Question" "default" -> echoes the chosen value. Prompts via the tty, since
# under `curl | sh` stdin is the script, not the keyboard.
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

# Single-quoted YAML scalar: no escapes except '' for a literal quote, so any
# name (quotes, backslashes, colons) round-trips.
yaml_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

ensure_local_vars() {
	if [ -f ansible/local.yml ] && [ "$reconfigure" -eq 0 ]; then
		echo "Using existing ansible/local.yml (pass --reconfigure to change)."
		# Recover shared_home so ensure_ansible's uv paths match the playbook's.
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
git_name: $(yaml_quote "$_name")
git_email: $(yaml_quote "$_email")
allow_sudo: $_allow_sudo
shared_home: $SHARED_HOME
EOF
	echo "Wrote ansible/local.yml."
}

# --- Acquire the repo (skipped when already running from inside a checkout) ---
# Under `curl | sh` $0 is just "sh", and dirname would wrongly resolve to the
# caller's cwd; only trust $0 when it names this script.
case "$0" in
*install.sh) self_dir="$(CDPATH='' cd "$(dirname "$0")" && pwd)" ;;
*) self_dir="" ;;
esac
if [ -z "$self_dir" ] || [ ! -f "$self_dir/ansible/site.yml" ]; then
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

# local_vars first: it resolves SHARED_HOME, which decides uv's install dirs.
# PATH before ensure_ansible, or a prior uv install isn't found and re-runs.
ensure_local_vars
_lbin="$(local_bin_dir)"
export PATH="$_lbin:$HOME/.local/bin:$PATH"
ensure_ansible

# Ansible modules run on the target's python3, which minimal hosts lack; fall
# back to the uv python behind ansible-core (here, so reruns get it too).
_uv_ansible_py="$(local_share_dir)/uv/tools/ansible-core/bin/python"
if ! have python3 && [ -x "$_uv_ansible_py" ]; then
	export ANSIBLE_PYTHON_INTERPRETER="$_uv_ansible_py"
fi

# Bare ansible-core ships no collections, and the playbook fails at parse time
# without community.general. Already-installed collections are skipped.
ansible-galaxy collection install -r "$self_dir/ansible/requirements.yml" >/dev/null

# Run from ansible/ so its ansible.cfg is loaded (ansible reads it from cwd).
(cd "$self_dir/ansible" && ansible-playbook site.yml "$@")

# Wire up the repo's pre-commit hook (binary installed by the playbook). Non-fatal.
if have pre-commit; then
	(cd "$self_dir" && pre-commit install) ||
		echo "warning: 'pre-commit install' failed — run it manually in the repo later" >&2
fi
