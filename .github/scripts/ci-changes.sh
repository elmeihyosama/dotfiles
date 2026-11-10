#!/usr/bin/env sh
# Decide whether a change needs the gated bootstrap workflow (ci.yml's
# `changes` job).
# Usage: ci-changes.sh [--full] <changed-paths
# Prints bootstrap=true|false.
set -eu

bootstrap=false
[ "${1:-}" = --full ] && bootstrap=true

while IFS= read -r p; do
	case "$p" in
	# The gate itself, what the playbook deploys, the scripts it, CI or doctor
	# run, and the entry point.
	.github/workflows/ci.yml | .github/scripts/ci-changes.sh | \
		ansible/* | home/* | scripts/* | .chezmoiroot | \
		.github/scripts/assert-tools.sh | .github/scripts/assert-idempotent.sh | \
		install.sh | .github/scripts/bootstrap-smoke.sh | .github/workflows/bootstrap.yml)
		bootstrap=true
		;;
	esac
done

echo "bootstrap=$bootstrap"
