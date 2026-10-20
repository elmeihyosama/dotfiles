#!/usr/bin/env bash
# The TUI: ruff plus Textual pilot tests against a stub CLI (tests/tui/).
source "$(dirname "$0")/lib.sh"

command -v uv >/dev/null 2>&1 || {
	fail "uv not on PATH (the repo mise.toml pins it)"
	exit 1
}
out="$(cd "$TESTS_REPO" && uv run --quiet --locked --script tests/tui/test_tui.py 2>&1)" || {
	fail "tests/tui/test_tui.py"
	printf '%s\n' "$out" >&2
}
