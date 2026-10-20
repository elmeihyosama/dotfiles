#!/bin/sh
# One-command bootstrap for a fresh machine:
#
#   curl -fsSL https://elmeihyosama.github.io/dotfiles/install.sh | sh
#
# Clones or fast-forwards the repo, installs Ansible, prompts once for
# ansible/local.yml (reused unless --reconfigure), then runs the playbook.
# DOTFILES_REPO and DOTFILES_DIR override the source repo and destination.
set -eu

REPO_URL="${DOTFILES_REPO:-https://github.com/elmeihyosama/dotfiles.git}"
DEST="${DOTFILES_DIR:-$HOME/workspace/dotfiles}"

# "true" when one $HOME is shared across CPU arches; ensure_local_vars sets the
# real value. Matches shared_home in ansible/group_vars/all.yml.
SHARED_HOME=false

have() { command -v "$1" >/dev/null 2>&1; }

# Arch-suffixed under a shared $HOME so binaries don't collide; mirrors
# ansible/group_vars/all.yml.
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

# gv_pin KEY FILE: the value of `KEY: "X"` in group_vars (sed: no Ansible yet).
gv_pin() { sed -nE "s/^$1:[[:space:]]*\"([^\"]*)\".*/\\1/p" "$2"; }

sha256_of() {
	if have sha256sum; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

# Install a pinned, sha256-checked uv, then the pinned ansible-core on the
# pinned uv Python (versions from ansible/group_vars/all.yml; dirs match
# ansible/tasks/python.yml).
ensure_ansible() {
	_gv=ansible/group_vars/all.yml
	_uv_version="$(gv_pin uv_version "$_gv")"
	_ansible_version="$(gv_pin ansible_core_version "$_gv")"
	_python_version="$(gv_pin python_version "$_gv")"
	if [ -z "$_uv_version" ] || [ -z "$_ansible_version" ] || [ -z "$_python_version" ]; then
		echo "uv_version / ansible_core_version / python_version not found in $_gv" >&2
		exit 1
	fi
	_lbin="$(local_bin_dir)"
	_lshare="$(local_share_dir)"
	if "$_lbin/ansible-playbook" --version 2>/dev/null | head -n1 | grep -qF "[core $_ansible_version]"; then
		return
	fi
	# Under a shared $HOME a `uv` on PATH may be the other arch's binary.
	_uv="$_lbin/uv"
	if ! "$_uv" --version 2>/dev/null | grep -qF "uv $_uv_version"; then
		have curl || {
			echo "curl is required to install uv; install it and re-run." >&2
			exit 1
		}
		# uv publishes no installer checksum; scripts/relock.sh records one. The
		# installer then checks the uv archive against its embedded sha256.
		_uv_sha="$(gv_pin uv_installer_sha256 "$_gv")"
		_uv_inst="$(mktemp)"
		curl -LsSf "https://github.com/astral-sh/uv/releases/download/$_uv_version/uv-installer.sh" -o "$_uv_inst"
		if [ "$(sha256_of "$_uv_inst")" != "$_uv_sha" ]; then
			rm -f "$_uv_inst"
			echo "uv $_uv_version installer does not match uv_installer_sha256 in $_gv (run scripts/relock.sh after a uv bump)." >&2
			exit 1
		fi
		# UV_NO_MODIFY_PATH: chezmoi owns the shell rc files.
		env XDG_BIN_HOME="$_lbin" UV_NO_MODIFY_PATH=1 sh "$_uv_inst"
		rm -f "$_uv_inst"
	fi
	XDG_BIN_HOME="$_lbin" \
		UV_PYTHON_INSTALL_DIR="$_lshare/uv/python" \
		UV_TOOL_DIR="$_lshare/uv/tools" \
		"$_uv" tool install --force --python "$_python_version" "ansible-core==$_ansible_version"
	export PATH="$_lbin:$HOME/.local/bin:$PATH"
}

# `[ -r /dev/tty ]` passes in CI/cron yet the open fails, so try opening it.
have_tty() { (exec >/dev/tty) 2>/dev/null; }

# ask "Question" "default": prompts via the tty, since under `curl | sh` stdin
# is the script.
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

# Single-quoted YAML: only '' needs escaping, so any name round-trips.
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

	_key_def=""
	# shellcheck disable=SC2088  # literal ~, stored unexpanded
	[ -f "$HOME/.ssh/id_ed25519.pub" ] && _key_def="~/.ssh/id_ed25519.pub"
	_signing_key="$(ask "SSH public key for signing GitHub-identity commits (blank to skip)" "$_key_def")"

	if sudo -n true >/dev/null 2>&1; then _sudo_default="yes"; else _sudo_default="no"; fi
	_sudo_answer="$(ask "Allow sudo for native package installs? (yes/no)" "$_sudo_default")"
	case "$_sudo_answer" in [Yy]*) _allow_sudo="true" ;; *) _allow_sudo="false" ;; esac

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
	if [ -n "$_signing_key" ]; then
		printf 'signing_key: %s\n' "$(yaml_quote "$_signing_key")" >>ansible/local.yml
	fi
	echo "Wrote ansible/local.yml."
}

# --- Acquire the repo (skipped when run from inside a checkout) ---
# Under `curl | sh` $0 is "sh"; only trust $0 when it names this script.
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
		# Never pull over local changes: the repo's git config autostashes,
		# which could leave conflict markers. Same rule as `dotfiles update`.
		_dirty="$(git -C "$DEST" status --porcelain 2>/dev/null | cut -c4- | paste -sd, - | sed 's/,/, /g')"
		if [ -n "$_dirty" ]; then
			echo "  (skipping update; local changes in: $_dirty; commit or discard them, then run \`dotfiles update\` once installed)"
		elif ! git -C "$DEST" -c merge.autostash=false -c rebase.autostash=false \
			pull --no-rebase --ff-only; then
			echo "  (skipping update; the pull failed; \`dotfiles update\` retries it once installed)"
		fi
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
# Our own flags out; the rest goes to ansible-playbook.
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

# local_vars first: it sets SHARED_HOME, which decides uv's dirs. PATH before
# ensure_ansible, or a prior uv install isn't found.
ensure_local_vars
_lbin="$(local_bin_dir)"
export PATH="$_lbin:$HOME/.local/bin:$PATH"
ensure_ansible

# Modules need the target's python3, which minimal hosts lack: fall back to
# the uv python behind ansible-core.
_uv_ansible_py="$(local_share_dir)/uv/tools/ansible-core/bin/python"
if ! have python3 && [ -x "$_uv_ansible_py" ]; then
	export ANSIBLE_PYTHON_INTERPRETER="$_uv_ansible_py"
fi

# Bare ansible-core has no collections; the playbook needs community.general.
ansible-galaxy collection install -r "$self_dir/ansible/requirements.yml" >/dev/null

# ansible reads ansible.cfg from cwd.
(cd "$self_dir/ansible" && ansible-playbook site.yml "$@")

# Non-fatal: the hook binary comes from the playbook.
if have pre-commit; then
	(cd "$self_dir" && pre-commit install) ||
		echo "warning: 'pre-commit install' failed — run it manually in the repo later" >&2
fi
