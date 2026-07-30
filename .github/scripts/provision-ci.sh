#!/usr/bin/env sh
# Provision the dotfiles env inside a distro container and assert the tools.
# MODE=sudo   -> run as root with allow_sudo=true  (native + shims + ubi fallback)
# MODE=nosudo -> run as an unprivileged user with allow_sudo=false (pure ubi)
set -eu

MODE="${MODE:?set MODE=sudo|nosudo}"

# --- Bootstrap deps via whichever package manager exists (we are root here) ---
if command -v apt-get >/dev/null 2>&1; then
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq python3 python3-pip git curl ca-certificates sudo >/dev/null
	pip install --quiet --break-system-packages ansible-core
elif command -v pacman >/dev/null 2>&1; then
	# ansible-core from pacman, not pip: pip's PyYAML in system site-packages
	# collides with pacman's python-yaml when the playbook later installs yq
	# (same source install.sh uses on real Arch machines).
	pacman -Sy --noconfirm --quiet python git curl sudo ansible-core >/dev/null
elif command -v dnf >/dev/null 2>&1; then
	# Fedora's python3 is new enough for ansible-core; EL (Rocky/Alma/RHEL) ships
	# too old, so pin python3.12. --allowerasing resolves the curl vs curl-minimal
	# conflict on EL9+.
	# shellcheck source=/dev/null
	. /etc/os-release
	if [ "${ID:-}" = "fedora" ]; then
		dnf install -y -q --allowerasing python3 python3-pip git curl sudo >/dev/null
		python3 -m pip install --quiet ansible-core
	else
		dnf install -y -q --allowerasing python3.12 python3.12-pip git curl sudo >/dev/null
		python3.12 -m pip install --quiet ansible-core
	fi
else
	echo "no supported package manager"
	exit 1
fi

# /usr/local/bin holds the EL python3.12 ansible-playbook; ~/.local/bin holds ubi tools.
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
# Install collections to a shared path so the unprivileged tester user can read them.
COLLECTIONS_PATH=/usr/share/ansible/collections
export ANSIBLE_COLLECTIONS_PATH="$COLLECTIONS_PATH"
ansible-galaxy collection install -r ansible/requirements.yml -p "$COLLECTIONS_PATH" >/dev/null
git config --global --add safe.directory "$PWD"

# ubi reads GITHUB_TOKEN from the env to raise its GitHub API rate limit; empty is fine.
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"

write_local() { # $1 = allow_sudo value
	printf '%s\n' '---' 'git_name: ci' 'git_email: ci@example.com' "allow_sudo: $1" 'shared_home: false' >ansible/local.yml
}

# Assert a captured playbook run changed nothing (idempotence). The PLAY RECAP is
# the only place `changed=N` appears (task lines use `changed: [host]`), so
# `changed=[1-9]` matches iff the run was not convergent. $1 = log file, $2 = mode.
assert_idempotent() {
	if grep -qE 'changed=[1-9]' "$1"; then
		echo "IDEMPOTENCE FAIL ($2): second run reported changes:"
		grep -E 'PLAY RECAP|changed=' "$1"
		exit 1
	fi
	echo "IDEMPOTENT ($2): second run reported changed=0"
}

# Run from ansible/ so its ansible.cfg loads (become=false, interpreter discovery,
# inventory) — both modes must run under the same config. Only the packages tag:
# fonts/chezmoi/sheldon/shell need a real home + TTY, out of scope for this matrix.
if [ "$MODE" = "sudo" ]; then
	write_local true
	(cd ansible && ansible-playbook site.yml --tags packages)
	# Some distro btop packages setcap the binary (cap_perfmon) so it can read
	# perf counters. A default container's capability bounding set can't grant
	# that, so exec'ing it fails with EPERM (even as root) — a container-only
	# artifact. Strip the cap so the smoke-test can run `btop --version`; real
	# machines keep it. Best-effort (setcap may be absent on distros that didn't
	# set the cap in the first place).
	if command -v setcap >/dev/null 2>&1 && command -v btop >/dev/null 2>&1; then
		setcap -r "$(command -v btop)" 2>/dev/null || true
	fi
	./.github/scripts/assert-tools.sh ansible/group_vars/all.yml
	# Second run must be a no-op (idempotence).
	(cd ansible && ansible-playbook site.yml --tags packages) >/tmp/run2.log 2>&1 || {
		cat /tmp/run2.log
		exit 1
	}
	cat /tmp/run2.log
	assert_idempotent /tmp/run2.log sudo
else
	# Genuine unprivileged user with NO sudo rights. Pass the token + collections
	# path inline — simple and portable across su versions; fine for a no-scope
	# token in an ephemeral single-tenant container.
	useradd -m tester
	write_local false
	chown -R tester "$PWD"
	su tester -c "cd '$PWD/ansible' && GITHUB_TOKEN='${GITHUB_TOKEN:-}' ANSIBLE_COLLECTIONS_PATH='$COLLECTIONS_PATH' ansible-playbook site.yml --tags packages"
	su tester -c "cd '$PWD' && ./.github/scripts/assert-tools.sh ansible/group_vars/all.yml"
	# Second run must be a no-op (idempotence), same invocation as the first.
	su tester -c "cd '$PWD/ansible' && GITHUB_TOKEN='${GITHUB_TOKEN:-}' ANSIBLE_COLLECTIONS_PATH='$COLLECTIONS_PATH' ansible-playbook site.yml --tags packages" >/tmp/run2.log 2>&1 || {
		cat /tmp/run2.log
		exit 1
	}
	cat /tmp/run2.log
	assert_idempotent /tmp/run2.log nosudo
fi
