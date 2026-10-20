#!/usr/bin/env sh
# Provision the dotfiles env inside a distro container and assert the tools.
# MODE=sudo   -> run as root with allow_sudo=true  (mise tools + native essentials)
# MODE=nosudo -> run as an unprivileged user with allow_sudo=false (mise tools only)
set -eu

MODE="${MODE:?set MODE=sudo|nosudo}"

# --- Bootstrap deps (we are root here) ---
# ansible-core at install.sh's pinned version, so the matrix tests what users
# get; Arch keeps pacman's (see below).
gv_pin() { sed -nE "s/^$1:[[:space:]]*\"([^\"]*)\".*/\\1/p" ansible/group_vars/all.yml; }
ANSIBLE_CORE="$(gv_pin ansible_core_version)"
UV="$(gv_pin uv_version)"
PY="$(gv_pin python_version)"
[ -n "$ANSIBLE_CORE" ] && [ -n "$UV" ] && [ -n "$PY" ] || {
	echo "ansible_core_version / uv_version / python_version not found in ansible/group_vars/all.yml"
	exit 1
}
# install_ansible PYTHON: pinned ansible-core into /usr/local/bin, via pip when
# PYTHON >= 3.12, else (Debian 12) via the pinned uv and Python as install.sh
# does. Under /opt so the unprivileged tester can run it.
install_ansible() {
	if "$1" -c 'import sys; sys.exit(sys.version_info < (3, 12))'; then
		"$1" -m pip install --quiet --break-system-packages "ansible-core==$ANSIBLE_CORE"
	else
		"$1" -m pip install --quiet --break-system-packages "uv==$UV"
		UV_TOOL_DIR=/opt/uv/tools UV_TOOL_BIN_DIR=/usr/local/bin UV_PYTHON_INSTALL_DIR=/opt/uv/python \
			"$1" -m uv tool install --quiet --python "$PY" "ansible-core==$ANSIBLE_CORE"
	fi
}
if command -v apt-get >/dev/null 2>&1; then
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq python3 python3-pip git curl ca-certificates sudo >/dev/null
	install_ansible python3
elif command -v pacman >/dev/null 2>&1; then
	# pacman's ansible-core: pip's PyYAML would collide with python-yaml
	# when the playbook installs yq.
	pacman -Sy --noconfirm --quiet python git curl sudo ansible-core >/dev/null
elif command -v dnf >/dev/null 2>&1; then
	# EL's python3 is too old: pin python3.12. EL's curl-minimal conflicts
	# with curl, so leave it for the playbook to meet as on a stock host.
	# shellcheck source=/dev/null
	. /etc/os-release
	if [ "${ID:-}" = "fedora" ]; then
		dnf install -y -q --allowerasing python3 python3-pip git curl sudo >/dev/null
		install_ansible python3
	else
		dnf install -y -q python3.12 python3.12-pip git sudo >/dev/null
		install_ansible python3.12
	fi
else
	echo "no supported package manager"
	exit 1
fi

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
# A shared path, readable by the unprivileged tester.
COLLECTIONS_PATH=/usr/share/ansible/collections
export ANSIBLE_COLLECTIONS_PATH="$COLLECTIONS_PATH"
ansible-galaxy collection install -r ansible/requirements.yml -p "$COLLECTIONS_PATH" >/dev/null
git config --global --add safe.directory "$PWD"

# Raises mise's GitHub API rate limit; empty is fine.
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"

write_local() { # $1 = allow_sudo value
	printf '%s\n' '---' 'git_name: ci' 'git_email: ci@example.com' "allow_sudo: $1" 'shared_home: false' >ansible/local.yml
}

# From ansible/ so its ansible.cfg loads in both modes. chezmoi deploys the
# full mise pins the second locked install reads.
if [ "$MODE" = "sudo" ]; then
	write_local true
	(cd ansible && ansible-playbook site.yml --tags packages,chezmoi)
	# Some distro btops setcap cap_perfmon, which a container's bounding
	# set can't grant (EPERM even as root): strip it for the smoke test.
	if command -v setcap >/dev/null 2>&1 && command -v btop >/dev/null 2>&1; then
		setcap -r "$(command -v btop)" 2>/dev/null || true
	fi
	./.github/scripts/assert-tools.sh
	# Second run must be a no-op.
	(cd ansible && ansible-playbook site.yml --tags packages,chezmoi) >/tmp/run2.log 2>&1 || {
		cat /tmp/run2.log
		exit 1
	}
	cat /tmp/run2.log
	sh .github/scripts/assert-idempotent.sh /tmp/run2.log
else
	# A real unprivileged user without sudo; token passed inline (no-scope
	# token, ephemeral container).
	useradd -m tester
	write_local false
	chown -R tester "$PWD"
	su tester -c "cd '$PWD/ansible' && GITHUB_TOKEN='${GITHUB_TOKEN:-}' ANSIBLE_COLLECTIONS_PATH='$COLLECTIONS_PATH' ansible-playbook site.yml --tags packages,chezmoi"
	su tester -c "cd '$PWD' && ./.github/scripts/assert-tools.sh"
	# Second run must be a no-op.
	su tester -c "cd '$PWD/ansible' && GITHUB_TOKEN='${GITHUB_TOKEN:-}' ANSIBLE_COLLECTIONS_PATH='$COLLECTIONS_PATH' ansible-playbook site.yml --tags packages,chezmoi" >/tmp/run2.log 2>&1 || {
		cat /tmp/run2.log
		exit 1
	}
	cat /tmp/run2.log
	sh .github/scripts/assert-idempotent.sh /tmp/run2.log
fi
