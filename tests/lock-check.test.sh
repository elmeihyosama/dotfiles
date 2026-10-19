#!/usr/bin/env bash
# check-lock.sh gates every mise.lock: each tool needs a checksum for each
# locked platform, or an explicit (and still-needed) exception.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$TESTS_REPO/.github/scripts/check-lock.sh"
dir="$(mktemp -d)"
_tests_tmpdirs+=("$dir")

# plat_block TOOL PLATFORM: one platform table with a checksum.
plat_block() {
	printf '[tools."%s"."platforms.%s"]\nchecksum = "sha256:abc"\nurl = "https://example.invalid/x"\n' "$1" "$2"
}
# mk_lock FILE TOOL PLATFORM...: write a one-tool lock covering PLATFORMs.
mk_lock() {
	local file="$1" tool="$2" p
	shift 2
	printf '[[tools."%s"]]\nversion = "1.0.0"\nbackend = "%s"\n' "$tool" "$tool" >"$file"
	for p in "$@"; do plat_block "$tool" "$p" >>"$file"; done
}

# run_check ARGS...: capture output and status of the checker.
run_check() {
	out="$(bash "$script" "$@" 2>&1)"
	rc=$?
}

# complete_lock_passes (bare key too, to cover both key styles)
mk_lock "$dir/ok.lock" aqua:x/y macos-arm64 linux-x64 linux-arm64
run_check "$dir/ok.lock"
assert_eq 0 "$rc" "complete lock passes"
mk_lock "$dir/bare.lock" ripgrep macos-arm64 linux-x64 linux-arm64
run_check "$dir/bare.lock"
assert_eq 0 "$rc" "bare tool key passes"

# missing_checksum_fails
mk_lock "$dir/missing.lock" aqua:x/y macos-arm64 linux-x64
run_check "$dir/missing.lock"
assert_eq 1 "$rc" "missing checksum fails"
assert_contains "$out" "MISSING aqua:x/y linux-arm64" "names the missing platform"
assert_not_contains "$out" "MISSING aqua:x/y linux-x64" "does not flag present platform"

# exception_allows
printf '# comment\n\naqua:x/y linux-arm64  # no arm64 build\n' >"$dir/exc.txt"
run_check "$dir/missing.lock" "$dir/exc.txt"
assert_eq 0 "$rc" "exception allows the gap"
printf 'aqua:x/y *  # nothing built\n' >"$dir/star.txt"
mk_lock "$dir/none.lock" aqua:x/y
run_check "$dir/none.lock" "$dir/star.txt"
assert_eq 0 "$rc" "wildcard exception covers all platforms"

# stale_exception_fails
run_check "$dir/ok.lock" "$dir/exc.txt"
assert_eq 1 "$rc" "stale exception fails"
assert_contains "$out" "STALE-EXCEPTION aqua:x/y linux-arm64" "names the stale exception"
