#!/usr/bin/env sh
# Provision the dotfiles env inside a distro container and assert the tools.
# MODE=sudo   -> run as root with allow_sudo=true  (mise tools + native essentials)
# MODE=nosudo -> run as an unprivileged user with allow_sudo=false (mise tools only)
set -eu

MODE="${MODE:?set MODE=sudo|nosudo}"

# --- Bootstrap deps via whichever package manager exists (we are root here) ---
# ansible-core at the version users get (install.sh: ansible_core_version in
# group_vars), so the matrix tests the same Ansible. Arch keeps pacman's (see
# below).
gv_pin() { sed -nE "s/^$1:[[:space:]]*\"([^\"]*)\".*/\\1/p" ansible/group_vars/all.yml; }
ANSIBLE_CORE="$(gv_pin ansible_core_version)"
UV="$(gv_pin uv_version)"
PY="$(gv_pin python_version)"
[ -n "$ANSIBLE_CORE" ] && [ -n "$UV" ] && [ -n "$PY" ] || {
	echo "ansible_core_version / uv_version / python_version not found in ansible/group_vars/all.yml"
	exit 1
}
# install_ansible PYTHON: the pinned ansible-core into /usr/local/bin. Through
# PYTHON's pip when it meets ansible-core's floor (3.12); otherwise (Debian 12
# ships 3.11) through the pinned uv with the pinned uv-managed Python, as
# install.sh does. Under /opt so the unprivileged tester can run it too.
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
	# ansible-core from pacman, not pip: pip's PyYAML in system site-packages
	# collides with pacman's python-yaml when the playbook later installs yq
	# (same source install.sh uses on real Arch machines).
	pacman -Sy --noconfirm --quiet python git curl sudo ansible-core >/dev/null
elif command -v dnf >/dev/null 2>&1; then
	# Fedora's python3 is new enough for ansible-core; EL (Rocky/Alma/RHEL) ships
	# too old, so pin python3.12. EL images ship curl-minimal, which conflicts
	# with the curl package: leave it alone (no curl, no --allowerasing here) so
	# the playbook's essentials task meets a stock EL host.
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

# /usr/local/bin holds the EL python3.12 ansible-playbook; ~/.local/bin holds mise.
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
# Install collections to a shared path so the unprivileged tester user can read them.
COLLECTIONS_PATH=/usr/share/ansible/collections
export ANSIBLE_COLLECTIONS_PATH="$COLLECTIONS_PATH"
ansible-galaxy collection install -r ansible/requirements.yml -p "$COLLECTIONS_PATH" >/dev/null
git config --global --add safe.directory "$PWD"

# mise reads GITHUB_TOKEN from the env to raise its GitHub API rate limit; empty is fine.
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"

write_local() { # $1 = allow_sudo value
	printf '%s\n' '---' 'git_name: ci' 'git_email: ci@example.com' "allow_sudo: $1" 'shared_home: false' >ansible/local.yml
}

# Run from ansible/ so its ansible.cfg loads (become=false, interpreter discovery,
# inventory) — both modes must run under the same config. Tags packages +
# chezmoi: chezmoi deploys the full mise pins that the second locked install
# reads (fonts/sheldon/shell are out of scope for this matrix).
if [ "$MODE" = "sudo" ]; then
	write_local true
	(cd ansible && ansible-playbook site.yml --tags packages,chezmoi)
	# Some distro btop packages setcap the binary (cap_perfmon) so it can read
	# perf counters. A default container's capability bounding set can't grant
	# that, so exec'ing it fails with EPERM (even as root) — a container-only
	# artifact. Strip the cap so the smoke-test can run `btop --version`; real
	# machines keep it. Best-effort (setcap may be absent on distros that didn't
	# set the cap in the first place).
	if command -v setcap >/dev/null 2>&1 && command -v btop >/dev/null 2>&1; then
		setcap -r "$(command -v btop)" 2>/dev/null || true
	fi
	./.github/scripts/assert-tools.sh
	# Second run must be a no-op (idempotence).
	(cd ansible && ansible-playbook site.yml --tags packages,chezmoi) >/tmp/run2.log 2>&1 || {
		cat /tmp/run2.log
		exit 1
	}
	cat /tmp/run2.log
	sh .github/scripts/assert-idempotent.sh /tmp/run2.log
else
	# Genuine unprivileged user with NO sudo rights. Pass the token + collections
	# path inline — simple and portable across su versions; fine for a no-scope
	# token in an ephemeral single-tenant container.
	useradd -m tester
	write_local false
	chown -R tester "$PWD"
	su tester -c "cd '$PWD/ansible' && GITHUB_TOKEN='${GITHUB_TOKEN:-}' ANSIBLE_COLLECTIONS_PATH='$COLLECTIONS_PATH' ansible-playbook site.yml --tags packages,chezmoi"
	su tester -c "cd '$PWD' && ./.github/scripts/assert-tools.sh"
	# Second run must be a no-op (idempotence), same invocation as the first.
	su tester -c "cd '$PWD/ansible' && GITHUB_TOKEN='${GITHUB_TOKEN:-}' ANSIBLE_COLLECTIONS_PATH='$COLLECTIONS_PATH' ansible-playbook site.yml --tags packages,chezmoi" >/tmp/run2.log 2>&1 || {
		cat /tmp/run2.log
		exit 1
	}
	cat /tmp/run2.log
	sh .github/scripts/assert-idempotent.sh /tmp/run2.log
fi
