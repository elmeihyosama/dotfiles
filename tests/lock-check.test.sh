#!/usr/bin/env bash
# check-lock.sh gates every mise.lock: each tool needs a checksum for each
# locked platform, unless tools.yaml says otherwise (no_checksum_on, native).
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

# pipx_tools_need_no_platform_checksum: a hash-pinned uv.lock covers them,
# but the lock must still record its digest.
printf '[[tools."pipx:x"]]\nversion = "1.0.0"\nuv = { path = ".mise/locks/pipx-x/1.0.0", digest = "sha256:aa" }\n' >"$dir/pipx.lock"
run_check "$dir/pipx.lock"
assert_eq 0 "$rc" "pipx tool with a uv.lock digest passes ($out)"
printf '[[tools."pipx:x"]]\nversion = "1.0.0"\n' >"$dir/pipx-nodigest.lock"
run_check "$dir/pipx-nodigest.lock"
assert_eq 1 "$rc" "pipx tool without a uv.lock digest fails"
assert_contains "$out" "MISSING pipx:x uv.lock digest" "names the missing digest"

# With TOOLS_YAML: no_checksum_on allows a gap; native / missing platforms skip.
# mk_tools FILE EXTRA: one tool y (backend aqua:x/y) with EXTRA yaml lines.
mk_tools() {
	printf 'tool_groups: [core]\ntools:\n  y:\n    group: core\n    backend: aqua:x/y\n    version: "1.0.0"\n%s' "$2" >"$1"
}
mk_tools "$dir/t-nocs.yaml" $'    no_checksum_on: [linux-arm64] # no sums upstream\n'
run_check "$dir/missing.lock" "$dir/t-nocs.yaml"
assert_eq 0 "$rc" "no_checksum_on allows the gap ($out)"
mk_tools "$dir/t-other.yaml" $'    no_checksum_on: [linux-x64] # no sums upstream\n'
run_check "$dir/missing.lock" "$dir/t-other.yaml"
assert_eq 1 "$rc" "no_checksum_on for another platform does not cover the gap"
assert_contains "$out" "MISSING aqua:x/y linux-arm64" "still names the gap"
mk_tools "$dir/t-plain.yaml" ''
run_check "$dir/missing.lock" "$dir/t-plain.yaml"
assert_eq 1 "$rc" "tools.yaml without no_checksum_on: gap fails"

# native_and_missing_platforms_skip: no checksum needed where mise does not install it
mk_lock "$dir/mac-only.lock" aqua:x/y macos-arm64
mk_tools "$dir/t-native.yaml" $'    native_on: [linux]\n'
run_check "$dir/mac-only.lock" "$dir/t-native.yaml"
assert_eq 0 "$rc" "native_on platforms are skipped ($out)"
mk_tools "$dir/t-missing.yaml" $'    missing_on: [linux-x64, linux-arm64]\n'
run_check "$dir/mac-only.lock" "$dir/t-missing.yaml"
assert_eq 0 "$rc" "missing_on platforms are skipped ($out)"
mk_tools "$dir/t-missing1.yaml" $'    missing_on: [linux-x64]\n'
run_check "$dir/mac-only.lock" "$dir/t-missing1.yaml"
assert_eq 1 "$rc" "missing_on skips only its own platforms"
assert_contains "$out" "MISSING aqua:x/y linux-arm64" "names the remaining gap"

# stale_no_checksum_on_fails: the checksum is there now, so the entry must go
run_check "$dir/ok.lock" "$dir/t-nocs.yaml"
assert_eq 1 "$rc" "stale no_checksum_on fails"
assert_contains "$out" "STALE-EXCEPTION aqua:x/y linux-arm64" "names the stale entry"
assert_contains "$out" "remove linux-arm64 from y.no_checksum_on" "says to remove it"

# no_checksum_on_needs_a_reason: a trailing # comment, else usage error (exit 2)
mk_tools "$dir/t-noreason.yaml" $'    no_checksum_on: [linux-arm64]\n'
run_check "$dir/missing.lock" "$dir/t-noreason.yaml"
assert_eq 2 "$rc" "no_checksum_on without a reason is rejected"
assert_contains "$out" "y.no_checksum_on" "names the tool lacking a reason"
mk_tools "$dir/t-badplat.yaml" $'    no_checksum_on: [linux-riscv] # x\n'
run_check "$dir/missing.lock" "$dir/t-badplat.yaml"
assert_eq 2 "$rc" "no_checksum_on with an unknown platform is rejected"
