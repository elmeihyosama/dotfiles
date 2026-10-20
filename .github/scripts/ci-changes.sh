#!/usr/bin/env sh
# Decide which gated CI workflows a change needs (ci.yml's `changes` job).
# Usage: ci-changes.sh [--full] <changed-paths
# Prints provision=true|false and bootstrap=true|false, one per line.
set -eu

provision=false
bootstrap=false
[ "${1:-}" = --full ] && provision=true bootstrap=true

while IFS= read -r p; do
	case "$p" in
	# The gate itself: run everything.
	.github/workflows/ci.yml | .github/scripts/ci-changes.sh)
		provision=true bootstrap=true
		;;
	# Both: what the playbook deploys and the scripts it, CI or doctor run.
	ansible/* | home/* | scripts/* | .chezmoiroot | \
		.github/scripts/assert-tools.sh | .github/scripts/assert-idempotent.sh)
		provision=true bootstrap=true
		;;
	# The macOS job installs ansible from the repo toolchain.
	mise.toml | mise.lock | .mise/* | \
		.github/scripts/provision-ci.sh | .github/workflows/provision.yml)
		provision=true
		;;
	install.sh | .github/scripts/bootstrap-smoke.sh | .github/workflows/bootstrap.yml)
		bootstrap=true
		;;
	esac
done

echo "provision=$provision"
echo "bootstrap=$bootstrap"
